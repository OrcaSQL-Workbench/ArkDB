import { ArkDbError, ArkDbErrorKind, ConnectionDeadline, ConnectionState, ConnectionTimerPort, SystemConnectionTimerPort } from '@arkdb/core';
import { createDefaultPostgresStartupRunner } from '../command/PostgresStartup';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandPhase, PostgresCommandScope } from '../execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement, PostgresStartupSession, PostgresStartupTransport, applyPostgresReadyStatus, postgresAppendCleanupError, resetPostgresSessionStatus, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresConnectionConfig, PostgresSslConfig } from '../model/PostgresConnectionConfig';
import { PostgresDatabaseSessionStatus, PostgresError, PostgresServerInfo } from '../model/PostgresModels';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import { PostgresByteTransport, PostgresMessage, PostgresMessageChannel, PostgresReadyStatus } from '../protocol/PostgresMessageChannel';
import { PostgresTcpTransport } from '../transport/PostgresTcpTransport';

export const POSTGRES_TERMINATE_TIMEOUT_MS: number = 1000;
const postgresLifecyclePasswords: WeakMap<PostgresConnectionLifecycle, string> = new WeakMap<PostgresConnectionLifecycle, string>();
const postgresBackendSecrets: WeakMap<PostgresConnectionLifecycle, PostgresBackendCancellationKey> = new WeakMap<PostgresConnectionLifecycle, PostgresBackendCancellationKey>();

export interface PostgresLifecycleTransport extends PostgresStartupTransport {
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
  private activeToken: Object | null = null;
  constructor(transport: PostgresByteTransport, onBegin: () => void, onEnd: (error: Object | null, isOwner: boolean) => Object) {
    super(transport); this.onBegin = onBegin; this.onEnd = onEnd;
  }
  readMessage(maxFrameBytes?: number): Promise<PostgresMessage> { return this.guard<PostgresMessage>((): Promise<PostgresMessage> => super.readMessage(maxFrameBytes)); }
  writeMessage(type: number, payload: Uint8Array): Promise<void> { return this.guard<void>((): Promise<void> => super.writeMessage(type, payload)); }
  writeUntypedMessage(payload: Uint8Array): Promise<void> { return this.guard<void>((): Promise<void> => super.writeUntypedMessage(payload)); }
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
  constructor(inner: PostgresLifecycleTransport, assertIoScope: () => void, assertRetireScope: () => void,
    onBeginIo: () => void, onEndIo: (damaged: ArkDbError | null) => void, onRetire: (reason: ArkDbError) => Promise<void>) {
    this.inner = inner; this.assertIoScope = assertIoScope; this.assertRetireScope = assertRetireScope;
    this.onBeginIo = onBeginIo; this.onEndIo = onEndIo; this.onRetire = onRetire;
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
    return this.guardIo<number>(ArkDbErrorKind.Network, (): Promise<number> => this.inner.write(data),
      (n: number): ArkDbError | null => !Number.isSafeInteger(n) || n !== data.length ? ArkDbError.protocol('PostgreSQL transport write was incomplete.') : null);
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
  readBackendKeyData(): PostgresBackendCancellationKey | null {
    const stored = postgresBackendSecrets.get(this);
    return stored === undefined ? null : new PostgresBackendCancellationKey(stored.processId, copySecretBytes(stored.secretKey), stored.secretKeyInt32);
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
  async runCommand<T>(kind: PostgresCommandKind, runner: PostgresCommandRunner<T>): Promise<T> {
    if (kind === PostgresCommandKind.Connect || kind === PostgresCommandKind.Close) throw ArkDbError.protocol('Invalid PostgreSQL command kind for session execution.');
    if (this.closeRequested || this.currentState === ConnectionState.Closed) throw ArkDbError.protocol('PostgreSQL connection is closed.');
    if (this.currentState === ConnectionState.Idle) throw ArkDbError.protocol('PostgreSQL connection is not connected.');
    if (this.currentState === ConnectionState.Error || this.unsynchronized) throw ArkDbError.protocol('PostgreSQL connection is retired after an unrecoverable error.');
    const scope = this.commandGate.reserve(kind); const settlement = new PostgresCommandCloseSettlement(scope);
    this.activeSettlement = settlement; this.activeReleaseScope = null; this.activeScopeRelease = null; this.closedScope = null;
    let failure: ArkDbError | null = null; let output: T | undefined = undefined; this.retiredCleanup = null; this.retiredComposed = null;
    try {
      this.commandGate.start(scope); this.throwIfRetiredOrClosing(settlement);
      if (this.currentState !== ConnectionState.Ready || this.transport === null) throw ArkDbError.protocol('PostgreSQL connection channel is unavailable.');
      const channel = this.createScopedChannel(scope, this.transport);
      this.commandGate.setPhase(scope, PostgresCommandPhase.Executing); this.currentState = ConnectionState.Querying;
      const result = await settlement.raceClose<T>((): Promise<T> => runner(scope, channel, settlement));
      this.throwIfRetiredOrClosing(settlement);
      if (this.pendingIoCount > 0 || this.awaitingReadyForQuery || !this.readySynchronized || this.transport === null) throw ArkDbError.protocol('PostgreSQL command completed without ReadyForQuery synchronization.');
      this.currentState = ConnectionState.Ready; output = result;
    } catch (error) {
      const rawErr = toPostgresArkDbError(error as Object);
      const primary = rawErr === settlement.closeReason && this.unsynchronized && this.retiredReason !== null ? this.retiredReason : rawErr;
      const alreadyAppended = primary === this.retiredComposed || primary === this.retiredCleanup;
      if (this.closeRequested || settlement.isCloseRequested) failure = await this.abortScopeFailure(scope, primary, alreadyAppended, ConnectionState.Closed);
      else if (this.unsynchronized || this.pendingIoCount > 0 || this.awaitingReadyForQuery || !this.readySynchronized || this.transport === null || shouldRetireAfterError(primary)) {
        this.markStreamDamaged(primary); failure = await this.abortScopeFailure(scope, primary, alreadyAppended, ConnectionState.Error);
      } else { this.currentState = ConnectionState.Ready; failure = primary; }
    } finally {
      this.retiredCleanup = null; this.retiredComposed = null; failure = this.finishScope(scope, settlement, failure);
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
        this.retiredComposed = composed; this.retiredReason = composed;
      }
      throw composed;
    }
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
    const settlement = this.activeSettlement;
    const activeScope = settlement !== null ? settlement.scope : this.commandGate.current;
    if (activeScope !== null) {
      if (this.closedScope === activeScope) {
        this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed; return;
      }
      const closeReason = ArkDbError.cancelled('PostgreSQL connection closed during operation.');
      this.closeRequested = true; this.closedScope = activeScope;
      if (settlement !== null) {
        this.closedSettlement = settlement; this.closedSettlementTerminalError = null; this.awaitingClosedSettlement = true;
      }
      let timerErr: ArkDbError | null = null; let cleanup: ArkDbError | null = null; let terminalErr: ArkDbError | null = null;
      try {
        this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
        if (this.commandGate.isOwner(activeScope)) {
          this.commandGate.advanceGenerationOnRelease(activeScope);
          if (activeScope.phase !== PostgresCommandPhase.Closing) this.commandGate.setPhase(activeScope, PostgresCommandPhase.Closing);
        }
        const activeDeadline = this.opening; this.opening = null;
        timerErr = safeCancelDeadline(activeDeadline, closeReason);
        if (settlement !== null) settlement.signalClose(closeReason);
        cleanup = await this.releaseTransport(closeReason);
        if (settlement !== null) {
          await settlement.settled;
          if (this.activeReleaseScope === activeScope && this.activeScopeRelease !== null) {
            cleanup = composeOptionalErrors(cleanup, await this.activeScopeRelease);
          }
          if (this.closedSettlement === settlement) terminalErr = this.closedSettlementTerminalError;
        }
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
      const cleanup = await this.releaseTransport(null);
      if (cleanup !== null) throw cleanup;
      return;
    }
    if (this.currentState === ConnectionState.Idle && this.commandGate.current === null) {
      this.closeRequested = true; this.clearSecretsAndChannel(); this.commandGate.advanceGeneration(); this.currentState = ConnectionState.Closed; return;
    }
    const activeTransport = this.transport;
    const shouldSendTerminate = this.currentState === ConnectionState.Ready && this.commandGate.current === null &&
      !this.unsynchronized && !this.awaitingReadyForQuery && this.pendingIoCount === 0 && this.readySynchronized && activeTransport !== null;
    this.closeRequested = true;
    const scope = this.commandGate.reserve(PostgresCommandKind.Close);
    let failure: ArkDbError | null = null;
    try {
      this.commandGate.advanceGenerationOnRelease(scope); this.commandGate.setPhase(scope, PostgresCommandPhase.Closing);
      try { this.commandGate.start(scope); } catch (e) { failure = toPostgresArkDbError(e as Object); }
      this.clearSecretsAndChannel(); this.currentState = ConnectionState.Closed;
      if (failure === null && shouldSendTerminate && activeTransport !== null && this.transport === activeTransport) {
        await this.sendTerminateBestEffort(activeTransport);
      }
      const cleanup = await this.releaseTransport(failure);
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
      const resolved = captured !== null && captured.kind !== ArkDbErrorKind.Protocol ? captured : err;
      if (this.commandGate.isOwner(scope)) { const typed = toPostgresArkDbError(resolved); if (typed.kind !== ArkDbErrorKind.Validation) this.markStreamDamaged(typed); }
      return resolved;
    });
  }
  private createScopedTransport(scope: PostgresCommandScope, transport: PostgresLifecycleTransport,
    isClosed?: () => boolean, onDamaged?: (damaged: ArkDbError) => void): PostgresLifecycleTransport {
    return new ScopedPostgresTransport(transport, (): void => { this.assertActiveIoScope(scope, isClosed); },
      (): void => { this.assertActiveScope(scope, isClosed); },
      (): void => { this.pendingIoCount += 1; this.awaitingReadyForQuery = true; this.readySynchronized = false; resetPostgresSessionStatus(this.sessionStatus); },
      (d: ArkDbError | null): void => {
        this.decrementPendingIo();
        if (d !== null) { if (onDamaged !== undefined) onDamaged(d); if (this.commandGate.isOwner(scope)) this.markStreamDamaged(d); }
      }, (reason: ArkDbError): Promise<void> => this.retire(scope, reason));
  }
  private async abortScopeFailure(scope: PostgresCommandScope, primary: ArkDbError, alreadyAppended: boolean, state: ConnectionState): Promise<ArkDbError> {
    const targetState = this.closeRequested ? ConnectionState.Closed : state;
    this.clearSecretsAndChannel(); this.currentState = targetState;
    if (scope.phase !== PostgresCommandPhase.Closing) this.commandGate.setPhase(scope, PostgresCommandPhase.Closing);
    this.commandGate.advanceGenerationOnRelease(scope);
    const cleanup = await this.releaseTransport(primary);
    await this.waitPendingIoIdle();
    this.clearSecretsAndChannel(); this.currentState = this.closeRequested ? ConnectionState.Closed : targetState;
    const base = alreadyAppended ? primary : this.composeRetiredCleanup(primary);
    return !alreadyAppended && cleanup !== null && cleanup !== base && cleanup !== this.retiredCleanup ? postgresAppendCleanupError(base, cleanup) : base;
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
    this.readySynchronized = true; this.awaitingReadyForQuery = false;
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
  private markStreamDamaged(reason: ArkDbError): void { if (!this.unsynchronized) this.retiredReason = reason; this.unsynchronized = true; this.readySynchronized = false; resetPostgresSessionStatus(this.sessionStatus); }
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
  private finishScope(scope: PostgresCommandScope, settlement: PostgresCommandCloseSettlement, failure: ArkDbError | null): ArkDbError | null {
    if (this.activeSettlement === settlement) {
      this.activeSettlement = null;
      if (!this.awaitingClosedSettlement || this.closedSettlement !== settlement) {
        if (this.activeReleaseScope === scope) { this.activeReleaseScope = null; this.activeScopeRelease = null; }
        if (this.closedScope === scope) this.closedScope = null;
      }
    }
    let scopeEndErr: ArkDbError | null = null;
    try { settlement.markSettled(); } catch (e) { scopeEndErr = toPostgresArkDbError(e as Object); }
    scopeEndErr = this.releaseScopeSafe(scope, scopeEndErr);
    if (this.closedSettlement === settlement) {
      if (this.awaitingClosedSettlement) this.closedSettlementTerminalError = scopeEndErr;
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
  private clearSecretsAndChannel(): void {
    postgresLifecyclePasswords.delete(this); const storedKey = postgresBackendSecrets.get(this);
    if (storedKey !== undefined) { storedKey.secretKey.fill(0); postgresBackendSecrets.delete(this); }
    resetPostgresSessionStatus(this.sessionStatus); commitServerInfo(defaultPostgresServerInfo(), this.serverInfo);
    this.readySynchronized = false; this.awaitingReadyForQuery = false;
  }
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
  return postgresAppendCleanupError(primary, secondary);
}
function shouldRetireAfterError(error: ArkDbError): boolean {
  if (error instanceof PostgresError && (error.severity === 'FATAL' || error.severity === 'PANIC' ||
    error.localizedSeverity === 'FATAL' || error.localizedSeverity === 'PANIC')) return true;
  return error.kind === ArkDbErrorKind.Network || error.kind === ArkDbErrorKind.Tls || error.kind === ArkDbErrorKind.Protocol;
}
function copySecretBytes(source: Uint8Array): Uint8Array {
  const copy = new Uint8Array(source.length); copy.set(source); return copy;
}
