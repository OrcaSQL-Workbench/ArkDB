import { ConnectionConfig } from './model/ConnectionConfig';
import {
  DatabaseContext, DatabaseContextPolicy, ConnectionState, DbConnectionFeatures,
  DbConnectionHealth, DbContextController, DbTransactionController, DbExecutionController,
  QueryCancellationResult, DatabaseSessionStatus,
  QueryExecutionSummary, QueryOptions, QueryResultSink, ArkDbError, ArkDbErrorKind, DbConnection,
  ConnectionTimerPort, SystemConnectionTimerPort, Logger,
  LogTag, monotonicNowMs, QueryResultMeta, QueryResultSummary, QueryRowChunk, QueryTruncation,
  validateQueryOptions
} from '@arkdb/core';
import { MySqlServerInfo as ServerInfo } from './model/MySqlServerInfo';
import { MySqlQueryResult as QueryResult } from './model/MySqlQueryResult';
import {
  MySqlCoreStreamingConnection, MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary,
  MySqlQueryResultSink, MySqlResultSinkAdapter, mysqlExecutionSummary, mysqlSessionStatus
} from './model/MySqlQueryStream';
import { MySqlDbConnection } from './api/MySqlContracts';
import {
  MySqlConnectionFeatures, MySqlSession
} from './api/MySqlConnectionFeatures';
import {
  MySqlBatchExecutor, MySqlInsertRowsExecutor, MySqlInsertRowsSnapshot,
  MySqlLongDataExecutor, MySqlNamedExecutor, MySqlProcedureCaller
} from './api/MySqlFeatureContracts';
import {
  MySqlCursorExecutor
} from './api/MySqlCursorContracts';
import {
  MySqlPreparedExecutor
} from './api/MySqlPreparedContracts';
import {
  MySqlExecutionDispatcher, MySqlExecutionObserver
} from './diagnostics/MySqlExecutionObserver';
import { TcpTransport } from './transport/TcpTransport';
import { PacketChannel, MysqlPacket, MysqlPacketSource } from './protocol/PacketChannel';
import { PacketWriter } from './protocol/PacketWriter';
import { Command } from './protocol/Constants';
import {
  buildComQuery, parseQueryStream, parseResultSet, TextRowDecoder
} from './command/Query';
import {
  mysqlContextPolicy, mysqlDatabaseForContext
} from './features/session/MySqlContext';
import { MySqlMetadataProvider } from './metadata/MySqlMetadataProvider';
import { MySqlServerMetricsProvider } from './metrics/MySqlServerMetricsProvider';
import {
  mysqlCleanupError as toCleanupError,
  mysqlOperationContains as operationContainsFailure,
  mysqlOperationFailure as operationFailure
} from './execution/MySqlFailure';
import { MySqlPreparedBatchExecutor } from './execution/MySqlBatchExecutor';
import {
  MySqlPreparedNamedExecutor
} from './features/named/MySqlNamedExecutor';
import {
  MySqlPreparedInsertRowsExecutor, snapshotMySqlInsertRowsInput
} from './execution/MySqlInsertRowsExecutor';
import { MySqlPreparedProcedureCaller } from './execution/MySqlProcedureCaller';
import { MySqlConnectionDeadlineExecutor } from './execution/MySqlDeadlineExecutor';
import {
  MySqlConnectionSessionController
} from './features/session/MySqlSessionController';
import {
  MYSQL_COMMIT_NO_CHAIN_NO_RELEASE, MYSQL_ROLLBACK_NO_CHAIN_NO_RELEASE,
  MySqlConnectionTransactionRunner, MySqlTransactionRunnerHost
} from './features/transaction/MySqlTransactionRunner';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from './execution/MySqlCommandGate';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from './model/MySqlOperationError';
import {
  MySqlBatchResult
} from './model/MySqlBatch';
import { MySqlDeadlineOptions } from './model/MySqlDeadlineOptions';
import { MySqlInsertRowsOptions } from './model/MySqlInsertRows';
import { MySqlParameter } from './features/prepared/MySqlParameter';
import {
  MySqlPreparedExecutor as InternalPreparedExecutor
} from './features/prepared/PreparedExecutor';
import {
  MySqlReadOnlyCursorExecutor
} from './features/cursor/MySqlCursor';
import {
  MySqlResultTerminatorObservation, parseBufferedResultStream, parseResultStream
} from './command/ResultStream';
import { BinaryRowDecoder } from './features/prepared/BinaryRowDecoder';
import {
  MySqlConnectionBatchExecutor, MySqlConnectionCursorExecutor,
  MySqlConnectionInsertRowsExecutor, MySqlConnectionLongDataExecutor,
  MySqlConnectionNamedExecutor, MySqlConnectionPreparedExecutor,
  MySqlConnectionProcedureCaller
} from './connection/MySqlFeatureFacades';
import {
  MySqlPreparedConnectionHost, MySqlPreparedPacketSource
} from './connection/MySqlPreparedConnectionHost';
import {
  MySqlTransactionConnectionHost
} from './connection/MySqlTransactionConnectionHost';
import {
  MySqlConnectionLifecycle, MySqlPreparedOperationSettlement,
  MySqlSessionFingerprint
} from './connection/MySqlConnectionLifecycle';

export {
  authPluginLogValue, connectionStateAfterCommandFailure,
  mysqlTlsRequested
} from './connection/MySqlConnectionLifecycle';

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
  private lifecycle: MySqlConnectionLifecycle<MySqlConnection>;
  private batch: MySqlPreparedBatchExecutor | null = null;
  private insertRows: MySqlPreparedInsertRowsExecutor | null = null;
  private named: MySqlPreparedNamedExecutor | null = null;
  private procedures: MySqlPreparedProcedureCaller | null = null;
  private prepared: InternalPreparedExecutor | null = null;
  private cursors: MySqlReadOnlyCursorExecutor | null = null;

  constructor(config: ConnectionConfig, password: string, transport: TcpTransport = new TcpTransport(),
    timers: ConnectionTimerPort = new SystemConnectionTimerPort(),
    createControlConnection?: () => DbConnection) {
    this.lifecycle = new MySqlConnectionLifecycle<MySqlConnection>(
      config, password, transport, timers, createControlConnection,
      (controlConfig: ConnectionConfig, controlPassword: string,
        controlFactory: () => DbConnection): MySqlConnection => {
        const control = new MySqlConnection(
          controlConfig, controlPassword, undefined, undefined,
          controlFactory);
        control.lifecycle.skipAutocommitSetup = true;
        return control;
      },
      (): DbConnection => this.createDefaultControlConnection(),
      (): DbConnection => this,
      (): void => this.invalidatePreparedState(),
      (scope: MySqlCommandScope, command: Uint8Array,
        parse: (channel: PacketChannel) => Promise<QueryResult>):
        Promise<QueryResult> =>
        this.bufferedCommandOwned(scope, command, parse),
      (scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> =>
        this.readMySqlSessionFingerprint(scope));
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
    return this.lifecycle.preparedCloseSignal(scope);
  }

  private get config(): ConnectionConfig { return this.lifecycle.config; }
  private get transport(): TcpTransport { return this.lifecycle.transport; }
  private get timers(): ConnectionTimerPort { return this.lifecycle.timers; }
  private get channel(): PacketChannel | null { return this.lifecycle.channel; }
  private set channel(value: PacketChannel | null) { this.lifecycle.channel = value; }
  private get clientCaps(): number { return this.lifecycle.clientCaps; }
  private get connState(): ConnectionState { return this.lifecycle.connState; }
  private set connState(value: ConnectionState) { this.lifecycle.connState = value; }
  private get info(): ServerInfo { return this.lifecycle.info; }
  private get status(): DatabaseSessionStatus { return this.lifecycle.status; }
  private set status(value: DatabaseSessionStatus) { this.lifecycle.status = value; }
  private get cancelTask(): Promise<QueryCancellationResult> | null {
    return this.lifecycle.cancelTask;
  }
  private get retiredByCancellation(): boolean {
    return this.lifecycle.retiredByCancellation;
  }
  private get commandGate(): MySqlCommandGate {
    return this.lifecycle.commandGate;
  }
  private set commandGate(value: MySqlCommandGate) {
    this.lifecycle.commandGate = value;
  }
  private get executingScope(): MySqlCommandScope | null {
    return this.lifecycle.executingScope;
  }
  private set executingScope(value: MySqlCommandScope | null) {
    this.lifecycle.executingScope = value;
  }
  private get queryWrite(): Promise<void> | null {
    return this.lifecycle.queryWrite;
  }
  private set queryWrite(value: Promise<void> | null) {
    this.lifecycle.queryWrite = value;
  }
  private get preparedOperation(): MySqlPreparedOperationSettlement | null {
    return this.lifecycle.preparedOperation;
  }
  private set preparedOperation(
    value: MySqlPreparedOperationSettlement | null) {
    this.lifecycle.preparedOperation = value;
  }
  private get cursorOperation(): MySqlPreparedOperationSettlement | null {
    return this.lifecycle.cursorOperation;
  }
  private set cursorOperation(
    value: MySqlPreparedOperationSettlement | null) {
    this.lifecycle.cursorOperation = value;
  }
  private get transactionOperation(): MySqlPreparedOperationSettlement | null {
    return this.lifecycle.transactionOperation;
  }
  private set transactionOperation(
    value: MySqlPreparedOperationSettlement | null) {
    this.lifecycle.transactionOperation = value;
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
    return this.lifecycle.createDefaultControlConnection();
  }

  protected async readMySqlSessionFingerprint(scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> {
    return this.lifecycle.readMySqlSessionFingerprint(scope);
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
    return new MySqlTransactionConnectionHost(
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
      (tableParts: string[], columns: string[],
        rows: MySqlParameter[][],
        options?: MySqlInsertRowsOptions): MySqlInsertRowsSnapshot =>
        snapshotMySqlInsertRowsInput(
          tableParts, columns, rows, options),
      (scope: MySqlCommandScope,
        input: MySqlInsertRowsSnapshot): Promise<MySqlBatchResult> =>
        this.transactionInsertRowsOwned(scope, input));
  }

  private preparedHost(): MySqlPreparedConnectionHost {
    return new MySqlPreparedConnectionHost(this.commandGate, this.timers,
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
            parseBufferedResultStream(new MySqlPreparedPacketSource(channel, this.clientCaps),
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
              parseResultStream(new MySqlPreparedPacketSource(channel, this.clientCaps),
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
    return this.lifecycle.connect();
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
    return this.lifecycle.resetSession();
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
    input: MySqlInsertRowsSnapshot): Promise<MySqlBatchResult> {
    return new MySqlPreparedInsertRowsExecutor(
      this.preparedHost(),
      (owned: MySqlCommandScope): Promise<void> =>
        this.settleTransactionPreparedExecution(owned))
      .executeInputOwned(scope, input);
  }

  cancel(): Promise<QueryCancellationResult> {
    return this.lifecycle.cancel();
  }

  isInterruptionError(error: ArkDbError): boolean {
    return this.lifecycle.isInterruptionError(error);
  }

  /** Attempt COM_QUIT when idle, always close the socket, and retain any failures. */
  close(): Promise<void> {
    return this.lifecycle.close();
  }

  private requireReady(): PacketChannel {
    return this.lifecycle.requireReady();
  }

  private reserveCommandOwnership(kind: MySqlCommandKind): MySqlCommandScope {
    this.requireReady();
    return this.commandGate.reserve(kind);
  }

  private async runOrdinaryCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T> {
    const scope = this.reserveCommandOwnership(kind);
    const settlement = this.lifecycle.createOrdinaryOperation(scope);
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
    if (this.lifecycle.ordinaryOperation === settlement) {
      this.lifecycle.ordinaryOperation = null;
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
    const settlement = this.lifecycle.createTransactionOperation(scope);
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
    return this.lifecycle.settleTransactionOperation(
      scope, completedCloseCleanup);
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
    return this.lifecycle.finishTransactionOperation(scope);
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
    return this.lifecycle.runDeadline<T>(scope, options, operation);
  }

  private ordinaryCloseJoin(
    scope: MySqlCommandScope): Promise<ArkDbError | null> | null {
    return this.lifecycle.ordinaryCloseJoin(scope);
  }

  private markOrdinaryCommandDispatched(scope: MySqlCommandScope): void {
    this.lifecycle.markOrdinaryCommandDispatched(scope);
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
    return this.lifecycle.retirePreparedSession(error);
  }

  protected async runPreparedCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience: boolean = false): Promise<T> {
    const scope = this.reserveCommandOwnership(kind);
    const settlement = this.lifecycle.createPreparedOperation(scope);
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
    const settlement = this.lifecycle.createCursorOperation(scope);
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
        new MySqlPreparedPacketSource(channel, this.clientCaps));
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
    settlement: MySqlPreparedOperationSettlement,
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
    return this.lifecycle.settlePreparedCancellation(scope);
  }

  private requireOwnedChannel(scope: MySqlCommandScope): PacketChannel {
    return this.lifecycle.requireOwnedChannel(scope);
  }

  private finishCommand(scope: MySqlCommandScope): void {
    this.lifecycle.finishCommand(scope);
  }

  private releaseCompletedCommand(): void {
    this.lifecycle.releaseCompletedCommand();
  }

  private expectOk(pkt: MysqlPacket): void {
    this.lifecycle.expectOk(pkt);
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

  private applyStatusFlags(statusFlags: number): void {
    this.lifecycle.applyStatusFlags(statusFlags);
  }

  private async classifyCommandFailure(scope: MySqlCommandScope, error: Object,
    reading: boolean, synchronized: boolean = false): Promise<ArkDbError> {
    return this.lifecycle.classifyCommandFailure(
      scope, error, reading, synchronized);
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

function callbackFailure(error: Object): MySqlOperationError {
  if (error instanceof MySqlOperationError) {
    return new MySqlOperationError(error.primary, error.cleanupErrors, MySqlExecutionOutcome.Unknown,
      error.originalCause !== undefined ? error.originalCause : error);
  }
  return new MySqlOperationError(toArkDbError(error), [], MySqlExecutionOutcome.Unknown, error);
}
