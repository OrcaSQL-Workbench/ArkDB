import { ConnectionConfig, SslMode } from './model/ConnectionConfig';
import {
  DatabaseContext, DatabaseContextPolicy, ConnectionState, DbConnectionFeatures,
  DbConnectionHealth, DbContextController, DbTransactionController, DbExecutionController,
  CancellationOutcome, ConnectionReuse, QueryCancellationResult, DatabaseSessionStatus,
  QueryExecutionSummary, QueryOptions, QueryResultSink, ArkDbError, ArkDbErrorKind, DbConnection,
  ConnectionDeadline, ConnectionTimerPort, SystemConnectionTimerPort, Logger,
  LogTag, monotonicNowMs, QueryResultMeta, QueryResultSummary, QueryRowChunk, QueryTruncation
} from '@arkdb/core';
import { MySqlServerInfo as ServerInfo } from './model/MySqlServerInfo';
import { MySqlQueryResult as QueryResult } from './model/MySqlQueryResult';
import {
  MySqlCoreStreamingConnection, MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary,
  MySqlQueryResultSink, MySqlResultSinkAdapter, mysqlExecutionSummary, mysqlSessionStatus
} from './model/MySqlQueryStream';
import { MySqlDbConnection } from './driver/MySqlContracts';
import {
  MySqlExecutionDispatcher, MySqlExecutionObserver
} from './diagnostics/MySqlExecutionObserver';
import { TcpTransport } from './transport/TcpTransport';
import { PacketChannel, MysqlPacket, MysqlPacketSource } from './protocol/PacketChannel';
import { PacketWriter } from './protocol/PacketWriter';
import { Capabilities, Command, PacketType } from './protocol/Constants';
import { parseHandshake, HandshakePacket } from './auth/Handshake';
import { nativeScramble } from './auth/NativePassword';
import { cachingSha2Scramble, obfuscatePassword } from './auth/CachingSha2';
import { rsaOaepEncrypt } from './auth/Crypto';
import {
  buildHandshakeResponse, buildSslRequest, computeClientCapabilities, HandshakeResponseParams
} from './auth/HandshakeResponse';
import { parseErr, parseOk } from './command/ResultPackets';
import {
  buildComQuery, parseQueryStream, parseResultSet, TextRowDecoder, validateQueryOptions
} from './command/Query';
import { mysqlContextPolicy, mysqlDatabaseForContext } from './model/MySqlContext';
import { MySqlMetadataProvider } from './metadata/MySqlMetadataProvider';
import { MySqlServerMetricsProvider } from './metrics/MySqlServerMetricsProvider';
import {
  MySqlExecutionController, isMySqlInterruptionError, mysqlKillQueryForHandle
} from './execution/MySqlExecutionController';
import {
  MySqlBatchExecutor, MySqlPreparedBatchExecutor
} from './execution/MySqlBatchExecutor';
import {
  MySqlNamedExecutor, MySqlNamedExecutorHost, MySqlPreparedNamedExecutor
} from './execution/MySqlNamedExecutor';
import {
  MySqlInsertRowsExecutor, MySqlInsertRowsInput,
  MySqlPreparedInsertRowsExecutor, snapshotMySqlInsertRowsInput
} from './execution/MySqlInsertRowsExecutor';
import {
  MySqlPreparedProcedureCaller, MySqlProcedureCaller
} from './execution/MySqlProcedureCaller';
import {
  MySqlCursor, MySqlCursorExecutor
} from './driver/MySqlCursorContracts';
import { MySqlConnectionDeadlineExecutor } from './execution/MySqlDeadlineExecutor';
import { MySqlConnectionSessionController } from './execution/MySqlSessionController';
import {
  MYSQL_COMMIT_NO_CHAIN_NO_RELEASE, MYSQL_ROLLBACK_NO_CHAIN_NO_RELEASE,
  MySqlConnectionTransactionRunner, MySqlTransactionRunnerHost
} from './execution/MySqlTransactionRunner';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from './execution/MySqlCommandGate';
import {
  MYSQL_SESSION_CHARACTER_SET_SQL, MYSQL_SESSION_FINGERPRINT_SQL, MySqlSessionFingerprint,
  MySqlSessionFingerprintRowDecoder, mysqlSessionFingerprint, mysqlSessionInitializationSql
} from './execution/MySqlSessionInitialization';
import {
  MySqlExecutionOutcome, MySqlOperationError, isMySqlServerRejection
} from './model/MySqlOperationError';
import {
  MySqlBatchError, MySqlBatchOptions, MySqlBatchResult, validateMySqlBatchOptions
} from './model/MySqlBatch';
import { MySqlDeadlineOptions } from './model/MySqlDeadlineOptions';
import { MySqlCursorOptions } from './model/MySqlCursorOptions';
import { MySqlInsertRowsOptions } from './model/MySqlInsertRows';
import { MySqlPreparedExecutor, MySqlPreparedStatement } from './driver/MySqlPreparedContracts';
import { MySqlConnectionFeatures } from './driver/MySqlConnectionFeatures';
import { MySqlSession } from './driver/MySqlSession';
import { MySqlParameter } from './model/MySqlParameter';
import { MySqlNamedParameter } from './model/MySqlNamedParameter';
import {
  MySqlProcedureArgument, MySqlProcedureResult
} from './model/MySqlProcedure';
import { MySqlPreparedExecutor as InternalPreparedExecutor } from './command/PreparedExecutor';
import {
  MySqlCursorExecutorHost, MySqlReadOnlyCursorExecutor
} from './command/MySqlCursor';
import {
  MySqlResultTerminatorObservation, parseBufferedResultStream, parseResultStream
} from './command/ResultStream';
import { prepareServerError } from './command/PrepareResponse';
import { BinaryRowDecoder } from './value/BinaryRowDecoder';
import { MySqlLongDataExecutor } from './command/LongData';
import {
  MySqlLongDataOptions, MySqlLongParameter
} from './model/MySqlLongDataOptions';

const MAX_MYSQL_DEADLINE_TIMER_DELAY_MS: number = 2147483647;

class MySqlExecutionObserverCapability {}

const mysqlExecutionObserverCapability: Object =
  new MySqlExecutionObserverCapability();

type MySqlExecutionObserverBinding =
  (capability: Object, observer: MySqlExecutionObserver,
    executionClock: () => number) => void;

const mySqlExecutionObserverBindings:
  WeakMap<MySqlConnection, MySqlExecutionObserverBinding> =
  new WeakMap<MySqlConnection, MySqlExecutionObserverBinding>();

/**
 * A single MySQL/MariaDB connection over TCP with an optional in-handshake TLS upgrade.
 * Orchestrates: connect → handshake → mysql_native_password auth → commands.
 * Not thread-safe — run one per Worker connection, requests strictly serialized.
 */
export class MySqlConnection implements MySqlDbConnection, DbConnectionHealth,
  DbContextController, DbTransactionController, DbExecutionController, MySqlSession {
  readonly features: DbConnectionFeatures = new DbConnectionFeatures();
  readonly mysqlFeatures: MySqlConnectionFeatures = new MySqlConnectionFeatures();
  readonly contextPolicy: DatabaseContextPolicy = mysqlContextPolicy();
  private config: ConnectionConfig;
  private password: string;
  private transport: TcpTransport;
  private timers: ConnectionTimerPort;
  private opening: ConnectionDeadline | null = null;
  private resetting: ConnectionDeadline | null = null;
  private closing: Promise<void> | null = null;
  private channel: PacketChannel | null = null;
  private clientCaps: number = 0;
  private authNonce: Uint8Array = new Uint8Array(0);
  private tlsActive: boolean = false;
  private connState: ConnectionState = ConnectionState.Idle;
  private info: ServerInfo = new ServerInfo();
  private status: DatabaseSessionStatus = new MySqlDatabaseSessionStatus();
  private cancelTask: Promise<QueryCancellationResult> | null = null;
  private cancellationControl: DbConnection | null = null;
  private deadlineCancellation: DeadlineCancellationSettlement | null = null;
  private retiredByCancellation: boolean = false;
  private commandGate: MySqlCommandGate = new MySqlCommandGate();
  private completedScope: MySqlCommandScope | null = null;
  private executingScope: MySqlCommandScope | null = null;
  private closePending: boolean = false;
  private queryWrite: Promise<void> | null = null;
  private cancellationHandle: string = '';
  private createControlConnection: () => DbConnection;
  private skipAutocommitSetup: boolean = false;
  private batch: MySqlPreparedBatchExecutor | null = null;
  private insertRows: MySqlPreparedInsertRowsExecutor | null = null;
  private named: MySqlPreparedNamedExecutor | null = null;
  private procedures: MySqlPreparedProcedureCaller | null = null;
  private prepared: InternalPreparedExecutor | null = null;
  private cursors: MySqlReadOnlyCursorExecutor | null = null;
  private connectOperation: CommandCloseSettlement | null = null;
  private ordinaryOperation: OrdinaryCommandSettlement | null = null;
  private preparedOperation: PreparedCommandSettlement | null = null;
  private cursorOperation: PreparedCommandSettlement | null = null;
  private transactionOperation: PreparedCommandSettlement | null = null;

  constructor(config: ConnectionConfig, password: string, transport: TcpTransport = new TcpTransport(),
    timers: ConnectionTimerPort = new SystemConnectionTimerPort(),
    createControlConnection?: () => DbConnection) {
    this.config = config.clone();
    this.password = password;
    this.transport = transport;
    this.timers = timers;
    mySqlExecutionObserverBindings.set(this,
      (capability: Object, observer: MySqlExecutionObserver,
        executionClock: () => number): void => {
        if (capability !== mysqlExecutionObserverCapability) {
          throw ArkDbError.protocol('Invalid MySQL execution observer capability.');
        }
        if (this.commandGate.hasReserved) {
          mySqlExecutionObserverBindings.delete(this);
          throw ArkDbError.protocol(
            'Execution observation must be configured before the first command.');
        }
        mySqlExecutionObserverBindings.delete(this);
        this.commandGate = new MySqlCommandGate(
          new MySqlExecutionDispatcher(observer, executionClock));
      });
    this.createControlConnection = createControlConnection !== undefined ? createControlConnection :
      (): DbConnection => this.createDefaultControlConnection();
    this.features.streaming = new MySqlCoreStreamingConnection(this,
      (sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> =>
        this.queryStreamInternal(sql, options, sink));
    this.features.health = this;
    this.features.context = this;
    this.features.transactions = this;
    this.features.cancellation = this;
    this.features.metadata = new MySqlMetadataProvider(this);
    this.features.metrics = new MySqlServerMetricsProvider(this.features.streaming);
    this.mysqlFeatures.batch = new MySqlConnectionBatchExecutor(
      (): MySqlBatchExecutor => this.batchExecutor());
    this.mysqlFeatures.cursors = new MySqlConnectionCursorExecutor(
      (): MySqlCursorExecutor => this.cursorExecutor());
    this.mysqlFeatures.deadlines = new MySqlConnectionDeadlineExecutor(
      (sql: string, options: MySqlDeadlineOptions): Promise<QueryResult> =>
        this.queryWithDeadline(sql, options),
      (sql: string, parameters: MySqlParameter[],
        options: MySqlDeadlineOptions): Promise<QueryResult> =>
        this.executeWithDeadline(sql, parameters, options));
    this.mysqlFeatures.insertRows = new MySqlConnectionInsertRowsExecutor(
      (): MySqlPreparedInsertRowsExecutor => this.insertRowsExecutor());
    this.mysqlFeatures.named = new MySqlConnectionNamedExecutor(
      (): MySqlNamedExecutor => this.namedExecutor());
    this.mysqlFeatures.longData = new MySqlConnectionLongDataExecutor(
      (): MySqlLongDataExecutor => this.internalPreparedExecutor().longData);
    this.mysqlFeatures.prepared = new MySqlConnectionPreparedExecutor(
      (): MySqlPreparedExecutor => this.preparedExecutor());
    this.mysqlFeatures.procedures = new MySqlConnectionProcedureCaller(
      (): MySqlProcedureCaller => this.procedureCaller());
    this.mysqlFeatures.session = new MySqlConnectionSessionController(
      (): Promise<void> => this.resetSession());
    this.mysqlFeatures.transactions = new MySqlConnectionTransactionRunner(this.transactionHost());
  }

  private preparedCloseSignal(scope: MySqlCommandScope): Promise<ArkDbError> {
    const operation = this.preparedOperation;
    if (operation === null || operation.scope !== scope) {
      return Promise.reject<ArkDbError>(
        ArkDbError.protocol('Prepared operation close signal is unavailable.'));
    }
    return operation.closeRequested;
  }

  get state(): ConnectionState {
    return this.connState;
  }

  get serverInfo(): ServerInfo {
    return this.info;
  }

  get sessionStatus(): MySqlDatabaseSessionStatus {
    return mysqlSessionStatus(this.status);
  }

  protected createDefaultControlConnection(): MySqlConnection {
    const controlConfig = this.config.clone();
    controlConfig.defaultSchema = undefined;
    controlConfig.autocommit = true;
    controlConfig.session = undefined;
    controlConfig.multipleStatements = false;
    const control = new MySqlConnection(controlConfig, this.password, undefined, undefined,
      (): DbConnection => {
        throw ArkDbError.unsupported('A MySQL control connection cannot create another control connection.');
      });
    control.skipAutocommitSetup = true;
    return control;
  }

  protected async readMySqlSessionFingerprint(scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> {
    this.commandGate.assertOwner(scope);
    this.requireReady();
    let fingerprint: MySqlSessionFingerprint | null = null;
    const command = buildComQuery(MYSQL_SESSION_FINGERPRINT_SQL);
    await this.bufferedCommandOwned(scope, command, async (channel: PacketChannel): Promise<QueryResult> => {
      const result = await parseBufferedResultStream(channel, this.clientCaps,
        new MySqlSessionFingerprintRowDecoder());
      this.commandGate.assertOwner(scope);
      fingerprint = mysqlSessionFingerprint(result);
      return result;
    });
    this.commandGate.assertOwner(scope);
    if (fingerprint === null) throw ArkDbError.protocol('The MySQL session fingerprint result was not produced.');
    return fingerprint;
  }

  protected preparedExecutor(): MySqlPreparedExecutor {
    return this.internalPreparedExecutor();
  }

  private internalPreparedExecutor(): InternalPreparedExecutor {
    this.requireReady();
    if (this.prepared !== null) return this.prepared;
    this.requireExecutorCreationAllowed();
    this.prepared = new InternalPreparedExecutor(this.preparedHost());
    return this.prepared;
  }

  protected batchExecutor(): MySqlBatchExecutor {
    if (this.batch !== null) return this.batch;
    this.requireReady();
    this.requireExecutorCreationAllowed();
    this.batch = new MySqlPreparedBatchExecutor(this.preparedHost(),
      (): DatabaseSessionStatus => this.status.clone());
    return this.batch;
  }

  protected cursorExecutor(): MySqlCursorExecutor {
    if (this.cursors !== null) return this.cursors;
    this.requireReady();
    this.requireExecutorCreationAllowed();
    this.cursors = new MySqlReadOnlyCursorExecutor(this.preparedHost());
    return this.cursors;
  }

  protected insertRowsExecutor(): MySqlPreparedInsertRowsExecutor {
    if (this.insertRows !== null) return this.insertRows;
    this.requireReady();
    this.requireExecutorCreationAllowed();
    this.insertRows = new MySqlPreparedInsertRowsExecutor(this.preparedHost());
    return this.insertRows;
  }

  protected namedExecutor(): MySqlNamedExecutor {
    this.requireReady();
    if (this.named !== null) return this.named;
    this.requireExecutorCreationAllowed();
    this.named = new MySqlPreparedNamedExecutor(this.preparedHost());
    return this.named;
  }

  protected procedureCaller(): MySqlProcedureCaller {
    this.requireReady();
    if (this.procedures !== null) return this.procedures;
    this.requireExecutorCreationAllowed();
    this.procedures = new MySqlPreparedProcedureCaller(this.preparedHost());
    return this.procedures;
  }

  private requireExecutorCreationAllowed(): void {
    if (this.commandGate.current !== null) {
      throw ArkDbError.protocol('Another command already owns this connection.');
    }
  }

  private transactionHost(): MySqlTransactionRunnerHost {
    return new TransactionConnectionHost(
      (): ConnectionState => this.connState,
      (): MySqlConnectionFeatures => this.mysqlFeatures,
      (): ServerInfo => this.info,
      (): MySqlDatabaseSessionStatus => this.sessionStatus,
      (): MySqlCommandScope => this.reserveTransactionRunnerScope(),
      (scope: MySqlCommandScope): Promise<ArkDbError[]> =>
        this.settleTransactionOperation(scope),
      (scope: MySqlCommandScope): Promise<ArkDbError[]> =>
        this.finishTransactionRunnerScope(scope),
      (scope: MySqlCommandScope): Promise<void> =>
        this.refreshTransactionStatus(scope),
      (scope: MySqlCommandScope, error: ArkDbError): Promise<void> =>
        this.retireTransaction(scope, error),
      (scope: MySqlCommandScope, sql: string): Promise<QueryResult> =>
        this.queryOwned(scope, sql),
      (scope: MySqlCommandScope, sql: string, options: QueryOptions,
        sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> =>
        this.transactionQueryStreamOwned(scope, sql, options, sink),
      (scope: MySqlCommandScope,
        input: MySqlInsertRowsInput): Promise<MySqlBatchResult> =>
        this.transactionInsertRowsOwned(scope, input));
  }

  private preparedHost(): PreparedConnectionHost {
    return new PreparedConnectionHost(this.commandGate, this.timers,
      (): PacketChannel | null => this.channel, (): number => this.clientCaps,
      (): ConnectionState => this.connState,
      (error: ArkDbError): Promise<void> => this.retirePreparedSession(error),
      <T>(kind: MySqlCommandKind, operation: (scope: MySqlCommandScope) => Promise<T>,
        cachedConvenience?: boolean): Promise<T> =>
        this.runPreparedCommand<T>(kind, operation, cachedConvenience),
      (scope: MySqlCommandScope): Promise<ArkDbError> =>
        this.preparedCloseSignal(scope),
      (scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
        observer?: (result: QueryResult) => void,
        observations?: MySqlResultTerminatorObservation[]): Promise<QueryResult> =>
        this.awaitPreparedExecution(scope,
          this.bufferedCommandOwned(scope, command, (channel: PacketChannel): Promise<QueryResult> =>
            parseBufferedResultStream(new PreparedPacketSource(channel, this.clientCaps),
              this.clientCaps, new BinaryRowDecoder(), options, this.status,
              observations))
            .then((result: QueryResult): QueryResult => {
              if (observer !== undefined) observer(result);
              return result;
            })),
      async (scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
        sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> =>
        mysqlExecutionSummary(await this.awaitPreparedExecution(scope,
          this.streamCommandOwned(scope, command, new MySqlResultSinkAdapter(sink),
            (channel: PacketChannel, guarded: QueryResultSink): Promise<QueryExecutionSummary> =>
              parseResultStream(new PreparedPacketSource(channel, this.clientCaps),
                this.clientCaps, options, guarded, new BinaryRowDecoder(), this.status)))),
      async (scope: MySqlCommandScope): Promise<string> =>
        (await this.awaitPreparedExecution(scope,
          this.readMySqlSessionFingerprint(scope),
          MySqlExecutionOutcome.NotDispatched,
          MySqlExecutionOutcome.NotDispatched)).sqlMode,
      <T>(operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T> =>
        this.startCursorCommand<T>(operation),
      <T>(scope: MySqlCommandScope, phase: MySqlCommandPhase,
        command: Uint8Array,
        parse: (source: MysqlPacketSource) => Promise<T>): Promise<T> =>
        this.runCursorCommandOwned<T>(scope, phase, command, parse),
      (scope: MySqlCommandScope): void => {
        this.requireOwnedChannel(scope);
      },
      (scope: MySqlCommandScope, statusFlags: number): void =>
        this.applyCursorStatus(scope, statusFlags),
      (scope: MySqlCommandScope, primary?: Object,
        outcome?: MySqlExecutionOutcome, validate?: () => void,
        complete?: () => void): Promise<void> =>
        this.finishCursorCommand(scope, primary, outcome, validate, complete),
      this.config.preparedCacheSize === undefined ? 0 : this.config.preparedCacheSize);
  }

  /** Connect, read the handshake, and authenticate. */
  async connect(): Promise<void> {
    if (this.retiredByCancellation) {
      throw ArkDbError.protocol('Connection retired after an unacknowledged cancellation; create a new connection.');
    }
    if (this.cancelTask !== null) throw ArkDbError.protocol('A cancellation request is still settling.');
    if (this.connState !== ConnectionState.Idle && this.connState !== ConnectionState.Closed) {
      throw ArkDbError.protocol('connect() called in state ' + this.connState);
    }
    this.commandGate.advanceGeneration();
    this.invalidatePreparedState();
    const deadline = new ConnectionDeadline(this.config.connectTimeoutMs, this.timers);
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
    const executionOutcome = primary instanceof MySqlOperationError ? primary.outcome :
      (primary === null ? MySqlExecutionOutcome.Completed : MySqlExecutionOutcome.NotDispatched);
    const closeJoin = this.commandCloseJoin(settlement, scope);
    if (closeJoin !== null) {
      const closeFailure = await closeJoin;
      if (closeFailure !== null) {
        if (primary === null) primary = closeFailure;
        else if (!operationContainsFailure(primary, closeFailure)) cleanup.push(closeFailure);
      }
    }
    try {
      this.finishCommand(scope);
    } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    if (this.connectOperation === settlement) this.connectOperation = null;
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
      throw operationFailure(cleanup[0], cleanup.slice(1), MySqlExecutionOutcome.Completed);
    }
  }

  private async connectOwned(scope: MySqlCommandScope,
    deadline: ConnectionDeadline): Promise<void> {
    let primary: Object | null = null;
    const cleanupErrors: ArkDbError[] = [];
    let dispatched = false;
    try {
      if (this.closePending) throw ArkDbError.cancelled('Connection closed while opening.');
      const sessionStatements = mysqlSessionInitializationSql(this.config.session);
      this.commandGate.setPhase(scope, MySqlCommandPhase.Preparing);
      this.connState = ConnectionState.Connecting;
      this.status.known = false;
      this.tlsActive = false;
      Logger.i(LogTag.Conn, 'connecting host=' + Logger.mask(this.config.host) + ' port=' + this.config.port);
      await deadline.wait((): Promise<void> =>
        this.transport.connect(this.config.host, this.config.port, deadline.remainingMs()));
      deadline.remainingMs();
      const channel = new PacketChannel(this.transport);
      this.channel = channel;

      const handshakePkt = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
      deadline.remainingMs();
      if (firstByte(handshakePkt.payload) === PacketType.ERR) {
        const err = parseErr(handshakePkt.payload, 0);
        throw ArkDbError.server(err.message, err.code, err.sqlState);
      }
      const handshake = parseHandshake(handshakePkt.payload);
      this.applyServerInfo(handshake);
      this.authNonce = handshake.salt;
      Logger.i(LogTag.Conn, 'handshake family=' + String(handshake.family) +
        ' plugin=' + authPluginLogValue(handshake.authPluginName));

      const withDb = this.config.defaultSchema !== undefined && this.config.defaultSchema.length > 0;
      const withTls = mysqlTlsRequested(this.config.ssl.mode, handshake.capabilities);
      this.clientCaps = computeClientCapabilities(handshake.capabilities, withDb, withTls,
        this.config.multipleStatements === true);

      this.connState = ConnectionState.Authenticating;
      const params = new HandshakeResponseParams();
      params.capabilities = this.clientCaps;
      params.user = this.config.user;
      params.authPluginName = handshake.authPluginName;
      if (withDb) {
        params.database = this.config.defaultSchema;
      }
      if (withTls) {
        this.transport.prepareTlsUpgrade();
        dispatched = true;
        await deadline.wait((): Promise<void> => channel.writePacket(buildSslRequest(
          params.capabilities, params.charset, params.maxPacketSize)));
        await deadline.wait((): Promise<void> => this.transport.upgradeToTls(
          this.config.host, this.config.port, this.config.ssl, deadline.remainingMs()));
        deadline.remainingMs();
        this.tlsActive = true;
        this.info.tlsActive = true;
      }
      params.authResponse = await deadline.wait((): Promise<Uint8Array> =>
        this.computeAuth(handshake.authPluginName, handshake.salt));
      dispatched = true;
      await deadline.wait((): Promise<void> => channel.writePacket(buildHandshakeResponse(params)));

      const authStatusFlags = await this.readAuthResult(channel, deadline);
      deadline.remainingMs();
      this.applyStatusFlags(authStatusFlags);
      if (!this.skipAutocommitSetup && this.status.autocommit !== this.config.autocommit) {
        channel.resetSequence();
        await deadline.wait((): Promise<void> => channel.writePacket(buildComQuery(
          this.config.autocommit ? 'SET autocommit = 1' : 'SET autocommit = 0')));
        const setup = await deadline.wait((): Promise<QueryResult> =>
          parseResultSet(channel, this.clientCaps));
        deadline.remainingMs();
        this.status.autocommit = setup.autocommit;
        this.status.inTransaction = setup.inTransaction;
      }
      for (const sql of sessionStatements) {
        this.commandGate.assertOwner(scope);
        channel.resetSequence();
        await deadline.wait((): Promise<void> => channel.writePacket(buildComQuery(sql)));
        const setup = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
        deadline.remainingMs();
        this.expectOk(setup);
      }
      deadline.remainingMs();
      this.connState = ConnectionState.Ready;
      Logger.i(LogTag.Conn, 'ready host=' + Logger.mask(this.config.host) + ' user=' + Logger.mask(this.config.user));
    } catch (e) {
      primary = e as Object;
      if (this.connState !== ConnectionState.Closed) this.connState = ConnectionState.Error;
      this.status.known = false;
      const oe = toArkDbError(e);
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      try { deadline.cancel(oe); } catch (cleanup) {
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
      Logger.e(LogTag.Conn, 'connect failed host=' + Logger.mask(this.config.host) +
        ' kind=' + String(oe.kind) + ' error=' + Logger.errorToken(oe));
      this.channel = null;
      this.invalidatePreparedState();
      const settlement = this.connectOperation;
      const rootCloseOwnsCleanup = settlement !== null &&
        settlement.scope === scope && settlement.closeResult !== null;
      if (!rootCloseOwnsCleanup) {
        try {
          await this.transport.abort(oe);
        } catch (cleanup) {
          Logger.w(LogTag.Conn, 'connect cleanup failed error=' + Logger.errorToken(cleanup));
          cleanupErrors.push(toCleanupError(cleanup as Object));
        }
      }
    } finally {
      try { deadline.dispose(); } catch (cleanup) {
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
      if (this.opening === deadline) this.opening = null;
    }
    if (primary !== null) {
      const outcome = isMySqlServerRejection(toArkDbError(primary)) ? MySqlExecutionOutcome.ServerRejected :
        (dispatched ? MySqlExecutionOutcome.Unknown : MySqlExecutionOutcome.NotDispatched);
      throw operationFailure(primary, cleanupErrors, outcome);
    }
    if (cleanupErrors.length > 0) {
      throw operationFailure(cleanupErrors[0], cleanupErrors, MySqlExecutionOutcome.Completed);
    }
  }

  /** Run a text SQL statement and return the (fully buffered) result. */
  async query(sql: string): Promise<QueryResult> {
    return this.runOrdinaryCommand<QueryResult>(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<QueryResult> => this.queryOwned(scope, sql));
  }

  private async queryWithDeadline(sql: string, options: MySqlDeadlineOptions): Promise<QueryResult> {
    return this.runOrdinaryCommand<QueryResult>(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<QueryResult> =>
        this.runMySqlDeadline<QueryResult>(scope, options,
          (): Promise<QueryResult> => this.queryOwnedWithOptions(scope, sql, options.queryOptions)));
  }

  private executeWithDeadline(sql: string, parameters: MySqlParameter[],
    options: MySqlDeadlineOptions): Promise<QueryResult> {
    const executor = this.internalPreparedExecutor();
    return this.runPreparedCommand<QueryResult>(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<QueryResult> =>
        this.runMySqlDeadline<QueryResult>(scope, options,
          (): Promise<QueryResult> =>
            executor.executeOwned(scope, sql, parameters, options.queryOptions)),
      executor.cacheEnabled);
  }

  private async queryOwned(scope: MySqlCommandScope, sql: string): Promise<QueryResult> {
    const command = buildComQuery(sql);
    return this.bufferedCommandOwned(scope, command,
      (channel: PacketChannel): Promise<QueryResult> => parseResultSet(channel, this.clientCaps));
  }

  private async queryOwnedWithOptions(scope: MySqlCommandScope, sql: string,
    options: QueryOptions): Promise<QueryResult> {
    const command = buildComQuery(sql);
    return this.bufferedCommandOwned(scope, command,
      (channel: PacketChannel): Promise<QueryResult> =>
        parseBufferedResultStream(channel, this.clientCaps, new TextRowDecoder(), options, this.status));
  }

  private async bufferedCommandOwned(scope: MySqlCommandScope, command: Uint8Array,
    parse: (channel: PacketChannel) => Promise<QueryResult>): Promise<QueryResult> {
    const channel = this.requireOwnedChannel(scope);
    let startedAtMs: number = 0;
    let reading = false;
    this.connState = ConnectionState.Querying;
    this.executingScope = scope;
    this.commandGate.setPhase(scope, MySqlCommandPhase.Executing);
    try {
      channel.resetSequence();
      startedAtMs = monotonicNowMs();
      this.markOrdinaryCommandDispatched(scope);
      this.queryWrite = channel.writePacket(command);
      await this.queryWrite;
      reading = true;
      const result = await parse(channel);
      result.executionTimeMs = monotonicNowMs() - startedAtMs;
      if (this.state !== ConnectionState.Closed) {
        this.status.autocommit = result.autocommit;
        this.status.inTransaction = result.inTransaction;
        this.status.known = result.statusKnown;
        this.connState = ConnectionState.Ready;
      }
      Logger.d(LogTag.Query, 'query ok rows=' + result.rows.length + ' cols=' + result.columns.length + ' dur=' + result.executionTimeMs + 'ms');
      return result;
    } catch (e) {
      const failedAtMs = monotonicNowMs();
      const oe = await this.classifyCommandFailure(scope, e, reading);
      const diagnostic = queryFailureDiagnostic(oe, failedAtMs - startedAtMs);
      Logger.e(LogTag.Query, 'query failed ' + diagnostic);
      throw oe;
    } finally {
      this.queryWrite = null;
      this.executingScope = null;
    }
  }

  /** Run a text SQL statement and emit bounded result chunks through an awaited sink. */
  async queryStream(sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return mysqlExecutionSummary(await this.queryStreamInternal(sql, options, new MySqlResultSinkAdapter(sink)));
  }

  private async queryStreamInternal(sql: string, options: QueryOptions,
    sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return this.runOrdinaryCommand<QueryExecutionSummary>(MySqlCommandKind.QueryStream,
      (scope: MySqlCommandScope): Promise<QueryExecutionSummary> => {
      const executionOptions = options.clone();
      validateQueryOptions(executionOptions);
      return this.queryStreamOwned(scope, sql, executionOptions, sink);
    });
  }

  private async queryStreamOwned(scope: MySqlCommandScope, sql: string, executionOptions: QueryOptions,
    sink: QueryResultSink): Promise<QueryExecutionSummary> {
    const command = buildComQuery(sql);
    return this.streamCommandOwned(scope, command, sink,
      (channel: PacketChannel, guarded: QueryResultSink): Promise<QueryExecutionSummary> =>
        parseQueryStream(channel, this.clientCaps, executionOptions, guarded, this.status));
  }

  private async streamCommandOwned(scope: MySqlCommandScope, command: Uint8Array, sink: QueryResultSink,
    parse: (channel: PacketChannel, guarded: QueryResultSink) => Promise<QueryExecutionSummary>
  ): Promise<QueryExecutionSummary> {
    const channel = this.requireOwnedChannel(scope);
    const operationSink = new OperationResultSink(sink, (): void => {
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
    });
    let startedAtMs: number = 0;
    let reading = false;
    let synchronized = false;
    this.connState = ConnectionState.Querying;
    this.executingScope = scope;
    this.commandGate.setPhase(scope, MySqlCommandPhase.Executing);
    try {
      channel.resetSequence();
      startedAtMs = monotonicNowMs();
      this.markOrdinaryCommandDispatched(scope);
      this.queryWrite = channel.writePacket(command);
      await this.queryWrite;
      reading = true;
      if (this.state !== ConnectionState.Closed) {
        this.commandGate.setPhase(scope, MySqlCommandPhase.Streaming);
      }
      const summary = await parse(channel, operationSink);
      if (!summary.statusKnown) {
        try {
          await this.refreshSessionStatus(scope, summary.synchronizationDeadlineMs);
        } catch (error) {
          throw synchronizationRefreshFailure(error as Object);
        }
        summary.status = this.status.clone();
        summary.statusKnown = true;
      }
      if (this.state !== ConnectionState.Closed) {
        this.status = summary.status.clone();
        this.connState = ConnectionState.Ready;
        synchronized = true;
      }
      const hookFailure = operationSink.truncationFailure;
      if (hookFailure !== null) throw hookFailure;
      Logger.d(LogTag.Query, 'query stream ok results=' + summary.resultSetCount + ' rows=' +
        summary.loadedRowCount + '/' + summary.rowCount + ' dur=' + summary.executionTimeMs + 'ms');
      return summary;
    } catch (e) {
      const failedAtMs = monotonicNowMs();
      let primary = e as Object;
      const hookFailure = operationSink.truncationFailure;
      if (hookFailure !== null && primary !== hookFailure) {
        primary = operationFailure(hookFailure, [toCleanupError(primary)], MySqlExecutionOutcome.Unknown);
      }
      const error = await this.classifyCommandFailure(scope, primary, reading, synchronized);
      const diagnostic = queryFailureDiagnostic(error, failedAtMs - startedAtMs);
      Logger.e(LogTag.Query, 'query stream failed ' + diagnostic);
      throw error;
    } finally {
      this.queryWrite = null;
      this.executingScope = null;
    }
  }

  /** Round-trip COM_PING. */
  async ping(): Promise<void> {
    return this.runOrdinaryCommand<void>(MySqlCommandKind.Ping,
      (scope: MySqlCommandScope): Promise<void> => {
      const command = new PacketWriter().writeUInt8(Command.PING).toUint8Array();
      return this.executeOkOwned(scope, command);
    });
  }

  /** Switch the default database (COM_INIT_DB / USE). */
  async useDatabase(name: string): Promise<void> {
    return this.runOrdinaryCommand<void>(MySqlCommandKind.Context,
      (scope: MySqlCommandScope): Promise<void> => {
      Logger.d(LogTag.Conn, 'useDatabase ' + Logger.mask(name));
      const command = new PacketWriter().writeUInt8(Command.INIT_DB).writeString(name).toUint8Array();
      return this.executeOkOwned(scope, command);
    });
  }

  private async resetSession(): Promise<void> {
    this.requireReady();
    const deadline = new ConnectionDeadline(this.config.connectTimeoutMs, this.timers);
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
        new PacketWriter().writeUInt8(Command.RESET_CONNECTION).toUint8Array(), true, deadline);
      accepted = true;
      this.invalidatePreparedState();
      this.commandGate.advanceGenerationOnRelease(scope);
      await this.reinitializeSessionOwned(scope, deadline);
    } catch (error) {
      const caught = error as Object;
      primary = caught instanceof ArkDbError && caught.kind === ArkDbErrorKind.Timeout ?
        ArkDbError.timeout('MySQL session reset timed out.') : caught;
      const failure = toArkDbError(primary);
      reusableRejection = !accepted &&
        (failure.kind === ArkDbErrorKind.Unsupported || isMySqlServerRejection(failure));
      if (!reusableRejection) {
        this.commandGate.advanceGenerationOnRelease(scope);
        const retirement = await this.retireResetScope(scope);
        for (const cleanupFailure of retirement) cleanup.push(cleanupFailure);
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
      const failure = toArkDbError(primary);
      if (reusableRejection && cleanup.length === 0 &&
        failure.kind === ArkDbErrorKind.Unsupported) throw primary as Error;
      throw operationFailure(primary, cleanup,
        reusableRejection ? MySqlExecutionOutcome.ServerRejected : MySqlExecutionOutcome.Unknown);
    }
    if (cleanup.length > 0) {
      throw operationFailure(cleanup[0], cleanup.slice(1), MySqlExecutionOutcome.Completed);
    }
  }

  private async reinitializeSessionOwned(scope: MySqlCommandScope,
    deadline: ConnectionDeadline): Promise<void> {
    await this.executeResetOkOwned(scope,
      buildComQuery(MYSQL_SESSION_CHARACTER_SET_SQL), false, deadline);
    const database = this.config.defaultSchema;
    if (database !== undefined && database.length > 0) {
      const command = new PacketWriter().writeUInt8(Command.INIT_DB).writeString(database).toUint8Array();
      await this.executeResetOkOwned(scope, command, false, deadline);
    }
    if (!this.skipAutocommitSetup && this.status.autocommit !== this.config.autocommit) {
      await this.executeResetOkOwned(scope, buildComQuery(
        this.config.autocommit ? 'SET autocommit = 1' : 'SET autocommit = 0'), false, deadline);
    }
    for (const sql of mysqlSessionInitializationSql(this.config.session)) {
      await this.executeResetOkOwned(scope, buildComQuery(sql), false, deadline);
    }
    const fingerprint = await deadline.wait((): Promise<MySqlSessionFingerprint> =>
      this.readMySqlSessionFingerprint(scope));
    deadline.remainingMs();
    this.validateResetFingerprint(fingerprint);
  }

  private validateResetFingerprint(fingerprint: MySqlSessionFingerprint): void {
    if (fingerprint.characterSetClient !== 'utf8mb4') {
      throw ArkDbError.protocol(
        'MySQL session reset did not restore character_set_client=utf8mb4.');
    }
    const database = this.config.defaultSchema;
    if (database !== undefined && database.length > 0) {
      if (fingerprint.database !== database) {
        throw ArkDbError.protocol('MySQL session reset did not restore the configured default database.');
      }
      return;
    }
    if (fingerprint.database !== null && fingerprint.database.length > 0) {
      throw ArkDbError.protocol('MySQL session reset retained an unexpected default database.');
    }
  }

  private async executeResetOkOwned(scope: MySqlCommandScope, command: Uint8Array,
    resetCommand: boolean, deadline: ConnectionDeadline): Promise<void> {
    const channel = this.requireOwnedChannel(scope);
    this.commandGate.setPhase(scope, MySqlCommandPhase.Resetting);
    channel.resetSequence();
    await deadline.wait((): Promise<void> => channel.writePacket(command));
    deadline.remainingMs();
    const response = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
    deadline.remainingMs();
    if (resetCommand) this.expectResetOk(response);
    else this.expectOk(response);
  }

  private async retireResetScope(scope: MySqlCommandScope): Promise<ArkDbError[]> {
    const cleanup: ArkDbError[] = [];
    this.commandGate.assertOwner(scope);
    this.commandGate.advanceGenerationOnRelease(scope);
    if (this.closing === null) {
      this.closePending = true;
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      this.closing = this.closeWithScope(scope, false, false);
    }
    try {
      await this.closing;
    } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    return cleanup;
  }

  private async executeOkOwned(scope: MySqlCommandScope, command: Uint8Array): Promise<void> {
    const channel = this.requireOwnedChannel(scope);
    let reading = false;
    this.commandGate.setPhase(scope, MySqlCommandPhase.Executing);
    try {
      channel.resetSequence();
      this.markOrdinaryCommandDispatched(scope);
      await channel.writePacket(command);
      reading = true;
      this.expectOk(await channel.readPacket());
    } catch (error) {
      throw await this.classifyCommandFailure(scope, error as Object, reading);
    }
  }

  private expectResetOk(packet: MysqlPacket): void {
    if (firstByte(packet.payload) === PacketType.ERR) {
      const error = parseErr(packet.payload, this.clientCaps);
      if (error.code === 1047 || error.code === 1235) {
        throw new ArkDbError(ArkDbErrorKind.Unsupported,
          'Server does not support COM_RESET_CONNECTION.', error.code, error.sqlState);
      }
      throw ArkDbError.server(error.message, error.code, error.sqlState);
    }
    this.expectOk(packet);
  }

  async changeContext(context: DatabaseContext): Promise<void> {
    await this.useDatabase(mysqlDatabaseForContext(context));
  }

  async begin(): Promise<MySqlDatabaseSessionStatus> {
    return this.transactionCommand('START TRANSACTION');
  }

  async setAutocommit(enabled: boolean): Promise<MySqlDatabaseSessionStatus> {
    return this.transactionCommand(enabled ? 'SET autocommit = 1' : 'SET autocommit = 0');
  }

  async commit(): Promise<MySqlDatabaseSessionStatus> {
    return this.transactionCommand(MYSQL_COMMIT_NO_CHAIN_NO_RELEASE);
  }

  async rollback(): Promise<MySqlDatabaseSessionStatus> {
    return this.transactionCommand(MYSQL_ROLLBACK_NO_CHAIN_NO_RELEASE);
  }

  async savepoint(_name: string): Promise<void> {
    throw ArkDbError.validation('Savepoints are only available inside a transaction callback session.');
  }

  async rollbackTo(_name: string): Promise<void> {
    throw ArkDbError.validation('Savepoints are only available inside a transaction callback session.');
  }

  async releaseSavepoint(_name: string): Promise<void> {
    throw ArkDbError.validation('Savepoints are only available inside a transaction callback session.');
  }

  private async transactionCommand(sql: string): Promise<MySqlDatabaseSessionStatus> {
    return this.runOrdinaryCommand<MySqlDatabaseSessionStatus>(MySqlCommandKind.Transaction,
      async (scope: MySqlCommandScope): Promise<MySqlDatabaseSessionStatus> => {
        await this.queryOwned(scope, sql);
        return this.sessionStatus;
      });
  }

  private async transactionQueryStreamOwned(scope: MySqlCommandScope, sql: string,
    options: QueryOptions, sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    const executionOptions = options.clone();
    validateQueryOptions(executionOptions);
    return mysqlExecutionSummary(await this.queryStreamOwned(scope, sql, executionOptions,
      new MySqlResultSinkAdapter(sink)));
  }

  private transactionInsertRowsOwned(scope: MySqlCommandScope,
    input: MySqlInsertRowsInput): Promise<MySqlBatchResult> {
    return new MySqlPreparedInsertRowsExecutor(
      this.preparedHost(),
      (owned: MySqlCommandScope): Promise<void> =>
        this.settleTransactionPreparedExecution(owned))
      .executeInputOwned(scope, input);
  }

  cancel(): Promise<QueryCancellationResult> {
    const scope = this.commandGate.current;
    if (scope === null) {
      return Promise.resolve(new QueryCancellationResult(CancellationOutcome.NotRunning, this.reuseState()));
    }
    return this.cancelScope(scope);
  }

  private cancelScope(scope: MySqlCommandScope): Promise<QueryCancellationResult> {
    if (this.cancelTask !== null) {
      this.retainDeadlineCancellation(scope, this.cancelTask);
      return this.cancelTask;
    }
    if (!this.canCancelScope(scope)) {
      return Promise.resolve(new QueryCancellationResult(CancellationOutcome.NotRunning, this.reuseState()));
    }
    const task = this.cancelCurrentQuery(scope, this.cancellationHandle, this.queryWrite);
    this.cancelTask = task;
    this.retainDeadlineCancellation(scope, task);
    if (this.preparedOperation !== null && this.preparedOperation.scope === scope) {
      this.preparedOperation.cancellations.push(task);
    }
    if (this.transactionOperation !== null && this.transactionOperation.scope === scope) {
      this.transactionOperation.cancellations.push(task);
    }
    const settled = (): void => {
      this.cancelTask = null;
      this.releaseCompletedCommand();
    };
    task.then(settled, settled);
    return task;
  }

  isInterruptionError(error: ArkDbError): boolean {
    return isMySqlInterruptionError(error);
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
    return this.commandGate.isOwner(scope) && this.executingScope === scope &&
      this.connState === ConnectionState.Querying &&
      (ordinaryWire || cursorWire);
  }

  private async cancelCurrentQuery(scope: MySqlCommandScope, handle: string,
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
      // Validate before marking a KILL dispatch attempt.
      mysqlKillQueryForHandle(handle);
      const ownedControl = this.createControlConnection();
      if (ownedControl === this) {
        throw ArkDbError.validation('MySQL cancellation requires a distinct control connection.');
      }
      control = ownedControl;
      this.cancellationControl = ownedControl;
      const budget = new ConnectionDeadline(this.config.connectTimeoutMs, this.timers);
      deadline = budget;
      await budget.wait((): Promise<void> => ownedControl.connect());
      if (this.canCancelScope(scope)) {
        const dispatch = written;
        if (dispatch !== null) await budget.wait((): Promise<void> => dispatch);
        if (this.canCancelScope(scope)) {
          outcome = await budget.wait(async (): Promise<CancellationOutcome> => {
            dispatched = true;
            try {
              const result = await new MySqlExecutionController(ownedControl).requestCancellation(handle);
              outcomeKnown = true;
              return result;
            } catch (error) {
              const failure = toArkDbError(error as Object);
              knownNotDispatched = failure instanceof MySqlOperationError &&
                failure.outcome === MySqlExecutionOutcome.NotDispatched && failure.originalCause === undefined;
              outcomeKnown = isMySqlServerRejection(failure) || knownNotDispatched;
              throw error as Error;
            }
          });
        }
      }
    } catch (error) {
      primary = error as Object;
    } finally {
      if (deadline !== null) {
        try { deadline.dispose(); } catch (cleanup) {
          cleanupErrors.push(toCleanupError(cleanup as Object));
        }
      }
    }
    // Closing the control socket cannot rule out a delayed server-side KILL.
    if (dispatched && !outcomeKnown && !this.retiredByCancellation) {
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      this.retiredByCancellation = true;
      this.connState = ConnectionState.Closed;
      this.status.known = false;
      this.channel = null;
      this.invalidatePreparedState();
      const failure = primary !== null ? toArkDbError(primary) :
        ArkDbError.cancelled('Connection retired after an unacknowledged cancellation.');
      if (primary === null) primary = failure;
      try {
        await this.transport.abort(failure);
      } catch (cleanup) {
        Logger.w(LogTag.Conn, 'cancellation target cleanup failed error=' + Logger.errorToken(cleanup));
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
    }
    if (control !== null) {
      try {
        await control.close();
      } catch (cleanup) {
        Logger.w(LogTag.Conn, 'cancellation cleanup failed error=' + Logger.errorToken(cleanup));
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
      if (this.cancellationControl === control) this.cancellationControl = null;
    }
    if (primary !== null) {
      const failure = toArkDbError(primary);
      const failedOutcome = !dispatched || knownNotDispatched ?
        MySqlExecutionOutcome.NotDispatched : (isMySqlServerRejection(failure) ?
          MySqlExecutionOutcome.ServerRejected : MySqlExecutionOutcome.Unknown);
      throw operationFailure(primary, cleanupErrors, failedOutcome);
    }
    if (cleanupErrors.length > 0) {
      throw operationFailure(cleanupErrors[0], cleanupErrors,
        dispatched ? MySqlExecutionOutcome.Completed : MySqlExecutionOutcome.NotDispatched);
    }
    return new QueryCancellationResult(outcome, this.reuseState());
  }

  private reuseState(): ConnectionReuse {
    if (this.connState === ConnectionState.Querying) return ConnectionReuse.AwaitingCompletion;
    if (this.connState === ConnectionState.Ready) {
      if (this.commandGate.current !== null && this.completedScope !== this.commandGate.current) {
        return ConnectionReuse.AwaitingCompletion;
      }
      return this.status.known ? ConnectionReuse.Ready : ConnectionReuse.RequiresSynchronization;
    }
    return this.connState === ConnectionState.Closed ? ConnectionReuse.Closed : ConnectionReuse.NotReady;
  }

  /** Attempt COM_QUIT when idle, always close the socket, and retain any failures. */
  close(): Promise<void> {
    if (this.closing === null) {
      const current = this.commandGate.current;
      const ownsScope = current === null;
      const scope = current !== null ? current : this.commandGate.reserve(MySqlCommandKind.Close);
      const polite = ownsScope && this.opening === null && this.connState === ConnectionState.Ready;
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
      if (connecting !== null && connecting.scope === scope) connecting.closeResult = closing;
      const ordinary = this.ordinaryOperation;
      if (ordinary !== null && ordinary.scope === scope) ordinary.closeResult = closing;
      const prepared = this.preparedOperation;
      if (prepared !== null && prepared.scope === scope) {
        prepared.closeResult = closing;
        prepared.signalClose(
          ArkDbError.cancelled('Connection closed during a MySQL operation.'));
      }
      if (cursor !== null && (cursor.scope === scope || ownsScope)) {
        cursor.closeResult = closing;
      }
      const transaction = this.transactionOperation;
      if (transaction !== null && transaction.scope === scope) transaction.closeResult = closing;
      if (ownsScope) this.commandGate.start(scope);
      begin();
    }
    return this.closing;
  }

  private async closeWithScope(scope: MySqlCommandScope,
    ownsScope: boolean, polite: boolean,
    releaseIdleCursor: boolean = false): Promise<void> {
    try {
      await this.closeInternal(polite);
    } finally {
      this.closePending = false;
      if (ownsScope) this.finishCommand(scope);
      else {
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
        this.opening.cancel(ArkDbError.cancelled('Connection closed while opening.'));
      } catch (error) { primary = error as Object; }
    }
    if (this.resetting !== null) {
      try {
        this.resetting.cancel(ArkDbError.cancelled('Connection closed while resetting the session.'));
      } catch (error) {
        if (primary === null) primary = error as Object;
        else cleanupErrors.push(toCleanupError(error as Object));
      }
    }
    if (channel !== null && polite) {
      try {
        channel.resetSequence();
        const w = new PacketWriter();
        w.writeUInt8(Command.QUIT);
        await channel.writePacket(w.toUint8Array(), 1000);
      } catch (e) {
        Logger.w(LogTag.Conn, 'quit before close failed error=' + Logger.errorToken(e));
        if (primary === null) primary = e as Object;
        else cleanupErrors.push(toCleanupError(e as Object));
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
      Logger.w(LogTag.Conn, 'close cancellation cleanup failed error=' + Logger.errorToken(cleanup));
      if (primary === null) primary = cleanup as Object;
      else cleanupErrors.push(toCleanupError(cleanup as Object));
    }
    if (primary !== null) {
      throw operationFailure(primary, cleanupErrors, MySqlExecutionOutcome.Unknown);
    }
    Logger.d(LogTag.Conn, 'closed');
  }

  private async computeAuth(plugin: string, salt: Uint8Array): Promise<Uint8Array> {
    if (plugin === 'mysql_native_password' || plugin.length === 0) {
      Logger.d(LogTag.Auth, 'scramble plugin=mysql_native_password');
      return await nativeScramble(this.password, salt);
    }
    if (plugin === 'caching_sha2_password') {
      Logger.d(LogTag.Auth, 'scramble plugin=caching_sha2_password (fast)');
      return await cachingSha2Scramble(this.password, salt);
    }
    Logger.e(LogTag.Auth, 'unsupported auth plugin=' + authPluginLogValue(plugin));
    throw new ArkDbError(ArkDbErrorKind.Auth, 'Unsupported authentication plugin: ' + plugin);
  }

  private async readAuthResult(channel: PacketChannel, deadline: ConnectionDeadline): Promise<number> {
    const pkt = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
    deadline.remainingMs();
    const fb = firstByte(pkt.payload);
    if (fb === PacketType.OK) {
      return parseOk(pkt.payload, this.clientCaps).statusFlags;
    }
    if (fb === PacketType.ERR) {
      const err = parseErr(pkt.payload, this.clientCaps);
      throw ArkDbError.server(err.message, err.code, err.sqlState);
    }
    if (fb === 0xfe) {
      // AuthSwitchRequest: [0xfe][plugin NUL][salt EOF]
      const r = pkt.reader();
      r.readUInt8();
      const newPlugin = r.readNulString();
      let newSalt = r.readBytes(r.remaining);
      if (newSalt.length > 0 && newSalt[newSalt.length - 1] === 0x00) {
        newSalt = newSalt.subarray(0, newSalt.length - 1);
      }
      this.authNonce = newSalt;
      this.info.authPlugin = newPlugin;
      Logger.d(LogTag.Auth, 'auth-switch -> ' + authPluginLogValue(newPlugin));
      const response = await deadline.wait((): Promise<Uint8Array> => this.computeAuth(newPlugin, newSalt));
      await deadline.wait((): Promise<void> => channel.writePacket(response));
      return await this.readAuthResult(channel, deadline);
    }
    if (fb === 0x01) {
      // AuthMoreData — caching_sha2_password flow.
      const r = pkt.reader();
      r.readUInt8(); // 0x01
      const indicator = r.hasMore() ? r.peekUInt8() : -1;
      if (indicator === 0x03) {
        // fast-auth success — the OK packet follows.
        Logger.d(LogTag.Auth, 'caching_sha2 fast-auth ok');
        return await this.readAuthResult(channel, deadline);
      }
      if (indicator === 0x04) {
        // full authentication required.
        Logger.d(LogTag.Auth, 'caching_sha2 full-auth required');
        await this.cachingSha2FullAuth(channel, deadline);
        return await this.readAuthResult(channel, deadline);
      }
      throw ArkDbError.protocol('Unexpected AuthMoreData indicator 0x' + (indicator & 0xff).toString(16));
    }
    throw ArkDbError.protocol('Unexpected auth response byte 0x' + fb.toString(16));
  }

  /** caching_sha2 full auth: cleartext over TLS, else RSA-OAEP over the plaintext channel. */
  private async cachingSha2FullAuth(channel: PacketChannel, deadline: ConnectionDeadline): Promise<void> {
    if (this.tlsActive) {
      Logger.d(LogTag.Auth, 'full-auth via TLS cleartext');
      const w = new PacketWriter();
      w.writeString(this.password);
      w.writeUInt8(0x00);
      await deadline.wait((): Promise<void> => channel.writePacket(w.toUint8Array()));
      return;
    }
    Logger.d(LogTag.Auth, 'full-auth via RSA public key');
    // Plaintext: request the server RSA public key, then send OAEP(password XOR nonce).
    const request = new PacketWriter();
    request.writeUInt8(0x02); // request_public_key
    await deadline.wait((): Promise<void> => channel.writePacket(request.toUint8Array()));

    const keyPkt = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
    const kr = keyPkt.reader();
    if (kr.readUInt8() !== 0x01) {
      throw ArkDbError.protocol('Expected AuthMoreData carrying the RSA public key');
    }
    const pem = kr.readEofString();
    const obfuscated = obfuscatePassword(this.password, this.authNonce);
    const encrypted = await deadline.wait((): Promise<Uint8Array> => rsaOaepEncrypt(pem, obfuscated));
    await deadline.wait((): Promise<void> => channel.writePacket(encrypted));
  }

  private requireReady(): PacketChannel {
    if (this.cancelTask !== null) {
      throw ArkDbError.protocol('Await the cancellation request before starting another command.');
    }
    if (this.connState !== ConnectionState.Ready || this.channel === null) {
      throw ArkDbError.protocol('Connection is not ready (state ' + this.connState + ')');
    }
    return this.channel;
  }

  private reserveCommandOwnership(kind: MySqlCommandKind): MySqlCommandScope {
    this.requireReady();
    return this.commandGate.reserve(kind);
  }

  private async runOrdinaryCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T> {
    const scope = this.reserveCommandOwnership(kind);
    const settlement = new OrdinaryCommandSettlement(scope);
    this.ordinaryOperation = settlement;
    let value: T | undefined;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      this.commandGate.start(scope);
      if (this.prepared !== null) {
        this.prepared.retireCacheContext(scope);
      }
      value = await operation(scope);
    } catch (error) {
      primary = error as Object;
    }
    const executionOutcome = primary === null ? MySqlExecutionOutcome.Completed :
      (!settlement.dispatched ? MySqlExecutionOutcome.NotDispatched :
        (primary instanceof MySqlOperationError ?
          primary.outcome : MySqlExecutionOutcome.Unknown));
    const closeJoin = this.ordinaryCloseJoin(scope);
    if (closeJoin !== null) {
      const closeFailure = await closeJoin;
      if (closeFailure !== null) {
        if (primary === null) primary = closeFailure;
        else if (!operationContainsFailure(primary, closeFailure)) cleanup.push(closeFailure);
      }
    }
    try {
      this.finishCommand(scope);
    } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    if (this.ordinaryOperation === settlement) this.ordinaryOperation = null;
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
      throw operationFailure(cleanup[0], cleanup.slice(1), MySqlExecutionOutcome.Completed);
    }
    return value!;
  }

  private reserveTransactionRunnerScope(): MySqlCommandScope {
    if (this.cancelTask !== null || this.connState !== ConnectionState.Ready || this.channel === null) {
      throw ArkDbError.validation('Transaction callback requires a ready connection.');
    }
    if (this.status.known !== true) {
      throw ArkDbError.validation('Transaction callback requires known session transaction status.');
    }
    if (this.status.inTransaction) {
      throw ArkDbError.validation('Transaction callback cannot enter an existing transaction.');
    }
    if (!this.status.autocommit) {
      throw ArkDbError.validation('Transaction callback requires autocommit to be enabled.');
    }
    const scope = this.reserveCommandOwnership(MySqlCommandKind.Transaction);
    const settlement = new PreparedCommandSettlement(scope);
    this.transactionOperation = settlement;
    this.commandGate.start(scope);
    try {
      if (this.prepared !== null) this.prepared.retireCacheContext(scope);
      return scope;
    } catch (error) {
      this.finishCommand(scope);
      if (this.transactionOperation === settlement) this.transactionOperation = null;
      throw error as Error;
    }
  }

  private async settleTransactionOperation(scope: MySqlCommandScope,
    completedCloseCleanup: boolean = false): Promise<ArkDbError[]> {
    const failures: ArkDbError[] = [];
    const operation = this.transactionOperation;
    if (operation === null || operation.scope !== scope) return failures;
    while (operation.joinedCancellations < operation.cancellations.length) {
      const cancellation = operation.cancellations[operation.joinedCancellations++];
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
          operationFailure(error as Object, [], MySqlExecutionOutcome.Completed) :
          toCleanupError(error as Object));
      }
    }
    return failures;
  }

  private async settleTransactionPreparedExecution(
    scope: MySqlCommandScope): Promise<void> {
    const cleanup = await this.settleTransactionOperation(scope);
    if (cleanup.length === 0) return;
    let outcome = this.retiredByCancellation ?
      MySqlExecutionOutcome.Unknown : MySqlExecutionOutcome.Completed;
    for (const failure of cleanup) {
      if (failure instanceof MySqlOperationError &&
        failure.outcome === MySqlExecutionOutcome.Unknown) {
        outcome = MySqlExecutionOutcome.Unknown;
      }
    }
    throw operationFailure(cleanup[0], cleanup.slice(1), outcome);
  }

  private async finishTransactionRunnerScope(scope: MySqlCommandScope): Promise<ArkDbError[]> {
    const failures = await this.settleTransactionOperation(scope);
    try {
      this.finishCommand(scope);
    } catch (error) {
      failures.push(toCleanupError(error as Object));
    }
    const lateFailures = await this.settleTransactionOperation(scope, true);
    for (const failure of lateFailures) failures.push(failure);
    if (this.transactionOperation !== null &&
      this.transactionOperation.scope === scope) this.transactionOperation = null;
    return failures;
  }

  private refreshTransactionStatus(scope: MySqlCommandScope): Promise<void> {
    const command = new PacketWriter().writeUInt8(Command.PING).toUint8Array();
    return this.executeOkOwned(scope, command);
  }

  private retireTransaction(scope: MySqlCommandScope, error: ArkDbError): Promise<void> {
    this.commandGate.assertOwner(scope);
    return this.retirePreparedSession(error);
  }

  private async runMySqlDeadline<T>(scope: MySqlCommandScope, options: MySqlDeadlineOptions,
    operation: () => Promise<T>): Promise<T> {
    if (options.timeoutMs === 0) return operation();
    const settlement = new DeadlineCancellationSettlement(scope);
    this.deadlineCancellation = settlement;

    try {
      let expire: () => void = (): void => {};
      const expired = new Promise<void>((resolve: () => void): void => {
        expire = resolve;
      });
      const serial = scope.serial;
      const deadlineTimer = new MySqlDeadlineTimer(options.timeoutMs, this.timers, (): void => {
        if (this.commandGate.expireDeadline(scope, serial)) expire();
      });

      let operationTask: Promise<T>;
      try {
        operationTask = operation();
      } catch (error) {
        operationTask = Promise.reject<T>(error as Object);
      }
      const observed = new DeadlineObservation<T>(operationTask);
      const closeCleanup: ArkDbError[] = [];
      const converged = this.settleDeadlineConvergence(observed, settlement, closeCleanup);
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
        const cancellationUnknown = this.retiredByCancellation || settlement.unknown;
        if (observed.failure !== null) {
          const cleanup: ArkDbError[] = [];
          this.appendDeadlineCancellationFailures(cleanup, settlement);
          for (const failure of closeCleanup) this.appendDeadlineCleanup(cleanup, failure);
          const outcome = cancellationUnknown ? MySqlExecutionOutcome.Unknown :
            (observed.failure instanceof MySqlOperationError ?
              observed.failure.outcome : MySqlExecutionOutcome.Unknown);
          throw operationFailure(observed.failure, cleanup, outcome);
        }
        if (settlement.failures.length > 0) {
          const primary = settlement.failures[0];
          const cleanup = settlement.failures.slice(1);
          for (const failure of closeCleanup) this.appendDeadlineCleanup(cleanup, failure);
          const outcome = cancellationUnknown ?
            MySqlExecutionOutcome.Unknown : MySqlExecutionOutcome.Completed;
          throw operationFailure(primary, cleanup, outcome);
        }
        if (closeCleanup.length > 0) {
          const outcome = cancellationUnknown ?
            MySqlExecutionOutcome.Unknown : MySqlExecutionOutcome.Completed;
          throw operationFailure(closeCleanup[0], closeCleanup, outcome);
        }
        return observed.value!;
      }

      deadlineTimer.cancel();
      const timeout = ArkDbError.timeout('MySQL operation deadline expired.');
      this.cancelScope(scope);
      let expireGrace: () => void = (): void => {};
      const graceExpired = new Promise<void>((resolve: () => void): void => {
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
        if (observed.failure !== null) this.appendDeadlineCleanup(cleanup, observed.failure);
        this.appendDeadlineCancellationFailures(cleanup, settlement);
        for (const failure of closeCleanup) this.appendDeadlineCleanup(cleanup, failure);
        const cancellationUnknown = this.retiredByCancellation || settlement.unknown;
        const outcome = cancellationUnknown ? MySqlExecutionOutcome.Unknown :
          (observed.failure instanceof MySqlOperationError ?
            observed.failure.outcome : (observed.failure === null ?
              MySqlExecutionOutcome.Completed : MySqlExecutionOutcome.Unknown));
        throw new MySqlOperationError(timeout, cleanup, outcome);
      }

      graceTimer.cancel();
      const cleanup: ArkDbError[] = [
        ArkDbError.timeout('MySQL operation did not converge within the cancellation grace period.')
      ];
      const retirement = await this.retireDeadlineScope(scope, timeout);
      for (const failure of retirement) this.appendDeadlineCleanup(cleanup, failure);
      await this.settleDeadlineCancellationAttempts(settlement);
      const operationSettled = await this.joinDeadlineOperationAfterAbort(observed);
      await this.settleDeadlineCancellationAttempts(settlement);
      this.invalidatePreparedState();
      this.appendDeadlineCancellationFailures(cleanup, settlement);
      if (observed.failure !== null) this.appendDeadlineCleanup(cleanup, observed.failure);
      if (!operationSettled) {
        this.appendDeadlineCleanup(cleanup,
          ArkDbError.timeout('MySQL operation did not settle during bounded post-abort cleanup.'));
      }
      await this.joinDeadlineClose(scope, cleanup);
      return Promise.reject<T>(
        new MySqlOperationError(timeout, cleanup, MySqlExecutionOutcome.Unknown));
    } finally {
      if (this.deadlineCancellation === settlement &&
        settlement.scope === scope) this.deadlineCancellation = null;
    }
  }

  private async settleDeadlineConvergence<T>(
    observation: DeadlineObservation<T>, settlement: DeadlineCancellationSettlement,
    closeCleanup: ArkDbError[]): Promise<void> {
    await observation.settled;
    await this.settleDeadlineCancellationAttempts(settlement);
    await this.joinDeadlineClose(settlement.scope, closeCleanup);
    await this.settleDeadlineCancellationAttempts(settlement);
  }

  private retainDeadlineCancellation(scope: MySqlCommandScope,
    task: Promise<QueryCancellationResult>): void {
    const settlement = this.deadlineCancellation;
    if (settlement !== null && settlement.scope === scope) settlement.add(task);
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
          failure.outcome === MySqlExecutionOutcome.Unknown) settlement.unknown = true;
        settlement.addFailure(failure);
      }
      if (settlement.joined === index) settlement.joined = index + 1;
    }
  }

  private appendDeadlineCancellationFailures(cleanup: ArkDbError[],
    settlement: DeadlineCancellationSettlement): void {
    for (const failure of settlement.failures) this.appendDeadlineCleanup(cleanup, failure);
  }

  private appendDeadlineCleanup(cleanup: ArkDbError[], error: Object): void {
    const failure = toCleanupError(error);
    for (const existing of cleanup) {
      if (existing === failure) return;
    }
    cleanup.push(failure);
  }

  private joinDeadlineOperationAfterAbort<T>(
    observation: DeadlineObservation<T>): Promise<boolean> {
    if (observation.settledNow) return Promise.resolve<boolean>(true);
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
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
      if (failure !== null) this.appendDeadlineCleanup(cleanup, failure);
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

  private ordinaryCloseJoin(
    scope: MySqlCommandScope): Promise<ArkDbError | null> | null {
    return this.commandCloseJoin(this.ordinaryOperation, scope);
  }

  private commandCloseJoin(settlement: CommandCloseSettlement | null,
    scope: MySqlCommandScope): Promise<ArkDbError | null> | null {
    if (settlement === null || settlement.scope !== scope ||
      settlement.closeResult === null) return null;
    if (settlement.closeJoin === null) {
      settlement.closeJoin = settlement.closeResult.then(
        (): ArkDbError | null => null,
        (error: Object): ArkDbError | null => toCleanupError(error));
    }
    return settlement.closeJoin;
  }

  private markOrdinaryCommandDispatched(scope: MySqlCommandScope): void {
    const settlement = this.ordinaryOperation;
    if (settlement !== null && settlement.scope === scope) {
      settlement.dispatched = true;
    }
  }

  private async retireDeadlineScope(scope: MySqlCommandScope,
    error: ArkDbError): Promise<ArkDbError[]> {
    const cleanup: ArkDbError[] = [];
    if (!this.commandGate.isOwner(scope)) return cleanup;
    this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
    this.retiredByCancellation = true;
    this.connState = ConnectionState.Closed;
    this.status.known = false;
    this.channel = null;
    const target = new DeadlineObservation<void>(this.transport.abort(error));
    const control = this.cancellationControl;
    let controlClose: DeadlineObservation<void> | null = null;
    if (control !== null) {
      try {
        controlClose = new DeadlineObservation<void>(control.close());
      } catch (failure) {
        this.appendDeadlineCleanup(cleanup, failure as Object);
      }
    }
    await target.settled;
    if (target.failure !== null) this.appendDeadlineCleanup(cleanup, target.failure);
    if (controlClose !== null) {
      await controlClose.settled;
      if (controlClose.failure !== null) this.appendDeadlineCleanup(cleanup, controlClose.failure);
    }
    return cleanup;
  }

  private invalidatePreparedState(): void {
    this.batch = null;
    this.insertRows = null;
    this.named = null;
    this.procedures = null;
    if (this.cursors !== null) this.cursors.invalidate();
    this.cursors = null;
    if (this.prepared !== null) this.prepared.invalidate();
    this.prepared = null;
  }

  private async retirePreparedSession(error: ArkDbError): Promise<void> {
    this.connState = ConnectionState.Closed;
    this.status.known = false;
    this.channel = null;
    this.invalidatePreparedState();
    await this.transport.abort(error);
  }

  protected async runPreparedCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience: boolean = false): Promise<T> {
    const scope = this.reserveCommandOwnership(kind);
    const settlement = new PreparedCommandSettlement(scope);
    this.preparedOperation = settlement;
    let begin: () => void = (): void => {};
    const task = new Promise<T>((resolve: (value: T) => void,
      reject: (reason?: Object) => void): void => {
      begin = (): void => {
        this.runPreparedCommandOwned(scope, settlement, operation, cachedConvenience)
          .then(resolve, reject);
      };
    });
    this.commandGate.start(scope);
    begin();
    return task;
  }

  private startCursorCommand<T>(
    operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T> {
    const scope = this.reserveCommandOwnership(MySqlCommandKind.Cursor);
    const settlement = new PreparedCommandSettlement(scope);
    this.cursorOperation = settlement;
    this.preparedOperation = settlement;
    let begin: () => void = (): void => {};
    const task = new Promise<T>((resolve: (value: T) => void,
      reject: (reason?: Object) => void): void => {
      begin = (): void => {
        this.startCursorCommandOwned(scope, operation).then(
          (value: T): void => {
            try {
              this.requireOwnedChannel(scope);
              this.commandGate.setPhase(
                scope, MySqlCommandPhase.CursorIdle);
              resolve(value);
            } catch (error) {
              const primary = error as Object;
              this.finishCursorCommand(
                scope, primary, MySqlExecutionOutcome.Completed)
                .then((): void => reject(primary), reject);
            }
          }, reject);
      };
    });
    this.commandGate.start(scope);
    begin();
    return task;
  }

  private async startCursorCommandOwned<T>(scope: MySqlCommandScope,
    operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T> {
    try {
      if (this.prepared !== null) this.prepared.retireCacheContext(scope);
      return await operation(scope);
    } catch (error) {
      const primary = error as Object;
      await this.finishCursorCommand(scope, primary,
        primary instanceof MySqlOperationError ?
          primary.outcome : MySqlExecutionOutcome.Unknown);
      throw primary as Error;
    }
  }

  private async runCursorCommandOwned<T>(scope: MySqlCommandScope,
    phase: MySqlCommandPhase, command: Uint8Array,
    parse: (source: MysqlPacketSource) => Promise<T>): Promise<T> {
    const channel = this.requireOwnedChannel(scope);
    let reading = false;
    let value: T | undefined;
    let primary: Object | null = null;
    this.connState = ConnectionState.Querying;
    this.executingScope = scope;
    this.commandGate.setPhase(scope, phase);
    try {
      channel.resetSequence();
      this.queryWrite = channel.writePacket(command);
      await this.queryWrite;
      reading = true;
      value = await parse(
        new PreparedPacketSource(channel, this.clientCaps));
      this.requireOwnedChannel(scope);
      if (this.state !== ConnectionState.Closed) {
        this.connState = ConnectionState.Ready;
      }
    } catch (error) {
      primary = await this.classifyCommandFailure(
        scope, error as Object, reading);
    } finally {
      this.queryWrite = null;
      this.executingScope = null;
    }
    if (this.commandGate.isOwner(scope)) {
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
    }
    const cleanup = await this.settlePreparedCancellation(scope);
    if (primary !== null) {
      if (cleanup.length === 0) throw primary as Error;
      throw operationFailure(
        primary, cleanup,
        this.executionOutcomeAfterCancellation(
          primary, MySqlExecutionOutcome.Unknown));
    }
    if (cleanup.length > 0) {
      const outcome = this.retiredByCancellation ?
        MySqlExecutionOutcome.Unknown : MySqlExecutionOutcome.Completed;
      throw operationFailure(cleanup[0], cleanup.slice(1), outcome);
    }
    return value!;
  }

  private applyCursorStatus(scope: MySqlCommandScope,
    statusFlags: number): void {
    this.commandGate.assertOwner(scope);
    if (this.connState !== ConnectionState.Closed) {
      this.applyStatusFlags(statusFlags);
      this.connState = ConnectionState.Ready;
    }
  }

  private async finishCursorCommand(scope: MySqlCommandScope,
    primary?: Object,
    outcome: MySqlExecutionOutcome = MySqlExecutionOutcome.Completed,
    validate?: () => void, complete?: () => void): Promise<void> {
    const settlement = this.cursorOperation;
    const cleanup: ArkDbError[] = [];
    let cancellationCleanupCount = 0;
    let rootCloseFailure: ArkDbError | null = null;
    let failure = primary;
    if (settlement !== null && settlement.scope === scope) {
      if (this.commandGate.isOwner(scope)) {
        this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      }
      const cancellationCleanup = await this.settlePreparedCancellation(scope);
      for (const failure of cancellationCleanup) cleanup.push(failure);
      cancellationCleanupCount = cancellationCleanup.length;
      const closeResult = settlement.closeResult;
      if (closeResult !== null && !settlement.closeJoined) {
        settlement.closeJoined = true;
        try {
          await closeResult;
        } catch (error) {
          rootCloseFailure = toCleanupError(error as Object);
          cleanup.push(rootCloseFailure);
        }
      }
    }
    if (failure === undefined && cleanup.length === 0 &&
      validate !== undefined) {
      try {
        validate();
      } catch (error) {
        failure = error as Object;
      }
    }
    if (this.commandGate.isOwner(scope)) {
      try {
        this.finishCommand(scope);
      } catch (error) {
        cleanup.push(toCleanupError(error as Object));
      }
    }
    if (settlement !== null && settlement.scope === scope) {
      const closeResult = settlement.closeResult;
      if (closeResult !== null && !settlement.closeJoined) {
        settlement.closeJoined = true;
        try {
          await closeResult;
        } catch (error) {
          rootCloseFailure = toCleanupError(error as Object);
          cleanup.push(rootCloseFailure);
        }
      }
    }
    if (this.cursorOperation === settlement) this.cursorOperation = null;
    if (this.preparedOperation === settlement) this.preparedOperation = null;
    if (failure !== undefined) {
      const failedOutcome = cleanup.length > cancellationCleanupCount ?
        MySqlExecutionOutcome.Unknown :
        this.executionOutcomeAfterCancellation(failure, outcome);
      throw operationFailure(failure, cleanup,
        failedOutcome);
    }
    if (cleanup.length > 0) {
      if (rootCloseFailure !== null &&
        cleanup.length === 1 && cleanup[0] === rootCloseFailure) {
        throw rootCloseFailure;
      }
      throw operationFailure(cleanup[0], cleanup.slice(1),
        MySqlExecutionOutcome.Completed);
    }
    if (complete !== undefined) {
      try {
        complete();
      } catch (error) {
        throw operationFailure(
          error as Object, [], MySqlExecutionOutcome.Completed);
      }
    }
  }

  private async runPreparedCommandOwned<T>(scope: MySqlCommandScope,
    settlement: PreparedCommandSettlement,
    operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience: boolean): Promise<T> {
    let value: T | undefined;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      if (!cachedConvenience && this.prepared !== null) {
        this.prepared.retireCacheContext(scope);
      }
      let task: Promise<T>;
      try { task = operation(scope); } catch (error) { task = Promise.reject<T>(error as Object); }
      value = await this.awaitPreparedExecution(scope, task, MySqlExecutionOutcome.NotDispatched);
    } catch (error) {
      primary = error as Object;
    }
    const executionOutcome = primary instanceof MySqlOperationError ? primary.outcome :
      (primary === null ? MySqlExecutionOutcome.Completed : MySqlExecutionOutcome.NotDispatched);
    const closeResult = settlement.closeResult;
    if (closeResult !== null) {
      try { await closeResult; } catch (error) {
        if (primary === null) primary = error as Object;
        else cleanup.push(toCleanupError(error as Object));
      }
    }
    try { this.finishCommand(scope); } catch (error) {
      cleanup.push(toCleanupError(error as Object));
    }
    if (this.preparedOperation === settlement) this.preparedOperation = null;
    if (primary !== null) {
      throw operationFailure(primary, cleanup, executionOutcome);
    }
    if (cleanup.length > 0) throw operationFailure(cleanup[0], cleanup.slice(1), MySqlExecutionOutcome.Completed);
    return value!;
  }

  private async awaitPreparedExecution<T>(scope: MySqlCommandScope, task: Promise<T>,
    fallbackOutcome: MySqlExecutionOutcome = MySqlExecutionOutcome.Unknown,
    cleanupOnlyOutcome: MySqlExecutionOutcome = MySqlExecutionOutcome.Completed): Promise<T> {
    let value: T | undefined;
    let primary: Object | null = null;
    try { value = await task; } catch (error) { primary = error as Object; }
    this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
    const cleanup = await this.settlePreparedCancellation(scope);
    if (primary !== null) {
      throw operationFailure(primary, cleanup,
        this.executionOutcomeAfterCancellation(primary, fallbackOutcome));
    }
    if (cleanup.length > 0) {
      // Consuming SQL does not acknowledge an unknown dispatched KILL.
      const outcome = this.retiredByCancellation ?
        MySqlExecutionOutcome.Unknown : cleanupOnlyOutcome;
      throw operationFailure(cleanup[0], cleanup.slice(1), outcome);
    }
    return value!;
  }

  private executionOutcomeAfterCancellation(primary: Object,
    fallback: MySqlExecutionOutcome): MySqlExecutionOutcome {
    if (this.retiredByCancellation) return MySqlExecutionOutcome.Unknown;
    return primary instanceof MySqlOperationError ?
      primary.outcome : fallback;
  }

  private async settlePreparedCancellation(scope: MySqlCommandScope): Promise<ArkDbError[]> {
    const failures: ArkDbError[] = [];
    const operation = this.preparedOperation;
    if (operation === null || operation.scope !== scope) return failures;
    while (operation.joinedCancellations < operation.cancellations.length) {
      const cancellation = operation.cancellations[operation.joinedCancellations++];
      try { await cancellation; } catch (error) {
        failures.push(toCleanupError(error as Object));
      }
    }
    return failures;
  }

  private requireOwnedChannel(scope: MySqlCommandScope): PacketChannel {
    this.commandGate.assertOwner(scope);
    if (this.channel === null || (this.connState !== ConnectionState.Ready &&
      this.connState !== ConnectionState.Querying)) {
      throw ArkDbError.protocol('The owned command has no ready connection channel.');
    }
    return this.channel;
  }

  private finishCommand(scope: MySqlCommandScope): void {
    this.commandGate.assertOwner(scope);
    this.completedScope = scope;
    if (this.cancelTask !== null || this.closePending) {
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
    }
    this.releaseCompletedCommand();
  }

  private releaseCompletedCommand(): void {
    const scope = this.completedScope;
    if (scope !== null && this.cancelTask === null && !this.closePending) {
      this.completedScope = null;
      this.commandGate.release(scope);
    }
  }

  private expectOk(pkt: MysqlPacket): void {
    const fb = firstByte(pkt.payload);
    if (fb === PacketType.ERR) {
      const err = parseErr(pkt.payload, this.clientCaps);
      throw ArkDbError.server(err.message, err.code, err.sqlState);
    }
    if (fb !== PacketType.OK) {
      throw ArkDbError.protocol('Expected an OK packet, got 0x' + fb.toString(16));
    }
    const flags = parseOk(pkt.payload, this.clientCaps).statusFlags;
    if (this.connState !== ConnectionState.Closed) this.applyStatusFlags(flags);
  }

  private async refreshSessionStatus(scope: MySqlCommandScope,
    synchronizationDeadlineMs: number): Promise<void> {
    this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
    const cancellation = this.cancelTask;
    if (this.preparedOperation !== null && this.preparedOperation.scope === scope) {
      const failures = await this.settlePreparedCancellation(scope);
      if (failures.length > 0) {
        throw operationFailure(failures[0], failures.slice(1), MySqlExecutionOutcome.Unknown);
      }
    } else if (cancellation !== null) {
      await cancellation;
    }
    const channel = this.requireOwnedChannel(scope);
    if (remainingSynchronizationTimeMs(synchronizationDeadlineMs, monotonicNowMs()) <= 0) {
      throw ArkDbError.protocol('Truncated result exceeded synchronization drain time budget');
    }
    channel.resetSequence();
    const writer = new PacketWriter();
    writer.writeUInt8(Command.PING);
    let remaining = remainingSynchronizationTimeMs(
      synchronizationDeadlineMs, monotonicNowMs());
    if (remaining <= 0) {
      throw ArkDbError.protocol('Truncated result exceeded synchronization drain time budget');
    }
    await channel.writePacket(writer.toUint8Array(), remaining);
    remaining = remainingSynchronizationTimeMs(
      synchronizationDeadlineMs, monotonicNowMs());
    if (remaining <= 0) {
      throw ArkDbError.protocol('Truncated result exceeded synchronization drain time budget');
    }
    this.expectOk(await channel.readPacket(remaining));
  }

  private applyServerInfo(hp: HandshakePacket): void {
    const si = new ServerInfo();
    si.family = hp.family;
    si.driverId = 'mysql';
    si.productName = String(hp.family);
    si.connectionHandle = String(hp.connectionId);
    this.cancellationHandle = si.connectionHandle;
    si.nativeCapabilities = String(hp.capabilities);
    si.defaultEncoding = 'utf8mb4';
    si.version = hp.serverVersion;
    si.protocolVersion = hp.protocolVersion;
    si.connectionId = hp.connectionId;
    si.capabilities = hp.capabilities;
    si.charset = hp.charset;
    si.authPlugin = hp.authPluginName;
    si.tlsActive = this.tlsActive;
    this.info = si;
    this.applyStatusFlags(hp.statusFlags);
  }

  private applyStatusFlags(statusFlags: number): void {
    this.status.known = true;
    this.status.autocommit = (statusFlags & 0x0002) !== 0;
    this.status.inTransaction = (statusFlags & 0x0001) !== 0;
  }

  private async classifyCommandFailure(scope: MySqlCommandScope, error: Object,
    reading: boolean, synchronized: boolean = false): Promise<ArkDbError> {
    if (synchronized) {
      return operationFailure(error, [], MySqlExecutionOutcome.Completed);
    }
    const typed = toArkDbError(error);
    const rejected = reading && isMySqlServerRejection(typed);
    const reusable = rejected && (!(typed instanceof MySqlOperationError) || typed.cleanupErrors.length === 0);
    this.status.known = false;
    if (this.connState !== ConnectionState.Closed) {
      this.connState = connectionStateAfterCommandFailure(typed.kind, reusable);
    }
    const cleanupErrors: ArkDbError[] = [];
    if (this.connState === ConnectionState.Error) {
      this.commandGate.setPhase(scope, MySqlCommandPhase.Cleaning);
      this.channel = null;
      this.invalidatePreparedState();
      try {
        await this.transport.close();
      } catch (cleanup) {
        Logger.w(LogTag.Conn, 'transport cleanup failed error=' + Logger.errorToken(cleanup));
        cleanupErrors.push(toCleanupError(cleanup as Object));
      }
    }
    return operationFailure(error, cleanupErrors,
      rejected ? MySqlExecutionOutcome.ServerRejected : MySqlExecutionOutcome.Unknown);
  }
}

class MySqlConnectionPreparedExecutor implements MySqlPreparedExecutor {
  private getExecutor: () => MySqlPreparedExecutor;

  constructor(getExecutor: () => MySqlPreparedExecutor) {
    this.getExecutor = getExecutor;
  }

  async prepare(sql: string): Promise<MySqlPreparedStatement> {
    return this.getExecutor().prepare(sql);
  }

  async execute(sql: string, parameters: MySqlParameter[], options?: QueryOptions): Promise<QueryResult> {
    return this.getExecutor().execute(sql, parameters, options);
  }

  async executeStream(sql: string, parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.getExecutor().executeStream(sql, parameters, options, sink);
  }
}

class MySqlConnectionLongDataExecutor implements MySqlLongDataExecutor {
  private getExecutor: () => MySqlLongDataExecutor;

  constructor(getExecutor: () => MySqlLongDataExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    sources: MySqlLongParameter[], options?: MySqlLongDataOptions): Promise<QueryResult> {
    return this.getExecutor().execute(statement, parameters, sources, options);
  }
}

class MySqlConnectionCursorExecutor implements MySqlCursorExecutor {
  private getExecutor: () => MySqlCursorExecutor;

  constructor(getExecutor: () => MySqlCursorExecutor) {
    this.getExecutor = getExecutor;
  }

  async open(sql: string, parameters: MySqlParameter[],
    options?: MySqlCursorOptions): Promise<MySqlCursor> {
    return this.getExecutor().open(
      sql, parameters.slice(),
      options === undefined ? undefined : options.clone());
  }
}

class MySqlConnectionNamedExecutor implements MySqlNamedExecutor {
  private getExecutor: () => MySqlNamedExecutor;

  constructor(getExecutor: () => MySqlNamedExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(sql: string, parameters: MySqlNamedParameter[],
    options?: QueryOptions): Promise<QueryResult> {
    return this.getExecutor().execute(sql, parameters, options);
  }

  async executeStream(sql: string, parameters: MySqlNamedParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.getExecutor().executeStream(sql, parameters, options, sink);
  }
}

class MySqlConnectionInsertRowsExecutor implements MySqlInsertRowsExecutor {
  private getExecutor: () => MySqlPreparedInsertRowsExecutor;

  constructor(getExecutor: () => MySqlPreparedInsertRowsExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(tableParts: string[], columns: string[],
    rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions): Promise<MySqlBatchResult> {
    const input: MySqlInsertRowsInput = snapshotMySqlInsertRowsInput(
      tableParts, columns, rows, options);
    if (input.groups.length === 0) return new MySqlBatchResult();
    let executor: MySqlPreparedInsertRowsExecutor;
    try {
      executor = this.getExecutor();
    } catch (error) {
      throw new MySqlBatchError(
        operationFailure(error as Object, [],
          MySqlExecutionOutcome.NotDispatched),
        [], 0);
    }
    return executor.executeInput(input);
  }
}

class MySqlConnectionProcedureCaller implements MySqlProcedureCaller {
  private getCaller: () => MySqlProcedureCaller;

  constructor(getCaller: () => MySqlProcedureCaller) {
    this.getCaller = getCaller;
  }

  async call(procedure: string[], procedureArguments: MySqlProcedureArgument[],
    options?: QueryOptions): Promise<MySqlProcedureResult> {
    return this.getCaller().call(procedure, procedureArguments, options);
  }
}

class MySqlConnectionBatchExecutor implements MySqlBatchExecutor {
  private getExecutor: () => MySqlBatchExecutor;

  constructor(getExecutor: () => MySqlBatchExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(sql: string, rows: MySqlParameter[][],
    options?: MySqlBatchOptions): Promise<MySqlBatchResult> {
    const snapshot = options === undefined ? new MySqlBatchOptions() : options.clone();
    const errors = validateMySqlBatchOptions(snapshot, rows.length);
    if (errors.length > 0) {
      throw new MySqlBatchError(
        operationFailure(errors[0], [], MySqlExecutionOutcome.NotDispatched), [], 0);
    }
    if (rows.length === 0) {
      return new MySqlBatchResult();
    }
    let executor: MySqlBatchExecutor;
    try {
      executor = this.getExecutor();
    } catch (error) {
      throw new MySqlBatchError(
        operationFailure(error as Object, [], MySqlExecutionOutcome.NotDispatched), [], 0);
    }
    return executor.execute(sql, rows, snapshot);
  }
}

class TransactionConnectionHost implements MySqlTransactionRunnerHost {
  private readState: () => ConnectionState;
  private readFeatures: () => MySqlConnectionFeatures;
  private readServerInfo: () => ServerInfo;
  private readSessionStatus: () => MySqlDatabaseSessionStatus;
  private reserve: () => MySqlCommandScope;
  private settle: (scope: MySqlCommandScope) => Promise<ArkDbError[]>;
  private finish: (scope: MySqlCommandScope) => Promise<ArkDbError[]>;
  private refreshStatus: (scope: MySqlCommandScope) => Promise<void>;
  private retire: (scope: MySqlCommandScope, error: ArkDbError) => Promise<void>;
  private executeQuery: (scope: MySqlCommandScope, sql: string) => Promise<QueryResult>;
  private executeStream: (scope: MySqlCommandScope, sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>;
  private executeInsertRows: (scope: MySqlCommandScope,
    input: MySqlInsertRowsInput) => Promise<MySqlBatchResult>;

  constructor(readState: () => ConnectionState,
    readFeatures: () => MySqlConnectionFeatures,
    readServerInfo: () => ServerInfo,
    readSessionStatus: () => MySqlDatabaseSessionStatus,
    reserve: () => MySqlCommandScope,
    settle: (scope: MySqlCommandScope) => Promise<ArkDbError[]>,
    finish: (scope: MySqlCommandScope) => Promise<ArkDbError[]>,
    refreshStatus: (scope: MySqlCommandScope) => Promise<void>,
    retire: (scope: MySqlCommandScope, error: ArkDbError) => Promise<void>,
    executeQuery: (scope: MySqlCommandScope, sql: string) => Promise<QueryResult>,
    executeStream: (scope: MySqlCommandScope, sql: string, options: QueryOptions,
      sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>,
    executeInsertRows: (scope: MySqlCommandScope,
      input: MySqlInsertRowsInput) => Promise<MySqlBatchResult>) {
    this.readState = readState;
    this.readFeatures = readFeatures;
    this.readServerInfo = readServerInfo;
    this.readSessionStatus = readSessionStatus;
    this.reserve = reserve;
    this.settle = settle;
    this.finish = finish;
    this.refreshStatus = refreshStatus;
    this.retire = retire;
    this.executeQuery = executeQuery;
    this.executeStream = executeStream;
    this.executeInsertRows = executeInsertRows;
  }

  get state(): ConnectionState { return this.readState(); }
  get mysqlFeatures(): MySqlConnectionFeatures { return this.readFeatures(); }
  get serverInfo(): ServerInfo { return this.readServerInfo(); }
  get sessionStatus(): MySqlDatabaseSessionStatus { return this.readSessionStatus(); }

  reserveTransaction(): MySqlCommandScope { return this.reserve(); }
  settleTransaction(scope: MySqlCommandScope): Promise<ArkDbError[]> {
    return this.settle(scope);
  }
  finishTransaction(scope: MySqlCommandScope): Promise<ArkDbError[]> {
    return this.finish(scope);
  }
  refreshTransactionStatus(scope: MySqlCommandScope): Promise<void> {
    return this.refreshStatus(scope);
  }
  retireTransaction(scope: MySqlCommandScope, error: ArkDbError): Promise<void> {
    return this.retire(scope, error);
  }

  query(scope: MySqlCommandScope, sql: string): Promise<QueryResult> {
    return this.executeQuery(scope, sql);
  }

  queryStream(scope: MySqlCommandScope, sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.executeStream(scope, sql, options, sink);
  }

  insertRows(scope: MySqlCommandScope,
    input: MySqlInsertRowsInput): Promise<MySqlBatchResult> {
    return this.executeInsertRows(scope, input);
  }
}

type PreparedCommandRunner = <T>(kind: MySqlCommandKind,
  operation: (scope: MySqlCommandScope) => Promise<T>,
  cachedConvenience?: boolean) => Promise<T>;

type CursorCommandStarter = <T>(
  operation: (scope: MySqlCommandScope) => Promise<T>) => Promise<T>;
type CursorWireRunner = <T>(scope: MySqlCommandScope,
  phase: MySqlCommandPhase, command: Uint8Array,
  parse: (source: MysqlPacketSource) => Promise<T>) => Promise<T>;
type CursorContinuationValidator = (scope: MySqlCommandScope) => void;
type CursorStatusApplier =
  (scope: MySqlCommandScope, statusFlags: number) => void;
type CursorCommandFinisher = (scope: MySqlCommandScope,
  primary?: Object, outcome?: MySqlExecutionOutcome,
  validate?: () => void, complete?: () => void) => Promise<void>;

class PreparedConnectionHost implements MySqlNamedExecutorHost,
  MySqlCursorExecutorHost {
  readonly commandGate: MySqlCommandGate;
  readonly timers: ConnectionTimerPort;
  readonly preparedCacheSize: number;
  private readChannel: () => PacketChannel | null;
  private readCapabilities: () => number;
  private readState: () => ConnectionState;
  private retireSession: (error: ArkDbError) => Promise<void>;
  private run: PreparedCommandRunner;
  private readCloseSignal: (scope: MySqlCommandScope) => Promise<ArkDbError>;
  private buffered: (scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
    observer?: (result: QueryResult) => void,
    observations?: MySqlResultTerminatorObservation[]) => Promise<QueryResult>;
  private stream: (scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
    sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>;
  private readSqlMode: (scope: MySqlCommandScope) => Promise<string>;
  private startOwnedCursor: CursorCommandStarter;
  private runCursorWire: CursorWireRunner;
  private validateCursorContinuation: CursorContinuationValidator;
  private applyOwnedCursorStatus: CursorStatusApplier;
  private finishOwnedCursor: CursorCommandFinisher;

  constructor(gate: MySqlCommandGate, timers: ConnectionTimerPort,
    readChannel: () => PacketChannel | null,
    readCapabilities: () => number, readState: () => ConnectionState,
    retire: (error: ArkDbError) => Promise<void>, run: PreparedCommandRunner,
    readCloseSignal: (scope: MySqlCommandScope) => Promise<ArkDbError>,
    buffered: (scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
      observer?: (result: QueryResult) => void,
      observations?: MySqlResultTerminatorObservation[]) => Promise<QueryResult>,
    stream: (scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
      sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>,
    readSqlMode: (scope: MySqlCommandScope) => Promise<string>,
    startCursor: CursorCommandStarter,
    runCursor: CursorWireRunner,
    assertCursorActive: CursorContinuationValidator,
    applyCursorStatus: CursorStatusApplier,
    finishCursor: CursorCommandFinisher,
    preparedCacheSize: number) {
    this.commandGate = gate;
    this.timers = timers;
    this.preparedCacheSize = preparedCacheSize;
    this.readChannel = readChannel;
    this.readCapabilities = readCapabilities;
    this.readState = readState;
    this.retireSession = retire;
    this.run = run;
    this.readCloseSignal = readCloseSignal;
    this.buffered = buffered;
    this.stream = stream;
    this.readSqlMode = readSqlMode;
    this.startOwnedCursor = startCursor;
    this.runCursorWire = runCursor;
    this.validateCursorContinuation = assertCursorActive;
    this.applyOwnedCursorStatus = applyCursorStatus;
    this.finishOwnedCursor = finishCursor;
  }

  get channel(): PacketChannel | null { return this.readChannel(); }
  get capabilities(): number { return this.readCapabilities(); }
  get state(): ConnectionState { return this.readState(); }

  retire(error: ArkDbError): Promise<void> { return this.retireSession(error); }

  runCommand<T>(kind: MySqlCommandKind, operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience: boolean = false): Promise<T> {
    return this.run<T>(kind, operation, cachedConvenience);
  }

  closeSignal(scope: MySqlCommandScope): Promise<ArkDbError> {
    return this.readCloseSignal(scope);
  }

  executePrepared(scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
    observer?: (result: QueryResult) => void,
    observations?: MySqlResultTerminatorObservation[]): Promise<QueryResult> {
    return this.buffered(scope, command, options, observer, observations);
  }

  streamPrepared(scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.stream(scope, command, options, sink);
  }

  readSessionSqlMode(scope: MySqlCommandScope): Promise<string> {
    return this.readSqlMode(scope);
  }

  startCursor<T>(
    operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T> {
    return this.startOwnedCursor<T>(operation);
  }

  runCursorCommand<T>(scope: MySqlCommandScope,
    phase: MySqlCommandPhase, command: Uint8Array,
    parse: (source: MysqlPacketSource) => Promise<T>): Promise<T> {
    return this.runCursorWire<T>(scope, phase, command, parse);
  }

  assertCursorActive(scope: MySqlCommandScope): void {
    this.validateCursorContinuation(scope);
  }

  applyCursorStatus(scope: MySqlCommandScope, statusFlags: number): void {
    this.applyOwnedCursorStatus(scope, statusFlags);
  }

  finishCursor(scope: MySqlCommandScope, primary?: Object,
    outcome?: MySqlExecutionOutcome, validate?: () => void,
    complete?: () => void): Promise<void> {
    return this.finishOwnedCursor(
      scope, primary, outcome, validate, complete);
  }
}

class PreparedCommandSettlement {
  readonly scope: MySqlCommandScope;
  readonly cancellations: Promise<QueryCancellationResult>[] = [];
  readonly closeRequested: Promise<ArkDbError>;
  joinedCancellations: number = 0;
  closeResult: Promise<void> | null = null;
  closeJoined: boolean = false;
  private resolveClose: (error: ArkDbError) => void =
    (_error: ArkDbError): void => {};
  private closeSignalled: boolean = false;

  constructor(scope: MySqlCommandScope) {
    this.scope = scope;
    this.closeRequested = new Promise<ArkDbError>(
      (resolve: (error: ArkDbError) => void): void => {
        this.resolveClose = resolve;
      });
  }

  signalClose(error: ArkDbError): void {
    if (this.closeSignalled) return;
    this.closeSignalled = true;
    this.resolveClose(error);
  }
}

class CommandCloseSettlement {
  readonly scope: MySqlCommandScope;
  closeResult: Promise<void> | null = null;
  closeJoin: Promise<ArkDbError | null> | null = null;

  constructor(scope: MySqlCommandScope) {
    this.scope = scope;
  }
}

class OrdinaryCommandSettlement extends CommandCloseSettlement {
  dispatched: boolean = false;
}

class DeadlineObservation<T> {
  readonly settled: Promise<void>;
  value: T | undefined = undefined;
  failure: Object | null = null;
  settledNow: boolean = false;

  constructor(task: Promise<T>) {
    this.settled = task.then(
      (value: T): void => {
        this.value = value;
        this.settledNow = true;
      },
      (error: Object): void => {
        this.failure = error;
        this.settledNow = true;
      });
  }
}

class DeadlineCancellationSettlement {
  readonly scope: MySqlCommandScope;
  readonly attempts: Promise<QueryCancellationResult>[] = [];
  readonly failures: ArkDbError[] = [];
  joined: number = 0;
  unknown: boolean = false;

  constructor(scope: MySqlCommandScope) {
    this.scope = scope;
  }

  add(task: Promise<QueryCancellationResult>): void {
    for (const attempt of this.attempts) {
      if (attempt === task) return;
    }
    this.attempts.push(task);
  }

  addFailure(failure: ArkDbError): void {
    for (const existing of this.failures) {
      if (existing === failure) return;
    }
    this.failures.push(failure);
  }
}

class MySqlDeadlineTimer {
  private timers: ConnectionTimerPort;
  private expiresAtMs: number;
  private callback: () => void;
  private timerId: number = 0;
  private generation: number = 0;
  private active: boolean = true;

  constructor(timeoutMs: number, timers: ConnectionTimerPort, callback: () => void) {
    this.timers = timers;
    this.callback = callback;
    const now = this.nowMs();
    this.expiresAtMs = timeoutMs > Number.MAX_SAFE_INTEGER - now ?
      Number.MAX_SAFE_INTEGER : now + timeoutMs;
    this.arm();
  }

  cancel(): void {
    if (!this.active) return;
    this.active = false;
    this.generation += 1;
    if (this.timerId !== 0) this.timers.cancel(this.timerId);
    this.timerId = 0;
  }

  isExpired(): boolean {
    return this.expiresAtMs <= this.nowMs();
  }

  private arm(): void {
    if (!this.active) return;
    const remaining = Math.max(0, this.expiresAtMs - this.nowMs());
    const delay = Math.min(remaining, MAX_MYSQL_DEADLINE_TIMER_DELAY_MS);
    const generation = this.generation + 1;
    this.generation = generation;
    this.timerId = this.timers.schedule((): void => {
      if (!this.active || this.generation !== generation) return;
      this.timerId = 0;
      if (this.expiresAtMs > this.nowMs()) {
        this.arm();
        return;
      }
      this.active = false;
      this.callback();
    }, delay);
  }

  private nowMs(): number {
    const now = this.timers.nowMs();
    if (!Number.isSafeInteger(now) || now < 0) {
      throw ArkDbError.protocol('Connection clock is unavailable.');
    }
    return now;
  }
}

class PreparedPacketSource implements MysqlPacketSource {
  private channel: PacketChannel;
  private capabilities: number;

  constructor(channel: PacketChannel, capabilities: number) {
    this.channel = channel;
    this.capabilities = capabilities;
  }

  async readPacket(timeoutMs: number = 0): Promise<MysqlPacket> {
    let packet: MysqlPacket;
    try {
      packet = await this.channel.readPacket(timeoutMs);
    } catch (error) {
      throw operationFailure(error as Object, [], MySqlExecutionOutcome.Unknown);
    }
    if (packet.payload[0] === PacketType.ERR) prepareServerError(packet.payload, this.capabilities);
    return packet;
  }

  async runWhileOpen<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await this.channel.runWhileOpen(operation);
    } catch (error) {
      throw operationFailure(error as Object, [], MySqlExecutionOutcome.Unknown);
    }
  }
}

class OperationResultSink implements QueryResultSink {
  private sink: QueryResultSink;
  private finishWireQuery: () => void;
  private retainedTruncationFailure: MySqlOperationError | null = null;

  constructor(sink: QueryResultSink, finishWireQuery: () => void) {
    this.sink = sink;
    this.finishWireQuery = finishWireQuery;
  }

  get truncationFailure(): MySqlOperationError | null {
    return this.retainedTruncationFailure;
  }

  async onResultStart(meta: QueryResultMeta): Promise<void> {
    await this.invoke((): Promise<void> => this.sink.onResultStart(meta));
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    await this.invoke((): Promise<void> => this.sink.onRows(chunk));
  }

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    if (!summary.statusKnown) this.finishWireQuery();
    await this.invoke((): Promise<void> => this.sink.onResultEnd(summary));
  }

  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    try {
      if (this.sink.onTruncation === undefined) return false;
      return await this.sink.onTruncation(truncation);
    } catch (error) {
      const failure = callbackFailure(error as Object);
      this.retainedTruncationFailure = this.retainedTruncationFailure === null ? failure :
        operationFailure(this.retainedTruncationFailure, [failure], MySqlExecutionOutcome.Unknown);
      Logger.w(LogTag.Query, 'truncation control failed error=' + Logger.errorToken(error));
      return false;
    }
  }

  private async invoke(callback: () => Promise<void>): Promise<void> {
    try {
      await callback();
    } catch (error) {
      throw callbackFailure(error as Object);
    }
  }
}

export function connectionStateAfterCommandFailure(kind: ArkDbErrorKind,
  reusableServerError: boolean = true): ConnectionState {
  return kind === ArkDbErrorKind.Server && reusableServerError ? ConnectionState.Ready : ConnectionState.Error;
}

export function authPluginLogValue(plugin: string): string {
  if (plugin === 'mysql_native_password' || plugin === 'caching_sha2_password') {
    return plugin;
  }
  return Logger.mask(plugin);
}

export function queryFailureDiagnostic(error: ArkDbError, durationMs: number): string {
  let diagnostic = 'kind=' + errorKindLogValue(error.kind);
  if (typeof error.code === 'number' && Number.isFinite(error.code) &&
    Math.floor(error.code) === error.code) {
    diagnostic += ' code=' + error.code;
  }
  if (error.sqlState !== undefined && isSafeSqlState(error.sqlState)) {
    diagnostic += ' sqlState=' + error.sqlState;
  }
  return diagnostic + ' dur=' + diagnosticDurationMs(durationMs) +
    'ms error=' + Logger.errorToken(error);
}

export function mysqlTlsRequested(mode: SslMode, serverCapabilities: number): boolean {
  const supported = (serverCapabilities & Capabilities.SSL) !== 0;
  if (mode === SslMode.DISABLED) return false;
  if (mode === SslMode.PREFERRED) return supported;
  if (mode === SslMode.REQUIRED || mode === SslMode.VERIFY_CA ||
    mode === SslMode.VERIFY_IDENTITY) {
    if (!supported) {
      throw ArkDbError.tls('Server does not support TLS required by SSL mode ' + String(mode));
    }
    return true;
  }
  throw ArkDbError.tls('Unsupported SSL mode: ' + String(mode));
}

export function remainingSynchronizationTimeMs(deadlineMs: number, nowMs: number): number {
  if (!Number.isFinite(deadlineMs) || !Number.isFinite(nowMs) || deadlineMs < 0) return 0;
  return Math.max(0, deadlineMs - nowMs);
}

export function synchronizationRefreshFailure(error: Object): ArkDbError {
  return operationFailure(error, [], MySqlExecutionOutcome.Unknown);
}

/** Convenience factory mirroring the documented public API. */
export function createMySqlConnection(config: ConnectionConfig, password: string): MySqlConnection {
  return new MySqlConnection(config, password);
}

export function initializeMySqlExecutionObserverInternal(connection: MySqlConnection,
  observer: MySqlExecutionObserver,
  executionClock: () => number = monotonicNowMs): void {
  initializeMySqlExecutionObserverWithCapabilityInternal(connection,
    mysqlExecutionObserverCapability, observer, executionClock);
}

export function initializeMySqlExecutionObserverWithCapabilityInternal(
  connection: MySqlConnection, capability: Object,
  observer: MySqlExecutionObserver,
  executionClock: () => number = monotonicNowMs): void {
  const binding = mySqlExecutionObserverBindings.get(connection);
  if (binding === undefined) {
    throw ArkDbError.protocol(
      'Execution observation is unavailable after initialization or command reservation.');
  }
  binding(capability, observer, executionClock);
}

function firstByte(payload: Uint8Array): number {
  return payload.length > 0 ? payload[0] : -1;
}

function diagnosticDurationMs(durationMs: number): number {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return 0;
  return Math.min(Number.MAX_SAFE_INTEGER, Math.floor(durationMs));
}

function isSafeSqlState(sqlState: string): boolean {
  if (sqlState.length !== 5) return false;
  for (let index = 0; index < sqlState.length; index += 1) {
    const code = sqlState.charCodeAt(index);
    const isDigit = code >= 0x30 && code <= 0x39;
    const isUppercaseLetter = code >= 0x41 && code <= 0x5a;
    if (!isDigit && !isUppercaseLetter) return false;
  }
  return true;
}

function errorKindLogValue(kind: ArkDbErrorKind): string {
  switch (kind) {
    case ArkDbErrorKind.Network:
      return 'Network';
    case ArkDbErrorKind.Tls:
      return 'Tls';
    case ArkDbErrorKind.Auth:
      return 'Auth';
    case ArkDbErrorKind.Protocol:
      return 'Protocol';
    case ArkDbErrorKind.Server:
      return 'Server';
    case ArkDbErrorKind.Timeout:
      return 'Timeout';
    case ArkDbErrorKind.Cancelled:
      return 'Cancelled';
    case ArkDbErrorKind.Validation:
      return 'Validation';
    case ArkDbErrorKind.Unsupported:
      return 'Unsupported';
  }
}

function toArkDbError(e: Object): ArkDbError {
  if (e instanceof ArkDbError) {
    return e;
  }
  const err = e as Error;
  const msg = err !== null && err !== undefined && err.message !== undefined ? err.message : String(e);
  return ArkDbError.protocol(msg);
}

function toCleanupError(error: Object): ArkDbError {
  return error instanceof ArkDbError ? error : operationFailure(error, [], MySqlExecutionOutcome.Unknown);
}

function operationFailure(error: Object, cleanupErrors: ArkDbError[],
  outcome: MySqlExecutionOutcome): MySqlOperationError {
  if (error instanceof MySqlOperationError) {
    const combined = error.cleanupErrors.slice();
    for (const cleanup of cleanupErrors) combined.push(cleanup);
    return new MySqlOperationError(error.primary, combined, outcome, error.originalCause);
  }
  return new MySqlOperationError(toArkDbError(error), cleanupErrors, outcome,
    error instanceof ArkDbError ? undefined : error);
}

function operationContainsFailure(error: Object, expected: ArkDbError): boolean {
  if (error === expected) return true;
  if (!(error instanceof MySqlOperationError)) return false;
  if (operationContainsFailure(error.primary, expected)) return true;
  for (const cleanup of error.cleanupErrors) {
    if (operationContainsFailure(cleanup, expected)) return true;
  }
  return false;
}

function callbackFailure(error: Object): MySqlOperationError {
  if (error instanceof MySqlOperationError) {
    return new MySqlOperationError(error.primary, error.cleanupErrors, MySqlExecutionOutcome.Unknown,
      error.originalCause !== undefined ? error.originalCause : error);
  }
  return new MySqlOperationError(toArkDbError(error), [], MySqlExecutionOutcome.Unknown, error);
}
