import { ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionDeadline, ConnectionReuse, ConnectionState, ConnectionTimerPort, QueryCancellationResult, QueryOptions, SystemConnectionTimerPort } from '@arkdb/core';
import { createDefaultPostgresStartupRunner } from '../command/PostgresStartup';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandPhase, PostgresCommandScope } from '../execution/PostgresCommandGate';
import { PostgresCancelHandle, PostgresCancelTransport, awaitBoundedCleanup, dispatchPostgresCancelRequest, isPostgresInterruptionError } from '../execution/PostgresExecutionController';
import { PostgresCommandCloseSettlement, PostgresStartupSession, applyPostgresReadyStatus, postgresAppendCleanupError, postgresAppendDecomposedCleanup, resetPostgresSessionStatus, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresStatementDeadlineHost, runPostgresStatementDeadline } from '../execution/PostgresStatementDeadline';
import { PostgresConnectionConfig, PostgresSslConfig } from '../model/PostgresConnectionConfig';
import { PostgresDatabaseSessionStatus, PostgresError, PostgresServerInfo } from '../model/PostgresModels';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import { PostgresByteTransport, PostgresMessage, PostgresMessageChannel, PostgresReadyStatus } from '../protocol/PostgresMessageChannel';
import { PostgresTcpTransport } from '../transport/PostgresTcpTransport';

export const POSTGRES_TERMINATE_TIMEOUT_MS: number = 1000;
const MISSING_BACKEND_KEY_MSG: string = 'PostgreSQL server did not provide a backend cancellation key.';
const postgresLifecyclePasswords: WeakMap<PostgresConnectionLifecycle, string> = new WeakMap<PostgresConnectionLifecycle, string>();
const postgresBackendSecrets: WeakMap<PostgresConnectionLifecycle, PostgresBackendCancellationKey> = new WeakMap<PostgresConnectionLifecycle, PostgresBackendCancellationKey>();

export interface PostgresLifecycleTransport extends PostgresCancelTransport {
  connect(host: string, port: number, timeoutMs: number): Promise<void>;
  prepareTlsUpgrade?(): void;
  upgradeToTls?(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void>;
  close(): Promise<void>; abort(error: ArkDbError): Promise<void>;
}
export class PostgresBackendCancellationKey {
  readonly processId: number; readonly secretKey: Uint8Array; readonly secretKeyInt32: number;
  constructor(processId: number, secretKey: Uint8Array, secretKeyInt32: number) {
    this.processId = processId; this.secretKey = secretKey; this.secretKeyInt32 = secretKeyInt32;
  }
}
interface StartupCallbacks {
  enterAuth: () => void; readPassword: () => string;
  setBackendKey: (pid: number, key: Uint8Array) => void; applyReady: (ready: PostgresReadyStatus) => void;
}
export class PostgresStartupContext implements PostgresStartupSession {
  readonly scope: PostgresCommandScope; readonly config: PostgresConnectionConfig;
  readonly transport: PostgresLifecycleTransport; readonly channel: PostgresMessageChannel;
  readonly deadline: ConnectionDeadline; readonly settlement: PostgresCommandCloseSettlement;
  readonly serverInfo: PostgresServerInfo; private readonly cb: StartupCallbacks;
  constructor(scope: PostgresCommandScope, config: PostgresConnectionConfig, transport: PostgresLifecycleTransport,
    channel: PostgresMessageChannel, deadline: ConnectionDeadline, settlement: PostgresCommandCloseSettlement,
    serverInfo: PostgresServerInfo, cb: StartupCallbacks) {
    this.scope = scope; this.config = config; this.transport = transport; this.channel = channel;
    this.deadline = deadline; this.settlement = settlement; this.serverInfo = serverInfo; this.cb = cb;
  }
  enterAuthenticating(): void { this.cb.enterAuth(); }
  readPassword(): string { return this.cb.readPassword(); }
  setBackendKeyData(processId: number, secretKey: Uint8Array): void { this.cb.setBackendKey(processId, secretKey); }
  applyReadyStatus(ready: PostgresReadyStatus): void { this.cb.applyReady(ready); }
}
export type PostgresStartupRunner = (context: PostgresStartupContext) => Promise<void>;
export type PostgresCommandRunner<T> = (scope: PostgresCommandScope, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement) => Promise<T>;
class DefaultPostgresLifecycleTransport implements PostgresLifecycleTransport {
  private readonly inner: PostgresTcpTransport;
  constructor(timers: ConnectionTimerPort) { this.inner = new PostgresTcpTransport(undefined, undefined, timers); }
  connect(host: string, port: number, timeoutMs: number): Promise<void> { return this.inner.connect(host, port, timeoutMs); }
  prepareTlsUpgrade(): void { this.inner.prepareTlsUpgrade(); }
  upgradeToTls(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void> { return this.inner.upgradeToTls(host, port, config, timeoutMs); }
  read(maximumBytes: number): Promise<Uint8Array | null> { return this.inner.read(maximumBytes); }
  write(data: Uint8Array): Promise<number> { return this.inner.write(data); }
  close(): Promise<void> { return this.inner.close(); }
  abort(error: ArkDbError): Promise<void> { return this.inner.abort(error); }
}
class ScopedPostgresMessageChannel extends PostgresMessageChannel {
  private readonly onBegin: () => void; private readonly onEnd: (error: Object | null, isOwner: boolean) => Object;
  private readonly onDirection: (reading: boolean) => void;
  private activeToken: Object | null = null;
  constructor(transport: PostgresByteTransport, onBegin: () => void, onEnd: (error: Object | null, isOwner: boolean) => Object,
    onDirection: (reading: boolean) => void) {
    super(transport); this.onBegin = onBegin; this.onEnd = onEnd; this.onDirection = onDirection;
  }
  readMessage(maxFrameBytes?: number | ((frameBytes: number) => number)): Promise<PostgresMessage> { return this.guard<PostgresMessage>((): Promise<PostgresMessage> => { this.onDirection(true); return super.readMessage(maxFrameBytes); }); }
  writeMessage(type: number, payload: Uint8Array): Promise<void> { return this.guard<void>((): Promise<void> => { this.onDirection(false); return super.writeMessage(type, payload); }); }
  writeUntypedMessage(payload: Uint8Array): Promise<void> { return this.guard<void>((): Promise<void> => { this.onDirection(false); return super.writeUntypedMessage(payload); }); }
  private guard<T>(op: () => Promise<T>): Promise<T> {
    try { this.onBegin(); } catch (e) { return Promise.reject<T>(e as Object); }
    const token = new Object(); const isOwner = this.activeToken === null;
    if (isOwner) this.activeToken = token;
    const clear = (): void => { if (this.activeToken === token) this.activeToken = null; };
    try {
      return op().then((v: T): T => { clear(); this.onEnd(null, isOwner); return v; },
        (e: Object): Promise<T> => { clear(); return Promise.reject<T>(this.onEnd(e, isOwner)); });
    } catch (e) { clear(); return Promise.reject<T>(this.onEnd(e as Object, isOwner)); }
  }
}
class ScopedPostgresTransport implements PostgresLifecycleTransport {
  private readonly inner: PostgresLifecycleTransport;
  private readonly assertIoScope: () => void; private readonly assertRetireScope: () => void;
  private readonly onBeginIo: () => void; private readonly onEndIo: (damaged: ArkDbError | null) => void;
  private readonly onRetire: (reason: ArkDbError) => Promise<void>;
  private readonly onWriteDelta: ((delta: number) => void) | undefined;
  constructor(inner: PostgresLifecycleTransport, assertIoScope: () => void, assertRetireScope: () => void,
    onBeginIo: () => void, onEndIo: (damaged: ArkDbError | null) => void, onRetire: (reason: ArkDbError) => Promise<void>, onWriteDelta?: (delta: number) => void) {
    this.inner = inner; this.assertIoScope = assertIoScope; this.assertRetireScope = assertRetireScope;
    this.onBeginIo = onBeginIo; this.onEndIo = onEndIo; this.onRetire = onRetire; this.onWriteDelta = onWriteDelta;
  }
  connect(host: string, port: number, timeoutMs: number): Promise<void> { return this.guardIo<void>(ArkDbErrorKind.Network, (): Promise<void> => this.inner.connect(host, port, timeoutMs), (): ArkDbError | null => null); }
  prepareTlsUpgrade(): void {
    this.assertIoScope(); this.onBeginIo();
    try {
      if (this.inner.prepareTlsUpgrade === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable.');
      this.inner.prepareTlsUpgrade(); this.onEndIo(null);
    } catch (e) { const typed = toPostgresArkDbError(e as Object, ArkDbErrorKind.Tls); this.onEndIo(typed); throw typed; }
  }
  upgradeToTls(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void> {
    return this.guardIo<void>(ArkDbErrorKind.Tls, (): Promise<void> => {
      if (this.inner.upgradeToTls === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable.');
      return this.inner.upgradeToTls(host, port, config, timeoutMs);
    }, (): ArkDbError | null => null);
  }
  read(maxBytes: number): Promise<Uint8Array | null> {
    return this.guardIo<Uint8Array | null>(ArkDbErrorKind.Network, (): Promise<Uint8Array | null> => this.inner.read(maxBytes),
      (c: Uint8Array | null): ArkDbError | null => {
        if (!Number.isSafeInteger(maxBytes) || maxBytes < 0 || c === null || (maxBytes > 0 && c.length === 0) || c.length > maxBytes) {
          if (c !== null) c.fill(0);
          return ArkDbError.protocol('PostgreSQL transport read was incomplete.');
        }
        return null;
      });
  }
  write(data: Uint8Array): Promise<number> {
    return this.guardIo<number>(ArkDbErrorKind.Network, (): Promise<number> => {
      if (this.onWriteDelta !== undefined) this.onWriteDelta(1);
      return this.inner.write(data).finally((): void => { if (this.onWriteDelta !== undefined) this.onWriteDelta(-1); });
    }, (n: number): ArkDbError | null => !Number.isSafeInteger(n) || n !== data.length ? ArkDbError.protocol('PostgreSQL transport write was incomplete.') : null);
  }
  close(): Promise<void> { return this.guardRetire(ArkDbError.protocol('PostgreSQL transport closed during operation.')); }
  abort(error: ArkDbError): Promise<void> { return this.guardRetire(error); }
  private guardIo<T>(fallback: ArkDbErrorKind, op: () => Promise<T>, check: (val: T) => ArkDbError | null): Promise<T> {
    try { this.assertIoScope(); } catch (e) {
      const typed = toPostgresArkDbError(e as Object);
      if (typed.kind !== ArkDbErrorKind.Protocol) { this.onBeginIo(); this.onEndIo(typed); }
      return Promise.reject<T>(typed);
    }
    this.onBeginIo();
    try {
      return op().then((val: T): Promise<T> => { const damaged = check(val); this.onEndIo(damaged); return damaged !== null ? Promise.reject<T>(damaged) : Promise.resolve<T>(val); },
        (e: Object): Promise<T> => { const typed = toPostgresArkDbError(e, fallback); this.onEndIo(typed); return Promise.reject<T>(typed); });
    } catch (e) { const typed = toPostgresArkDbError(e as Object, fallback); this.onEndIo(typed); return Promise.reject<T>(typed); }
  }
  private guardRetire(reason: ArkDbError): Promise<void> { try { this.assertRetireScope(); return this.onRetire(reason); } catch (e) { return Promise.reject<void>(e as Object); } }
}

export class PostgresConnectionLifecycle {
  readonly timers: ConnectionTimerPort;
  readonly serverInfo: PostgresServerInfo = new PostgresServerInfo();
  readonly sessionStatus: PostgresDatabaseSessionStatus = new PostgresDatabaseSessionStatus();
  readonly commandGate: PostgresCommandGate;
  private readonly storedConfig: PostgresConnectionConfig;
  private readonly transportFactory: () => PostgresLifecycleTransport;
  private readonly startupRunner: PostgresStartupRunner;
  private currentState: ConnectionState = ConnectionState.Idle;
  private transport: PostgresLifecycleTransport | null = null;
  private opening: ConnectionDeadline | null = null;
  private activeSettlement: PostgresCommandCloseSettlement | null = null;
  private activeReleaseScope: PostgresCommandScope | null = null;
  private activeScopeRelease: Promise<ArkDbError | null> | null = null;
  private closedScope: PostgresCommandScope | null = null;
  private closedSettlement: PostgresCommandCloseSettlement | null = null;
  private closedSettlementTerminalError: ArkDbError | null = null;
  private awaitingClosedSettlement: boolean = false;
  private closing: Promise<void> | null = null;
  private releaseTask: Promise<ArkDbError | null> | null = null;
  private closeRequested: boolean = false;
  private readySynchronized: boolean = false;
  private pendingIoCount: number = 0; private pendingIoWaiters: Array<() => void> = [];
  private awaitingReadyForQuery: boolean = false; private unsynchronized: boolean = false;
  private deadlineRetiredScope: PostgresCommandScope | null = null; private deadlineAbortReason: ArkDbError | null = null; private activeDeadlineScope: PostgresCommandScope | null = null; private activeDeadlineStep: Promise<ArkDbError | null> | null = null;
  private wireExecutionEpoch: number = 0; private wireEpochActive: boolean = false; private wireEpochReading: boolean = false; private activeWireWriteCount: number = 0;
  private readonly wireDispatchWaiters: Set<() => void> = new Set<() => void>(); private readonly cancelSettleWaiters: Set<() => void> = new Set<() => void>();
  private readonly activeCancels: Set<PostgresCancelHandle> = new Set<PostgresCancelHandle>();
  private activeCancelScope: PostgresCommandScope | null = null; private activeCancelEpoch: number = 0; private activeCancelTask: Promise<QueryCancellationResult> | null = null;
  private latchedPrimaryError: ArkDbError | null = null; private lastConsumerError: ArkDbError | null = null; private synchronizedConsumerError: ArkDbError | null = null; private deadlineRootError: ArkDbError | null = null;
  private retiredReason: ArkDbError | null = null; private retiredCleanup: ArkDbError | null = null; private retiredComposed: ArkDbError | null = null;
  constructor(config: PostgresConnectionConfig, password: string, timers: ConnectionTimerPort = new SystemConnectionTimerPort(),
    transportFactory?: () => PostgresLifecycleTransport, startupRunner?: PostgresStartupRunner,
    commandGate: PostgresCommandGate = new PostgresCommandGate()) {
    const errors = config.validate();
    if (errors.length > 0) throw errors[0];
    this.storedConfig = config.clone(); this.timers = timers; this.commandGate = commandGate;
    this.transportFactory = transportFactory === undefined ? (): PostgresLifecycleTransport => new DefaultPostgresLifecycleTransport(this.timers) : transportFactory;
    this.startupRunner = startupRunner === undefined ? createDefaultPostgresStartupRunner() : startupRunner;
    postgresLifecyclePasswords.set(this, password); commitServerInfo(defaultPostgresServerInfo(), this.serverInfo);
  }
  get config(): PostgresConnectionConfig { return this.storedConfig.clone(); }
  get state(): ConnectionState { return this.currentState; }
  get currentWireEpoch(): number { return this.wireExecutionEpoch; }
  readBackendKeyData(): PostgresBackendCancellationKey | null {
    const stored = postgresBackendSecrets.get(this);
    return stored === undefined ? null : new PostgresBackendCancellationKey(stored.processId, copySecretBytes(stored.secretKey), stored.secretKeyInt32);
  }
  latchConsumerError(scope: PostgresCommandScope, error: ArkDbError, synchronized: boolean = false): void {
    this.commandGate.assertOwner(scope); this.lastConsumerError = error;
    if (this.deadlineRootError !== null) {
      const root = this.deadlineRootError;
      const base = this.latchedPrimaryError !== null ? this.latchedPrimaryError : root;
      const next = error === base || error === root || isPostgresInterruptionError(error) ? base : postgresAppendDecomposedCleanup(base, error);
      this.latchedPrimaryError = next; if (synchronized) this.synchronizedConsumerError = next; return;
    }
    this.latchedPrimaryError = error; if (synchronized) this.synchronizedConsumerError = error;
  }
  latchDeadlineError(scope: PostgresCommandScope, error: ArkDbError): void {
    this.commandGate.assertOwner(scope);
    if (this.deadlineRootError === null) this.deadlineRootError = error;
    const prev = this.latchedPrimaryError;
    this.latchedPrimaryError = prev !== null && prev !== error && !isPostgresInterruptionError(prev) ? postgresAppendDecomposedCleanup(error, prev) : error;
  }
  readDeadlineBase(scope: PostgresCommandScope, root: ArkDbError): ArkDbError { return this.commandGate.isOwner(scope) && this.latchedPrimaryError !== null && this.latchedPrimaryError.kind === ArkDbErrorKind.Timeout ? this.latchedPrimaryError : root; }
  isLatchedConsumerError(error: ArkDbError): boolean { return this.lastConsumerError === error; }
  syncDeadlineError(scope: PostgresCommandScope, error: ArkDbError, synchronized: boolean): void {
    if (!this.commandGate.isOwner(scope)) return;
    this.latchedPrimaryError = error; this.synchronizedConsumerError = synchronized ? error : null;
  }
  isSynchronizedConsumerError(error: ArkDbError): boolean { return this.synchronizedConsumerError === error; }
  awaitBounded(op: () => Promise<ArkDbError | null>, msg: string): Promise<ArkDbError | null> { return awaitBoundedCleanup(op, this.timers, msg); }
  clearConsumerError(scope: PostgresCommandScope): void {
    if (this.commandGate.isOwner(scope)) { this.latchedPrimaryError = null; this.lastConsumerError = null; this.synchronizedConsumerError = null; this.deadlineRootError = null; }
  }
  isCommandSynchronized(scope: PostgresCommandScope): boolean {
    return this.commandGate.isOwner(scope) && !this.closeRequested && this.currentState === ConnectionState.Querying &&
      !this.unsynchronized && this.pendingIoCount === 0 && !this.awaitingReadyForQuery && this.readySynchronized && this.sessionStatus.known === true && this.transport !== null;
  }
  waitForStepReady(scope: PostgresCommandScope, settlement: PostgresCommandCloseSettlement): Promise<void> | null {
    this.commandGate.assertOwner(scope); this.throwIfRetiredOrClosing(settlement);
    return this.hasBlockingCancels() ? settlement.raceConsumer<void>((): Promise<void> => this.waitBlockingCancelsSettled()).then((): void => { this.throwIfRetiredOrClosing(settlement); }) : null;
  }
  applyReadyStatus(scope: PostgresCommandScope, ready: PostgresReadyStatus): void {
    this.commandGate.assertOwner(scope);
    if (this.unsynchronized || this.pendingIoCount > 0 || scope.kind === PostgresCommandKind.Connect) {
      throw ArkDbError.protocol('PostgreSQL ReadyForQuery requires an active synchronized command.');
    }
    if (this.activeSettlement !== null && this.activeSettlement.scope === scope && this.activeSettlement.closeReason !== null) {
      throw this.activeSettlement.closeReason;
    }
    if (scope.phase === PostgresCommandPhase.Closing || this.currentState !== ConnectionState.Querying) {
      throw this.closeRequested ? ArkDbError.cancelled('PostgreSQL connection closed during operation.') :
        ArkDbError.protocol('PostgreSQL ReadyForQuery requires an active synchronized command.');
    }
    this.commitReadyStatus(ready);
  }
  async connect(): Promise<void> {
    if (this.closeRequested || this.currentState === ConnectionState.Closed) throw ArkDbError.protocol('PostgreSQL connection is closed.');
    if (this.currentState !== ConnectionState.Idle) throw ArkDbError.protocol('PostgreSQL connection cannot connect in state ' + this.currentState + '.');
    const scope = this.commandGate.reserve(PostgresCommandKind.Connect); const settlement = new PostgresCommandCloseSettlement(scope);
    this.activeSettlement = settlement; this.activeReleaseScope = null; this.activeScopeRelease = null; this.closedScope = null;
    let deadline: ConnectionDeadline | null = null; let startupClosed = false; let failure: ArkDbError | null = null;
    const stagingInfo = defaultPostgresServerInfo(); this.retiredCleanup = null; this.retiredComposed = null;
    try {
      this.commandGate.start(scope); this.throwIfRetiredOrClosing(settlement);
      deadline = new ConnectionDeadline(this.storedConfig.connectTimeoutMs, this.timers); this.opening = deadline;
      this.throwIfRetiredOrClosing(settlement);
      const budget = deadline; this.commandGate.setPhase(scope, PostgresCommandPhase.Connecting);
      this.currentState = ConnectionState.Connecting; resetPostgresSessionStatus(this.sessionStatus); this.readySynchronized = false;
      this.pendingIoCount = 0; this.awaitingReadyForQuery = false; this.unsynchronized = false; this.retiredReason = null;
      const transport = this.transportFactory(); this.transport = transport;
      this.throwIfRetiredOrClosing(settlement);
      await budget.wait((): Promise<void> => settlement.raceClose((): Promise<void> => {
        const timeoutMs = budget.remainingMs(); this.throwIfRetiredOrClosing(settlement);
        return transport.connect(this.storedConfig.host, this.storedConfig.port, timeoutMs);
      }));
      this.throwIfRetiredOrClosing(settlement); budget.remainingMs(); this.throwIfRetiredOrClosing(settlement);
      const isClosed = (): boolean => startupClosed;
      const scoped = this.createScopedTransport(scope, transport, isClosed);
      const context = this.createStartupContext(scope, scoped, this.createScopedChannel(scope, transport, isClosed), budget, settlement, stagingInfo, isClosed);
      await budget.wait((): Promise<void> => settlement.raceClose((): Promise<void> => this.startupRunner(context)));
      this.throwIfRetiredOrClosing(settlement); budget.remainingMs(); this.throwIfRetiredOrClosing(settlement);
      if (this.state !== ConnectionState.Authenticating) throw ArkDbError.protocol('PostgreSQL startup completed without authentication.');
      if (this.pendingIoCount > 0 || this.awaitingReadyForQuery || !this.readySynchronized || this.transport === null) throw ArkDbError.protocol('PostgreSQL startup completed without ReadyForQuery synchronization.');
      startupClosed = true; postgresLifecyclePasswords.delete(this);
      if (this.opening === deadline) this.opening = null;
      const disposeErr = safeDisposeDeadline(deadline); deadline = null;
      if (disposeErr !== null) throw disposeErr;
      this.throwIfRetiredOrClosing(settlement);
      commitServerInfo(stagingInfo, this.serverInfo); this.currentState = ConnectionState.Ready;
    } catch (error) {
      startupClosed = true;
      if (this.opening === deadline) this.opening = null;
      const rawErr = toPostgresArkDbError(error as Object, ArkDbErrorKind.Network);
      const rawPrimary = rawErr === settlement.closeReason && this.unsynchronized && this.retiredReason !== null ? this.retiredReason : rawErr;
      const alreadyAppended = this.retiredCleanup !== null;
      let primary = this.composeRetiredCleanup(rawPrimary); const timerErr = safeDisposeDeadline(deadline); deadline = null;
      if (timerErr !== null && timerErr !== primary) primary = postgresAppendCleanupError(primary, timerErr);
      failure = await this.abortScopeFailure(scope, primary, alreadyAppended, (this.closeRequested || settlement.isCloseRequested) ? ConnectionState.Closed : ConnectionState.Error);
    } finally {
      startupClosed = true; if (this.opening === deadline) this.opening = null; safeDisposeDeadline(deadline);
      this.retiredCleanup = null; this.retiredComposed = null; failure = this.finishScope(scope, settlement, failure);
    }
    if (failure !== null) {
      if (this.currentState === ConnectionState.Ready) {
        this.clearSecretsAndChannel();
        this.currentState = this.closeRequested ? ConnectionState.Closed : ConnectionState.Error;
        if (this.commandGate.current === null) this.commandGate.advanceGeneration();
        const cleanup = await this.releaseTransport(failure);
        if (cleanup !== null && cleanup !== failure) failure = postgresAppendCleanupError(failure, cleanup);
      }
      throw failure;
    }
  }
  runCommand<T>(kind: PostgresCommandKind, runner: PostgresCommandRunner<T>): Promise<T> {
    return this.executeCommand<T>(kind, undefined, (scope: PostgresCommandScope, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, _opts: QueryOptions | null): Promise<T> => runner(scope, channel, settlement));
  }
  runDeadlineCommand<T>(kind: PostgresCommandKind, prepareOptions: () => QueryOptions,
    runner: (scope: PostgresCommandScope, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, opts: QueryOptions) => Promise<T>,
    scrubValue?: (value: T) => void): Promise<T> {
    return this.executeCommand<T>(kind, prepareOptions, (scope: PostgresCommandScope, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, opts: QueryOptions | null): Promise<T> => runner(scope, channel, settlement, opts!), scrubValue);
  }
  runStepWithDeadline<R>(scope: PostgresCommandScope, settlement: PostgresCommandCloseSettlement, options: QueryOptions,
    operation: () => Promise<R>, scrubValue?: (value: R) => void, canLatch?: () => boolean): Promise<R> {
    const clearRoot = (): void => { if (this.commandGate.isOwner(scope)) this.deadlineRootError = null; };
    const task = runPostgresStatementDeadline<R>(new LifecycleDeadlineHost(this, scope, settlement, canLatch), settlement, options, operation, scrubValue);
    if (options.statementTimeoutMs > 0) {
      const stepDone = task.then((_v: R): ArkDbError | null => null, (e: Object): ArkDbError | null => toPostgresArkDbError(e));
      this.activeDeadlineScope = scope; this.activeDeadlineStep = stepDone;
      stepDone.then((se: ArkDbError | null): void => { if ((se === null || (settlement.closeReason === null && this.isCommandSynchronized(scope))) && this.activeDeadlineStep === stepDone) { this.activeDeadlineScope = null; this.activeDeadlineStep = null; } });
    }
    return task.then((val: R): R => { clearRoot(); return val; }, (err: Object): Promise<R> => { clearRoot(); return Promise.reject<R>(err); });
  }
  assertCommandDispatchable(): void {
    if (this.closeRequested || this.currentState === ConnectionState.Closed) throw ArkDbError.protocol('PostgreSQL connection is closed.');
    if (this.currentState === ConnectionState.Idle) throw ArkDbError.protocol('PostgreSQL connection is not connected.');
    if (this.currentState === ConnectionState.Error || this.unsynchronized) throw ArkDbError.protocol('PostgreSQL connection is retired after an unrecoverable error.');
    if (this.commandGate.current !== null) throw ArkDbError.protocol('Another command already owns this PostgreSQL connection.');
  }
  private async executeCommand<T>(kind: PostgresCommandKind, prepareOptions: (() => QueryOptions) | undefined,
    runner: (scope: PostgresCommandScope, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, opts: QueryOptions | null) => Promise<T>,
    scrubValue?: (value: T) => void): Promise<T> {
    if (kind === PostgresCommandKind.Connect || kind === PostgresCommandKind.Close) throw ArkDbError.protocol('Invalid PostgreSQL command kind for session execution.');
    this.assertCommandDispatchable();
    const scope = this.commandGate.reserve(kind); const settlement = new PostgresCommandCloseSettlement(scope);
    this.activeSettlement = settlement; this.activeReleaseScope = null; this.activeScopeRelease = null; this.closedScope = null;
    let failure: ArkDbError | null = null; let output: T | undefined = undefined; let delivered = false;
    this.latchedPrimaryError = null; this.lastConsumerError = null; this.synchronizedConsumerError = null; this.deadlineRootError = null; this.retiredCleanup = null; this.retiredComposed = null;
    try {
      this.commandGate.start(scope); this.throwIfRetiredOrClosing(settlement);
      const opts = prepareOptions !== undefined ? prepareOptions() : null;
      const useDeadline = opts !== null && opts.statementTimeoutMs > 0;
      const runCore = async (): Promise<T> => {
        if (this.hasBlockingCancels()) {
          await (useDeadline ? settlement.raceConsumer<void>((): Promise<void> => this.waitBlockingCancelsSettled()) : settlement.raceClose<void>((): Promise<void> => this.waitBlockingCancelsSettled()));
          this.throwIfRetiredOrClosing(settlement);
        }
        if ((this.currentState !== ConnectionState.Ready && this.currentState !== ConnectionState.Querying) || this.transport === null) throw ArkDbError.protocol('PostgreSQL connection channel is unavailable.');
        const channel = this.createScopedChannel(scope, this.transport);
        this.commandGate.setPhase(scope, PostgresCommandPhase.Executing); this.currentState = ConnectionState.Querying;
        return runner(scope, channel, settlement, opts);
      };
      let result: T;
      if (useDeadline) {
        if (this.currentState !== ConnectionState.Ready || this.transport === null) throw ArkDbError.protocol('PostgreSQL connection channel is unavailable.');
        this.commandGate.setPhase(scope, PostgresCommandPhase.Executing); this.currentState = ConnectionState.Querying;
        result = await this.runStepWithDeadline<T>(scope, settlement, opts!, runCore, scrubValue);
      } else {
        result = await settlement.raceClose<T>(runCore);
      }
      this.throwIfRetiredOrClosing(settlement);
      if (this.pendingIoCount > 0 || this.awaitingReadyForQuery || !this.readySynchronized || this.transport === null) throw ArkDbError.protocol('PostgreSQL command completed without ReadyForQuery synchronization.');
      this.currentState = ConnectionState.Ready; output = result; delivered = true;
    } catch (error) {
      const stepErr = this.activeDeadlineScope === scope && this.activeDeadlineStep !== null ? await this.activeDeadlineStep : null;
      const rawErr = toPostgresArkDbError(error as Object);
      let primary = rawErr === settlement.closeReason && this.unsynchronized && this.retiredReason !== null ? this.retiredReason : rawErr;
      if (this.latchedPrimaryError !== null && primary !== this.latchedPrimaryError) primary = postgresAppendDecomposedCleanup(this.latchedPrimaryError, primary);
      const alreadyAppended = primary === this.retiredComposed || primary === this.retiredCleanup;
      const retireOnError = primary !== this.synchronizedConsumerError && shouldRetireAfterError(primary);
      if (this.closeRequested || settlement.isCloseRequested) failure = await this.abortScopeFailure(scope, primary, alreadyAppended, ConnectionState.Closed, stepErr);
      else if (this.unsynchronized || this.pendingIoCount > 0 || this.awaitingReadyForQuery || !this.readySynchronized || this.transport === null || retireOnError) {
        this.markStreamDamaged(primary); failure = await this.abortScopeFailure(scope, primary, alreadyAppended, ConnectionState.Error, stepErr);
      } else { this.currentState = ConnectionState.Ready; failure = stepErr !== null ? postgresAppendDecomposedCleanup(primary, stepErr) : primary; }
    } finally {
      this.latchedPrimaryError = null; this.lastConsumerError = null; this.synchronizedConsumerError = null; this.deadlineRootError = null; this.retiredCleanup = null; this.retiredComposed = null;
      if (this.deadlineRetiredScope === scope) this.deadlineRetiredScope = null;
      if (this.activeDeadlineScope === scope) { this.activeDeadlineScope = null; this.activeDeadlineStep = null; }
      if (this.activeCancelScope === scope) this.clearActiveCancel();
      this.deadlineAbortReason = null;
      failure = this.finishScope(scope, settlement, failure, delivered && failure === null);
      if (delivered && failure === null) settlement.markDelivered(); else settlement.discardUndelivered();
    }
    if (failure !== null) throw failure;
    return output as T;
  }
  async retire(scope: PostgresCommandScope, reason: ArkDbError): Promise<void> {
    this.commandGate.assertOwner(scope);
    this.markStreamDamaged(reason); this.clearSecretsAndChannel();
    if (this.currentState !== ConnectionState.Closed && !this.closeRequested) this.currentState = ConnectionState.Error;
    if (scope.phase !== PostgresCommandPhase.Closing) this.commandGate.setPhase(scope, PostgresCommandPhase.Closing);
    this.commandGate.advanceGenerationOnRelease(scope);
    const cleanup = await this.releaseTransport(reason);
    if (cleanup !== null && cleanup !== reason) {
      const composed = postgresAppendCleanupError(reason, cleanup);
      if (this.commandGate.isOwner(scope)) {
        if (this.retiredCleanup === null) this.retiredCleanup = cleanup;
        if (this.latchedPrimaryError === reason) this.latchedPrimaryError = composed;
        this.retiredComposed = composed; this.retiredReason = composed;
      }
      throw composed;
    }
  }
  isInterruptionError(error: ArkDbError): boolean { return isPostgresInterruptionError(error); }
  cancel(): Promise<QueryCancellationResult> {
    const scope = this.commandGate.current; const epoch = this.wireExecutionEpoch;
    if (scope === null || !this.canCancelExecution(scope, epoch)) return Promise.resolve<QueryCancellationResult>(new QueryCancellationResult(CancellationOutcome.NotRunning, this.reuseState()));
    if (this.activeCancelTask !== null && this.activeCancelScope === scope && this.activeCancelEpoch === epoch) return this.activeCancelTask;
    const key = this.readBackendKeyData();
    if (key === null || key.processId === 0) { if (key !== null) key.secretKey.fill(0); return Promise.reject<QueryCancellationResult>(ArkDbError.unsupported(MISSING_BACKEND_KEY_MSG)); }
    let cancelTransport: PostgresLifecycleTransport;
    try { cancelTransport = this.transportFactory(); } catch (e) { key.secretKey.fill(0); return Promise.reject<QueryCancellationResult>(toPostgresArkDbError(e as Object, ArkDbErrorKind.Network)); }
    if (cancelTransport === null || cancelTransport === undefined || cancelTransport === this.transport) { key.secretKey.fill(0); return Promise.reject<QueryCancellationResult>(ArkDbError.validation('PostgreSQL cancellation requires a distinct transport instance.')); }
    const handle = new PostgresCancelHandle((): void => this.wakeCancelSettleWaiters()); this.activeCancels.add(handle);
    const task = dispatchPostgresCancelRequest({
      config: this.storedConfig.clone(), timers: this.timers, transport: cancelTransport, processId: key.processId, secretKey: key.secretKey, secretKeyInt32: key.secretKeyInt32,
      isStillRunning: (): boolean => this.canCancelExecution(scope, epoch), awaitTargetDispatched: (): Promise<void> | null => this.awaitWireExecutionDispatched(scope, epoch, handle),
      onUnconfirmedDispatch: (reason: ArkDbError): Promise<ArkDbError | null> => this.retireAfterUnconfirmedCancel(reason),
      onSettled: (): void => { this.activeCancels.delete(handle); this.wakeCancelSettleWaiters(); }, handle: handle
    }).then((outcome: CancellationOutcome): QueryCancellationResult => new QueryCancellationResult(outcome, this.reuseState()));
    this.activeCancelScope = scope; this.activeCancelEpoch = epoch; this.activeCancelTask = task;
    const clearActive = (): void => { if (this.activeCancelTask === task) this.clearActiveCancel(); };
    task.then((res: QueryCancellationResult): void => { if (res.outcome !== CancellationOutcome.Requested) clearActive(); }, (): void => { if (!handle.confirmed) clearActive(); });
    return task;
  }
  close(): Promise<void> {
    if (this.closing !== null) return this.closing;
    let start: () => void = (): void => {};
    const task = new Promise<void>((resolve: () => void, reject: (reason?: Object) => void): void => {
      start = (): void => { this.closeOnce().then(resolve, reject); };
    });
    const clear = (): void => { if (this.closing === task) this.closing = null; };
    this.closing = task;
    task.then(clear, clear);
    start();
    return task;
  }
  private async closeOnce(): Promise<void> {
    const closeReason = ArkDbError.cancelled('PostgreSQL connection closed during operation.');
    const settlement = this.activeSettlement;
    const activeScope = settlement !== null ? settlement.scope : this.commandGate.current;
    if (activeScope !== null) {
      if (this.closedScope === activeScope) {
        this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
        const dupErr = await this.abortActiveCancels(closeReason); if (dupErr !== null) throw dupErr; return;
      }
      this.closeRequested = true; this.closedScope = activeScope;
      if (settlement !== null) {
        this.closedSettlement = settlement; this.closedSettlementTerminalError = null; this.awaitingClosedSettlement = true;
      }
      let timerErr: ArkDbError | null = null; let cleanup: ArkDbError | null = null; let terminalErr: ArkDbError | null = null;
      const cancelCleanupTask = this.abortActiveCancels(closeReason);
      try {
        this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
        if (this.commandGate.isOwner(activeScope)) {
          this.commandGate.advanceGenerationOnRelease(activeScope);
          if (activeScope.phase !== PostgresCommandPhase.Closing) this.commandGate.setPhase(activeScope, PostgresCommandPhase.Closing);
        }
        const activeDeadline = this.opening; this.opening = null;
        timerErr = safeCancelDeadline(activeDeadline, closeReason);
        if (settlement !== null) settlement.signalClose(closeReason);
        const rawCloseRelease = this.releaseTransport(closeReason);
        if (settlement !== null) {
          await settlement.settled;
          cleanup = await (this.activeReleaseScope === activeScope && this.activeScopeRelease !== null ? this.activeScopeRelease : rawCloseRelease);
          if (this.closedSettlement === settlement) terminalErr = this.closedSettlementTerminalError;
        } else cleanup = await rawCloseRelease;
        cleanup = composeOptionalErrors(cleanup, await cancelCleanupTask);
      } finally {
        this.awaitingClosedSettlement = false;
        const scopeSettled = settlement !== null ? this.activeSettlement !== settlement : this.commandGate.current !== activeScope;
        if (scopeSettled && this.closedScope === activeScope) {
          this.closedScope = null;
          if (this.activeReleaseScope === activeScope) { this.activeReleaseScope = null; this.activeScopeRelease = null; }
        }
        if (settlement !== null && this.activeSettlement !== settlement && this.closedSettlement === settlement) {
          this.closedSettlement = null; this.closedSettlementTerminalError = null;
        }
        this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
      }
      const failure = composeOptionalErrors(composeOptionalErrors(timerErr, cleanup), terminalErr);
      if (failure !== null) throw failure;
      return;
    }
    this.closedScope = null; this.activeReleaseScope = null; this.activeScopeRelease = null;
    if ((this.currentState === ConnectionState.Closed || this.currentState === ConnectionState.Error) && this.commandGate.current === null) {
      this.closeRequested = true; this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
      const cancelCleanupTask = this.abortActiveCancels(closeReason);
      const cleanup = composeOptionalErrors(await this.releaseTransport(null), await cancelCleanupTask);
      if (cleanup !== null) throw cleanup;
      return;
    }
    if (this.currentState === ConnectionState.Idle && this.commandGate.current === null) {
      this.closeRequested = true; this.clearSecretsAndChannel(); this.commandGate.advanceGeneration(); this.currentState = ConnectionState.Closed;
      const cancelErr = await this.abortActiveCancels(closeReason); if (cancelErr !== null) throw cancelErr; return;
    }
    const activeTransport = this.transport;
    const shouldSendTerminate = this.currentState === ConnectionState.Ready && this.commandGate.current === null &&
      !this.unsynchronized && !this.awaitingReadyForQuery && this.pendingIoCount === 0 && this.readySynchronized && activeTransport !== null;
    this.closeRequested = true;
    const cancelCleanupTask = this.abortActiveCancels(closeReason);
    const scope = this.commandGate.reserve(PostgresCommandKind.Close);
    let failure: ArkDbError | null = null;
    try {
      this.commandGate.advanceGenerationOnRelease(scope); this.commandGate.setPhase(scope, PostgresCommandPhase.Closing);
      try { this.commandGate.start(scope); } catch (e) { failure = toPostgresArkDbError(e as Object); }
      this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
      if (failure === null && shouldSendTerminate && activeTransport !== null && this.transport === activeTransport) {
        await this.sendTerminateBestEffort(activeTransport);
      }
      const cleanup = composeOptionalErrors(await this.releaseTransport(failure), await cancelCleanupTask);
      if (cleanup !== null) failure = failure !== null && cleanup !== failure ? postgresAppendCleanupError(failure, cleanup) : cleanup;
    } finally {
      this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
      failure = this.releaseScopeSafe(scope, failure);
    }
    if (failure !== null) throw failure;
  }
  private assertActiveScope(scope: PostgresCommandScope, isClosed?: () => boolean): void {
    this.commandGate.assertOwner(scope);
    if (!this.unsynchronized && this.activeSettlement !== null && this.activeSettlement.scope === scope && this.activeSettlement.closeReason !== null) {
      throw this.activeSettlement.closeReason;
    }
    if ((isClosed !== undefined && isClosed()) || scope.phase === PostgresCommandPhase.Closing || this.transport === null) {
      throw !this.unsynchronized && this.closeRequested ?
        ArkDbError.cancelled('PostgreSQL connection closed during operation.') :
        ArkDbError.protocol('PostgreSQL command scope is closing.');
    }
  }
  private assertActiveIoScope(scope: PostgresCommandScope, isClosed?: () => boolean): void {
    this.assertActiveScope(scope, isClosed);
    if (this.unsynchronized) throw ArkDbError.protocol('PostgreSQL connection synchronization was lost.');
  }
  private createScopedChannel(scope: PostgresCommandScope, rawTransport: PostgresLifecycleTransport, isClosed?: () => boolean): PostgresMessageChannel {
    let channelTransportFailure: ArkDbError | null = null;
    const transport = this.createScopedTransport(scope, rawTransport, isClosed, (d: ArkDbError): void => { if (channelTransportFailure === null) channelTransportFailure = d; });
    return new ScopedPostgresMessageChannel(transport, (): void => { this.assertActiveIoScope(scope, isClosed); this.pendingIoCount += 1; }, (err: Object | null, isOwner: boolean): Object => {
      this.decrementPendingIo();
      const captured = isOwner ? channelTransportFailure : null;
      if (isOwner) channelTransportFailure = null;
      if (err === null) return new Object();
      const resolved = captured !== null && (captured.kind !== ArkDbErrorKind.Protocol || captured.nativeCode !== undefined) ? captured : err;
      if (this.commandGate.isOwner(scope)) { const typed = toPostgresArkDbError(resolved); if (typed.kind !== ArkDbErrorKind.Validation) this.markStreamDamaged(typed); }
      return resolved;
    }, (reading: boolean): void => { this.wireEpochReading = reading; if (reading && this.activeWireWriteCount === 0) this.wakeWireDispatchWaiters(); });
  }
  private createScopedTransport(scope: PostgresCommandScope, transport: PostgresLifecycleTransport,
    isClosed?: () => boolean, onDamaged?: (damaged: ArkDbError) => void): PostgresLifecycleTransport {
    return new ScopedPostgresTransport(transport, (): void => { this.assertActiveIoScope(scope, isClosed); },
      (): void => { this.assertActiveScope(scope, isClosed); },
      (): void => { if (!this.awaitingReadyForQuery) { this.wireExecutionEpoch += 1; this.wireEpochActive = true; this.wireEpochReading = false; } this.pendingIoCount += 1; this.awaitingReadyForQuery = true; this.readySynchronized = false; resetPostgresSessionStatus(this.sessionStatus); },
      (d: ArkDbError | null): void => {
        this.decrementPendingIo();
        if (d !== null) { if (onDamaged !== undefined) onDamaged(d); if (this.commandGate.isOwner(scope)) this.markStreamDamaged(d); }
      }, (reason: ArkDbError): Promise<void> => this.retire(scope, reason),
      (delta: number): void => { this.activeWireWriteCount = Math.max(0, this.activeWireWriteCount + delta); if (this.activeWireWriteCount === 0 && this.wireEpochReading) this.wakeWireDispatchWaiters(); });
  }
  private async abortScopeFailure(scope: PostgresCommandScope, primary: ArkDbError, alreadyAppended: boolean, state: ConnectionState, stepErr: ArkDbError | null = null): Promise<ArkDbError> {
    const pendingStep = stepErr !== null ? stepErr : (this.activeDeadlineScope === scope && this.activeDeadlineStep !== null ? await this.activeDeadlineStep : null);
    const targetState = this.closeRequested ? ConnectionState.Closed : state;
    this.clearSecretsAndChannel(); this.currentState = targetState;
    if (scope.phase !== PostgresCommandPhase.Closing) this.commandGate.setPhase(scope, PostgresCommandPhase.Closing);
    this.commandGate.advanceGenerationOnRelease(scope);
    const skipBoundedWait = this.deadlineRetiredScope === scope;
    const cleanup = skipBoundedWait ? null : await this.releaseTransport(primary);
    if (!skipBoundedWait) await this.waitPendingIoIdle();
    this.clearSecretsAndChannel(); this.currentState = this.closeRequested ? ConnectionState.Closed : targetState;
    let base = alreadyAppended ? primary : this.composeRetiredCleanup(primary);
    if (pendingStep !== null) base = postgresAppendDecomposedCleanup(base, pendingStep);
    return !alreadyAppended && cleanup !== null && cleanup !== base && cleanup !== this.retiredCleanup ? postgresAppendDecomposedCleanup(base, cleanup) : base;
  }
  private createStartupContext(scope: PostgresCommandScope, transport: PostgresLifecycleTransport, channel: PostgresMessageChannel,
    budget: ConnectionDeadline, settlement: PostgresCommandCloseSettlement, stagingInfo: PostgresServerInfo, isClosed: () => boolean): PostgresStartupContext {
    let startupSynchronized = false;
    const assertStartupOpen = (): void => {
      if (isClosed()) throw ArkDbError.protocol('PostgreSQL startup is no longer active.');
      this.commandGate.assertOwner(scope); this.throwIfRetiredOrClosing(settlement);
      budget.remainingMs(); this.throwIfRetiredOrClosing(settlement);
      if (startupSynchronized) throw ArkDbError.protocol('PostgreSQL startup already synchronized on ReadyForQuery.');
    };
    const assertAuthPhase = (msg: string): void => {
      assertStartupOpen();
      if (this.state !== ConnectionState.Authenticating || scope.phase !== PostgresCommandPhase.Authenticating) throw ArkDbError.protocol(msg);
    };
    return new PostgresStartupContext(scope, this.storedConfig.clone(), transport, channel, budget, settlement, stagingInfo, {
      enterAuth: (): void => {
        assertStartupOpen(); const state = this.state;
        if (state !== ConnectionState.Connecting && state !== ConnectionState.Authenticating) throw ArkDbError.protocol('Invalid PostgreSQL startup authentication transition.');
        this.commandGate.setPhase(scope, PostgresCommandPhase.Authenticating); this.currentState = ConnectionState.Authenticating;
      },
      readPassword: (): string => {
        assertAuthPhase('PostgreSQL password is available only during authentication.');
        const pw = postgresLifecyclePasswords.get(this);
        if (pw === undefined) throw ArkDbError.protocol('PostgreSQL password is no longer available.');
        return pw;
      },
      setBackendKey: (pid: number, key: Uint8Array): void => { assertAuthPhase('PostgreSQL BackendKeyData is valid only during startup authentication.'); this.storeBackendKeyData(pid, key, stagingInfo); },
      applyReady: (ready: PostgresReadyStatus): void => {
        assertAuthPhase('PostgreSQL startup ReadyForQuery requires authentication phase.');
        if (this.pendingIoCount > 0) throw ArkDbError.protocol('PostgreSQL ReadyForQuery requires idle startup I/O.');
        this.commitReadyStatus(ready); startupSynchronized = true; postgresLifecyclePasswords.delete(this);
      }
    });
  }
  private commitReadyStatus(ready: PostgresReadyStatus): void {
    try { applyPostgresReadyStatus(this.sessionStatus, ready); } catch (e) {
      const typed = toPostgresArkDbError(e as Object); this.markStreamDamaged(typed); throw typed;
    }
    this.readySynchronized = true; this.awaitingReadyForQuery = false; this.wireEpochActive = false; this.wireEpochReading = false;
    this.clearActiveCancel(); this.wakeWireDispatchWaiters();
  }
  private storeBackendKeyData(processId: number, secretKey: Uint8Array, targetInfo: PostgresServerInfo): void {
    if (!Number.isInteger(processId) || processId < -2147483648 || processId > 2147483647) throw ArkDbError.protocol('Invalid PostgreSQL backend process ID.');
    if (secretKey.length !== 4) throw ArkDbError.protocol('Invalid PostgreSQL backend secret key length.');
    const normalizedPid = processId === 0 ? 0 : processId; const previous = postgresBackendSecrets.get(this);
    if (previous !== undefined) previous.secretKey.fill(0);
    const copy = copySecretBytes(secretKey); const int32 = new DataView(copy.buffer, copy.byteOffset, 4).getInt32(0, false);
    postgresBackendSecrets.set(this, new PostgresBackendCancellationKey(normalizedPid, copy, int32));
    targetInfo.backendProcessId = normalizedPid; targetInfo.connectionHandle = String(normalizedPid);
  }
  private markStreamDamaged(reason: ArkDbError): void {
    if (!this.unsynchronized) this.retiredReason = reason;
    this.unsynchronized = true; this.readySynchronized = false; this.wireEpochActive = false; resetPostgresSessionStatus(this.sessionStatus);
    this.clearActiveCancel(); this.wakeWireDispatchWaiters();
  }
  private throwIfRetiredOrClosing(settlement: PostgresCommandCloseSettlement): void {
    if (this.unsynchronized) throw this.retiredReason !== null ? this.retiredReason : ArkDbError.protocol('PostgreSQL connection synchronization was lost.');
    if (settlement.closeReason !== null) throw settlement.closeReason;
    if (this.closeRequested) throw ArkDbError.cancelled('PostgreSQL connection closed during operation.');
  }
  private composeRetiredCleanup(primary: ArkDbError): ArkDbError {
    return this.retiredCleanup !== null && primary !== this.retiredComposed && primary !== this.retiredCleanup ? postgresAppendCleanupError(primary, this.retiredCleanup) : primary;
  }
  private releaseScopeSafe(scope: PostgresCommandScope, failure: ArkDbError | null): ArkDbError | null {
    if (!this.commandGate.isOwner(scope)) return failure;
    try { this.commandGate.release(scope); return failure; } catch (e) {
      return composeOptionalErrors(failure, toPostgresArkDbError(e as Object));
    }
  }
  private decrementPendingIo(): void {
    this.pendingIoCount -= 1;
    if (this.pendingIoCount <= 0) {
      this.pendingIoCount = 0;
      const waiters = this.pendingIoWaiters;
      if (waiters.length > 0) { this.pendingIoWaiters = []; for (const wake of waiters) wake(); }
    }
  }
  private waitPendingIoIdle(): Promise<void> {
    if (this.pendingIoCount <= 0) return Promise.resolve();
    return new Promise<void>((resolve: () => void): void => { this.pendingIoWaiters.push(resolve); });
  }
  private finishScope(scope: PostgresCommandScope, settlement: PostgresCommandCloseSettlement, failure: ArkDbError | null, preservePendingDelivery: boolean = false): ArkDbError | null {
    if (this.activeSettlement === settlement) {
      this.activeSettlement = null;
      if (!this.awaitingClosedSettlement || this.closedSettlement !== settlement) {
        if (this.activeReleaseScope === scope) { this.activeReleaseScope = null; this.activeScopeRelease = null; }
        if (this.closedScope === scope) this.closedScope = null;
      }
    }
    let scopeEndErr: ArkDbError | null = null;
    try { settlement.markSettled(preservePendingDelivery); } catch (e) { scopeEndErr = toPostgresArkDbError(e as Object); }
    scopeEndErr = this.releaseScopeSafe(scope, scopeEndErr);
    if (this.activeCancelScope === scope) this.clearActiveCancel();
    this.wakeWireDispatchWaiters();
    if (this.closedSettlement === settlement) {
      if (this.awaitingClosedSettlement) this.closedSettlementTerminalError = composeOptionalErrors(this.closedSettlementTerminalError, scopeEndErr);
      else {
        this.closedSettlement = null; this.closedSettlementTerminalError = null;
        if (this.closedScope === scope) this.closedScope = null;
        if (this.activeReleaseScope === scope) { this.activeReleaseScope = null; this.activeScopeRelease = null; }
      }
    }
    return composeOptionalErrors(failure, scopeEndErr);
  }
  private releaseTransport(abortReason: ArkDbError | null): Promise<ArkDbError | null> {
    const ownerScope = this.activeSettlement !== null ? this.activeSettlement.scope : this.commandGate.current;
    if (ownerScope === null) { this.activeReleaseScope = null; this.activeScopeRelease = null; }
    else if (this.activeReleaseScope === ownerScope && this.activeScopeRelease !== null) return this.activeScopeRelease;
    if (this.releaseTask !== null) {
      if (ownerScope !== null) { this.activeReleaseScope = ownerScope; this.activeScopeRelease = this.releaseTask; }
      return this.releaseTask;
    }
    const active = this.transport;
    if (active === null) return Promise.resolve<ArkDbError | null>(null);
    this.transport = null; this.awaitingReadyForQuery = false;
    let begin: () => void = (): void => {};
    const tracked = new Promise<ArkDbError | null>((resolve: (err: ArkDbError | null) => void): void => {
      begin = (): void => {
        let raw: Promise<ArkDbError | null>;
        try {
          raw = (abortReason !== null ? active.abort(abortReason) : active.close()).then((): ArkDbError | null => null, (cleanup: Object): ArkDbError | null => toPostgresArkDbError(cleanup, ArkDbErrorKind.Network));
        } catch (cleanup) { raw = Promise.resolve<ArkDbError | null>(toPostgresArkDbError(cleanup as Object, ArkDbErrorKind.Network)); }
        raw.then((err: ArkDbError | null): void => { if (this.releaseTask === tracked) this.releaseTask = null; resolve(err); });
      };
    });
    this.releaseTask = tracked;
    if (ownerScope !== null) { this.activeReleaseScope = ownerScope; this.activeScopeRelease = tracked; }
    begin();
    return tracked;
  }
  private async sendTerminateBestEffort(transport: PostgresLifecycleTransport): Promise<void> {
    let timerId = 0; let settled = false;
    const cancelTimer = (): void => {
      if (timerId === 0) return;
      const id = timerId; timerId = 0;
      try { this.timers.cancel(id); } catch (_e) {}
    };
    try {
      const frame = PostgresFrontendSerializer.terminate();
      await new Promise<void>((resolve: () => void): void => {
        const finish = (): void => {
          if (settled) return;
          settled = true; cancelTimer(); resolve();
        };
        try {
          timerId = this.timers.schedule((): void => { timerId = 0; finish(); }, POSTGRES_TERMINATE_TIMEOUT_MS);
          if (settled) { cancelTimer(); return; }
          this.writeTerminateBytes(transport, frame, (): boolean => settled).then(finish, (): void => finish());
        } catch (_e) { finish(); }
      });
    } catch (_e) {} finally { settled = true; cancelTimer(); }
  }
  private async writeTerminateBytes(transport: PostgresLifecycleTransport, frame: Uint8Array, isStopped: () => boolean): Promise<void> {
    let offset = 0;
    while (offset < frame.length && !isStopped()) {
      const chunk = offset === 0 ? frame : frame.subarray(offset);
      const written = await transport.write(chunk);
      if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.length) return;
      offset += written;
    }
  }
  private clearActiveCancel(): void { this.activeCancelTask = null; this.activeCancelScope = null; this.activeCancelEpoch = 0; }
  private clearSecretsAndChannel(): void {
    postgresLifecyclePasswords.delete(this); const storedKey = postgresBackendSecrets.get(this);
    if (storedKey !== undefined) { storedKey.secretKey.fill(0); postgresBackendSecrets.delete(this); }
    resetPostgresSessionStatus(this.sessionStatus); commitServerInfo(defaultPostgresServerInfo(), this.serverInfo);
    this.readySynchronized = false; this.awaitingReadyForQuery = false; this.wireEpochActive = false; this.wireEpochReading = false; this.clearActiveCancel(); this.wakeWireDispatchWaiters();
  }
  private canCancelExecution(scope: PostgresCommandScope, wireEpoch: number): boolean {
    if (this.closeRequested || this.currentState !== ConnectionState.Querying || this.unsynchronized || this.transport === null || !this.commandGate.isOwner(scope)) return false;
    if (scope.kind !== PostgresCommandKind.Query && scope.kind !== PostgresCommandKind.QueryStream && scope.kind !== PostgresCommandKind.ExtendedQuery && scope.kind !== PostgresCommandKind.Prepared && scope.kind !== PostgresCommandKind.Transaction) return false;
    return (scope.phase === PostgresCommandPhase.Executing || scope.phase === PostgresCommandPhase.Streaming || scope.phase === PostgresCommandPhase.Draining) && this.wireEpochActive && this.wireExecutionEpoch === wireEpoch && (this.awaitingReadyForQuery || this.pendingIoCount > 0);
  }
  private reuseState(): ConnectionReuse {
    if (this.currentState === ConnectionState.Closed || this.closeRequested) return ConnectionReuse.Closed;
    if (this.currentState === ConnectionState.Querying) return ConnectionReuse.AwaitingCompletion;
    if (this.currentState !== ConnectionState.Ready) return ConnectionReuse.NotReady;
    if (this.commandGate.current !== null || this.hasBlockingCancels()) return ConnectionReuse.AwaitingCompletion;
    return this.sessionStatus.known && this.readySynchronized && !this.unsynchronized && !this.awaitingReadyForQuery ? ConnectionReuse.Ready : ConnectionReuse.RequiresSynchronization;
  }
  cancelForDeadline(scope: PostgresCommandScope, epochBefore: number): Promise<ArkDbError | null> {
    if (this.closeRequested || this.wireExecutionEpoch <= epochBefore || !this.canCancelExecution(scope, this.wireExecutionEpoch)) return Promise.resolve<ArkDbError | null>(null);
    return this.cancel().then((): ArkDbError | null => null, (err: Object): ArkDbError | null => { const typed = toPostgresArkDbError(err, ArkDbErrorKind.Network); return (typed.kind === ArkDbErrorKind.Unsupported && typed.message === MISSING_BACKEND_KEY_MSG) || this.closeRequested || typed === this.deadlineAbortReason ? null : typed; });
  }
  async beginPortalBatch(scope: PostgresCommandScope, settlement: PostgresCommandCloseSettlement): Promise<void> {
    if (!this.commandGate.isOwner(scope) || this.unsynchronized || this.closeRequested) return;
    const stale = ArkDbError.cancelled('PostgreSQL portal batch completed before cancellation dispatched.'); this.wireExecutionEpoch += 1; this.wireEpochActive = true; this.wireEpochReading = false; this.clearActiveCancel(); this.wakeWireDispatchWaiters();
    this.activeCancels.forEach((h: PostgresCancelHandle): void => { if (!h.blocksPrimary) h.abort(stale); });
    if (this.hasBlockingCancels()) { await settlement.raceConsumer<void>((): Promise<void> => this.waitBlockingCancelsSettled()); this.throwIfRetiredOrClosing(settlement); }
  }
  recordClosedTimerError(scope: PostgresCommandScope, error: ArkDbError): void {
    if (this.awaitingClosedSettlement && this.closedScope === scope) this.closedSettlementTerminalError = composeOptionalErrors(this.closedSettlementTerminalError, error);
  }
  async retireFromDeadline(scope: PostgresCommandScope, stepSettlement: PostgresCommandCloseSettlement, reason: ArkDbError): Promise<ArkDbError | null> {
    this.deadlineAbortReason = reason; const cancelCleanupTask = this.abortActiveCancels(reason);
    this.deadlineRetiredScope = scope; this.markStreamDamaged(reason); this.clearSecretsAndChannel();
    this.currentState = this.closeRequested || this.currentState === ConnectionState.Closed ? ConnectionState.Closed : ConnectionState.Error;
    if (this.commandGate.isOwner(scope)) this.commandGate.advanceGenerationOnRelease(scope);
    stepSettlement.signalFatal(reason); const rawRelease = this.releaseTask !== null ? this.releaseTask : this.releaseTransport(reason);
    const boundedRelease = awaitBoundedCleanup(async (): Promise<ArkDbError | null> => { const err = await rawRelease; await this.waitPendingIoIdle(); return err; }, this.timers, 'PostgreSQL primary transport retirement timed out.');
    this.activeReleaseScope = scope; this.activeScopeRelease = boundedRelease;
    const transportCleanup = await boundedRelease; if (this.releaseTask === rawRelease) this.releaseTask = null;
    return composeOptionalErrors(await cancelCleanupTask, transportCleanup);
  }
  async settleConvergedCancels(reason: ArkDbError): Promise<ArkDbError | null> {
    this.deadlineAbortReason = reason; this.wakeWireDispatchWaiters(); this.wakeCancelSettleWaiters(); if (this.activeCancels.size === 0) return null;
    const handles: PostgresCancelHandle[] = []; this.activeCancels.forEach((h: PostgresCancelHandle): void => { if (!h.blocksPrimary) { handles.push(h); if (!h.confirmed) h.abort(reason); } });
    let combined: ArkDbError | null = null; for (const h of handles) combined = composeOptionalErrors(combined, await h.cleanupSettled); return combined;
  }
  hasBlockingCancels(): boolean { let b = false; this.activeCancels.forEach((h: PostgresCancelHandle): void => { if (h.blocksPrimary) b = true; }); return b; }
  waitBlockingCancelsSettled(onSettled?: () => void): Promise<void> {
    if (!this.hasBlockingCancels() || this.unsynchronized || this.closeRequested) { if (onSettled !== undefined) onSettled(); return Promise.resolve(); }
    return new Promise<void>((resolve: () => void): void => { const check = (): void => { if (!this.hasBlockingCancels() || this.unsynchronized || this.closeRequested) { this.cancelSettleWaiters.delete(check); if (onSettled !== undefined) onSettled(); resolve(); } }; this.cancelSettleWaiters.add(check); });
  }
  private wakeCancelSettleWaiters(): void { wakeWaiterSet(this.cancelSettleWaiters); }
  private retireAfterUnconfirmedCancel(reason: ArkDbError): Promise<ArkDbError | null> {
    if (this.closeRequested || this.currentState === ConnectionState.Closed) return Promise.resolve<ArkDbError | null>(null);
    this.markStreamDamaged(reason); this.clearSecretsAndChannel(); if (!this.closeRequested) this.currentState = ConnectionState.Error;
    if (this.commandGate.current === null) this.commandGate.advanceGeneration(); else this.commandGate.advanceGenerationOnRelease(this.commandGate.current);
    if (this.activeSettlement !== null) this.activeSettlement.signalFatal(reason);
    this.wakeCancelSettleWaiters(); return this.releaseTransport(reason);
  }
  private awaitWireExecutionDispatched(scope: PostgresCommandScope, epoch: number, handle: PostgresCancelHandle): Promise<void> | null {
    if (!this.canCancelExecution(scope, epoch) || (this.wireEpochReading && this.activeWireWriteCount === 0)) return null;
    return new Promise<void>((resolve: () => void): void => {
      let done = false; const finish = (): void => { if (!done) { done = true; this.wireDispatchWaiters.delete(check); resolve(); } };
      const check = (): void => { if (!this.canCancelExecution(scope, epoch) || (this.wireEpochReading && this.activeWireWriteCount === 0)) finish(); };
      this.wireDispatchWaiters.add(check); handle.cleanupSettled.then(finish);
    });
  }
  private wakeWireDispatchWaiters(): void { wakeWaiterSet(this.wireDispatchWaiters); }
  private async abortActiveCancels(reason: ArkDbError): Promise<ArkDbError | null> {
    this.wakeWireDispatchWaiters(); this.wakeCancelSettleWaiters(); if (this.activeCancels.size === 0) return null;
    const handles: PostgresCancelHandle[] = []; this.activeCancels.forEach((h: PostgresCancelHandle): void => { handles.push(h); h.abort(reason); });
    let combined: ArkDbError | null = null; for (const h of handles) combined = composeOptionalErrors(combined, await h.cleanupSettled); return combined;
  }
}
function wakeWaiterSet(waiters: Set<() => void>): void {
  if (waiters.size === 0) return; const pending: Array<() => void> = []; waiters.forEach((fn: () => void): void => { pending.push(fn); }); for (const fn of pending) fn();
}
function defaultPostgresServerInfo(): PostgresServerInfo {
  const info = new PostgresServerInfo(); info.driverId = 'pgsql'; info.productName = 'PostgreSQL'; return info;
}
function commitServerInfo(src: PostgresServerInfo, dst: PostgresServerInfo): void {
  dst.driverId = src.driverId; dst.productName = src.productName; dst.connectionHandle = src.connectionHandle;
  dst.defaultEncoding = src.defaultEncoding; dst.version = src.version; dst.tlsActive = src.tlsActive;
  dst.backendProcessId = src.backendProcessId; dst.protocolMajor = src.protocolMajor;
  dst.protocolMinor = src.protocolMinor; dst.serverEncoding = src.serverEncoding;
  dst.integerDatetimes = src.integerDatetimes; dst.dateStyle = src.dateStyle; dst.timeZone = src.timeZone;
}
function safeDisposeDeadline(deadline: ConnectionDeadline | null): ArkDbError | null {
  if (deadline === null) return null;
  try { deadline.dispose(); return null; } catch (error) { return toPostgresArkDbError(error as Object, ArkDbErrorKind.Protocol); }
}
function safeCancelDeadline(deadline: ConnectionDeadline | null, reason: ArkDbError): ArkDbError | null {
  if (deadline === null) return null;
  try { deadline.cancel(reason); return null; } catch (error) { return toPostgresArkDbError(error as Object, ArkDbErrorKind.Protocol); }
}
function composeOptionalErrors(primary: ArkDbError | null, secondary: ArkDbError | null): ArkDbError | null {
  if (primary === null) return secondary;
  if (secondary === null || secondary === primary) return primary;
  return postgresAppendDecomposedCleanup(primary, secondary);
}
function shouldRetireAfterError(error: ArkDbError): boolean {
  if (error instanceof PostgresError && (error.severity === 'FATAL' || error.severity === 'PANIC' ||
    error.localizedSeverity === 'FATAL' || error.localizedSeverity === 'PANIC')) return true;
  return error.kind === ArkDbErrorKind.Network || error.kind === ArkDbErrorKind.Tls || error.kind === ArkDbErrorKind.Protocol;
}
function copySecretBytes(source: Uint8Array): Uint8Array {
  const copy = new Uint8Array(source.length); copy.set(source); return copy;
}
class LifecycleDeadlineHost implements PostgresStatementDeadlineHost {
  private readonly lc: PostgresConnectionLifecycle; private readonly scope: PostgresCommandScope; private readonly st: PostgresCommandCloseSettlement; private readonly canLatch?: () => boolean;
  constructor(lc: PostgresConnectionLifecycle, scope: PostgresCommandScope, st: PostgresCommandCloseSettlement, canLatch?: () => boolean) { this.lc = lc; this.scope = scope; this.st = st; this.canLatch = canLatch; }
  get timers(): ConnectionTimerPort { return this.lc.timers; } get currentWireEpoch(): number { return this.lc.currentWireEpoch; }
  isSynchronized(): boolean { return this.lc.isCommandSynchronized(this.scope); } isSynchronizedConsumerError(error: ArkDbError): boolean { return this.lc.isSynchronizedConsumerError(error); }
  hasBlockingCancels(): boolean { return this.lc.hasBlockingCancels(); } waitBlockingCancelsSettled(onSettled?: () => void): Promise<void> { return this.lc.waitBlockingCancelsSettled(onSettled); }
  settleConvergedCancels(reason: ArkDbError): Promise<ArkDbError | null> { return this.lc.settleConvergedCancels(reason); }
  latchDeadlineError(error: ArkDbError): void { if (this.canLatch === undefined || this.canLatch()) this.lc.latchDeadlineError(this.scope, error); }
  readDeadlineBase(root: ArkDbError): ArkDbError { return this.canLatch === undefined || this.canLatch() ? this.lc.readDeadlineBase(this.scope, root) : root; }
  isLatchedConsumerError(error: ArkDbError): boolean { return (this.canLatch === undefined || this.canLatch()) && this.lc.isLatchedConsumerError(error); }
  syncDeadlineError(error: ArkDbError, synchronized: boolean): void { if (this.canLatch === undefined || this.canLatch()) this.lc.syncDeadlineError(this.scope, error, synchronized); }
  triggerDeadlineCancel(epochBefore: number): Promise<ArkDbError | null> { return this.lc.cancelForDeadline(this.scope, epochBefore); }
  retireOnDeadlineFailure(reason: ArkDbError): Promise<ArkDbError | null> { return this.lc.retireFromDeadline(this.scope, this.st, reason); }
  awaitBounded(op: () => Promise<ArkDbError | null>, msg: string): Promise<ArkDbError | null> { return this.lc.awaitBounded(op, msg); }
  reportCloseTimerError(error: ArkDbError): void { this.lc.recordClosedTimerError(this.scope, error); }
}
