import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort,
  DatabaseContext, DbConnection, DbConnectionFeatures, QueryOptions,
  QueryResult, ServerInfo
} from '@arkdb/core';
import { MySqlLongDataExecutor } from '../../../main/ets/mysql/command/LongData';
import {
  MYSQL_CURSOR_OPERATION_IN_PROGRESS_MESSAGE
} from '../../../main/ets/mysql/command/MySqlCursorErrors';
import { MySqlConnectionFeatures } from '../../../main/ets/mysql/driver/MySqlConnectionFeatures';
import {
  MySqlConnectionExtensions
} from '../../../main/ets/mysql/driver/MySqlConnectionExtensions';
import { MySqlConnection } from '../../../main/ets/mysql/MySqlConnection';
import { MySqlConnectionOptions } from '../../../main/ets/mysql/driver/MySqlConnectionOptions';
import { MySqlDriverFactory } from '../../../main/ets/mysql/driver/MySqlDriverFactory';
import {
  MySqlCursor, MySqlCursorExecutor
} from '../../../main/ets/mysql/driver/MySqlCursorContracts';
import {
  MySqlPreparedExecutor, MySqlPreparedStatement
} from '../../../main/ets/mysql/driver/MySqlPreparedContracts';
import { MySqlSession } from '../../../main/ets/mysql/driver/MySqlSession';
import {
  MySqlExecutionEvent, MySqlExecutionEventType, MySqlExecutionObserver
} from '../../../main/ets/mysql/diagnostics/MySqlExecutionObserver';
import { MySqlBatchExecutor } from '../../../main/ets/mysql/execution/MySqlBatchExecutor';
import { MySqlDeadlineExecutor } from '../../../main/ets/mysql/execution/MySqlDeadlineExecutor';
import { MySqlInsertRowsExecutor } from '../../../main/ets/mysql/execution/MySqlInsertRowsExecutor';
import { MySqlNamedExecutor } from '../../../main/ets/mysql/execution/MySqlNamedExecutor';
import { MySqlProcedureCaller } from '../../../main/ets/mysql/execution/MySqlProcedureCaller';
import { MySqlSessionController } from '../../../main/ets/mysql/execution/MySqlSessionController';
import { MySqlTransactionRunner } from '../../../main/ets/mysql/execution/MySqlTransactionRunner';
import {
  ConnectionConfig, SslMode
} from '../../../main/ets/mysql/model/ConnectionConfig';
import { MySqlBatchOptions, MySqlBatchResult } from '../../../main/ets/mysql/model/MySqlBatch';
import { MySqlCursorOptions } from '../../../main/ets/mysql/model/MySqlCursorOptions';
import { MySqlDeadlineOptions } from '../../../main/ets/mysql/model/MySqlDeadlineOptions';
import { MySqlInsertRowsOptions } from '../../../main/ets/mysql/model/MySqlInsertRows';
import {
  MySqlLongDataOptions, MySqlLongParameter
} from '../../../main/ets/mysql/model/MySqlLongDataOptions';
import { MySqlNamedParameter } from '../../../main/ets/mysql/model/MySqlNamedParameter';
import { MySqlPoolOptions } from '../../../main/ets/mysql/model/MySqlPoolOptions';
import { MySqlParameter } from '../../../main/ets/mysql/model/MySqlParameter';
import {
  MySqlProcedureArgument, MySqlProcedureResult
} from '../../../main/ets/mysql/model/MySqlProcedure';
import {
  MySqlColumnDef, MySqlQueryResult, MySqlValue
} from '../../../main/ets/mysql/model/MySqlQueryResult';
import { MySqlServerInfo } from '../../../main/ets/mysql/model/MySqlServerInfo';
import {
  MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary, MySqlQueryResultMeta,
  MySqlQueryResultSink, MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../main/ets/mysql/model/MySqlQueryStream';
import { MySqlTransactionOptions } from '../../../main/ets/mysql/model/MySqlTransactionOptions';
import {
  MySqlPool, MySqlPoolRuntime, clearPoolCloseReentryTest,
  createMySqlPoolInternal, poolCloseReentryTaskForTest,
  setupPoolCloseReentryTest, startPoolCloseReentryTest
} from '../../../main/ets/mysql/pool/MySqlPool';
import {
  MySqlConnectionLease, MySqlPoolConnection, MySqlPoolConnectionAdapter
} from '../../../main/ets/mysql/pool/MySqlConnectionLease';
import { MySqlOperationError } from '../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlCommandKind } from '../../../main/ets/mysql/execution/MySqlCommandGate';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import {
  PreparedSocket, columnPayload, eofPayload, errorPayload, flushPrepared,
  framePacket, handshake, okPayload, prepareResponse
} from '../command/PreparedExecutionFixture';
import { socket } from '../../../mock/NetworkKit.mock';

class PoolTimerTask {
  readonly at: number;
  readonly handler: () => void;

  constructor(at: number, handler: () => void) {
    this.at = at;
    this.handler = handler;
  }
}

export class PoolTimers implements ConnectionTimerPort {
  now: number = 1000;
  private nextId: number = 1;
  private tasks: Map<number, PoolTimerTask> = new Map<number, PoolTimerTask>();

  nowMs(): number {
    return this.now;
  }

  schedule(handler: () => void, timeoutMs: number): number {
    const id = this.nextId++;
    this.tasks.set(id, new PoolTimerTask(this.now + timeoutMs, handler));
    return id;
  }

  cancel(timerId: number): void {
    this.tasks.delete(timerId);
  }

  advance(ms: number): void {
    this.now += ms;
    let delivered = true;
    while (delivered) {
      delivered = false;
      const due: number[] = [];
      this.tasks.forEach((task: PoolTimerTask, id: number): void => {
        if (task.at <= this.now) due.push(id);
      });
      due.sort((left: number, right: number): number => left - right);
      for (const id of due) {
        const task = this.tasks.get(id);
        this.tasks.delete(id);
        if (task !== undefined) {
          delivered = true;
          task.handler();
        }
      }
    }
  }

  get size(): number {
    return this.tasks.size;
  }
}

export class PoolDeferred<T> {
  readonly promise: Promise<T>;
  private resolvePromise: (value: T | PromiseLike<T>) => void =
    (_value: T | PromiseLike<T>): void => {};
  private rejectPromise: (error: Object) => void = (_error: Object): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T | PromiseLike<T>) => void,
      reject: (error: Object) => void): void => {
      this.resolvePromise = resolve;
      this.rejectPromise = reject;
    });
  }

  resolve(value: T): void {
    this.resolvePromise(value);
  }

  reject(error: Object): void {
    this.rejectPromise(error);
  }
}

class FakeResetController implements MySqlSessionController {
  private connection: PoolConnection;

  constructor(connection: PoolConnection) {
    this.connection = connection;
  }

  reset(): Promise<void> {
    return this.connection.reset();
  }
}

export class PoolBatchExecutor implements MySqlBatchExecutor {
  calls: number = 0;

  async execute(_sql: string, _rows: MySqlParameter[][],
    _options?: MySqlBatchOptions): Promise<MySqlBatchResult> {
    this.calls++;
    return new MySqlBatchResult();
  }
}

export class PoolDeadlineExecutor implements MySqlDeadlineExecutor {
  calls: number = 0;

  async query(_sql: string, _options?: MySqlDeadlineOptions): Promise<MySqlQueryResult> {
    this.calls++;
    return new MySqlQueryResult();
  }

  async execute(_sql: string, _parameters: MySqlParameter[],
    _options?: MySqlDeadlineOptions): Promise<MySqlQueryResult> {
    this.calls++;
    return new MySqlQueryResult();
  }
}

export class PoolInsertRowsExecutor implements MySqlInsertRowsExecutor {
  calls: number = 0;

  async execute(_tableParts: string[], _columns: string[],
    _rows: MySqlParameter[][],
    _options?: MySqlInsertRowsOptions): Promise<MySqlBatchResult> {
    this.calls++;
    return new MySqlBatchResult();
  }
}

export class PoolNamedExecutor implements MySqlNamedExecutor {
  calls: number = 0;

  async execute(_sql: string, _parameters: MySqlNamedParameter[],
    _options?: QueryOptions): Promise<MySqlQueryResult> {
    this.calls++;
    return new MySqlQueryResult();
  }

  async executeStream(_sql: string, _parameters: MySqlNamedParameter[],
    _options: QueryOptions,
    _sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    this.calls++;
    return new MySqlQueryExecutionSummary();
  }
}

export class PoolProcedureCaller implements MySqlProcedureCaller {
  calls: number = 0;

  async call(_procedure: string[], _arguments: MySqlProcedureArgument[],
    _options?: QueryOptions): Promise<MySqlProcedureResult> {
    this.calls++;
    return new MySqlProcedureResult();
  }
}

export class PoolTransactionRunner implements MySqlTransactionRunner {
  calls: number = 0;
  private connection: PoolConnection;

  constructor(connection: PoolConnection) {
    this.connection = connection;
  }

  async run<T>(_options: MySqlTransactionOptions,
    body: (session: MySqlSession) => Promise<T>): Promise<T> {
    this.calls++;
    return await body(this.connection);
  }
}

export class PoolCursor implements MySqlCursor {
  readonly columns: MySqlColumnDef[] = [];
  fetchCalls: number = 0;
  closeCalls: number = 0;
  doneReads: number = 0;
  doneFailure: Object | null = null;
  private connection: PoolConnection;
  private ended: boolean = false;
  private fetching: boolean = false;

  constructor(connection: PoolConnection) {
    this.connection = connection;
  }

  get done(): boolean {
    this.doneReads++;
    if (this.doneFailure !== null) throw this.doneFailure as Error;
    return this.ended;
  }

  async fetch(): Promise<MySqlValue[][]> {
    this.fetchCalls++;
    let rows: MySqlValue[][] = [];
    if (this.connection.cursorFetchGate !== null) {
      this.fetching = true;
      try {
        rows = await this.connection.cursorFetchGate.promise;
      } finally {
        this.fetching = false;
      }
    }
    if (this.connection.cursorFetchEnds) this.ended = true;
    return rows;
  }

  async close(): Promise<void> {
    if (this.ended) return;
    if (this.connection.cursorRejectCloseWhileFetching && this.fetching) {
      throw ArkDbError.protocol(MYSQL_CURSOR_OPERATION_IN_PROGRESS_MESSAGE);
    }
    this.closeCalls++;
    this.connection.events.push('cursor-close');
    if (this.connection.cursorCloseGate !== null) {
      await this.connection.cursorCloseGate.promise;
    }
    if (this.connection.cursorCloseFailure !== null) {
      throw this.connection.cursorCloseFailure as Error;
    }
    this.ended = true;
  }
}

export class PoolCursorExecutor implements MySqlCursorExecutor {
  readonly cursors: PoolCursor[] = [];
  openCalls: number = 0;
  private connection: PoolConnection;

  constructor(connection: PoolConnection) {
    this.connection = connection;
  }

  async open(_sql: string, _parameters: MySqlParameter[],
    _options?: MySqlCursorOptions): Promise<MySqlCursor> {
    this.openCalls++;
    const cursor = new PoolCursor(this.connection);
    this.cursors.push(cursor);
    return cursor;
  }
}

export class PoolLongDataExecutor implements MySqlLongDataExecutor {
  calls: number = 0;
  private connection: PoolConnection;

  constructor(connection: PoolConnection) {
    this.connection = connection;
  }

  async execute(_statement: MySqlPreparedStatement,
    _parameters: MySqlParameter[], _sources: MySqlLongParameter[],
    _options?: MySqlLongDataOptions): Promise<MySqlQueryResult> {
    this.calls++;
    if (this.connection.longDataGate !== null) {
      return await this.connection.longDataGate.promise;
    }
    if (this.connection.longDataFailure !== null) {
      throw this.connection.longDataFailure as Error;
    }
    return new MySqlQueryResult();
  }
}

export class PoolPreparedStatement implements MySqlPreparedStatement {
  readonly parameterCount: number = 0;
  readonly columns: MySqlColumnDef[] = [];
  closeCalls: number = 0;
  executeCalls: number = 0;
  closeGate: PoolDeferred<void> | null = null;
  closeFailure: Object | null = null;
  private connection: PoolConnection;
  private isClosed: boolean = false;

  constructor(connection: PoolConnection) {
    this.connection = connection;
  }

  get closed(): boolean {
    return this.isClosed;
  }

  async execute(_parameters: MySqlParameter[],
    _options?: QueryOptions): Promise<MySqlQueryResult> {
    this.executeCalls++;
    return new MySqlQueryResult();
  }

  async executeStream(_parameters: MySqlParameter[], _options: QueryOptions,
    _sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    this.executeCalls++;
    return new MySqlQueryExecutionSummary();
  }

  async close(): Promise<void> {
    if (this.isClosed) return;
    this.closeCalls++;
    this.connection.events.push('statement-close');
    if (this.closeGate !== null) await this.closeGate.promise;
    if (this.closeFailure !== null) throw this.closeFailure as Error;
    this.isClosed = true;
  }
}

export class PoolResultSink implements MySqlQueryResultSink {
  async onResultStart(_meta: MySqlQueryResultMeta): Promise<void> {}
  async onRows(_chunk: MySqlQueryRowChunk): Promise<void> {}
  async onResultEnd(_summary: MySqlQueryResultSummary): Promise<void> {}
}

export class PoolPreparedExecutor implements MySqlPreparedExecutor {
  readonly statements: PoolPreparedStatement[] = [];
  executeCalls: number = 0;
  private connection: PoolConnection;

  constructor(connection: PoolConnection) {
    this.connection = connection;
  }

  async prepare(_sql: string): Promise<MySqlPreparedStatement> {
    const statement = new PoolPreparedStatement(this.connection);
    this.statements.push(statement);
    return statement;
  }

  async execute(_sql: string, _parameters: MySqlParameter[],
    _options?: QueryOptions): Promise<MySqlQueryResult> {
    this.executeCalls++;
    return new MySqlQueryResult();
  }

  async executeStream(_sql: string, _parameters: MySqlParameter[],
    _options: QueryOptions,
    _sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    this.executeCalls++;
    return new MySqlQueryExecutionSummary();
  }
}

export class PoolConnection implements MySqlPoolConnection {
  readonly features: DbConnectionFeatures = new DbConnectionFeatures();
  readonly mysqlFeatures: MySqlConnectionFeatures = new MySqlConnectionFeatures();
  readonly serverInfo: MySqlServerInfo = new MySqlServerInfo();
  readonly sessionStatus: MySqlDatabaseSessionStatus = new MySqlDatabaseSessionStatus();
  readonly prepared: PoolPreparedExecutor;
  readonly cursors: PoolCursorExecutor;
  readonly longData: PoolLongDataExecutor;
  readonly batch: PoolBatchExecutor = new PoolBatchExecutor();
  readonly deadlines: PoolDeadlineExecutor = new PoolDeadlineExecutor();
  readonly insertRows: PoolInsertRowsExecutor = new PoolInsertRowsExecutor();
  readonly named: PoolNamedExecutor = new PoolNamedExecutor();
  readonly procedures: PoolProcedureCaller = new PoolProcedureCaller();
  readonly transactions: PoolTransactionRunner;
  readonly id: number;
  state: ConnectionState = ConnectionState.Idle;
  connectGate: PoolDeferred<void> | null = null;
  queryGate: PoolDeferred<MySqlQueryResult> | null = null;
  streamGate: PoolDeferred<MySqlQueryExecutionSummary> | null = null;
  cursorFetchGate: PoolDeferred<MySqlValue[][]> | null = null;
  cursorCloseGate: PoolDeferred<void> | null = null;
  longDataGate: PoolDeferred<MySqlQueryResult> | null = null;
  resetGate: PoolDeferred<void> | null = null;
  closeGate: PoolDeferred<void> | null = null;
  closeSettlesQuery: boolean = false;
  cursorRejectCloseWhileFetching: boolean = false;
  cursorFetchEnds: boolean = false;
  resetFailure: Object | null = null;
  connectFailure: Object | null = null;
  closeFailure: Object | null = null;
  cursorCloseFailure: Object | null = null;
  longDataFailure: Object | null = null;
  dirtySession: boolean = false;
  queryCalls: number = 0;
  resetCalls: number = 0;
  closeCalls: number = 0;
  events: string[] = [];

  constructor(id: number) {
    this.id = id;
    this.serverInfo.connectionId = id;
    this.sessionStatus.known = true;
    this.mysqlFeatures.session = new FakeResetController(this);
    this.prepared = new PoolPreparedExecutor(this);
    this.cursors = new PoolCursorExecutor(this);
    this.longData = new PoolLongDataExecutor(this);
    this.transactions = new PoolTransactionRunner(this);
    this.mysqlFeatures.batch = this.batch;
    this.mysqlFeatures.cursors = this.cursors;
    this.mysqlFeatures.deadlines = this.deadlines;
    this.mysqlFeatures.insertRows = this.insertRows;
    this.mysqlFeatures.longData = this.longData;
    this.mysqlFeatures.named = this.named;
    this.mysqlFeatures.prepared = this.prepared;
    this.mysqlFeatures.procedures = this.procedures;
    this.mysqlFeatures.transactions = this.transactions;
  }

  async connect(): Promise<void> {
    this.state = ConnectionState.Connecting;
    if (this.connectGate !== null) await this.connectGate.promise;
    if (this.connectFailure !== null) throw this.connectFailure as Error;
    this.state = ConnectionState.Ready;
  }

  async ping(): Promise<void> {}

  async query(_sql: string): Promise<MySqlQueryResult> {
    this.queryCalls++;
    if (_sql === 'CONTAMINATE') this.dirtySession = true;
    if (_sql === 'ASSERT CLEAN' && this.dirtySession) {
      throw ArkDbError.protocol('Synthetic session contamination crossed a lease.');
    }
    if (this.queryGate !== null) return await this.queryGate.promise;
    return new MySqlQueryResult();
  }

  async queryStream(_sql: string, _options: QueryOptions,
    _sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    if (this.streamGate !== null) return await this.streamGate.promise;
    return new MySqlQueryExecutionSummary();
  }

  async changeContext(_context: DatabaseContext): Promise<void> {}

  async setAutocommit(enabled: boolean): Promise<MySqlDatabaseSessionStatus> {
    this.sessionStatus.autocommit = enabled;
    return this.sessionStatus;
  }

  async commit(): Promise<MySqlDatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async rollback(): Promise<MySqlDatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async savepoint(_name: string): Promise<void> {}

  async rollbackTo(_name: string): Promise<void> {}

  async releaseSavepoint(_name: string): Promise<void> {}

  async close(): Promise<void> {
    if (this.state === ConnectionState.Closed) return;
    this.closeCalls++;
    this.events.push('close');
    if (this.closeSettlesQuery && this.queryGate !== null) {
      this.queryGate.reject(ArkDbError.cancelled(
        'Synthetic physical close settled the active query.'));
      this.queryGate = null;
    }
    if (this.closeGate !== null) await this.closeGate.promise;
    if (this.closeFailure !== null) throw this.closeFailure as Error;
    this.state = ConnectionState.Closed;
  }

  async reset(): Promise<void> {
    this.resetCalls++;
    this.events.push('reset');
    if (this.resetGate !== null) await this.resetGate.promise;
    if (this.resetFailure !== null) throw this.resetFailure as Error;
    this.dirtySession = false;
  }
}

export class PoolRuntime implements MySqlPoolRuntime {
  readonly timers: PoolTimers = new PoolTimers();
  readonly connections: PoolConnection[] = [];
  readonly createdOptions: MySqlConnectionOptions[] = [];
  private queued: PoolConnection[] = [];
  createCalls: number = 0;

  enqueue(connection: PoolConnection): void {
    this.queued.push(connection);
  }

  createConnection(options: MySqlConnectionOptions): MySqlPoolConnection {
    this.createCalls++;
    this.createdOptions.push(options);
    const queued = this.queued.shift();
    const connection = queued === undefined ?
      new PoolConnection(this.createCalls) : queued;
    this.connections.push(connection);
    return connection;
  }
}

class PoolExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
  }
}

class ReentrantLeaseFinishObserver implements MySqlExecutionObserver {
  lease: MySqlConnectionLease | null = null;
  terminal: Promise<void> | null = null;
  private destroy: boolean;

  constructor(destroy: boolean) {
    this.destroy = destroy;
  }

  onEvent(event: MySqlExecutionEvent): void {
    if (event.type !== MySqlExecutionEventType.Start ||
      event.commandKind !== MySqlCommandKind.Query ||
      this.lease === null || this.terminal !== null) return;
    this.terminal = this.destroy ?
      this.lease.destroy() : this.lease.release();
  }

  requireTerminal(): Promise<void> {
    if (this.terminal === null) {
      throw new Error('Expected the Start observer to finish the lease.');
    }
    return this.terminal;
  }
}

class TerminalQueryReentryObserver implements MySqlExecutionObserver {
  lease: MySqlConnectionLease | null = null;
  private secondQuery: Promise<MySqlQueryResult> | null = null;
  private started: boolean = false;

  onEvent(event: MySqlExecutionEvent): void {
    if (event.type !== MySqlExecutionEventType.Terminal ||
      event.commandKind !== MySqlCommandKind.Query ||
      this.lease === null || this.started) return;
    this.started = true;
    this.secondQuery =
      this.lease.session.query('SELECT terminal reentrant held query');
  }

  requireSecondQuery(): Promise<MySqlQueryResult> {
    const task = this.secondQuery;
    if (task === null) {
      throw new Error('Expected the terminal observer to start query #2.');
    }
    return task;
  }
}

class ReentrantStatementCloseObserver implements MySqlExecutionObserver {
  statement: MySqlPreparedStatement | null = null;
  repeated: Promise<void> | null = null;
  starts: number = 0;

  onEvent(event: MySqlExecutionEvent): void {
    if (event.type !== MySqlExecutionEventType.Start ||
      event.commandKind !== MySqlCommandKind.StatementClose ||
      this.statement === null || this.repeated !== null) return;
    this.starts++;
    this.repeated = this.statement.close();
  }

  requireRepeated(): Promise<void> {
    if (this.repeated === null) {
      throw new Error('Expected reentrant statement close.');
    }
    return this.repeated;
  }
}

class ReentrantLeaseTerminalObserver implements MySqlExecutionObserver {
  lease: MySqlConnectionLease | null = null;
  repeated: Promise<void> | null = null;

  onEvent(event: MySqlExecutionEvent): void {
    if (event.type !== MySqlExecutionEventType.Start ||
      event.commandKind !== MySqlCommandKind.Close ||
      this.lease === null || this.repeated !== null) return;
    this.repeated = this.lease.destroy();
  }

  requireRepeated(): Promise<void> {
    if (this.repeated === null) {
      throw new Error('Expected reentrant lease terminal task.');
    }
    return this.repeated;
  }
}

class ObservedPoolRuntime implements MySqlPoolRuntime {
  readonly timers: PoolTimers = new PoolTimers();
  readonly peer: PreparedSocket = new PreparedSocket();
  closeFailure: ArkDbError | null = null;
  private factory: MySqlDriverFactory = new MySqlDriverFactory();

  createConnection(options: MySqlConnectionOptions): MySqlPoolConnection {
    socket.nextTcp = this.peer;
    return new ObservedPoolConnection(
      this.factory.create(options), this);
  }
}

class ObservedPoolConnection extends MySqlPoolConnectionAdapter {
  private runtime: ObservedPoolRuntime;

  constructor(root: MySqlConnection, runtime: ObservedPoolRuntime) {
    super(root);
    this.runtime = runtime;
  }

  close(): Promise<void> {
    const closing = super.close();
    return closing.then((): void => {
      if (this.runtime.closeFailure !== null) throw this.runtime.closeFailure;
    });
  }
}

class OpeningCancellationControl implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly connectEntered: PoolDeferred<void> = new PoolDeferred<void>();
  readonly opening: PoolDeferred<void> = new PoolDeferred<void>();
  closeCalls: number = 0;
  closed: boolean = false;

  async connect(): Promise<void> {
    this.connectEntered.resolve(undefined);
    await this.opening.promise;
    if (this.closed) {
      throw ArkDbError.cancelled('Synthetic control connection closed while opening.');
    }
    this.state = ConnectionState.Ready;
  }

  async query(_sql: string): Promise<QueryResult> {
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.closeCalls++;
    this.closed = true;
    this.state = ConnectionState.Closed;
    this.opening.resolve(undefined);
  }
}

class CancellationPoolRuntime implements MySqlPoolRuntime {
  readonly timers: PoolTimers = new PoolTimers();
  readonly peer: PreparedSocket = new PreparedSocket();
  readonly control: OpeningCancellationControl =
    new OpeningCancellationControl();

  createConnection(options: MySqlConnectionOptions): MySqlPoolConnection {
    socket.nextTcp = this.peer;
    return new MySqlPoolConnectionAdapter(new MySqlConnection(
      options.config, options.password, new TcpTransport(), this.timers,
      (): DbConnection => this.control));
  }
}

class ReentrantPoolCloseObserver implements MySqlExecutionObserver {
  readonly connected: PoolDeferred<void> = new PoolDeferred<void>();
  private reentered: boolean = false;

  onEvent(event: MySqlExecutionEvent): void {
    if (event.type === MySqlExecutionEventType.Terminal &&
      event.commandKind === MySqlCommandKind.Connect) {
      this.connected.resolve(undefined);
      return;
    }
    if (event.type !== MySqlExecutionEventType.Start ||
      event.commandKind !== MySqlCommandKind.Close ||
      this.reentered) return;
    this.reentered = true;
    startPoolCloseReentryTest();
  }
}

function createObservedPool(runtime: ObservedPoolRuntime,
  observer: MySqlExecutionObserver,
  options: MySqlPoolOptions = poolOptions()): MySqlPool {
  return createMySqlPoolInternal(
    observedConnectionOptions(observer), options, runtime);
}

function observedConnectionOptions(
  observer: MySqlExecutionObserver): MySqlConnectionOptions {
  const config = new ConnectionConfig();
  config.host = 'observer-pool.invalid';
  config.user = 'observer';
  config.ssl.mode = SslMode.DISABLED;
  return new MySqlConnectionOptions(config, '',
    new MySqlConnectionExtensions(observer));
}

function completeObservedConnect(runtime: ObservedPoolRuntime): void {
  runtime.peer.emitMessage(new PacketWriter()
    .writeBytes(handshake(Capabilities.PROTOCOL_41))
    .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
}

function completeCancellationPoolConnect(runtime: CancellationPoolRuntime): void {
  runtime.peer.emitMessage(new PacketWriter()
    .writeBytes(handshake(Capabilities.PROTOCOL_41))
    .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
}

function poolResetFingerprintResult(): Uint8Array[] {
  const row = new PacketWriter().writeUInt8(0xfb).writeLenEncString('')
    .writeLenEncString('utf8mb4').writeLenEncString('SYSTEM').toUint8Array();
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row, eofPayload()
  ];
}

function poolFailureContainsIdentity(error: Object, expected: Object): boolean {
  if (error === expected) return true;
  if (!(error instanceof MySqlOperationError)) return false;
  if (poolFailureContainsIdentity(error.primary, expected)) return true;
  for (const cleanup of error.cleanupErrors) {
    if (poolFailureContainsIdentity(cleanup, expected)) return true;
  }
  return false;
}

export class PoolOutcome<T> {
  settled: boolean = false;
  value: T | null = null;
  error: Object | null = null;
  readonly finished: Promise<void>;

  constructor(operation: Promise<T>) {
    this.finished = operation.then((value: T): void => {
      this.value = value;
      this.settled = true;
    }, (error: Object): void => {
      this.error = error;
      this.settled = true;
    });
  }
}

export function poolOptions(maxSize: number = 1): MySqlPoolOptions {
  const options = new MySqlPoolOptions();
  options.maxSize = maxSize;
  options.minIdle = 0;
  options.acquireTimeoutMs = 100;
  options.releaseTimeoutMs = 100;
  options.closeTimeoutMs = 100;
  options.idleTimeoutMs = 0;
  return options;
}

export function createTestPool(runtime: PoolRuntime,
  options: MySqlPoolOptions = poolOptions()): MySqlPool {
  const config = new ConnectionConfig();
  config.host = 'pool.invalid';
  config.user = 'pool';
  return createMySqlPoolInternal(
    new MySqlConnectionOptions(config, ''), options, runtime);
}

export async function flushPool(): Promise<void> {
  for (let turn = 0; turn < 40; turn++) await Promise.resolve();
}

export async function poolFailureOf<T>(operation: Promise<T>): Promise<ArkDbError | null> {
  return operation.then(
    (_value: T): ArkDbError | null => null,
    (error: Object): ArkDbError | null => error as ArkDbError);
}

async function assertStartObserverFinishStaysJoined(destroy: boolean): Promise<void> {
  const observer = new ReentrantLeaseFinishObserver(destroy);
  const runtime = new ObservedPoolRuntime();
  const config = new ConnectionConfig();
  config.host = 'observer-pool.invalid';
  config.user = 'observer';
  config.ssl.mode = SslMode.DISABLED;
  const options = poolOptions();
  options.releaseTimeoutMs = 100;
  const pool = createMySqlPoolInternal(
    new MySqlConnectionOptions(config, '',
      new MySqlConnectionExtensions(observer)),
    options, runtime);
  const acquiring = pool.acquire();
  runtime.peer.emitMessage(new PacketWriter()
    .writeBytes(handshake(Capabilities.PROTOCOL_41))
    .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
  const lease = await acquiring;
  observer.lease = lease;
  runtime.peer.writes = [];
  runtime.peer.holdCommand = 0x03;
  runtime.peer.onCommand = (command: number): void => {
    if (command !== 0x1f) return;
    Promise.resolve().then((): void => {
      runtime.peer.emitResponse([errorPayload(1047, '08S01')]);
    });
  };

  const query = new PoolOutcome<MySqlQueryResult>(
    lease.session.query('SELECT observer_reentry'));
  await flushPrepared();
  const terminal = new PoolOutcome<void>(observer.requireTerminal());
  expect(query.settled).assertFalse();
  expect(terminal.settled).assertFalse();
  expect(runtime.peer.closeCalls).assertEqual(0);

  runtime.peer.emitResponse([okPayload()]);
  await query.finished;
  expect(query.error === null).assertTrue();
  await terminal.finished;
  if (destroy) {
    expect(terminal.error === null).assertTrue();
  } else {
    expect(terminal.error instanceof ArkDbError).assertTrue();
    expect((terminal.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Unsupported);
  }
  runtime.peer.onCommand = null;
  await pool.close();
}

export default function mySqlPoolTest(): void {
  describe('MySQL FIFO lease pool', () => {
    it('usesSpecSevenPointTwoNumericDefaults', 0, () => {
      const options = new MySqlPoolOptions();
      expect(options.maxSize).assertEqual(4);
      expect(options.minIdle).assertEqual(0);
      expect(options.maxQueueSize).assertEqual(64);
      expect(options.acquireTimeoutMs).assertEqual(10000);
      expect(options.releaseTimeoutMs).assertEqual(5000);
      expect(options.idleTimeoutMs).assertEqual(60000);
      expect(options.closeTimeoutMs).assertEqual(5000);
      expect(options.validate().length).assertEqual(0);
    });

    it('snapshotsTlsMultiStatementAndObserverOptionsForPhysicalCreation', 0, async () => {
      const runtime = new PoolRuntime();
      const config = new ConnectionConfig();
      config.host = 'snapshot.invalid';
      config.user = 'snapshot';
      config.multipleStatements = true;
      config.ssl.mode = SslMode.VERIFY_IDENTITY;
      config.ssl.caCertPath = 'original-ca.pem';
      const observer = new PoolExecutionObserver();
      const extensions = new MySqlConnectionExtensions(observer);
      const pool = createMySqlPoolInternal(
        new MySqlConnectionOptions(config, 'secret', extensions),
        poolOptions(), runtime);

      config.multipleStatements = false;
      config.ssl.mode = SslMode.DISABLED;
      config.ssl.caCertPath = 'mutated-ca.pem';
      const lease = await pool.acquire();
      const captured = runtime.createdOptions[0];
      expect(captured.password).assertEqual('secret');
      expect(captured.config.multipleStatements).assertTrue();
      expect(captured.config.ssl.mode).assertEqual(SslMode.VERIFY_IDENTITY);
      expect(captured.config.ssl.caCertPath).assertEqual('original-ca.pem');
      expect(captured.extensions === extensions).assertFalse();
      expect(captured.extensions?.executionObserver === observer).assertTrue();
      await lease.destroy();
      await pool.close();
    });

    it('queryStartObserverReleaseStaysJoinedToAcceptedCommand', 0, async () => {
      await assertStartObserverFinishStaysJoined(false);
    });

    it('queryStartObserverDestroyStaysJoinedToAcceptedCommand', 0, async () => {
      await assertStartObserverFinishStaysJoined(true);
    });

    it('statementCloseStartReentrySharesOneLeaseCloseTask', 0, async () => {
      const observer = new ReentrantStatementCloseObserver();
      const runtime = new ObservedPoolRuntime();
      const pool = createObservedPool(runtime, observer);
      const acquiring = pool.acquire();
      completeObservedConnect(runtime);
      const lease = await acquiring;
      const prepared = lease.session.mysqlFeatures.prepared;
      if (prepared === undefined) throw new Error('Expected prepared support.');
      runtime.peer.responses.push(prepareResponse(7));
      const statement = await prepared.prepare('DO close_reentry');
      runtime.peer.writes = [];
      observer.statement = statement;

      const first = statement.close();
      const repeated = observer.requireRepeated();
      expect(first === repeated).assertTrue();
      expect(observer.starts).assertEqual(1);
      await first;
      await repeated;
      expect(runtime.peer.commands().join(',')).assertEqual('25');
      await lease.destroy();
      await pool.close();
    });

    it('forcedLeaseCloseStartReentrySharesOneTerminalTask', 0, async () => {
      const observer = new ReentrantLeaseTerminalObserver();
      const runtime = new ObservedPoolRuntime();
      const options = poolOptions();
      options.closeTimeoutMs = 10;
      options.releaseTimeoutMs = 100;
      const pool = createObservedPool(runtime, observer, options);
      const acquiring = pool.acquire();
      completeObservedConnect(runtime);
      const lease = await acquiring;
      observer.lease = lease;

      const closing = pool.close();
      runtime.timers.advance(10);
      await flushPrepared();
      const repeated = observer.requireRepeated();
      const after = lease.destroy();
      expect(repeated === after).assertTrue();
      expect((await poolFailureOf<void>(repeated))?.kind)
        .assertEqual(ArkDbErrorKind.Timeout);
      expect((await poolFailureOf<void>(closing))?.kind)
        .assertEqual(ArkDbErrorKind.Timeout);
    });

    it('poolCloseStartReentrySharesTaskAndRetainsPhysicalFailure', 0, async () => {
      const observer = new ReentrantPoolCloseObserver();
      const runtime = new ObservedPoolRuntime();
      const options = poolOptions();
      options.minIdle = 1;
      setupPoolCloseReentryTest(
        observedConnectionOptions(observer), options, runtime);
      try {
        completeObservedConnect(runtime);
        await observer.connected.promise;
        await flushPool();
        const physicalFailure =
          ArkDbError.network('Synthetic reentrant physical close failure.');
        runtime.closeFailure = physicalFailure;

        startPoolCloseReentryTest();
        const first = poolCloseReentryTaskForTest(false);
        const repeated = poolCloseReentryTaskForTest(true);
        try {
          if (first === null) throw new Error('Expected outer pool close.');
          if (repeated === null) throw new Error('Expected reentrant pool close.');
          expect(first === repeated).assertTrue();
          const firstFailure = await poolFailureOf<void>(first);
          const repeatedFailure = await poolFailureOf<void>(repeated);
          expect(firstFailure instanceof MySqlOperationError).assertTrue();
          expect(firstFailure === repeatedFailure).assertTrue();
          expect(poolFailureContainsIdentity(firstFailure!, physicalFailure)).assertTrue();
          expect(runtime.peer.closeCalls).assertEqual(1);
        } finally {
          if (first !== null) await poolFailureOf<void>(first);
          if (repeated !== null) await poolFailureOf<void>(repeated);
        }
      } finally {
        clearPoolCloseReentryTest();
        runtime.closeFailure = null;
      }
    });

    it('creatingSlotsCountTowardMaxSize', 0, async () => {
      const runtime = new PoolRuntime();
      const connecting = new PoolConnection(1);
      connecting.connectGate = new PoolDeferred<void>();
      runtime.enqueue(connecting);
      const pool = createTestPool(runtime);

      const first = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      expect(runtime.createCalls).assertEqual(1);
      expect(first.settled).assertFalse();
      expect(second.settled).assertFalse();

      connecting.connectGate.resolve(undefined);
      await first.finished;
      expect(first.value !== null).assertTrue();
      expect(second.settled).assertFalse();
      await first.value!.release();
      await second.finished;
      expect(runtime.createCalls).assertEqual(1);
      await second.value!.destroy();
      await pool.close();
    });

    it('maxSizeOneNeverDoubleLeases', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      expect(second.settled).assertFalse();

      await first.release();
      await second.finished;
      expect(second.value !== null).assertTrue();
      expect(runtime.createCalls).assertEqual(1);
      await second.value!.destroy();
      await pool.close();
    });

    it('fifoWaitersCannotBeBarged', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      const third = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();

      await first.release();
      await second.finished;
      expect(second.value !== null).assertTrue();
      expect(third.settled).assertFalse();
      await second.value!.release();
      await third.finished;
      expect(third.value !== null).assertTrue();
      await third.value!.destroy();
      await pool.close();
    });

    it('fasterConcurrentCreationCannotSettleLaterWaiterFirst', 0, async () => {
      const runtime = new PoolRuntime();
      const slow = new PoolConnection(1);
      slow.connectGate = new PoolDeferred<void>();
      const fast = new PoolConnection(2);
      runtime.enqueue(slow);
      runtime.enqueue(fast);
      const pool = createTestPool(runtime, poolOptions(2));

      const first = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      const firstSettledWithOneReadySlot = first.settled;
      const secondSettledWithOneReadySlot = second.settled;
      const timersWithOneReadySlot = runtime.timers.size;

      slow.connectGate.resolve(undefined);
      await first.finished;
      await second.finished;
      const timersAfterBothSettled = runtime.timers.size;
      if (first.value !== null) await first.value.destroy();
      if (second.value !== null) await second.value.destroy();
      await pool.close();

      expect(firstSettledWithOneReadySlot).assertTrue();
      expect(secondSettledWithOneReadySlot).assertFalse();
      expect(timersWithOneReadySlot).assertEqual(1);
      expect(first.value !== null).assertTrue();
      expect(second.value !== null).assertTrue();
      expect(timersAfterBothSettled).assertEqual(0);
    });

    it('releasedSlotCannotServeLaterWaiterAheadOfSlowOldest', 0, async () => {
      const runtime = new PoolRuntime();
      const activeConnection = new PoolConnection(1);
      const slow = new PoolConnection(2);
      slow.connectGate = new PoolDeferred<void>();
      runtime.enqueue(activeConnection);
      runtime.enqueue(slow);
      const pool = createTestPool(runtime, poolOptions(2));
      const active = await pool.acquire();

      const first = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      const timersBeforeRelease = runtime.timers.size;

      await active.release();
      await flushPool();
      const firstSettledAfterRelease = first.settled;
      const secondSettledAfterRelease = second.settled;
      const timersAfterRelease = runtime.timers.size;

      slow.connectGate.resolve(undefined);
      await first.finished;
      await second.finished;
      const timersAfterBothSettled = runtime.timers.size;
      if (first.value !== null) await first.value.destroy();
      if (second.value !== null) await second.value.destroy();
      await pool.close();

      expect(timersBeforeRelease).assertEqual(2);
      expect(firstSettledAfterRelease).assertTrue();
      expect(secondSettledAfterRelease).assertFalse();
      expect(timersAfterRelease).assertEqual(1);
      expect(first.value !== null).assertTrue();
      expect(second.value !== null).assertTrue();
      expect(timersAfterBothSettled).assertEqual(0);
    });

    it('failedCreationBindsOldestWaiterBeforeAsyncCleanup', 0, async () => {
      const runtime = new PoolRuntime();
      const failed = new PoolConnection(1);
      const connectFailure =
        ArkDbError.network('Synthetic connect failure before slow cleanup.');
      failed.connectFailure = connectFailure;
      failed.closeGate = new PoolDeferred<void>();
      const replacement = new PoolConnection(2);
      runtime.enqueue(failed);
      runtime.enqueue(replacement);
      const pool = createTestPool(runtime, poolOptions(2));

      const first = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      const firstValueWhileCleanup = first.value;
      const secondValueWhileCleanup = second.value;
      const timersWhileCleanup = runtime.timers.size;

      failed.closeGate.resolve(undefined);
      await first.finished;
      await second.finished;
      const firstFailure = first.error;
      if (first.value !== null) await first.value.destroy();
      if (second.value !== null) await second.value.destroy();
      await pool.close();

      expect(firstValueWhileCleanup === null).assertTrue();
      expect(secondValueWhileCleanup !== null).assertTrue();
      expect(timersWhileCleanup).assertEqual(1);
      expect(firstFailure === connectFailure).assertTrue();
      expect(second.value !== null).assertTrue();
    });

    it('failedCreationCleanupDoesNotCancelAcquireDeadline', 0, async () => {
      const runtime = new PoolRuntime();
      const failed = new PoolConnection(1);
      const connectFailure =
        ArkDbError.network('Synthetic delayed connect failure.');
      const cleanupFailure =
        ArkDbError.network('Synthetic delayed connect cleanup failure.');
      failed.connectFailure = connectFailure;
      failed.closeFailure = cleanupFailure;
      failed.closeGate = new PoolDeferred<void>();
      const replacement = new PoolConnection(2);
      runtime.enqueue(failed);
      runtime.enqueue(replacement);
      const options = poolOptions(2);
      options.acquireTimeoutMs = 10;
      const pool = createTestPool(runtime, options);

      let firstCompletions = 0;
      const firstTask = pool.acquire();
      firstTask.then(
        (_lease: MySqlConnectionLease): void => {
          firstCompletions++;
        },
        (_error: Object): void => {
          firstCompletions++;
        });
      const first = new PoolOutcome<MySqlConnectionLease>(firstTask);
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();

      runtime.timers.advance(10);
      await flushPool();
      const firstSettledAtDeadline = first.settled;
      const firstFailureAtDeadline = first.error;
      const timersAtDeadline = runtime.timers.size;

      failed.closeGate.resolve(undefined);
      await first.finished;
      await second.finished;
      if (second.value !== null) await second.value.destroy();
      const closeFailure = await poolFailureOf<void>(pool.close());

      expect(firstSettledAtDeadline).assertTrue();
      expect(firstFailureAtDeadline instanceof ArkDbError).assertTrue();
      expect((firstFailureAtDeadline as ArkDbError).kind)
        .assertEqual(ArkDbErrorKind.Timeout);
      expect(first.error === firstFailureAtDeadline).assertTrue();
      expect(first.value === null).assertTrue();
      expect(firstCompletions).assertEqual(1);
      expect(timersAtDeadline).assertEqual(0);
      expect(second.value !== null).assertTrue();
      expect(closeFailure instanceof MySqlOperationError).assertTrue();
      if (closeFailure instanceof MySqlOperationError) {
        expect(closeFailure.primary === connectFailure).assertTrue();
        expect(closeFailure.cleanupErrors.length).assertEqual(1);
        expect(closeFailure.cleanupErrors[0] === cleanupFailure).assertTrue();
      }
    });

    it('poolCloseCancelsWaiterDuringFailedCreationCleanup', 0, async () => {
      const runtime = new PoolRuntime();
      const failed = new PoolConnection(1);
      const connectFailure =
        ArkDbError.network('Synthetic connect failure during pool close.');
      const cleanupFailure =
        ArkDbError.network('Synthetic connect cleanup during pool close.');
      failed.connectFailure = connectFailure;
      failed.closeFailure = cleanupFailure;
      failed.closeGate = new PoolDeferred<void>();
      runtime.enqueue(failed);
      const pool = createTestPool(runtime);

      const acquiring = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      const closing = new PoolOutcome<void>(pool.close());
      await flushPool();
      const acquireSettledDuringClose = acquiring.settled;
      const acquireFailureDuringClose = acquiring.error;
      const timersDuringClose = runtime.timers.size;

      failed.closeGate.resolve(undefined);
      await acquiring.finished;
      await closing.finished;

      expect(acquireSettledDuringClose).assertTrue();
      expect(acquireFailureDuringClose instanceof ArkDbError).assertTrue();
      expect((acquireFailureDuringClose as ArkDbError).kind)
        .assertEqual(ArkDbErrorKind.Cancelled);
      expect(acquiring.error === acquireFailureDuringClose).assertTrue();
      expect(acquiring.value === null).assertTrue();
      expect(timersDuringClose).assertEqual(1);
      expect(closing.error instanceof MySqlOperationError).assertTrue();
      if (closing.error instanceof MySqlOperationError) {
        expect(closing.error.primary === connectFailure).assertTrue();
        expect(closing.error.cleanupErrors.length).assertEqual(1);
        expect(closing.error.cleanupErrors[0] === cleanupFailure).assertTrue();
      }
    });

    it('zeroQueueAcceptsWaiterCoveredByExistingDemandReservation', 0, async () => {
      const runtime = new PoolRuntime();
      const activeConnection = new PoolConnection(1);
      const slow = new PoolConnection(2);
      slow.connectGate = new PoolDeferred<void>();
      runtime.enqueue(activeConnection);
      runtime.enqueue(slow);
      const options = poolOptions(2);
      options.maxQueueSize = 0;
      const pool = createTestPool(runtime, options);
      const active = await pool.acquire();

      const first = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      await active.release();
      await first.finished;
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      const secondPendingWithReservation = !second.settled;
      const timersWithReservation = runtime.timers.size;

      slow.connectGate.resolve(undefined);
      await second.finished;
      if (first.value !== null) await first.value.destroy();
      if (second.value !== null) await second.value.destroy();
      await pool.close();

      expect(first.value !== null).assertTrue();
      expect(secondPendingWithReservation).assertTrue();
      expect(timersWithReservation).assertEqual(1);
      expect(second.error === null).assertTrue();
      expect(second.value !== null).assertTrue();
    });

    it('zeroQueueAcceptsWaiterCoveredByWarmupCreation', 0, async () => {
      const runtime = new PoolRuntime();
      const warmup = new PoolConnection(1);
      warmup.connectGate = new PoolDeferred<void>();
      runtime.enqueue(warmup);
      const options = poolOptions();
      options.minIdle = 1;
      options.maxQueueSize = 0;
      const pool = createTestPool(runtime, options);

      let completions = 0;
      const acquiring = pool.acquire();
      acquiring.then(
        (_lease: MySqlConnectionLease): void => {
          completions++;
        },
        (_error: Object): void => {
          completions++;
        });
      const outcome = new PoolOutcome<MySqlConnectionLease>(acquiring);
      await flushPool();
      const pendingDuringWarmup = !outcome.settled;
      const timersDuringWarmup = runtime.timers.size;

      warmup.connectGate.resolve(undefined);
      await outcome.finished;
      await flushPool();
      if (outcome.value !== null) {
        await outcome.value.session.query('SELECT warmup');
      }
      const createCallsAfterCompletion = runtime.createCalls;
      const timersAfterCompletion = runtime.timers.size;
      if (outcome.value !== null) await outcome.value.destroy();
      await pool.close();

      expect(pendingDuringWarmup).assertTrue();
      expect(timersDuringWarmup).assertEqual(1);
      expect(outcome.error === null).assertTrue();
      expect(outcome.value !== null).assertTrue();
      expect(completions).assertEqual(1);
      expect(createCallsAfterCompletion).assertEqual(1);
      expect(warmup.queryCalls).assertEqual(1);
      expect(timersAfterCompletion).assertEqual(0);
    });

    it('lateFailedDemandCreationIsReportedAfterTimedOutAcquire', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.connectGate = new PoolDeferred<void>();
      const connectFailure =
        ArkDbError.network('Synthetic late connect failure.');
      const cleanupFailure =
        ArkDbError.network('Synthetic late connect cleanup failure.');
      connection.connectFailure = connectFailure;
      connection.closeFailure = cleanupFailure;
      runtime.enqueue(connection);
      const options = poolOptions();
      options.acquireTimeoutMs = 10;
      const pool = createTestPool(runtime, options);

      const expired = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      runtime.timers.advance(10);
      await expired.finished;
      const timeoutFailure = expired.error;
      const timersAfterTimeout = runtime.timers.size;

      connection.connectGate.resolve(undefined);
      await flushPool();
      const closeFailure = await poolFailureOf<void>(pool.close());

      expect(timeoutFailure instanceof ArkDbError).assertTrue();
      expect((timeoutFailure as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(expired.error === timeoutFailure).assertTrue();
      expect(expired.value === null).assertTrue();
      expect(timersAfterTimeout).assertEqual(0);
      expect(connection.closeCalls).assertEqual(1);
      expect(closeFailure instanceof MySqlOperationError).assertTrue();
      if (closeFailure instanceof MySqlOperationError) {
        expect(closeFailure.primary === connectFailure).assertTrue();
        expect(closeFailure.cleanupErrors.length).assertEqual(1);
        expect(closeFailure.cleanupErrors[0] === cleanupFailure).assertTrue();
      }
    });

    it('lateAcquireCompletionCannotResurrectTimedOutWaiter', 0, async () => {
      const runtime = new PoolRuntime();
      const connecting = new PoolConnection(1);
      connecting.connectGate = new PoolDeferred<void>();
      runtime.enqueue(connecting);
      const options = poolOptions();
      options.acquireTimeoutMs = 10;
      const pool = createTestPool(runtime, options);

      const expired = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();
      runtime.timers.advance(10);
      await expired.finished;
      expect(expired.error instanceof ArkDbError).assertTrue();
      expect((expired.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);

      const successor = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      connecting.connectGate.resolve(undefined);
      await successor.finished;
      expect(successor.value !== null).assertTrue();
      expect(expired.value === null).assertTrue();
      await successor.value!.destroy();
      await pool.close();
    });

    it('failedCreationRejectsExactlyOneOldestWaiter', 0, async () => {
      const runtime = new PoolRuntime();
      const failed = new PoolConnection(1);
      failed.connectFailure = ArkDbError.network('Synthetic connect failure.');
      const replacement = new PoolConnection(2);
      runtime.enqueue(failed);
      runtime.enqueue(replacement);
      const pool = createTestPool(runtime);

      const first = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      const second = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await first.finished;
      await second.finished;
      expect(first.error instanceof ArkDbError).assertTrue();
      expect(second.value !== null).assertTrue();
      expect(runtime.createCalls).assertEqual(2);
      await second.value!.destroy();
      await pool.close();
    });

    it('resetFailureDiscardsPhysicalConnection', 0, async () => {
      const runtime = new PoolRuntime();
      const failed = new PoolConnection(1);
      failed.resetFailure = ArkDbError.network('Synthetic reset failure.');
      const replacement = new PoolConnection(2);
      runtime.enqueue(failed);
      runtime.enqueue(replacement);
      const pool = createTestPool(runtime);

      const first = await pool.acquire();
      const releaseFailure = await poolFailureOf<void>(first.release());
      expect(releaseFailure !== null).assertTrue();
      expect(failed.closeCalls).assertEqual(1);

      const second = await pool.acquire();
      await second.session.query('SELECT replacement');
      expect(failed.queryCalls).assertEqual(0);
      expect(replacement.queryCalls).assertEqual(1);
      expect(runtime.createCalls).assertEqual(2);
      await second.destroy();
      await pool.close();
    });

    it('destroyDispatchesQueuedSuccessorAfterSlotRemoval', 0, async () => {
      const runtime = new PoolRuntime();
      const firstConnection = new PoolConnection(1);
      const replacement = new PoolConnection(2);
      runtime.enqueue(firstConnection);
      runtime.enqueue(replacement);
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      const successor = new PoolOutcome<MySqlConnectionLease>(pool.acquire());

      await first.destroy();
      await flushPool();
      expect(successor.settled).assertTrue();
      expect(successor.value !== null).assertTrue();
      expect(runtime.createCalls).assertEqual(2);
      await successor.value!.destroy();
      await pool.close();
    });

    it('resetFailureDispatchesQueuedSuccessorAndKeepsReleaseError', 0, async () => {
      const runtime = new PoolRuntime();
      const failed = new PoolConnection(1);
      failed.resetFailure = ArkDbError.network('Synthetic queued reset failure.');
      const replacement = new PoolConnection(2);
      runtime.enqueue(failed);
      runtime.enqueue(replacement);
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      const successor = new PoolOutcome<MySqlConnectionLease>(pool.acquire());

      const releaseFailure = await poolFailureOf<void>(first.release());
      expect(releaseFailure instanceof MySqlOperationError).assertTrue();
      if (!(releaseFailure instanceof MySqlOperationError)) {
        throw new Error('Expected the reset release error graph.');
      }
      expect(releaseFailure.primary.message)
        .assertEqual('Synthetic queued reset failure.');
      await flushPool();
      expect(successor.settled).assertTrue();
      expect(successor.value !== null).assertTrue();
      expect(runtime.createCalls).assertEqual(2);
      await successor.value!.destroy();
      await pool.close();
    });

    it('resetAndPhysicalCloseFailuresRemainInOneErrorGraph', 0, async () => {
      const runtime = new PoolRuntime();
      const failed = new PoolConnection(1);
      failed.resetFailure = ArkDbError.network('Synthetic reset failure.');
      failed.closeFailure = ArkDbError.network('Synthetic physical close failure.');
      runtime.enqueue(failed);
      const pool = createTestPool(runtime);

      const lease = await pool.acquire();
      const failure = await poolFailureOf<void>(lease.release());
      expect(failure instanceof MySqlOperationError).assertTrue();
      if (!(failure instanceof MySqlOperationError)) {
        throw new Error('Expected one release error graph.');
      }
      expect(failure.primary.message).assertEqual('Synthetic reset failure.');
      expect(failure.cleanupErrors.length).assertEqual(1);
      expect(failure.cleanupErrors[0].message)
        .assertEqual('Synthetic physical close failure.');
      await pool.close();
    });

    it('defaultQueueRejectsWaiter65', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const active = await pool.acquire();
      const queued: PoolOutcome<MySqlConnectionLease>[] = [];
      for (let index = 0; index < 64; index++) {
        queued.push(new PoolOutcome<MySqlConnectionLease>(pool.acquire()));
      }
      const rejected = await poolFailureOf<MySqlConnectionLease>(pool.acquire());
      expect(rejected !== null).assertTrue();
      expect(rejected!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(runtime.createCalls).assertEqual(1);

      const closing = pool.close();
      await flushPool();
      for (const waiter of queued) {
        await waiter.finished;
        expect(waiter.error instanceof ArkDbError).assertTrue();
        expect((waiter.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Cancelled);
      }
      await active.release();
      await closing;
    });

    it('poolCloseDuringConnectDestroysLateCompletion', 0, async () => {
      const runtime = new PoolRuntime();
      const connecting = new PoolConnection(1);
      connecting.connectGate = new PoolDeferred<void>();
      runtime.enqueue(connecting);
      const pool = createTestPool(runtime);
      const acquire = new PoolOutcome<MySqlConnectionLease>(pool.acquire());
      await flushPool();

      const close = new PoolOutcome<void>(pool.close());
      await acquire.finished;
      expect(acquire.error instanceof ArkDbError).assertTrue();
      expect((acquire.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Cancelled);
      expect(close.settled).assertFalse();

      connecting.connectGate.resolve(undefined);
      await close.finished;
      expect(close.error === null).assertTrue();
      expect(connecting.closeCalls).assertEqual(1);
      expect(runtime.timers.size).assertEqual(0);
    });

    it('poolCloseClearsIdleAndCloseTimers', 0, async () => {
      const runtime = new PoolRuntime();
      const options = poolOptions();
      options.idleTimeoutMs = 50;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      await lease.release();
      expect(runtime.timers.size).assertEqual(1);

      await pool.close();
      expect(runtime.timers.size).assertEqual(0);
      expect(runtime.connections[0].closeCalls).assertEqual(1);
    });

    it('minIdleWarmupNeverExceedsMaxSize', 0, async () => {
      const runtime = new PoolRuntime();
      const options = poolOptions(2);
      options.minIdle = 2;
      options.idleTimeoutMs = 0;
      const pool = createTestPool(runtime, options);
      await flushPool();
      expect(runtime.createCalls).assertEqual(2);
      await pool.close();
      expect(runtime.connections[0].closeCalls).assertEqual(1);
      expect(runtime.connections[1].closeCalls).assertEqual(1);
    });

    it('idleExpiryNeverDropsBelowMinIdle', 0, async () => {
      const runtime = new PoolRuntime();
      const options = poolOptions(3);
      options.minIdle = 1;
      options.idleTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      await flushPool();
      const first = await pool.acquire();
      await flushPool();
      const second = await pool.acquire();
      await flushPool();
      const third = await pool.acquire();
      await first.release();
      await second.release();
      await third.release();

      runtime.timers.advance(10);
      await flushPool();
      const closed = runtime.connections.filter(
        (connection: PoolConnection): boolean => connection.closeCalls === 1);
      expect(closed.length).assertEqual(2);
      await pool.close();
      expect(runtime.connections.filter(
        (connection: PoolConnection): boolean => connection.closeCalls === 1).length)
        .assertEqual(3);
    });

    it('idleTimeoutZeroSchedulesNoEviction', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      await lease.release();
      expect(runtime.timers.size).assertEqual(0);
      runtime.timers.advance(1000);
      await flushPool();
      expect(runtime.connections[0].closeCalls).assertEqual(0);
      await pool.close();
    });

    it('poolCloseTimeoutRevokesAndDestroysOutstandingLease', 0, async () => {
      const runtime = new PoolRuntime();
      const options = poolOptions();
      options.closeTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const closing = new PoolOutcome<void>(pool.close());
      runtime.timers.advance(10);
      await closing.finished;
      expect(closing.error instanceof ArkDbError).assertTrue();
      expect((closing.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);
      const stale = await poolFailureOf<MySqlQueryResult>(
        lease.session.query('SELECT stale after close'));
      expect(stale !== null).assertTrue();
      expect(stale!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(runtime.connections[0].closeCalls).assertEqual(1);
      expect(runtime.timers.size).assertEqual(0);
    });

    it('poolCloseTimeoutDoesNotAwaitNeverSettlingStream', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.streamGate = new PoolDeferred<MySqlQueryExecutionSummary>();
      runtime.enqueue(connection);
      const options = poolOptions();
      options.closeTimeoutMs = 10;
      options.releaseTimeoutMs = 100;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const stream = new PoolOutcome<MySqlQueryExecutionSummary>(
        lease.session.queryStream('SELECT never', new QueryOptions(),
          new PoolResultSink()));
      await flushPool();

      const first = pool.close();
      const repeated = pool.close();
      const firstOutcome = new PoolOutcome<void>(first);
      const repeatedOutcome = new PoolOutcome<void>(repeated);
      expect(first === repeated).assertTrue();
      runtime.timers.advance(10);
      await flushPool();

      expect(firstOutcome.settled).assertTrue();
      expect(repeatedOutcome.settled).assertTrue();
      expect(firstOutcome.error instanceof ArkDbError).assertTrue();
      expect(firstOutcome.error === repeatedOutcome.error).assertTrue();
      expect((firstOutcome.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(stream.settled).assertFalse();
      expect(connection.closeCalls).assertEqual(1);
      expect(runtime.timers.size).assertEqual(0);
    });

    it('releaseAndPoolCloseBudgetsAbortOpeningCancellationControl', 0,
      async () => {
        const runtime = new CancellationPoolRuntime();
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        options.closeTimeoutMs = 20;
        const config = new ConnectionConfig();
        config.host = 'cancellation-pool.invalid';
        config.user = 'pool';
        config.ssl.mode = SslMode.DISABLED;
        const pool = createMySqlPoolInternal(
          new MySqlConnectionOptions(config, ''), options, runtime);
        const acquiring = pool.acquire();
        completeCancellationPoolConnect(runtime);
        const lease = await acquiring;
        const deadlines = lease.session.mysqlFeatures.deadlines;
        if (deadlines === undefined) {
          throw new Error('Expected deadline support.');
        }
        const deadlineOptions = new MySqlDeadlineOptions();
        deadlineOptions.timeoutMs = 5;
        deadlineOptions.cancellationGraceMs = 100;
        runtime.peer.holdCommand = 0x03;
        const running = new PoolOutcome<MySqlQueryResult>(
          deadlines.query('SELECT held cancellation', deadlineOptions));
        await flushPool();
        runtime.timers.advance(5);
        await runtime.control.connectEntered.promise;

        const release = new PoolOutcome<void>(lease.release());
        const closing = new PoolOutcome<void>(pool.close());
        runtime.timers.advance(20);
        await flushPool();
        const releaseSettledAtBudget = release.settled;
        const closeSettledAtBudget = closing.settled;
        const controlCloseCallsAtBudget = runtime.control.closeCalls;

        runtime.control.opening.resolve(undefined);
        await release.finished;
        await closing.finished;
        await running.finished;

        expect(releaseSettledAtBudget).assertTrue();
        expect(closeSettledAtBudget).assertTrue();
        expect(controlCloseCallsAtBudget).assertEqual(1);
        expect(release.error instanceof ArkDbError).assertTrue();
        expect((release.error as ArkDbError).kind)
          .assertEqual(ArkDbErrorKind.Timeout);
        expect(closing.error instanceof ArkDbError).assertTrue();
        expect((closing.error as ArkDbError).kind)
          .assertEqual(ArkDbErrorKind.Timeout);
        expect(runtime.timers.size).assertEqual(0);
      });

    it('releaseTimeoutCapturesPromptRootQueryFailureAfterClose', 0,
      async () => {
        const runtime = new CancellationPoolRuntime();
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const config = new ConnectionConfig();
        config.host = 'root-query-pool.invalid';
        config.user = 'pool';
        config.ssl.mode = SslMode.DISABLED;
        const pool = createMySqlPoolInternal(
          new MySqlConnectionOptions(config, ''), options, runtime);
        const acquiring = pool.acquire();
        completeCancellationPoolConnect(runtime);
        const lease = await acquiring;
        runtime.peer.holdCommand = 0x03;
        const query = new PoolOutcome<MySqlQueryResult>(
          lease.session.query('SELECT prompt close join'));
        await flushPool();

        const release = new PoolOutcome<void>(lease.release());
        runtime.timers.advance(10);
        await release.finished;
        await query.finished;
        const queryFailure = query.error;
        const releaseFailure = release.error;
        await pool.close();

        expect(queryFailure instanceof ArkDbError).assertTrue();
        expect(releaseFailure instanceof MySqlOperationError).assertTrue();
        expect(poolFailureContainsIdentity(releaseFailure!, queryFailure!))
          .assertTrue();
        expect(runtime.peer.closeCalls).assertEqual(1);
        expect(runtime.timers.size).assertEqual(0);
      });

    it('releaseTimeoutCapturesConsecutiveRootQueryFailureAfterClose', 0,
      async () => {
        const runtime = new CancellationPoolRuntime();
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const config = new ConnectionConfig();
        config.host = 'consecutive-root-query-pool.invalid';
        config.user = 'pool';
        config.ssl.mode = SslMode.DISABLED;
        const pool = createMySqlPoolInternal(
          new MySqlConnectionOptions(config, ''), options, runtime);
        const acquiring = pool.acquire();
        completeCancellationPoolConnect(runtime);
        const lease = await acquiring;
        runtime.peer.responses.push([okPayload()]);
        const firstQuery = lease.session.query('SELECT first query');
        const secondStarted =
          new PoolDeferred<PoolOutcome<MySqlQueryResult>>();
        await firstQuery.then((_result: MySqlQueryResult): void => {
          runtime.peer.holdCommand = 0x03;
          secondStarted.resolve(new PoolOutcome<MySqlQueryResult>(
            lease.session.query('SELECT consecutive held query')));
        });
        const secondQuery = await secondStarted.promise;
        await flushPool();

        const release = new PoolOutcome<void>(lease.release());
        runtime.timers.advance(10);
        await release.finished;
        await secondQuery.finished;
        const queryFailure = secondQuery.error;
        const releaseFailure = release.error;
        await pool.close();

        expect(queryFailure instanceof ArkDbError).assertTrue();
        expect(releaseFailure instanceof MySqlOperationError).assertTrue();
        expect(poolFailureContainsIdentity(releaseFailure!, queryFailure!))
          .assertTrue();
        expect(runtime.peer.closeCalls).assertEqual(1);
        expect(runtime.timers.size).assertEqual(0);
      });

    it('releaseTimeoutCapturesTerminalReentrantRootQueryFailureAfterClose', 0,
      async () => {
        const runtime = new ObservedPoolRuntime();
        const observer = new TerminalQueryReentryObserver();
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const pool = createObservedPool(runtime, observer, options);
        const acquiring = pool.acquire();
        completeObservedConnect(runtime);
        const lease = await acquiring;
        observer.lease = lease;
        runtime.peer.holdCommand = 0x03;
        const firstQuery = new PoolOutcome<MySqlQueryResult>(
          lease.session.query('SELECT first terminal query'));
        await flushPool();

        const rejectedOverlap = new PoolOutcome<MySqlQueryResult>(
          lease.session.query('SELECT rejected overlap'));
        await rejectedOverlap.finished;
        expect(rejectedOverlap.error instanceof ArkDbError).assertTrue();
        expect((rejectedOverlap.error as ArkDbError).kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect(firstQuery.settled).assertFalse();

        runtime.peer.emitResponse([okPayload()]);
        await firstQuery.finished;
        const secondQuery = new PoolOutcome<MySqlQueryResult>(
          observer.requireSecondQuery());
        await flushPool();
        expect(firstQuery.error === null).assertTrue();
        expect(secondQuery.settled).assertFalse();

        const release = new PoolOutcome<void>(lease.release());
        runtime.timers.advance(10);
        await release.finished;
        await secondQuery.finished;
        const queryFailure = secondQuery.error;
        const releaseFailure = release.error;
        await pool.close();

        expect(queryFailure instanceof ArkDbError).assertTrue();
        expect(releaseFailure instanceof MySqlOperationError).assertTrue();
        expect(poolFailureContainsIdentity(releaseFailure!, queryFailure!))
          .assertTrue();
        expect(poolFailureContainsIdentity(
          releaseFailure!, rejectedOverlap.error!)).assertFalse();
        expect(runtime.peer.closeCalls).assertEqual(1);
        expect(runtime.timers.size).assertEqual(0);
      });

    it('sameTurnRejectedOverlapCannotPoisonRelease', 0, async () => {
      const runtime = new CancellationPoolRuntime();
      const config = new ConnectionConfig();
      config.host = 'same-turn-overlap-pool.invalid';
      config.user = 'pool';
      config.ssl.mode = SslMode.DISABLED;
      const pool = createMySqlPoolInternal(
        new MySqlConnectionOptions(config, ''), poolOptions(), runtime);
      const acquiring = pool.acquire();
      completeCancellationPoolConnect(runtime);
      const lease = await acquiring;
      runtime.peer.holdCommand = 0x03;
      runtime.peer.onCommand = (command: number): void => {
        if (command !== 0x1f) return;
        runtime.peer.holdCommand = -1;
        runtime.peer.responses.push(
          [okPayload()], poolResetFingerprintResult());
        Promise.resolve().then((): void => {
          runtime.peer.emitResponse([okPayload()]);
        });
      };
      const query = new PoolOutcome<MySqlQueryResult>(
        lease.session.query('SELECT admitted query'));
      await flushPool();

      const rejectedOverlap = new PoolOutcome<MySqlQueryResult>(
        lease.session.query('SELECT rejected same-turn overlap'));
      const release = new PoolOutcome<void>(lease.release());
      runtime.peer.emitResponse([okPayload()]);
      await query.finished;
      await rejectedOverlap.finished;
      await release.finished;
      const overlapFailure = rejectedOverlap.error;
      const releaseFailure = release.error;
      const closeCallsBeforePoolClose = runtime.peer.closeCalls;
      const closing = new PoolOutcome<void>(pool.close());
      await closing.finished;

      expect(query.error === null).assertTrue();
      expect(overlapFailure instanceof ArkDbError).assertTrue();
      expect((overlapFailure as ArkDbError).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      const releaseContainsOverlap = releaseFailure !== null &&
        poolFailureContainsIdentity(releaseFailure, overlapFailure!);
      const closeContainsOverlap = closing.error !== null &&
        poolFailureContainsIdentity(closing.error, overlapFailure!);
      expect(releaseContainsOverlap).assertFalse();
      expect(releaseFailure === null).assertTrue();
      expect(closeContainsOverlap).assertFalse();
      expect(closing.error === null).assertTrue();
      expect(closeCallsBeforePoolClose).assertEqual(0);
      expect(runtime.peer.closeCalls).assertEqual(1);
      expect(runtime.timers.size).assertEqual(0);
    });

    it('poolOptionsRejectEveryOutOfRangeValue', 0, () => {
      const invalid: MySqlPoolOptions[] = [];
      const maxSize = new MySqlPoolOptions();
      maxSize.maxSize = 65;
      invalid.push(maxSize);
      const minIdle = new MySqlPoolOptions();
      minIdle.maxSize = 1;
      minIdle.minIdle = 2;
      invalid.push(minIdle);
      const queue = new MySqlPoolOptions();
      queue.maxQueueSize = 4097;
      invalid.push(queue);
      const acquire = new MySqlPoolOptions();
      acquire.acquireTimeoutMs = 0;
      invalid.push(acquire);
      const release = new MySqlPoolOptions();
      release.releaseTimeoutMs = 60001;
      invalid.push(release);
      const idle = new MySqlPoolOptions();
      idle.idleTimeoutMs = -1;
      invalid.push(idle);
      const close = new MySqlPoolOptions();
      close.closeTimeoutMs = 0;
      invalid.push(close);
      for (const options of invalid) {
        expect(options.validate().length).assertEqual(1);
        expect(options.validate()[0].kind).assertEqual(ArkDbErrorKind.Validation);
      }
    });
  });
}
