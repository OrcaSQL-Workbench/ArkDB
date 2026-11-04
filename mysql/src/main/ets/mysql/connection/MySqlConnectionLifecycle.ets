import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionDeadline,
  ConnectionReuse, ConnectionState, ConnectionTimerPort, DatabaseSessionStatus,
  DbConnection, Logger, LogTag, QueryCancellationResult, QueryOptions
} from '@arkdb/core';
import { cachingSha2Scramble, obfuscatePassword } from '../auth/CachingSha2';
import { rsaOaepEncrypt } from '../auth/Crypto';
import { HandshakePacket, parseHandshake } from '../auth/Handshake';
import {
  buildHandshakeResponse, buildSslRequest, computeClientCapabilities,
  HandshakeResponseParams
} from '../auth/HandshakeResponse';
import { nativeScramble } from '../auth/NativePassword';
import {
  parseBufferedResultStream
} from '../command/ResultStream';
import { buildComQuery, parseResultSet } from '../command/Query';
import { parseErr, parseOk } from '../command/ResultPackets';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../execution/MySqlCommandGate';
import {
  MySqlExecutionController, isMySqlInterruptionError,
  mysqlKillQueryForHandle
} from '../execution/MySqlExecutionController';
import {
  mysqlCleanupError as toCleanupError,
  mysqlOperationContains as operationContainsFailure,
  mysqlOperationFailure as operationFailure
} from '../execution/MySqlFailure';
import {
  MYSQL_SESSION_CHARACTER_SET_SQL, MYSQL_SESSION_FINGERPRINT_SQL,
  MySqlSessionFingerprint, MySqlSessionFingerprintRowDecoder,
  mysqlSessionFingerprint, mysqlSessionInitializationSql
} from '../execution/MySqlSessionInitialization';
import {
  CommandCloseSettlement, DeadlineCancellationSettlement, DeadlineObservation,
  MySqlDeadlineTimer, OrdinaryCommandSettlement, PreparedCommandSettlement
} from '../execution/MySqlSettlements';
import { ConnectionConfig, SslMode } from '../model/ConnectionConfig';
import { MySqlDeadlineOptions } from '../model/MySqlDeadlineOptions';
import {
  MySqlExecutionOutcome, MySqlOperationError, isMySqlServerRejection
} from '../model/MySqlOperationError';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  MySqlDatabaseSessionStatus
} from '../model/MySqlQueryStream';
import { MySqlServerInfo } from '../model/MySqlServerInfo';
import { Capabilities, Command, PacketType } from '../protocol/Constants';
import {
  MysqlPacket, PacketChannel
} from '../protocol/PacketChannel';
import { PacketWriter } from '../protocol/PacketWriter';
import { TcpTransport } from '../transport/TcpTransport';
import {
  MySqlControlConnectionBuilder, createMySqlControlConnection
} from './MySqlControlConnectionFactory';

export {
  MySqlSessionFingerprint
} from '../execution/MySqlSessionInitialization';

export type MySqlPreparedOperationSettlement = PreparedCommandSettlement;

type BufferedCommandRunner = (scope: MySqlCommandScope,
  command: Uint8Array,
  parse: (channel: PacketChannel) => Promise<MySqlQueryResult>) =>
  Promise<MySqlQueryResult>;

export class MySqlConnectionLifecycle<T extends DbConnection> {
  readonly config: ConnectionConfig;
  readonly password: string;
  readonly transport: TcpTransport;
  readonly timers: ConnectionTimerPort;
  commandGate: MySqlCommandGate = new MySqlCommandGate();
  channel: PacketChannel | null = null;
  clientCaps: number = 0;
  connState: ConnectionState = ConnectionState.Idle;
  info: MySqlServerInfo = new MySqlServerInfo();
  status: DatabaseSessionStatus = new MySqlDatabaseSessionStatus();
  cancelTask: Promise<QueryCancellationResult> | null = null;
  retiredByCancellation: boolean = false;
  executingScope: MySqlCommandScope | null = null;
  queryWrite: Promise<void> | null = null;
  connectOperation: CommandCloseSettlement | null = null;
  ordinaryOperation: OrdinaryCommandSettlement | null = null;
  preparedOperation: PreparedCommandSettlement | null = null;
  cursorOperation: PreparedCommandSettlement | null = null;
  transactionOperation: PreparedCommandSettlement | null = null;
  skipAutocommitSetup: boolean = false;
  private opening: ConnectionDeadline | null = null;
  private resetting: ConnectionDeadline | null = null;
  private closing: Promise<void> | null = null;
  private tlsActive: boolean = false;
  private authNonce: Uint8Array = new Uint8Array(0);
  private cancellationControl: DbConnection | null = null;
  private deadlineCancellation: DeadlineCancellationSettlement | null = null;
  private completedScope: MySqlCommandScope | null = null;
  private closePending: boolean = false;
  private cancellationHandle: string = '';
  private createControlOverride: (() => DbConnection) | null;
  private defaultControlBuilder: MySqlControlConnectionBuilder<T>;
  private resolveDefaultControlConnection: () => DbConnection;
  private readOwner: () => DbConnection;
  private invalidatePreparedState: () => void;
  private runBufferedCommand: BufferedCommandRunner;
  private readSessionFingerprint:
    (scope: MySqlCommandScope) => Promise<MySqlSessionFingerprint>;

  constructor(config: ConnectionConfig, password: string,
    transport: TcpTransport, timers: ConnectionTimerPort,
    createControlConnection: (() => DbConnection) | undefined,
    defaultControlBuilder: MySqlControlConnectionBuilder<T>,
    resolveDefaultControlConnection: () => DbConnection,
    readOwner: () => DbConnection,
    invalidatePreparedState: () => void,
    runBufferedCommand: BufferedCommandRunner,
    readSessionFingerprint:
      (scope: MySqlCommandScope) => Promise<MySqlSessionFingerprint>) {
    this.config = config.clone();
    this.password = password;
    this.transport = transport;
    this.timers = timers;
    this.createControlOverride = createControlConnection === undefined ?
      null : createControlConnection;
    this.defaultControlBuilder = defaultControlBuilder;
    this.resolveDefaultControlConnection =
      resolveDefaultControlConnection;
    this.readOwner = readOwner;
    this.invalidatePreparedState = invalidatePreparedState;
    this.runBufferedCommand = runBufferedCommand;
    this.readSessionFingerprint = readSessionFingerprint;
  }

  createDefaultControlConnection(): T {
    return createMySqlControlConnection<T>(
      this.config, this.password, this.defaultControlBuilder);
  }

  async connect(): Promise<void> {
    if (this.retiredByCancellation) {
      throw ArkDbError.protocol(
        'Connection retired after an unacknowledged cancellation; create a new connection.');
    }
    if (this.cancelTask !== null) {
      throw ArkDbError.protocol('A cancellation request is still settling.');
    }
    if (this.connState !== ConnectionState.Idle &&
      this.connState !== ConnectionState.Closed) {
      throw ArkDbError.protocol(
        'connect() called in state ' + this.connState);
    }
    this.commandGate.advanceGeneration();
    this.invalidatePreparedState();
    const deadline = new ConnectionDeadline(
      this.config.connectTimeoutMs, this.timers);
    this.opening = deadline;
    const scope = this.commandGate.reserve(MySqlCommandKind.Connect);
    const settlement = new CommandCloseSettlement(scope);
    this.connectOperation = settlement;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      this.commandGate.start(scope);
      await this.connectOwned(scope, deadline);
    } catch (error) {
      primary = error as Object;
    }
    const executionOutcome = primary instanceof MySqlOperationError ?
      primary.outcome : (primary === null ?
        MySqlExecutionOutcome.Completed :
        MySqlExecutionOutcome.NotDispatched);
    const closeJoin = this.commandCloseJoin(settlement, scope);
    if (closeJoin !== null) {
      const closeFailure = await closeJoin;
      if (closeFailure !== null) {
        if (primary === null) primary = closeFailure;
        else if (!operationContainsFailure(primary, closeFailure)) {
          cleanup.push(closeFailure);
        }
      }
    }
    try {
      this.finishCommand(scope);
    } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    if (this.connectOperation === settlement) {
      this.connectOperation = null;
    }
    if (primary !== null) {
      if (cleanup.length === 0 &&
        (settlement.closeResult === null ||
          (primary instanceof MySqlOperationError &&
            primary.outcome === executionOutcome))) {
        throw primary as Error;
      }
      throw operationFailure(primary, cleanup, executionOutcome);
    }
    if (cleanup.length > 0) {
      throw operationFailure(
        cleanup[0], cleanup.slice(1), MySqlExecutionOutcome.Completed);
    }
  }

  async readMySqlSessionFingerprint(
    scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> {
    this.commandGate.assertOwner(scope);
    this.requireReady();
    let fingerprint: MySqlSessionFingerprint | null = null;
    const command = buildComQuery(MYSQL_SESSION_FINGERPRINT_SQL);
    await this.runBufferedCommand(
      scope, command,
      async (channel: PacketChannel): Promise<MySqlQueryResult> => {
        const result = await parseBufferedResultStream(
          channel, this.clientCaps,
          new MySqlSessionFingerprintRowDecoder());
        this.commandGate.assertOwner(scope);
        fingerprint = mysqlSessionFingerprint(result);
        return result;
      });
    this.commandGate.assertOwner(scope);
    if (fingerprint === null) {
      throw ArkDbError.protocol(
        'The MySQL session fingerprint result was not produced.');
    }
    return fingerprint;
  }

  async resetSession(): Promise<void> {
    this.requireReady();
    const deadline = new ConnectionDeadline(
      this.config.connectTimeoutMs, this.timers);
    let scope: MySqlCommandScope;
    try {
      scope = this.commandGate.reserve(MySqlCommandKind.Reset);
    } catch (error) {
      deadline.dispose();
      throw error as Error;
    }
    this.resetting = deadline;
    this.commandGate.start(scope);
    let accepted = false;
    let primary: Object | null = null;
    let reusableRejection = false;
    const cleanup: ArkDbError[] = [];
    try {
      await this.executeResetOkOwned(scope,
        new PacketWriter().writeUInt8(
          Command.RESET_CONNECTION).toUint8Array(), true, deadline);
      accepted = true;
      this.invalidatePreparedState();
      this.commandGate.advanceGenerationOnRelease(scope);
      await this.reinitializeSessionOwned(scope, deadline);
    } catch (error) {
      const caught = error as Object;
      primary = caught instanceof ArkDbError &&
        caught.kind === ArkDbErrorKind.Timeout ?
        ArkDbError.timeout('MySQL session reset timed out.') : caught;
      const failure = toLifecycleArkDbError(primary);
      reusableRejection = !accepted &&
        (failure.kind === ArkDbErrorKind.Unsupported ||
          isMySqlServerRejection(failure));
      if (!reusableRejection) {
        this.commandGate.advanceGenerationOnRelease(scope);
        const retirement = await this.retireResetScope(scope);
        for (const cleanupFailure of retirement) {
          cleanup.push(cleanupFailure);
        }
      }
    }
    try {
      deadline.dispose();
    } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    if (this.resetting === deadline) this.resetting = null;
    try {
      this.finishCommand(scope);
    } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    if (primary !== null) {
      const failure = toLifecycleArkDbError(primary);
      if (reusableRejection && cleanup.length === 0 &&
        failure.kind === ArkDbErrorKind.Unsupported) {
        throw primary as Error;
      }
      throw operationFailure(primary, cleanup,
        reusableRejection ?
          MySqlExecutionOutcome.ServerRejected :
          MySqlExecutionOutcome.Unknown);
    }
    if (cleanup.length > 0) {
      throw operationFailure(
        cleanup[0], cleanup.slice(1), MySqlExecutionOutcome.Completed);
    }
  }

  cancel(): Promise<QueryCancellationResult> {
    const scope = this.commandGate.current;
    if (scope === null) {
      return Promise.resolve(new QueryCancellationResult(
        CancellationOutcome.NotRunning, this.reuseState()));
    }
    return this.cancelScope(scope);
  }

  isInterruptionError(error: ArkDbError): boolean {
    return isMySqlInterruptionError(error);
  }

  close(): Promise<void> {
    if (this.closing === null) {
      const current = this.commandGate.current;
      const ownsScope = current === null;
      const scope = current !== null ?
        current : this.commandGate.reserve(MySqlCommandKind.Close);
      const polite = ownsScope && this.opening === null &&
        this.connState === ConnectionState.Ready;
      const cursor = this.cursorOperation;
      const releaseIdleCursor = current !== null &&
        current.phase === MySqlCommandPhase.CursorIdle &&
        cursor !== null && cursor.scope === scope;
      this.closePending = true;
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      let begin: () => void = (): void => {};
      const closing = new Promise<void>((resolve: () => void,
        reject: (reason?: Object) => void): void => {
        begin = (): void => {
          this.closeWithScope(
            scope, ownsScope, polite, releaseIdleCursor).then(resolve, reject);
        };
      });
      this.closing = closing;
      const connecting = this.connectOperation;
      if (connecting !== null && connecting.scope === scope) {
        connecting.closeResult = closing;
      }
      const ordinary = this.ordinaryOperation;
      if (ordinary !== null && ordinary.scope === scope) {
        ordinary.closeResult = closing;
      }
      const prepared = this.preparedOperation;
      if (prepared !== null && prepared.scope === scope) {
        prepared.closeResult = closing;
        prepared.signalClose(
          ArkDbError.cancelled(
            'Connection closed during a MySQL operation.'));
      }
      if (cursor !== null && (cursor.scope === scope || ownsScope)) {
        cursor.closeResult = closing;
      }
      const transaction = this.transactionOperation;
      if (transaction !== null && transaction.scope === scope) {
        transaction.closeResult = closing;
      }
      if (ownsScope) this.commandGate.start(scope);
      begin();
    }
    return this.closing;
  }

  requireReady(): PacketChannel {
    if (this.cancelTask !== null) {
      throw ArkDbError.protocol(
        'Await the cancellation request before starting another command.');
    }
    if (this.connState !== ConnectionState.Ready || this.channel === null) {
      throw ArkDbError.protocol(
        'Connection is not ready (state ' + this.connState + ')');
    }
    return this.channel;
  }

  requireOwnedChannel(scope: MySqlCommandScope): PacketChannel {
    this.commandGate.assertOwner(scope);
    if (this.channel === null ||
      (this.connState !== ConnectionState.Ready &&
        this.connState !== ConnectionState.Querying)) {
      throw ArkDbError.protocol(
        'The owned command has no ready connection channel.');
    }
    return this.channel;
  }

  finishCommand(scope: MySqlCommandScope): void {
    this.commandGate.assertOwner(scope);
    this.completedScope = scope;
    if (this.cancelTask !== null || this.closePending) {
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
    }
    this.releaseCompletedCommand();
  }

  releaseCompletedCommand(): void {
    const scope = this.completedScope;
    if (scope !== null && this.cancelTask === null && !this.closePending) {
      this.completedScope = null;
      this.commandGate.release(scope);
    }
  }

  expectOk(packet: MysqlPacket): void {
    const first = firstByte(packet.payload);
    if (first === PacketType.ERR) {
      const error = parseErr(packet.payload, this.clientCaps);
      throw ArkDbError.server(
        error.message, error.code, error.sqlState);
    }
    if (first !== PacketType.OK) {
      throw ArkDbError.protocol(
        'Expected an OK packet, got 0x' + first.toString(16));
    }
    const flags = parseOk(packet.payload, this.clientCaps).statusFlags;
    if (this.connState !== ConnectionState.Closed) {
      this.applyStatusFlags(flags);
    }
  }

  applyStatusFlags(statusFlags: number): void {
    this.status.known = true;
    this.status.autocommit = (statusFlags & 0x0002) !== 0;
    this.status.inTransaction = (statusFlags & 0x0001) !== 0;
  }

  async classifyCommandFailure(scope: MySqlCommandScope, error: Object,
    reading: boolean, synchronized: boolean = false): Promise<ArkDbError> {
    if (synchronized) {
      return operationFailure(
        error, [], MySqlExecutionOutcome.Completed);
    }
    const typed = toLifecycleArkDbError(error);
    const rejected = reading && isMySqlServerRejection(typed);
    const reusable = rejected &&
      (!(typed instanceof MySqlOperationError) ||
        typed.cleanupErrors.length === 0);
    this.status.known = false;
    if (this.connState !== ConnectionState.Closed) {
      this.connState = connectionStateAfterCommandFailure(
        typed.kind, reusable);
    }
    const cleanupErrors: ArkDbError[] = [];
    if (this.connState === ConnectionState.Error) {
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      this.channel = null;
      this.invalidatePreparedState();
      try {
        await this.transport.close();
      } catch (cleanup) {
        Logger.w(
          LogTag.Conn,
          'transport cleanup failed error=' + Logger.errorToken(cleanup));
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
    }
    return operationFailure(error, cleanupErrors,
      rejected ?
        MySqlExecutionOutcome.ServerRejected :
        MySqlExecutionOutcome.Unknown);
  }

  createOrdinaryOperation(
    scope: MySqlCommandScope): OrdinaryCommandSettlement {
    const settlement = new OrdinaryCommandSettlement(scope);
    this.ordinaryOperation = settlement;
    return settlement;
  }

  createPreparedOperation(
    scope: MySqlCommandScope): PreparedCommandSettlement {
    const settlement = new PreparedCommandSettlement(scope);
    this.preparedOperation = settlement;
    return settlement;
  }

  createCursorOperation(
    scope: MySqlCommandScope): PreparedCommandSettlement {
    const settlement = new PreparedCommandSettlement(scope);
    this.cursorOperation = settlement;
    this.preparedOperation = settlement;
    return settlement;
  }

  createTransactionOperation(
    scope: MySqlCommandScope): PreparedCommandSettlement {
    const settlement = new PreparedCommandSettlement(scope);
    this.transactionOperation = settlement;
    return settlement;
  }

  preparedCloseSignal(
    scope: MySqlCommandScope): Promise<ArkDbError> {
    const operation = this.preparedOperation;
    if (operation === null || operation.scope !== scope) {
      return Promise.reject<ArkDbError>(
        ArkDbError.protocol(
          'Prepared operation close signal is unavailable.'));
    }
    return operation.closeRequested;
  }

  ordinaryCloseJoin(
    scope: MySqlCommandScope): Promise<ArkDbError | null> | null {
    return this.commandCloseJoin(this.ordinaryOperation, scope);
  }

  markOrdinaryCommandDispatched(scope: MySqlCommandScope): void {
    const settlement = this.ordinaryOperation;
    if (settlement !== null && settlement.scope === scope) {
      settlement.dispatched = true;
    }
  }

  async settlePreparedCancellation(
    scope: MySqlCommandScope): Promise<ArkDbError[]> {
    const failures: ArkDbError[] = [];
    const operation = this.preparedOperation;
    if (operation === null || operation.scope !== scope) return failures;
    while (operation.joinedCancellations <
      operation.cancellations.length) {
      const cancellation =
        operation.cancellations[operation.joinedCancellations++];
      try {
        await cancellation;
      } catch (error) {
        failures.push(toCleanupError(error as Object));
      }
    }
    return failures;
  }

  async settleTransactionOperation(scope: MySqlCommandScope,
    completedCloseCleanup: boolean = false): Promise<ArkDbError[]> {
    const failures: ArkDbError[] = [];
    const operation = this.transactionOperation;
    if (operation === null || operation.scope !== scope) return failures;
    while (operation.joinedCancellations <
      operation.cancellations.length) {
      const cancellation =
        operation.cancellations[operation.joinedCancellations++];
      try {
        await cancellation;
      } catch (error) {
        failures.push(toCleanupError(error as Object));
      }
    }
    const closeResult = operation.closeResult;
    if (closeResult !== null && !operation.closeJoined) {
      operation.closeJoined = true;
      try {
        await closeResult;
      } catch (error) {
        failures.push(completedCloseCleanup ?
          operationFailure(
            error as Object, [], MySqlExecutionOutcome.Completed) :
          toCleanupError(error as Object));
      }
    }
    return failures;
  }

  async finishTransactionOperation(
    scope: MySqlCommandScope): Promise<ArkDbError[]> {
    const failures = await this.settleTransactionOperation(scope);
    try {
      this.finishCommand(scope);
    } catch (error) {
      failures.push(toCleanupError(error as Object));
    }
    const lateFailures =
      await this.settleTransactionOperation(scope, true);
    for (const failure of lateFailures) failures.push(failure);
    if (this.transactionOperation !== null &&
      this.transactionOperation.scope === scope) {
      this.transactionOperation = null;
    }
    return failures;
  }

  async retirePreparedSession(error: ArkDbError): Promise<void> {
    this.connState = ConnectionState.Closed;
    this.status.known = false;
    this.channel = null;
    this.invalidatePreparedState();
    await this.transport.abort(error);
  }

  async runDeadline<TValue>(scope: MySqlCommandScope,
    options: MySqlDeadlineOptions,
    operation: () => Promise<TValue>): Promise<TValue> {
    if (options.timeoutMs === 0) return operation();
    const settlement = new DeadlineCancellationSettlement(scope);
    this.deadlineCancellation = settlement;

    try {
      let expire: () => void = (): void => {};
      const expired = new Promise<void>((resolve: () => void): void => {
        expire = resolve;
      });
      const serial = scope.serial;
      const deadlineTimer = new MySqlDeadlineTimer(
        options.timeoutMs, this.timers, (): void => {
          if (this.commandGate.expireDeadline(scope, serial)) expire();
        });

      let operationTask: Promise<TValue>;
      try {
        operationTask = operation();
      } catch (error) {
        operationTask = Promise.reject<TValue>(error as Object);
      }
      const observed = new DeadlineObservation<TValue>(operationTask);
      const closeCleanup: ArkDbError[] = [];
      const converged =
        this.settleDeadlineConvergence(
          observed, settlement, closeCleanup);
      let first = await Promise.race<number>([
        converged.then((): number => 0),
        expired.then((): number => 1)
      ]);
      if (first === 0 && deadlineTimer.isExpired() &&
        this.commandGate.expireDeadline(scope, serial)) {
        first = 1;
      }
      if (first === 0) {
        deadlineTimer.cancel();
        const cancellationUnknown =
          this.retiredByCancellation || settlement.unknown;
        if (observed.failure !== null) {
          const cleanup: ArkDbError[] = [];
          this.appendDeadlineCancellationFailures(cleanup, settlement);
          for (const failure of closeCleanup) {
            this.appendDeadlineCleanup(cleanup, failure);
          }
          const outcome = cancellationUnknown ?
            MySqlExecutionOutcome.Unknown :
            (observed.failure instanceof MySqlOperationError ?
              observed.failure.outcome :
              MySqlExecutionOutcome.Unknown);
          throw operationFailure(
            observed.failure, cleanup, outcome);
        }
        if (settlement.failures.length > 0) {
          const primary = settlement.failures[0];
          const cleanup = settlement.failures.slice(1);
          for (const failure of closeCleanup) {
            this.appendDeadlineCleanup(cleanup, failure);
          }
          const outcome = cancellationUnknown ?
            MySqlExecutionOutcome.Unknown :
            MySqlExecutionOutcome.Completed;
          throw operationFailure(primary, cleanup, outcome);
        }
        if (closeCleanup.length > 0) {
          const outcome = cancellationUnknown ?
            MySqlExecutionOutcome.Unknown :
            MySqlExecutionOutcome.Completed;
          throw operationFailure(
            closeCleanup[0], closeCleanup, outcome);
        }
        return observed.value!;
      }

      deadlineTimer.cancel();
      const timeout =
        ArkDbError.timeout('MySQL operation deadline expired.');
      this.cancelScope(scope);
      let expireGrace: () => void = (): void => {};
      const graceExpired =
        new Promise<void>((resolve: () => void): void => {
          expireGrace = resolve;
        });
      const graceTimer = new MySqlDeadlineTimer(
        options.cancellationGraceMs, this.timers, (): void => {
          expireGrace();
        });
      const convergence = await Promise.race<number>([
        converged.then((): number => 0),
        graceExpired.then((): number => 1)
      ]);
      if (convergence === 0) {
        graceTimer.cancel();
        const cleanup: ArkDbError[] = [];
        if (observed.failure !== null) {
          this.appendDeadlineCleanup(cleanup, observed.failure);
        }
        this.appendDeadlineCancellationFailures(cleanup, settlement);
        for (const failure of closeCleanup) {
          this.appendDeadlineCleanup(cleanup, failure);
        }
        const cancellationUnknown =
          this.retiredByCancellation || settlement.unknown;
        const outcome = cancellationUnknown ?
          MySqlExecutionOutcome.Unknown :
          (observed.failure instanceof MySqlOperationError ?
            observed.failure.outcome :
            (observed.failure === null ?
              MySqlExecutionOutcome.Completed :
              MySqlExecutionOutcome.Unknown));
        throw operationFailure(timeout, cleanup, outcome);
      }

      graceTimer.cancel();
      const cleanup: ArkDbError[] = [
        ArkDbError.timeout(
          'MySQL operation did not converge within the cancellation grace period.')
      ];
      const retirement =
        await this.retireDeadlineScope(scope, timeout);
      for (const failure of retirement) {
        this.appendDeadlineCleanup(cleanup, failure);
      }
      await this.settleDeadlineCancellationAttempts(settlement);
      const operationSettled =
        await this.joinDeadlineOperationAfterAbort(observed);
      await this.settleDeadlineCancellationAttempts(settlement);
      this.invalidatePreparedState();
      this.appendDeadlineCancellationFailures(cleanup, settlement);
      if (observed.failure !== null) {
        this.appendDeadlineCleanup(cleanup, observed.failure);
      }
      if (!operationSettled) {
        this.appendDeadlineCleanup(
          cleanup,
          ArkDbError.timeout(
            'MySQL operation did not settle during bounded post-abort cleanup.'));
      }
      await this.joinDeadlineClose(scope, cleanup);
      return Promise.reject<TValue>(
        operationFailure(
          timeout, cleanup, MySqlExecutionOutcome.Unknown));
    } finally {
      if (this.deadlineCancellation === settlement &&
        settlement.scope === scope) {
        this.deadlineCancellation = null;
      }
    }
  }

  private async connectOwned(scope: MySqlCommandScope,
    deadline: ConnectionDeadline): Promise<void> {
    let primary: Object | null = null;
    const cleanupErrors: ArkDbError[] = [];
    let dispatched = false;
    try {
      if (this.closePending) {
        throw ArkDbError.cancelled(
          'Connection closed while opening.');
      }
      const sessionStatements =
        mysqlSessionInitializationSql(this.config.session);
      this.commandGate.setPhase(
        scope, MySqlCommandPhase.Preparing);
      this.connState = ConnectionState.Connecting;
      this.status.known = false;
      this.tlsActive = false;
      Logger.i(
        LogTag.Conn,
        'connecting host=' + Logger.mask(this.config.host) +
          ' port=' + this.config.port);
      await deadline.wait((): Promise<void> =>
        this.transport.connect(
          this.config.host, this.config.port,
          deadline.remainingMs()));
      deadline.remainingMs();
      const channel = new PacketChannel(this.transport);
      this.channel = channel;

      const handshakePacket =
        await deadline.wait(
          (): Promise<MysqlPacket> => channel.readPacket());
      deadline.remainingMs();
      if (firstByte(handshakePacket.payload) === PacketType.ERR) {
        const error = parseErr(handshakePacket.payload, 0);
        throw ArkDbError.server(
          error.message, error.code, error.sqlState);
      }
      const handshake = parseHandshake(handshakePacket.payload);
      this.applyServerInfo(handshake);
      this.authNonce = handshake.salt;
      Logger.i(
        LogTag.Conn,
        'handshake family=' + String(handshake.family) +
          ' plugin=' + authPluginLogValue(handshake.authPluginName));

      const withDb = this.config.defaultSchema !== undefined &&
        this.config.defaultSchema.length > 0;
      const withTls = mysqlTlsRequested(
        this.config.ssl.mode, handshake.capabilities);
      this.clientCaps = computeClientCapabilities(
        handshake.capabilities, withDb, withTls,
        this.config.multipleStatements === true);

      this.connState = ConnectionState.Authenticating;
      const parameters = new HandshakeResponseParams();
      parameters.capabilities = this.clientCaps;
      parameters.user = this.config.user;
      parameters.authPluginName = handshake.authPluginName;
      if (withDb) {
        parameters.database = this.config.defaultSchema;
      }
      if (withTls) {
        this.transport.prepareTlsUpgrade();
        dispatched = true;
        await deadline.wait((): Promise<void> =>
          channel.writePacket(buildSslRequest(
            parameters.capabilities, parameters.charset,
            parameters.maxPacketSize)));
        await deadline.wait((): Promise<void> =>
          this.transport.upgradeToTls(
            this.config.host, this.config.port,
            this.config.ssl, deadline.remainingMs()));
        deadline.remainingMs();
        this.tlsActive = true;
        this.info.tlsActive = true;
      }
      parameters.authResponse =
        await deadline.wait((): Promise<Uint8Array> =>
          this.computeAuth(
            handshake.authPluginName, handshake.salt));
      dispatched = true;
      await deadline.wait((): Promise<void> =>
        channel.writePacket(buildHandshakeResponse(parameters)));

      const authStatusFlags =
        await this.readAuthResult(channel, deadline);
      deadline.remainingMs();
      this.applyStatusFlags(authStatusFlags);
      if (!this.skipAutocommitSetup &&
        this.status.autocommit !== this.config.autocommit) {
        channel.resetSequence();
        await deadline.wait((): Promise<void> =>
          channel.writePacket(buildComQuery(
            this.config.autocommit ?
              'SET autocommit = 1' :
              'SET autocommit = 0')));
        const setup =
          await deadline.wait((): Promise<MySqlQueryResult> =>
            parseResultSet(channel, this.clientCaps));
        deadline.remainingMs();
        this.status.autocommit = setup.autocommit;
        this.status.inTransaction = setup.inTransaction;
      }
      for (const sql of sessionStatements) {
        this.commandGate.assertOwner(scope);
        channel.resetSequence();
        await deadline.wait((): Promise<void> =>
          channel.writePacket(buildComQuery(sql)));
        const setup =
          await deadline.wait(
            (): Promise<MysqlPacket> => channel.readPacket());
        deadline.remainingMs();
        this.expectOk(setup);
      }
      deadline.remainingMs();
      this.connState = ConnectionState.Ready;
      Logger.i(
        LogTag.Conn,
        'ready host=' + Logger.mask(this.config.host) +
          ' user=' + Logger.mask(this.config.user));
    } catch (error) {
      primary = error as Object;
      if (this.connState !== ConnectionState.Closed) {
        this.connState = ConnectionState.Error;
      }
      this.status.known = false;
      const typed = toLifecycleArkDbError(error as Object);
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      try {
        deadline.cancel(typed);
      } catch (cleanup) {
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
      Logger.e(
        LogTag.Conn,
        'connect failed host=' + Logger.mask(this.config.host) +
          ' kind=' + String(typed.kind) +
          ' error=' + Logger.errorToken(typed));
      this.channel = null;
      this.invalidatePreparedState();
      const settlement = this.connectOperation;
      const rootCloseOwnsCleanup =
        settlement !== null && settlement.scope === scope &&
        settlement.closeResult !== null;
      if (!rootCloseOwnsCleanup) {
        try {
          await this.transport.abort(typed);
        } catch (cleanup) {
          Logger.w(
            LogTag.Conn,
            'connect cleanup failed error=' +
              Logger.errorToken(cleanup));
          cleanupErrors.push(toCleanupError(cleanup as Object));
        }
      }
    } finally {
      try {
        deadline.dispose();
      } catch (cleanup) {
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
      if (this.opening === deadline) this.opening = null;
    }
    if (primary !== null) {
      const outcome =
        isMySqlServerRejection(toLifecycleArkDbError(primary)) ?
          MySqlExecutionOutcome.ServerRejected :
          (dispatched ?
            MySqlExecutionOutcome.Unknown :
            MySqlExecutionOutcome.NotDispatched);
      throw operationFailure(primary, cleanupErrors, outcome);
    }
    if (cleanupErrors.length > 0) {
      throw operationFailure(
        cleanupErrors[0], cleanupErrors,
        MySqlExecutionOutcome.Completed);
    }
  }

  private async reinitializeSessionOwned(scope: MySqlCommandScope,
    deadline: ConnectionDeadline): Promise<void> {
    await this.executeResetOkOwned(
      scope, buildComQuery(MYSQL_SESSION_CHARACTER_SET_SQL),
      false, deadline);
    const database = this.config.defaultSchema;
    if (database !== undefined && database.length > 0) {
      const command = new PacketWriter()
        .writeUInt8(Command.INIT_DB)
        .writeString(database)
        .toUint8Array();
      await this.executeResetOkOwned(
        scope, command, false, deadline);
    }
    if (!this.skipAutocommitSetup &&
      this.status.autocommit !== this.config.autocommit) {
      await this.executeResetOkOwned(
        scope,
        buildComQuery(this.config.autocommit ?
          'SET autocommit = 1' :
          'SET autocommit = 0'),
        false, deadline);
    }
    for (const sql of
      mysqlSessionInitializationSql(this.config.session)) {
      await this.executeResetOkOwned(
        scope, buildComQuery(sql), false, deadline);
    }
    const fingerprint =
      await deadline.wait((): Promise<MySqlSessionFingerprint> =>
        this.readSessionFingerprint(scope));
    deadline.remainingMs();
    this.validateResetFingerprint(fingerprint);
  }

  private validateResetFingerprint(
    fingerprint: MySqlSessionFingerprint): void {
    if (fingerprint.characterSetClient !== 'utf8mb4') {
      throw ArkDbError.protocol(
        'MySQL session reset did not restore character_set_client=utf8mb4.');
    }
    const database = this.config.defaultSchema;
    if (database !== undefined && database.length > 0) {
      if (fingerprint.database !== database) {
        throw ArkDbError.protocol(
          'MySQL session reset did not restore the configured default database.');
      }
      return;
    }
    if (fingerprint.database !== null &&
      fingerprint.database.length > 0) {
      throw ArkDbError.protocol(
        'MySQL session reset retained an unexpected default database.');
    }
  }

  private async executeResetOkOwned(scope: MySqlCommandScope,
    command: Uint8Array, resetCommand: boolean,
    deadline: ConnectionDeadline): Promise<void> {
    const channel = this.requireOwnedChannel(scope);
    this.commandGate.setPhase(
      scope, MySqlCommandPhase.Resetting);
    channel.resetSequence();
    await deadline.wait(
      (): Promise<void> => channel.writePacket(command));
    deadline.remainingMs();
    const response =
      await deadline.wait(
        (): Promise<MysqlPacket> => channel.readPacket());
    deadline.remainingMs();
    if (resetCommand) this.expectResetOk(response);
    else this.expectOk(response);
  }

  private expectResetOk(packet: MysqlPacket): void {
    if (firstByte(packet.payload) === PacketType.ERR) {
      const error = parseErr(packet.payload, this.clientCaps);
      if (error.code === 1047 || error.code === 1235) {
        throw new ArkDbError(
          ArkDbErrorKind.Unsupported,
          'Server does not support COM_RESET_CONNECTION.',
          error.code, error.sqlState);
      }
      throw ArkDbError.server(
        error.message, error.code, error.sqlState);
    }
    this.expectOk(packet);
  }

  private async retireResetScope(
    scope: MySqlCommandScope): Promise<ArkDbError[]> {
    const cleanup: ArkDbError[] = [];
    this.commandGate.assertOwner(scope);
    this.commandGate.advanceGenerationOnRelease(scope);
    if (this.closing === null) {
      this.closePending = true;
      this.commandGate.setPhase(
        scope, MySqlCommandPhase.Cleaning);
      this.closing = this.closeWithScope(scope, false, false);
    }
    try {
      await this.closing;
    } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    return cleanup;
  }

  private cancelScope(
    scope: MySqlCommandScope): Promise<QueryCancellationResult> {
    if (this.cancelTask !== null) {
      this.retainDeadlineCancellation(scope, this.cancelTask);
      return this.cancelTask;
    }
    if (!this.canCancelScope(scope)) {
      return Promise.resolve(new QueryCancellationResult(
        CancellationOutcome.NotRunning, this.reuseState()));
    }
    const task = this.cancelCurrentQuery(
      scope, this.cancellationHandle, this.queryWrite);
    this.cancelTask = task;
    this.retainDeadlineCancellation(scope, task);
    if (this.preparedOperation !== null &&
      this.preparedOperation.scope === scope) {
      this.preparedOperation.cancellations.push(task);
    }
    if (this.transactionOperation !== null &&
      this.transactionOperation.scope === scope) {
      this.transactionOperation.cancellations.push(task);
    }
    const settled = (): void => {
      this.cancelTask = null;
      this.releaseCompletedCommand();
    };
    task.then(settled, settled);
    return task;
  }

  private canCancelScope(scope: MySqlCommandScope): boolean {
    const ordinaryWire =
      (scope.kind === MySqlCommandKind.Query ||
        scope.kind === MySqlCommandKind.QueryStream ||
        scope.kind === MySqlCommandKind.Transaction) &&
      (scope.phase === MySqlCommandPhase.Executing ||
        scope.phase === MySqlCommandPhase.Streaming);
    const cursorWire = scope.kind === MySqlCommandKind.Cursor &&
      (scope.phase === MySqlCommandPhase.Executing ||
        scope.phase === MySqlCommandPhase.Fetching);
    return this.commandGate.isOwner(scope) &&
      this.executingScope === scope &&
      this.connState === ConnectionState.Querying &&
      (ordinaryWire || cursorWire);
  }

  private async cancelCurrentQuery(scope: MySqlCommandScope,
    handle: string,
    written: Promise<void> | null): Promise<QueryCancellationResult> {
    let control: DbConnection | null = null;
    let deadline: ConnectionDeadline | null = null;
    let primary: Object | null = null;
    const cleanupErrors: ArkDbError[] = [];
    let outcome = CancellationOutcome.NotRunning;
    let dispatched = false;
    let outcomeKnown = false;
    let knownNotDispatched = false;
    try {
      mysqlKillQueryForHandle(handle);
      const ownedControl = this.createControlOverride !== null ?
        this.createControlOverride() :
        this.resolveDefaultControlConnection();
      if (ownedControl === this.readOwner()) {
        throw ArkDbError.validation(
          'MySQL cancellation requires a distinct control connection.');
      }
      control = ownedControl;
      this.cancellationControl = ownedControl;
      const budget = new ConnectionDeadline(
        this.config.connectTimeoutMs, this.timers);
      deadline = budget;
      await budget.wait(
        (): Promise<void> => ownedControl.connect());
      if (this.canCancelScope(scope)) {
        const dispatch = written;
        if (dispatch !== null) {
          await budget.wait((): Promise<void> => dispatch);
        }
        if (this.canCancelScope(scope)) {
          outcome = await budget.wait(
            async (): Promise<CancellationOutcome> => {
              dispatched = true;
              try {
                const result =
                  await new MySqlExecutionController(
                    ownedControl).requestCancellation(handle);
                outcomeKnown = true;
                return result;
              } catch (error) {
                const failure =
                  toLifecycleArkDbError(error as Object);
                knownNotDispatched =
                  failure instanceof MySqlOperationError &&
                  failure.outcome ===
                    MySqlExecutionOutcome.NotDispatched &&
                  failure.originalCause === undefined;
                outcomeKnown =
                  isMySqlServerRejection(failure) ||
                  knownNotDispatched;
                throw error as Error;
              }
            });
        }
      }
    } catch (error) {
      primary = error as Object;
    } finally {
      if (deadline !== null) {
        try {
          deadline.dispose();
        } catch (cleanup) {
          cleanupErrors.push(toCleanupError(cleanup as Object));
        }
      }
    }
    if (dispatched && !outcomeKnown &&
      !this.retiredByCancellation) {
      this.commandGate.setPhase(
        scope, MySqlCommandPhase.Cleaning);
      this.retiredByCancellation = true;
      this.connState = ConnectionState.Closed;
      this.status.known = false;
      this.channel = null;
      this.invalidatePreparedState();
      const failure = primary !== null ?
        toLifecycleArkDbError(primary) :
        ArkDbError.cancelled(
          'Connection retired after an unacknowledged cancellation.');
      if (primary === null) primary = failure;
      try {
        await this.transport.abort(failure);
      } catch (cleanup) {
        Logger.w(
          LogTag.Conn,
          'cancellation target cleanup failed error=' +
            Logger.errorToken(cleanup));
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
    }
    if (control !== null) {
      try {
        await control.close();
      } catch (cleanup) {
        Logger.w(
          LogTag.Conn,
          'cancellation cleanup failed error=' +
            Logger.errorToken(cleanup));
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
      if (this.cancellationControl === control) {
        this.cancellationControl = null;
      }
    }
    if (primary !== null) {
      const failure = toLifecycleArkDbError(primary);
      const failedOutcome = !dispatched || knownNotDispatched ?
        MySqlExecutionOutcome.NotDispatched :
        (isMySqlServerRejection(failure) ?
          MySqlExecutionOutcome.ServerRejected :
          MySqlExecutionOutcome.Unknown);
      throw operationFailure(
        primary, cleanupErrors, failedOutcome);
    }
    if (cleanupErrors.length > 0) {
      throw operationFailure(
        cleanupErrors[0], cleanupErrors,
        dispatched ?
          MySqlExecutionOutcome.Completed :
          MySqlExecutionOutcome.NotDispatched);
    }
    return new QueryCancellationResult(
      outcome, this.reuseState());
  }

  private reuseState(): ConnectionReuse {
    if (this.connState === ConnectionState.Querying) {
      return ConnectionReuse.AwaitingCompletion;
    }
    if (this.connState === ConnectionState.Ready) {
      if (this.commandGate.current !== null &&
        this.completedScope !== this.commandGate.current) {
        return ConnectionReuse.AwaitingCompletion;
      }
      return this.status.known ?
        ConnectionReuse.Ready :
        ConnectionReuse.RequiresSynchronization;
    }
    return this.connState === ConnectionState.Closed ?
      ConnectionReuse.Closed :
      ConnectionReuse.NotReady;
  }

  private async closeWithScope(scope: MySqlCommandScope,
    ownsScope: boolean, polite: boolean,
    releaseIdleCursor: boolean = false): Promise<void> {
    try {
      await this.closeInternal(polite);
    } finally {
      this.closePending = false;
      if (ownsScope) {
        this.finishCommand(scope);
      } else {
        const cursor = this.cursorOperation;
        if (releaseIdleCursor &&
          cursor !== null && cursor.scope === scope &&
          this.commandGate.isOwner(scope)) {
          this.completedScope = scope;
          if (this.preparedOperation === cursor) {
            this.preparedOperation = null;
          }
          this.cursorOperation = null;
        }
        this.releaseCompletedCommand();
      }
    }
  }

  private async closeInternal(polite: boolean): Promise<void> {
    const channel = this.channel;
    let primary: Object | null = null;
    const cleanupErrors: ArkDbError[] = [];
    this.connState = ConnectionState.Closed;
    this.status.known = false;
    this.channel = null;
    this.invalidatePreparedState();
    if (this.opening !== null) {
      try {
        this.opening.cancel(
          ArkDbError.cancelled(
            'Connection closed while opening.'));
      } catch (error) {
        primary = error as Object;
      }
    }
    if (this.resetting !== null) {
      try {
        this.resetting.cancel(
          ArkDbError.cancelled(
            'Connection closed while resetting the session.'));
      } catch (error) {
        if (primary === null) primary = error as Object;
        else cleanupErrors.push(toCleanupError(error as Object));
      }
    }
    if (channel !== null && polite) {
      try {
        channel.resetSequence();
        const writer = new PacketWriter();
        writer.writeUInt8(Command.QUIT);
        await channel.writePacket(
          writer.toUint8Array(), 1000);
      } catch (error) {
        Logger.w(
          LogTag.Conn,
          'quit before close failed error=' +
            Logger.errorToken(error));
        if (primary === null) primary = error as Object;
        else cleanupErrors.push(toCleanupError(error as Object));
      }
    }
    try {
      await this.transport.close();
    } catch (error) {
      if (primary === null) primary = error as Object;
      else cleanupErrors.push(toCleanupError(error as Object));
    }
    try {
      if (this.cancelTask !== null) await this.cancelTask;
    } catch (cleanup) {
      Logger.w(
        LogTag.Conn,
        'close cancellation cleanup failed error=' +
          Logger.errorToken(cleanup));
      if (primary === null) primary = cleanup as Object;
      else cleanupErrors.push(toCleanupError(cleanup as Object));
    }
    if (primary !== null) {
      throw operationFailure(
        primary, cleanupErrors, MySqlExecutionOutcome.Unknown);
    }
    Logger.d(LogTag.Conn, 'closed');
  }

  private async computeAuth(plugin: string,
    salt: Uint8Array): Promise<Uint8Array> {
    if (plugin === 'mysql_native_password' || plugin.length === 0) {
      Logger.d(
        LogTag.Auth,
        'scramble plugin=mysql_native_password');
      return await nativeScramble(this.password, salt);
    }
    if (plugin === 'caching_sha2_password') {
      Logger.d(
        LogTag.Auth,
        'scramble plugin=caching_sha2_password (fast)');
      return await cachingSha2Scramble(this.password, salt);
    }
    Logger.e(
      LogTag.Auth,
      'unsupported auth plugin=' + authPluginLogValue(plugin));
    throw new ArkDbError(
      ArkDbErrorKind.Auth,
      'Unsupported authentication plugin: ' + plugin);
  }

  private async readAuthResult(channel: PacketChannel,
    deadline: ConnectionDeadline): Promise<number> {
    const packet =
      await deadline.wait(
        (): Promise<MysqlPacket> => channel.readPacket());
    deadline.remainingMs();
    const first = firstByte(packet.payload);
    if (first === PacketType.OK) {
      return parseOk(
        packet.payload, this.clientCaps).statusFlags;
    }
    if (first === PacketType.ERR) {
      const error = parseErr(packet.payload, this.clientCaps);
      throw ArkDbError.server(
        error.message, error.code, error.sqlState);
    }
    if (first === 0xfe) {
      const reader = packet.reader();
      reader.readUInt8();
      const newPlugin = reader.readNulString();
      let newSalt = reader.readBytes(reader.remaining);
      if (newSalt.length > 0 &&
        newSalt[newSalt.length - 1] === 0x00) {
        newSalt = newSalt.subarray(0, newSalt.length - 1);
      }
      this.authNonce = newSalt;
      this.info.authPlugin = newPlugin;
      Logger.d(
        LogTag.Auth,
        'auth-switch -> ' + authPluginLogValue(newPlugin));
      const response =
        await deadline.wait((): Promise<Uint8Array> =>
          this.computeAuth(newPlugin, newSalt));
      await deadline.wait(
        (): Promise<void> => channel.writePacket(response));
      return await this.readAuthResult(channel, deadline);
    }
    if (first === 0x01) {
      const reader = packet.reader();
      reader.readUInt8();
      const indicator =
        reader.hasMore() ? reader.peekUInt8() : -1;
      if (indicator === 0x03) {
        Logger.d(LogTag.Auth, 'caching_sha2 fast-auth ok');
        return await this.readAuthResult(channel, deadline);
      }
      if (indicator === 0x04) {
        Logger.d(
          LogTag.Auth,
          'caching_sha2 full-auth required');
        await this.cachingSha2FullAuth(channel, deadline);
        return await this.readAuthResult(channel, deadline);
      }
      throw ArkDbError.protocol(
        'Unexpected AuthMoreData indicator 0x' +
          (indicator & 0xff).toString(16));
    }
    throw ArkDbError.protocol(
      'Unexpected auth response byte 0x' +
        first.toString(16));
  }

  private async cachingSha2FullAuth(channel: PacketChannel,
    deadline: ConnectionDeadline): Promise<void> {
    if (this.tlsActive) {
      Logger.d(
        LogTag.Auth,
        'full-auth via TLS cleartext');
      const writer = new PacketWriter();
      writer.writeString(this.password);
      writer.writeUInt8(0x00);
      await deadline.wait(
        (): Promise<void> =>
          channel.writePacket(writer.toUint8Array()));
      return;
    }
    Logger.d(
      LogTag.Auth,
      'full-auth via RSA public key');
    const request = new PacketWriter();
    request.writeUInt8(0x02);
    await deadline.wait(
      (): Promise<void> =>
        channel.writePacket(request.toUint8Array()));

    const keyPacket =
      await deadline.wait(
        (): Promise<MysqlPacket> => channel.readPacket());
    const reader = keyPacket.reader();
    if (reader.readUInt8() !== 0x01) {
      throw ArkDbError.protocol(
        'Expected AuthMoreData carrying the RSA public key');
    }
    const pem = reader.readEofString();
    const obfuscated =
      obfuscatePassword(this.password, this.authNonce);
    const encrypted =
      await deadline.wait((): Promise<Uint8Array> =>
        rsaOaepEncrypt(pem, obfuscated));
    await deadline.wait(
      (): Promise<void> => channel.writePacket(encrypted));
  }

  private applyServerInfo(handshake: HandshakePacket): void {
    const info = new MySqlServerInfo();
    info.family = handshake.family;
    info.driverId = 'mysql';
    info.productName = String(handshake.family);
    info.connectionHandle = String(handshake.connectionId);
    this.cancellationHandle = info.connectionHandle;
    info.nativeCapabilities = String(handshake.capabilities);
    info.defaultEncoding = 'utf8mb4';
    info.version = handshake.serverVersion;
    info.protocolVersion = handshake.protocolVersion;
    info.connectionId = handshake.connectionId;
    info.capabilities = handshake.capabilities;
    info.charset = handshake.charset;
    info.authPlugin = handshake.authPluginName;
    info.tlsActive = this.tlsActive;
    this.info = info;
    this.applyStatusFlags(handshake.statusFlags);
  }

  private retainDeadlineCancellation(scope: MySqlCommandScope,
    task: Promise<QueryCancellationResult>): void {
    const settlement = this.deadlineCancellation;
    if (settlement !== null && settlement.scope === scope) {
      settlement.add(task);
    }
  }

  private async settleDeadlineConvergence<TValue>(
    observation: DeadlineObservation<TValue>,
    settlement: DeadlineCancellationSettlement,
    closeCleanup: ArkDbError[]): Promise<void> {
    await observation.settled;
    await this.settleDeadlineCancellationAttempts(settlement);
    await this.joinDeadlineClose(settlement.scope, closeCleanup);
    await this.settleDeadlineCancellationAttempts(settlement);
  }

  private async settleDeadlineCancellationAttempts(
    settlement: DeadlineCancellationSettlement): Promise<void> {
    while (settlement.joined < settlement.attempts.length) {
      const index = settlement.joined;
      const attempt = settlement.attempts[index];
      try {
        await attempt;
      } catch (error) {
        const failure = toCleanupError(error as Object);
        if (failure instanceof MySqlOperationError &&
          failure.outcome === MySqlExecutionOutcome.Unknown) {
          settlement.unknown = true;
        }
        settlement.addFailure(failure);
      }
      if (settlement.joined === index) {
        settlement.joined = index + 1;
      }
    }
  }

  private appendDeadlineCancellationFailures(
    cleanup: ArkDbError[],
    settlement: DeadlineCancellationSettlement): void {
    for (const failure of settlement.failures) {
      this.appendDeadlineCleanup(cleanup, failure);
    }
  }

  private appendDeadlineCleanup(
    cleanup: ArkDbError[], error: Object): void {
    const failure = toCleanupError(error);
    for (const existing of cleanup) {
      if (existing === failure) return;
    }
    cleanup.push(failure);
  }

  private joinDeadlineOperationAfterAbort<TValue>(
    observation: DeadlineObservation<TValue>): Promise<boolean> {
    if (observation.settledNow) {
      return Promise.resolve<boolean>(true);
    }
    return new Promise<boolean>(
      (resolve: (value: boolean) => void): void => {
        let completed = false;
        const timerId = setTimeout((): void => {
          if (completed) return;
          completed = true;
          resolve(observation.settledNow);
        }, 0);
        observation.settled.then((): void => {
          if (completed) return;
          completed = true;
          clearTimeout(timerId);
          resolve(true);
        });
      });
  }

  private async joinDeadlineClose(scope: MySqlCommandScope,
    cleanup: ArkDbError[]): Promise<void> {
    const ordinaryClose = this.ordinaryCloseJoin(scope);
    if (ordinaryClose !== null) {
      const failure = await ordinaryClose;
      if (failure !== null) {
        this.appendDeadlineCleanup(cleanup, failure);
      }
      return;
    }
    const closing = this.closing;
    if (closing === null) return;
    try {
      await closing;
    } catch (failure) {
      this.appendDeadlineCleanup(cleanup, failure as Object);
    }
  }

  private async retireDeadlineScope(scope: MySqlCommandScope,
    error: ArkDbError): Promise<ArkDbError[]> {
    const cleanup: ArkDbError[] = [];
    if (!this.commandGate.isOwner(scope)) return cleanup;
    this.commandGate.setPhase(
      scope, MySqlCommandPhase.Cleaning);
    this.retiredByCancellation = true;
    this.connState = ConnectionState.Closed;
    this.status.known = false;
    this.channel = null;
    const target =
      new DeadlineObservation<void>(this.transport.abort(error));
    const control = this.cancellationControl;
    let controlClose: DeadlineObservation<void> | null = null;
    if (control !== null) {
      try {
        controlClose =
          new DeadlineObservation<void>(control.close());
      } catch (failure) {
        this.appendDeadlineCleanup(cleanup, failure as Object);
      }
    }
    await target.settled;
    if (target.failure !== null) {
      this.appendDeadlineCleanup(cleanup, target.failure);
    }
    if (controlClose !== null) {
      await controlClose.settled;
      if (controlClose.failure !== null) {
        this.appendDeadlineCleanup(
          cleanup, controlClose.failure);
      }
    }
    return cleanup;
  }

  private commandCloseJoin(
    settlement: CommandCloseSettlement | null,
    scope: MySqlCommandScope):
    Promise<ArkDbError | null> | null {
    if (settlement === null || settlement.scope !== scope ||
      settlement.closeResult === null) {
      return null;
    }
    if (settlement.closeJoin === null) {
      settlement.closeJoin = settlement.closeResult.then(
        (): ArkDbError | null => null,
        (error: Object): ArkDbError | null =>
          toCleanupError(error));
    }
    return settlement.closeJoin;
  }
}

export function authPluginLogValue(plugin: string): string {
  if (plugin === 'mysql_native_password' ||
    plugin === 'caching_sha2_password') {
    return plugin;
  }
  return Logger.mask(plugin);
}

export function mysqlTlsRequested(
  mode: SslMode, serverCapabilities: number): boolean {
  const supported =
    (serverCapabilities & Capabilities.SSL) !== 0;
  if (mode === SslMode.DISABLED) return false;
  if (mode === SslMode.PREFERRED) return supported;
  if (mode === SslMode.REQUIRED ||
    mode === SslMode.VERIFY_CA ||
    mode === SslMode.VERIFY_IDENTITY) {
    if (!supported) {
      throw ArkDbError.tls(
        'Server does not support TLS required by SSL mode ' +
          String(mode));
    }
    return true;
  }
  throw ArkDbError.tls(
    'Unsupported SSL mode: ' + String(mode));
}

function firstByte(payload: Uint8Array): number {
  return payload.length > 0 ? payload[0] : -1;
}

function toLifecycleArkDbError(error: Object): ArkDbError {
  if (error instanceof ArkDbError) return error;
  const typed = error as Error;
  const message =
    typed !== null && typed !== undefined &&
    typed.message !== undefined ?
      typed.message : String(error);
  return ArkDbError.protocol(message);
}

export function connectionStateAfterCommandFailure(
  kind: ArkDbErrorKind,
  reusableServerError: boolean = true): ConnectionState {
  return kind === ArkDbErrorKind.Server && reusableServerError ?
    ConnectionState.Ready :
    ConnectionState.Error;
}
