import { ArkDbError, ArkDbErrorKind, ConnectionDeadline, ConnectionState, ConnectionTimerPort, SystemConnectionTimerPort } from '@arkdb/core';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandPhase, PostgresCommandScope } from '../execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement, applyPostgresReadyStatus, postgresAppendCleanupError, resetPostgresSessionStatus, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresConnectionConfig, PostgresSslConfig } from '../model/PostgresConnectionConfig';
import { PostgresDatabaseSessionStatus, PostgresError, PostgresServerInfo } from '../model/PostgresModels';
import { PostgresByteTransport, PostgresMessageChannel, PostgresReadyStatus } from '../protocol/PostgresMessageChannel';
import { PostgresTcpTransport } from '../transport/PostgresTcpTransport';

const postgresLifecyclePasswords: WeakMap<PostgresConnectionLifecycle, string> = new WeakMap<PostgresConnectionLifecycle, string>();
const postgresBackendSecrets: WeakMap<PostgresConnectionLifecycle, PostgresBackendCancellationKey> = new WeakMap<PostgresConnectionLifecycle, PostgresBackendCancellationKey>();

export interface PostgresLifecycleTransport extends PostgresByteTransport {
  connect(host: string, port: number, timeoutMs: number): Promise<void>;
  prepareTlsUpgrade?(): void;
  upgradeToTls?(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void>;
  close(): Promise<void>;
  abort(error: ArkDbError): Promise<void>;
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
export class PostgresStartupContext {
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
export type PostgresCommandRunner<T> = (scope: PostgresCommandScope,
  channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement) => Promise<T>;

class DefaultPostgresLifecycleTransport implements PostgresLifecycleTransport {
  private readonly inner: PostgresTcpTransport;
  constructor(timers: ConnectionTimerPort) { this.inner = new PostgresTcpTransport(undefined, undefined, timers); }
  connect(host: string, port: number, timeoutMs: number): Promise<void> { return this.inner.connect(host, port, timeoutMs); }
  prepareTlsUpgrade(): void { this.inner.prepareTlsUpgrade(); }
  upgradeToTls(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void> {
    return this.inner.upgradeToTls(host, port, config, timeoutMs);
  }
  read(maximumBytes: number): Promise<Uint8Array | null> { return this.inner.read(maximumBytes); }
  write(data: Uint8Array): Promise<number> { return this.inner.write(data); }
  close(): Promise<void> { return this.inner.close(); }
  abort(error: ArkDbError): Promise<void> { return this.inner.abort(error); }
}
class ScopedPostgresTransport implements PostgresLifecycleTransport {
  private readonly inner: PostgresLifecycleTransport;
  private readonly assertScope: () => void; private readonly onWireIo: () => void;
  private readonly onRetire: (reason: ArkDbError) => Promise<void>;
  constructor(inner: PostgresLifecycleTransport, assertScope: () => void,
    onWireIo: () => void, onRetire: (reason: ArkDbError) => Promise<void>) {
    this.inner = inner; this.assertScope = assertScope; this.onWireIo = onWireIo; this.onRetire = onRetire;
  }
  connect(host: string, port: number, timeoutMs: number): Promise<void> {
    return this.guardIo<void>((): Promise<void> => this.inner.connect(host, port, timeoutMs));
  }
  prepareTlsUpgrade(): void {
    this.assertScope(); this.onWireIo();
    if (this.inner.prepareTlsUpgrade === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable.');
    this.inner.prepareTlsUpgrade();
  }
  upgradeToTls(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void> {
    return this.guardIo<void>((): Promise<void> => {
      if (this.inner.upgradeToTls === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable.');
      return this.inner.upgradeToTls(host, port, config, timeoutMs);
    });
  }
  read(maxBytes: number): Promise<Uint8Array | null> { return this.guardIo<Uint8Array | null>((): Promise<Uint8Array | null> => this.inner.read(maxBytes)); }
  write(data: Uint8Array): Promise<number> { return this.guardIo<number>((): Promise<number> => this.inner.write(data)); }
  close(): Promise<void> { return this.guardRetire(ArkDbError.protocol('PostgreSQL transport closed during operation.')); }
  abort(error: ArkDbError): Promise<void> { return this.guardRetire(error); }
  private guardIo<T>(op: () => Promise<T>): Promise<T> {
    try { this.assertScope(); this.onWireIo(); return op(); } catch (e) { return Promise.reject<T>(e as Object); }
  }
  private guardRetire(reason: ArkDbError): Promise<void> {
    try { return this.onRetire(reason); } catch (e) { return Promise.reject<void>(e as Object); }
  }
}

export class PostgresConnectionLifecycle {
  readonly timers: ConnectionTimerPort;
  readonly serverInfo: PostgresServerInfo = new PostgresServerInfo();
  readonly sessionStatus: PostgresDatabaseSessionStatus = new PostgresDatabaseSessionStatus();
  readonly commandGate: PostgresCommandGate;
  private readonly storedConfig: PostgresConnectionConfig;
  private readonly transportFactory: () => PostgresLifecycleTransport;
  private readonly startupRunner: PostgresStartupRunner | null;
  private currentState: ConnectionState = ConnectionState.Idle;
  private transport: PostgresLifecycleTransport | null = null;
  private releaseTask: Promise<ArkDbError | null> | null = null;
  private awaitingReadyForQuery: boolean = false; private unsynchronized: boolean = false;
  private retiredReason: ArkDbError | null = null; private retiredCleanup: ArkDbError | null = null;
  private retiredComposed: ArkDbError | null = null;
  constructor(config: PostgresConnectionConfig, password: string, timers: ConnectionTimerPort = new SystemConnectionTimerPort(),
    transportFactory?: () => PostgresLifecycleTransport, startupRunner?: PostgresStartupRunner,
    commandGate: PostgresCommandGate = new PostgresCommandGate()) {
    const errors = config.validate();
    if (errors.length > 0) throw errors[0];
    this.storedConfig = config.clone(); this.timers = timers; this.commandGate = commandGate;
    this.transportFactory = transportFactory === undefined ?
      (): PostgresLifecycleTransport => new DefaultPostgresLifecycleTransport(this.timers) : transportFactory;
    this.startupRunner = startupRunner === undefined ? null : startupRunner;
    postgresLifecyclePasswords.set(this, password); this.resetServerInfo();
  }
  get config(): PostgresConnectionConfig { return this.storedConfig.clone(); }
  get state(): ConnectionState { return this.currentState; }
  readBackendKeyData(): PostgresBackendCancellationKey | null {
    const stored = postgresBackendSecrets.get(this);
    return stored === undefined ? null : new PostgresBackendCancellationKey(stored.processId, copySecretBytes(stored.secretKey), stored.secretKeyInt32);
  }
  applyReadyStatus(scope: PostgresCommandScope, ready: PostgresReadyStatus): void {
    this.commandGate.assertOwner(scope);
    if (this.unsynchronized || scope.kind === PostgresCommandKind.Connect ||
      scope.phase === PostgresCommandPhase.Closing || this.currentState !== ConnectionState.Querying) {
      throw ArkDbError.protocol('PostgreSQL ReadyForQuery requires an active synchronized command.');
    }
    applyPostgresReadyStatus(this.sessionStatus, ready); this.awaitingReadyForQuery = false;
  }

  async connect(): Promise<void> {
    if (this.currentState === ConnectionState.Closed) throw ArkDbError.protocol('PostgreSQL connection is closed.');
    if (this.currentState !== ConnectionState.Idle) {
      throw ArkDbError.protocol('PostgreSQL connection cannot connect in state ' + this.currentState + '.');
    }
    if (this.startupRunner === null) throw ArkDbError.unsupported('PostgreSQL connection is not implemented.');
    const scope = this.commandGate.reserve(PostgresCommandKind.Connect);
    const settlement = new PostgresCommandCloseSettlement(scope);
    let deadline: ConnectionDeadline | null = null;
    this.retiredCleanup = null; this.retiredComposed = null;
    try {
      this.commandGate.start(scope);
      deadline = new ConnectionDeadline(this.storedConfig.connectTimeoutMs, this.timers);
      const budget = deadline;
      this.commandGate.setPhase(scope, PostgresCommandPhase.Connecting);
      this.currentState = ConnectionState.Connecting; resetPostgresSessionStatus(this.sessionStatus);
      this.awaitingReadyForQuery = false; this.unsynchronized = false; this.retiredReason = null;
      const transport = this.transportFactory(); this.transport = transport;
      await budget.wait((): Promise<void> => settlement.raceClose((): Promise<void> =>
        transport.connect(this.storedConfig.host, this.storedConfig.port, budget.remainingMs())));
      budget.remainingMs();
      const scoped = this.createScopedTransport(scope, transport);
      const channel = new PostgresMessageChannel(scoped);
      const context = this.createStartupContext(scope, scoped, channel, budget, settlement);
      await budget.wait((): Promise<void> => settlement.raceClose((): Promise<void> => this.startupRunner!(context)));
      this.throwIfRetiredOrClosing(settlement); budget.remainingMs();
      if (this.state !== ConnectionState.Authenticating) {
        throw ArkDbError.protocol('PostgreSQL startup completed without authentication.');
      }
      if (this.awaitingReadyForQuery || !this.sessionStatus.known || this.transport === null) {
        throw ArkDbError.protocol('PostgreSQL startup completed without ReadyForQuery synchronization.');
      }
      postgresLifecyclePasswords.delete(this);
      const disposeErr = safeDisposeDeadline(deadline); deadline = null;
      if (disposeErr !== null) throw disposeErr;
      this.currentState = ConnectionState.Ready;
    } catch (error) {
      let primary = toPostgresArkDbError(error as Object, ArkDbErrorKind.Network);
      const cleanup = await this.releaseTransport(primary);
      primary = this.composeRetiredCleanup(primary);
      const timerErr = safeDisposeDeadline(deadline); deadline = null;
      if (timerErr !== null && timerErr !== primary) primary = postgresAppendCleanupError(primary, timerErr);
      throw this.completeAbortedScope(scope, primary, cleanup, true,
        settlement.isCloseRequested ? ConnectionState.Closed : ConnectionState.Error);
    } finally {
      safeDisposeDeadline(deadline); this.retiredCleanup = null; this.retiredComposed = null;
      this.finishScope(scope, settlement);
    }
  }

  async runCommand<T>(kind: PostgresCommandKind, runner: PostgresCommandRunner<T>): Promise<T> {
    if (kind === PostgresCommandKind.Connect || kind === PostgresCommandKind.Close) {
      throw ArkDbError.protocol('Invalid PostgreSQL command kind for session execution.');
    }
    if (this.currentState === ConnectionState.Closed) throw ArkDbError.protocol('PostgreSQL connection is closed.');
    if (this.currentState === ConnectionState.Idle) throw ArkDbError.protocol('PostgreSQL connection is not connected.');
    if (this.currentState === ConnectionState.Error || this.unsynchronized) {
      throw ArkDbError.protocol('PostgreSQL connection is retired after an unrecoverable error.');
    }
    const scope = this.commandGate.reserve(kind);
    const settlement = new PostgresCommandCloseSettlement(scope);
    this.retiredCleanup = null; this.retiredComposed = null;
    try {
      this.commandGate.start(scope);
      if (this.currentState !== ConnectionState.Ready || this.transport === null) {
        throw ArkDbError.protocol('PostgreSQL connection channel is unavailable.');
      }
      const channel = new PostgresMessageChannel(this.createScopedTransport(scope, this.transport));
      this.commandGate.setPhase(scope, PostgresCommandPhase.Executing);
      this.currentState = ConnectionState.Querying;
      const result = await runner(scope, channel, settlement);
      this.throwIfRetiredOrClosing(settlement);
      if (this.awaitingReadyForQuery || !this.sessionStatus.known || this.transport === null) {
        throw ArkDbError.protocol('PostgreSQL command completed without ReadyForQuery synchronization.');
      }
      this.currentState = ConnectionState.Ready;
      return result;
    } catch (error) {
      let primary = toPostgresArkDbError(error as Object);
      if (settlement.isCloseRequested) {
        const cleanup = await this.releaseTransport(primary);
        throw this.completeAbortedScope(scope, this.composeRetiredCleanup(primary), cleanup, false, ConnectionState.Closed);
      }
      if (this.unsynchronized || this.awaitingReadyForQuery || !this.sessionStatus.known ||
        this.transport === null || shouldRetireAfterError(primary)) {
        if (!this.unsynchronized) {
          const cleanup = await this.retireInternal(scope, primary);
          if (cleanup !== null && cleanup !== primary) primary = postgresAppendCleanupError(primary, cleanup);
          throw primary;
        }
        const cleanup = await this.releaseTransport(primary);
        throw this.completeAbortedScope(scope, this.composeRetiredCleanup(primary), cleanup, false, ConnectionState.Error);
      }
      this.currentState = ConnectionState.Ready;
      throw primary;
    } finally {
      this.retiredCleanup = null; this.retiredComposed = null;
      this.finishScope(scope, settlement);
    }
  }

  async retire(scope: PostgresCommandScope, reason: ArkDbError): Promise<void> {
    this.commandGate.assertOwner(scope);
    const cleanup = await this.retireInternal(scope, reason);
    if (cleanup !== null && cleanup !== reason) {
      const composed = postgresAppendCleanupError(reason, cleanup);
      if (this.commandGate.isOwner(scope)) { this.retiredComposed = composed; this.retiredReason = composed; }
      throw composed;
    }
  }

  async close(): Promise<void> {
    if (this.currentState === ConnectionState.Closed && this.commandGate.current === null &&
      this.transport === null && this.releaseTask === null) {
      this.clearSecretsAndChannel(false); return;
    }
    if (this.currentState === ConnectionState.Idle && this.commandGate.current === null) {
      this.clearSecretsAndChannel(false); this.commandGate.advanceGeneration();
      this.currentState = ConnectionState.Closed; return;
    }
    if (this.currentState === ConnectionState.Error && this.commandGate.current === null) {
      const cleanup = await this.releaseTransport(null);
      this.clearSecretsAndChannel(false); this.currentState = ConnectionState.Closed;
      if (cleanup !== null) throw cleanup;
      return;
    }
    const scope = this.commandGate.reserve(PostgresCommandKind.Close);
    let cleanupFailure: ArkDbError | null = null;
    try {
      this.commandGate.start(scope); this.commandGate.setPhase(scope, PostgresCommandPhase.Closing);
      this.commandGate.advanceGenerationOnRelease(scope);
      cleanupFailure = await this.releaseTransport(null);
    } finally {
      this.clearSecretsAndChannel(false); this.currentState = ConnectionState.Closed;
      if (this.commandGate.isOwner(scope)) this.commandGate.release(scope);
    }
    if (cleanupFailure !== null) throw cleanupFailure;
  }

  private createScopedTransport(scope: PostgresCommandScope,
    transport: PostgresLifecycleTransport): PostgresLifecycleTransport {
    return new ScopedPostgresTransport(transport, (): void => { this.commandGate.assertOwner(scope); },
      (): void => { this.awaitingReadyForQuery = true; resetPostgresSessionStatus(this.sessionStatus); },
      (reason: ArkDbError): Promise<void> => this.retire(scope, reason));
  }

  private createStartupContext(scope: PostgresCommandScope, transport: PostgresLifecycleTransport,
    channel: PostgresMessageChannel, budget: ConnectionDeadline,
    settlement: PostgresCommandCloseSettlement): PostgresStartupContext {
    let startupSynchronized = false;
    const assertStartupOpen = (): void => {
      this.commandGate.assertOwner(scope); this.throwIfRetiredOrClosing(settlement); budget.remainingMs();
      if (startupSynchronized) throw ArkDbError.protocol('PostgreSQL startup already synchronized on ReadyForQuery.');
    };
    const assertAuthPhase = (msg: string): void => {
      assertStartupOpen();
      if (this.state !== ConnectionState.Authenticating || scope.phase !== PostgresCommandPhase.Authenticating) {
        throw ArkDbError.protocol(msg);
      }
    };
    return new PostgresStartupContext(scope, this.storedConfig.clone(), transport, channel, budget, settlement, this.serverInfo, {
      enterAuth: (): void => {
        assertStartupOpen();
        const state = this.state;
        if (state !== ConnectionState.Connecting && state !== ConnectionState.Authenticating) {
          throw ArkDbError.protocol('Invalid PostgreSQL startup authentication transition.');
        }
        this.commandGate.setPhase(scope, PostgresCommandPhase.Authenticating); this.currentState = ConnectionState.Authenticating;
      },
      readPassword: (): string => {
        assertAuthPhase('PostgreSQL password is available only during authentication.');
        const pw = postgresLifecyclePasswords.get(this);
        if (pw === undefined) throw ArkDbError.protocol('PostgreSQL password is no longer available.');
        return pw;
      },
      setBackendKey: (pid: number, key: Uint8Array): void => {
        assertAuthPhase('PostgreSQL BackendKeyData is valid only during startup authentication.');
        this.storeBackendKeyData(pid, key);
      },
      applyReady: (ready: PostgresReadyStatus): void => {
        assertAuthPhase('PostgreSQL startup ReadyForQuery requires authentication phase.');
        applyPostgresReadyStatus(this.sessionStatus, ready);
        this.awaitingReadyForQuery = false; startupSynchronized = true; postgresLifecyclePasswords.delete(this);
      }
    });
  }
  private storeBackendKeyData(processId: number, secretKey: Uint8Array): void {
    if (!Number.isInteger(processId) || processId < -2147483648 || processId > 2147483647) throw ArkDbError.protocol('Invalid PostgreSQL backend process ID.');
    if (secretKey.length !== 4) throw ArkDbError.protocol('Invalid PostgreSQL backend secret key length.');
    const normalizedPid = processId === 0 ? 0 : processId;
    const previous = postgresBackendSecrets.get(this);
    if (previous !== undefined) previous.secretKey.fill(0);
    const copy = copySecretBytes(secretKey);
    const int32 = new DataView(copy.buffer, copy.byteOffset, 4).getInt32(0, false);
    postgresBackendSecrets.set(this, new PostgresBackendCancellationKey(normalizedPid, copy, int32));
    this.serverInfo.backendProcessId = normalizedPid; this.serverInfo.connectionHandle = String(normalizedPid);
  }
  private throwIfRetiredOrClosing(settlement: PostgresCommandCloseSettlement): void {
    if (this.unsynchronized) throw this.retiredReason !== null ? this.retiredReason : ArkDbError.protocol('PostgreSQL connection synchronization was lost.');
    if (settlement.closeReason !== null) throw settlement.closeReason;
  }
  private composeRetiredCleanup(primary: ArkDbError): ArkDbError {
    return this.retiredCleanup !== null && primary !== this.retiredComposed && primary !== this.retiredCleanup ? postgresAppendCleanupError(primary, this.retiredCleanup) : primary;
  }
  private completeAbortedScope(scope: PostgresCommandScope, primary: ArkDbError, cleanup: ArkDbError | null, resetInfo: boolean, state: ConnectionState): ArkDbError {
    this.clearSecretsAndChannel(resetInfo); this.currentState = state; this.commandGate.advanceGenerationOnRelease(scope);
    return cleanup !== null && cleanup !== primary && cleanup !== this.retiredCleanup ? postgresAppendCleanupError(primary, cleanup) : primary;
  }
  private finishScope(scope: PostgresCommandScope, settlement: PostgresCommandCloseSettlement): void {
    try { settlement.markSettled(); } finally { if (this.commandGate.isOwner(scope)) this.commandGate.release(scope); }
  }
  private async retireInternal(scope: PostgresCommandScope, reason: ArkDbError): Promise<ArkDbError | null> {
    if (!this.unsynchronized) this.retiredReason = reason;
    this.unsynchronized = true; this.clearSecretsAndChannel(false); this.currentState = ConnectionState.Error;
    this.commandGate.advanceGenerationOnRelease(scope);
    const cleanup = await this.releaseTransport(reason);
    if (cleanup !== null && cleanup !== reason && this.retiredCleanup === null && this.commandGate.isOwner(scope)) this.retiredCleanup = cleanup;
    return cleanup;
  }
  private releaseTransport(abortReason: ArkDbError | null): Promise<ArkDbError | null> {
    if (this.releaseTask !== null) return this.releaseTask;
    const active = this.transport;
    if (active === null) return Promise.resolve<ArkDbError | null>(null);
    this.transport = null; this.awaitingReadyForQuery = false;
    let raw: Promise<ArkDbError | null>;
    try {
      raw = (abortReason !== null ? active.abort(abortReason) : active.close()).then((): ArkDbError | null => null,
        (cleanup: Object): ArkDbError | null => toPostgresArkDbError(cleanup, ArkDbErrorKind.Network));
    } catch (cleanup) { raw = Promise.resolve<ArkDbError | null>(toPostgresArkDbError(cleanup as Object, ArkDbErrorKind.Network)); }
    const tracked = raw.then((err: ArkDbError | null): ArkDbError | null => { if (this.releaseTask === tracked) this.releaseTask = null; return err; });
    this.releaseTask = tracked; return tracked;
  }
  private clearSecretsAndChannel(resetConnectServerInfo: boolean): void {
    postgresLifecyclePasswords.delete(this);
    const storedKey = postgresBackendSecrets.get(this);
    if (storedKey !== undefined) { storedKey.secretKey.fill(0); postgresBackendSecrets.delete(this); }
    resetPostgresSessionStatus(this.sessionStatus); this.awaitingReadyForQuery = false;
    if (resetConnectServerInfo) this.resetServerInfo();
  }
  private resetServerInfo(): void {
    this.serverInfo.driverId = 'pgsql'; this.serverInfo.productName = 'PostgreSQL';
    this.serverInfo.connectionHandle = ''; this.serverInfo.defaultEncoding = ''; this.serverInfo.version = '';
    this.serverInfo.tlsActive = false; this.serverInfo.backendProcessId = 0;
    this.serverInfo.protocolMajor = 3; this.serverInfo.protocolMinor = 0; this.serverInfo.serverEncoding = '';
    this.serverInfo.integerDatetimes = true; this.serverInfo.dateStyle = ''; this.serverInfo.timeZone = '';
  }
}
function safeDisposeDeadline(deadline: ConnectionDeadline | null): ArkDbError | null {
  if (deadline === null) return null;
  try { deadline.dispose(); return null; } catch (error) { return toPostgresArkDbError(error as Object, ArkDbErrorKind.Protocol); }
}
function shouldRetireAfterError(error: ArkDbError): boolean {
  if (error instanceof PostgresError && (error.severity === 'FATAL' || error.severity === 'PANIC' ||
    error.localizedSeverity === 'FATAL' || error.localizedSeverity === 'PANIC')) return true;
  return error.kind === ArkDbErrorKind.Network || error.kind === ArkDbErrorKind.Tls || error.kind === ArkDbErrorKind.Protocol;
}
function copySecretBytes(source: Uint8Array): Uint8Array {
  const copy = new Uint8Array(source.length); copy.set(source); return copy;
}
