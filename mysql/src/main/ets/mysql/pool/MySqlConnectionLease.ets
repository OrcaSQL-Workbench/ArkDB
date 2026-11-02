import { ArkDbError, QueryOptions } from '@arkdb/core';
import { MySqlConnection } from '../MySqlConnection';
import { MySqlLongDataExecutor } from '../command/LongData';
import { MySqlConnectionFeatures } from '../driver/MySqlConnectionFeatures';
import {
  MySqlCursor, MySqlCursorExecutor
} from '../driver/MySqlCursorContracts';
import {
  MySqlPreparedExecutor, MySqlPreparedStatement
} from '../driver/MySqlPreparedContracts';
import { MySqlSession } from '../driver/MySqlSession';
import { MySqlBatchExecutor } from '../execution/MySqlBatchExecutor';
import { MySqlDeadlineExecutor } from '../execution/MySqlDeadlineExecutor';
import { MySqlInsertRowsExecutor } from '../execution/MySqlInsertRowsExecutor';
import { MySqlNamedExecutor } from '../execution/MySqlNamedExecutor';
import { MySqlProcedureCaller } from '../execution/MySqlProcedureCaller';
import { MySqlTransactionRunner } from '../execution/MySqlTransactionRunner';
import { MySqlBatchOptions, MySqlBatchResult } from '../model/MySqlBatch';
import { MySqlDeadlineOptions } from '../model/MySqlDeadlineOptions';
import { MySqlInsertRowsOptions } from '../model/MySqlInsertRows';
import { MySqlCursorOptions } from '../model/MySqlCursorOptions';
import {
  MySqlLongDataOptions, MySqlLongParameter
} from '../model/MySqlLongDataOptions';
import { MySqlNamedParameter } from '../model/MySqlNamedParameter';
import { MySqlParameter } from '../model/MySqlParameter';
import {
  MySqlProcedureArgument, MySqlProcedureResult
} from '../model/MySqlProcedure';
import {
  MySqlColumnDef, MySqlQueryResult, MySqlValue
} from '../model/MySqlQueryResult';
import { MySqlServerInfo } from '../model/MySqlServerInfo';
import {
  MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';
import { MySqlTransactionOptions } from '../model/MySqlTransactionOptions';

export interface MySqlConnectionLease {
  readonly session: MySqlSession;
  release(): Promise<void>;
  destroy(): Promise<void>;
}

export interface MySqlPoolConnection extends MySqlSession {
  connect(): Promise<void>;
  close(): Promise<void>;
}

export class MySqlPoolConnectionAdapter implements MySqlPoolConnection {
  private root: MySqlConnection;

  constructor(root: MySqlConnection) {
    this.root = root;
  }

  get mysqlFeatures(): MySqlConnectionFeatures {
    return this.root.mysqlFeatures;
  }

  get serverInfo(): MySqlServerInfo {
    return this.root.serverInfo;
  }

  get sessionStatus(): MySqlDatabaseSessionStatus {
    return this.root.sessionStatus;
  }

  connect(): Promise<void> {
    return this.root.connect();
  }

  close(): Promise<void> {
    return this.root.close();
  }

  query(sql: string): Promise<MySqlQueryResult> {
    return this.root.query(sql);
  }

  queryStream(sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.root.queryStream(sql, options, sink);
  }

  savepoint(name: string): Promise<void> {
    return this.root.savepoint(name);
  }

  rollbackTo(name: string): Promise<void> {
    return this.root.rollbackTo(name);
  }

  releaseSavepoint(name: string): Promise<void> {
    return this.root.releaseSavepoint(name);
  }
}

export type MySqlLeaseFinish =
  (context: MySqlLeaseContext) => Promise<void>;
type MySqlLeaseForceHandler = (error: ArkDbError) => void;

class LeaseOperation {
  readonly settlement: Promise<Object | null>;
  private settle: (failure: Object | null) => void =
    (_failure: Object | null): void => {};

  constructor() {
    this.settlement = new Promise<Object | null>(
      (resolve: (failure: Object | null) => void): void => {
        this.settle = resolve;
      });
  }

  observe<T>(operation: Promise<T>): void {
    operation.then(
      (_value: T): void => this.settle(null),
      (error: Object): void => this.settle(error));
  }

  fail(error: Object): void {
    this.settle(error);
  }
}

class LeaseVoidTask {
  readonly promise: Promise<void>;
  private resolvePromise: () => void = (): void => {};
  private rejectPromise: (error: Object) => void = (_error: Object): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve: () => void,
      reject: (error: Object) => void): void => {
      this.resolvePromise = resolve;
      this.rejectPromise = reject;
    });
  }

  follow(start: () => Promise<void>): void {
    let task: Promise<void>;
    try {
      task = start();
    } catch (error) {
      this.rejectPromise(error as Object);
      return;
    }
    task.then(
      (): void => this.resolvePromise(),
      (error: Object): void => this.rejectPromise(error));
  }
}

export class MySqlLeaseContext {
  readonly connection: MySqlPoolConnection;
  destroyRequested: boolean = false;
  private active: boolean = true;
  private finish: MySqlLeaseFinish;
  private terminal: Promise<void> | null = null;
  private operations: LeaseOperation[] = [];
  private cursors: LeaseCursor[] = [];
  private statements: LeasePreparedStatement[] = [];
  private forceError: ArkDbError | null = null;
  private forceHandlers: MySqlLeaseForceHandler[] = [];

  constructor(connection: MySqlPoolConnection, finish: MySqlLeaseFinish) {
    this.connection = connection;
    this.finish = finish;
  }

  get isActive(): boolean {
    return this.active;
  }

  get forcedFailure(): ArkDbError | null {
    return this.forceError;
  }

  requestFinish(destroy: boolean): Promise<void> {
    if (destroy) this.destroyRequested = true;
    if (this.terminal !== null) return this.terminal;
    this.active = false;
    return this.startFinish();
  }

  forceFinish(error: ArkDbError): Promise<void> {
    this.destroyRequested = true;
    this.active = false;
    if (this.forceError === null) {
      this.forceError = error;
      const handlers = this.forceHandlers;
      this.forceHandlers = [];
      for (const handler of handlers) handler(error);
    }
    if (this.terminal !== null) return this.terminal;
    return this.startFinish();
  }

  private startFinish(): Promise<void> {
    const published = new LeaseVoidTask();
    this.terminal = published.promise;
    this.terminal.catch((_error: Object): void => {});
    published.follow((): Promise<void> => this.finish(this));
    return this.terminal;
  }

  onForce(handler: MySqlLeaseForceHandler): void {
    if (this.forceError !== null) {
      handler(this.forceError);
      return;
    }
    this.forceHandlers.push(handler);
  }

  assertActive(): void {
    if (!this.active) {
      throw ArkDbError.validation('The MySQL connection lease is no longer active.');
    }
  }

  runOperation<T>(operation: () => Promise<T>): Promise<T> {
    const tracked = new LeaseOperation();
    this.operations.push(tracked);
    tracked.settlement.then((): void => {
      const index = this.operations.indexOf(tracked);
      if (index >= 0) this.operations.splice(index, 1);
    });
    let task: Promise<T>;
    try {
      this.assertActive();
      task = operation();
    } catch (error) {
      tracked.fail(error as Object);
      return Promise.reject(error as Object);
    }
    tracked.observe(task);
    return task;
  }

  async waitForOperations(): Promise<Object[]> {
    const pending = this.operations.slice();
    const failures: Object[] = [];
    for (const operation of pending) {
      const failure = await operation.settlement;
      if (failure !== null) failures.push(failure);
    }
    return failures;
  }

  async closeStatements(): Promise<Object[]> {
    const owned = this.statements.slice();
    const failures: Object[] = [];
    for (const statement of owned) {
      try {
        await statement.closeForRelease();
      } catch (error) {
        failures.push(error as Object);
      }
    }
    return failures;
  }

  async closeCursors(): Promise<Object[]> {
    const owned = this.cursors.slice();
    const failures: Object[] = [];
    for (const cursor of owned) {
      try {
        await cursor.closeForRelease();
      } catch (error) {
        failures.push(error as Object);
      }
    }
    return failures;
  }

  wrapCursor(cursor: MySqlCursor): MySqlCursor {
    const wrapped = new LeaseCursor(this, cursor);
    this.cursors.push(wrapped);
    return wrapped;
  }

  forgetCursor(cursor: LeaseCursor): void {
    const index = this.cursors.indexOf(cursor);
    if (index >= 0) this.cursors.splice(index, 1);
  }

  wrapStatement(statement: MySqlPreparedStatement): MySqlPreparedStatement {
    const wrapped = new LeasePreparedStatement(this, statement);
    this.statements.push(wrapped);
    return wrapped;
  }

  forgetStatement(statement: LeasePreparedStatement): void {
    const index = this.statements.indexOf(statement);
    if (index >= 0) this.statements.splice(index, 1);
  }

  requireStatement(statement: MySqlPreparedStatement): MySqlPreparedStatement {
    this.assertActive();
    if (!(statement instanceof LeasePreparedStatement)) {
      throw ArkDbError.validation(
        'Long-data statements must belong to the active MySQL lease.');
    }
    return statement.unwrap(this);
  }
}

export class PooledMySqlConnectionLease implements MySqlConnectionLease {
  readonly session: MySqlSession;
  private context: MySqlLeaseContext;

  constructor(context: MySqlLeaseContext) {
    this.context = context;
    this.session = new LeaseSession(context, context.connection);
  }

  release(): Promise<void> {
    return this.context.requestFinish(false);
  }

  destroy(): Promise<void> {
    return this.context.requestFinish(true);
  }
}

class LeaseSession implements MySqlSession {
  private context: MySqlLeaseContext;
  private root: MySqlSession;
  private features: MySqlConnectionFeatures;

  constructor(context: MySqlLeaseContext, root: MySqlSession) {
    this.context = context;
    this.root = root;
    this.features = leaseFeatures(context, root.mysqlFeatures);
  }

  get mysqlFeatures(): MySqlConnectionFeatures {
    this.context.assertActive();
    return this.features;
  }

  get serverInfo(): MySqlServerInfo {
    this.context.assertActive();
    return cloneServerInfo(this.root.serverInfo);
  }

  get sessionStatus(): MySqlDatabaseSessionStatus {
    this.context.assertActive();
    return this.root.sessionStatus.clone();
  }

  query(sql: string): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> => this.root.query(sql));
  }

  queryStream(sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.context.runOperation(
      (): Promise<MySqlQueryExecutionSummary> =>
        this.root.queryStream(sql, options, sink));
  }

  savepoint(name: string): Promise<void> {
    return this.context.runOperation(
      (): Promise<void> => this.root.savepoint(name));
  }

  rollbackTo(name: string): Promise<void> {
    return this.context.runOperation(
      (): Promise<void> => this.root.rollbackTo(name));
  }

  releaseSavepoint(name: string): Promise<void> {
    return this.context.runOperation(
      (): Promise<void> => this.root.releaseSavepoint(name));
  }
}

class LeaseScopedTransactionSession implements MySqlSession {
  private context: MySqlLeaseContext;
  private root: MySqlSession;
  private features: MySqlConnectionFeatures = new MySqlConnectionFeatures();

  constructor(context: MySqlLeaseContext, root: MySqlSession) {
    this.context = context;
    this.root = root;
    const insertRows = root.mysqlFeatures.insertRows;
    if (insertRows !== undefined) {
      this.features.insertRows = new LeaseInsertRowsExecutor(context, insertRows);
    }
  }

  get mysqlFeatures(): MySqlConnectionFeatures {
    this.context.assertActive();
    return this.features;
  }

  get serverInfo(): MySqlServerInfo {
    this.context.assertActive();
    return cloneServerInfo(this.root.serverInfo);
  }

  get sessionStatus(): MySqlDatabaseSessionStatus {
    this.context.assertActive();
    return this.root.sessionStatus.clone();
  }

  query(sql: string): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> => this.root.query(sql));
  }

  queryStream(sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.context.runOperation(
      (): Promise<MySqlQueryExecutionSummary> =>
        this.root.queryStream(sql, options, sink));
  }

  savepoint(name: string): Promise<void> {
    return this.context.runOperation(
      (): Promise<void> => this.root.savepoint(name));
  }

  rollbackTo(name: string): Promise<void> {
    return this.context.runOperation(
      (): Promise<void> => this.root.rollbackTo(name));
  }

  releaseSavepoint(name: string): Promise<void> {
    return this.context.runOperation(
      (): Promise<void> => this.root.releaseSavepoint(name));
  }
}

class LeasePreparedExecutor implements MySqlPreparedExecutor {
  private context: MySqlLeaseContext;
  private root: MySqlPreparedExecutor;

  constructor(context: MySqlLeaseContext, root: MySqlPreparedExecutor) {
    this.context = context;
    this.root = root;
  }

  prepare(sql: string): Promise<MySqlPreparedStatement> {
    return this.context.runOperation(
      (): Promise<MySqlPreparedStatement> => this.root.prepare(sql))
      .then((statement: MySqlPreparedStatement): MySqlPreparedStatement =>
        this.context.wrapStatement(statement));
  }

  execute(sql: string, parameters: MySqlParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> =>
        this.root.execute(sql, parameters, options));
  }

  executeStream(sql: string, parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.context.runOperation(
      (): Promise<MySqlQueryExecutionSummary> =>
        this.root.executeStream(sql, parameters, options, sink));
  }
}

class LeaseCursorExecutor implements MySqlCursorExecutor {
  private context: MySqlLeaseContext;
  private root: MySqlCursorExecutor;

  constructor(context: MySqlLeaseContext, root: MySqlCursorExecutor) {
    this.context = context;
    this.root = root;
  }

  open(sql: string, parameters: MySqlParameter[],
    options?: MySqlCursorOptions): Promise<MySqlCursor> {
    return this.context.runOperation(
      (): Promise<MySqlCursor> => this.root.open(sql, parameters, options))
      .then((cursor: MySqlCursor): MySqlCursor =>
        this.context.wrapCursor(cursor));
  }
}

class LeaseCursor implements MySqlCursor {
  private context: MySqlLeaseContext;
  private root: MySqlCursor;
  private publicCloseTask: Promise<void> | null = null;
  private releaseCloseTask: Promise<void> | null = null;

  constructor(context: MySqlLeaseContext, root: MySqlCursor) {
    this.context = context;
    this.root = root;
  }

  get columns(): MySqlColumnDef[] {
    this.context.assertActive();
    return this.root.columns;
  }

  get done(): boolean {
    this.context.assertActive();
    return this.root.done;
  }

  fetch(): Promise<MySqlValue[][]> {
    return this.context.runOperation(
      (): Promise<MySqlValue[][]> => this.root.fetch());
  }

  close(): Promise<void> {
    if (this.publicCloseTask !== null) return this.publicCloseTask;
    const active = this.context.isActive;
    const closing = this.context.runOperation(
      (): Promise<void> => this.root.close());
    this.publicCloseTask = closing.then((): void => {
      this.context.forgetCursor(this);
    });
    if (active) this.releaseCloseTask = this.publicCloseTask;
    this.publicCloseTask.catch((_error: Object): void => {});
    return this.publicCloseTask;
  }

  async closeForRelease(): Promise<void> {
    if (this.releaseCloseTask !== null) {
      await this.releaseCloseTask;
      return;
    }
    if (this.root.done) {
      this.context.forgetCursor(this);
      return;
    }
    this.releaseCloseTask = this.root.close().then((): void => {
      this.context.forgetCursor(this);
    });
    this.releaseCloseTask.catch((_error: Object): void => {});
    await this.releaseCloseTask;
  }
}

class LeasePreparedStatement implements MySqlPreparedStatement {
  private context: MySqlLeaseContext;
  private root: MySqlPreparedStatement;
  private locallyClosed: boolean = false;
  private publicCloseTask: Promise<void> | null = null;
  private releaseCloseTask: Promise<void> | null = null;

  constructor(context: MySqlLeaseContext, root: MySqlPreparedStatement) {
    this.context = context;
    this.root = root;
  }

  get closed(): boolean {
    return !this.context.isActive || this.locallyClosed || this.root.closed;
  }

  get parameterCount(): number {
    this.context.assertActive();
    return this.root.parameterCount;
  }

  get columns(): MySqlColumnDef[] {
    this.context.assertActive();
    return this.root.columns.slice();
  }

  execute(parameters: MySqlParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> =>
        this.root.execute(parameters, options));
  }

  executeStream(parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.context.runOperation(
      (): Promise<MySqlQueryExecutionSummary> =>
        this.root.executeStream(parameters, options, sink));
  }

  close(): Promise<void> {
    if (this.publicCloseTask !== null) return this.publicCloseTask;
    const active = this.context.isActive;
    const published = new LeaseVoidTask();
    this.publicCloseTask = published.promise;
    if (active) this.releaseCloseTask = published.promise;
    published.promise.catch((_error: Object): void => {});
    published.follow((): Promise<void> =>
      this.context.runOperation(
        (): Promise<void> => this.root.close()).then((): void => {
        this.locallyClosed = true;
        this.context.forgetStatement(this);
      }));
    return published.promise;
  }

  async closeForRelease(): Promise<void> {
    if (this.releaseCloseTask !== null) {
      await this.releaseCloseTask;
      return;
    }
    if (this.locallyClosed || this.root.closed) return;
    this.releaseCloseTask = this.root.close().then((): void => {
      this.locallyClosed = true;
      this.context.forgetStatement(this);
    });
    this.releaseCloseTask.catch((_error: Object): void => {});
    await this.releaseCloseTask;
  }

  unwrap(context: MySqlLeaseContext): MySqlPreparedStatement {
    if (context !== this.context) {
      throw ArkDbError.validation(
        'The prepared statement belongs to another MySQL lease.');
    }
    this.context.assertActive();
    return this.root;
  }
}

class LeaseBatchExecutor implements MySqlBatchExecutor {
  private context: MySqlLeaseContext;
  private root: MySqlBatchExecutor;

  constructor(context: MySqlLeaseContext, root: MySqlBatchExecutor) {
    this.context = context;
    this.root = root;
  }

  execute(sql: string, rows: MySqlParameter[][],
    options?: MySqlBatchOptions): Promise<MySqlBatchResult> {
    return this.context.runOperation(
      (): Promise<MySqlBatchResult> => this.root.execute(sql, rows, options));
  }
}

class LeaseDeadlineExecutor implements MySqlDeadlineExecutor {
  private context: MySqlLeaseContext;
  private root: MySqlDeadlineExecutor;

  constructor(context: MySqlLeaseContext, root: MySqlDeadlineExecutor) {
    this.context = context;
    this.root = root;
  }

  query(sql: string, options?: MySqlDeadlineOptions): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> => this.root.query(sql, options));
  }

  execute(sql: string, parameters: MySqlParameter[],
    options?: MySqlDeadlineOptions): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> =>
        this.root.execute(sql, parameters, options));
  }
}

class LeaseInsertRowsExecutor implements MySqlInsertRowsExecutor {
  private context: MySqlLeaseContext;
  private root: MySqlInsertRowsExecutor;

  constructor(context: MySqlLeaseContext, root: MySqlInsertRowsExecutor) {
    this.context = context;
    this.root = root;
  }

  execute(tableParts: string[], columns: string[], rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions): Promise<MySqlBatchResult> {
    return this.context.runOperation(
      (): Promise<MySqlBatchResult> =>
        this.root.execute(tableParts, columns, rows, options));
  }
}

class LeaseLongDataExecutor implements MySqlLongDataExecutor {
  private context: MySqlLeaseContext;
  private root: MySqlLongDataExecutor;

  constructor(context: MySqlLeaseContext, root: MySqlLongDataExecutor) {
    this.context = context;
    this.root = root;
  }

  execute(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    sources: MySqlLongParameter[],
    options?: MySqlLongDataOptions): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> =>
        this.root.execute(
          this.context.requireStatement(statement),
          parameters, sources, options));
  }
}

class LeaseNamedExecutor implements MySqlNamedExecutor {
  private context: MySqlLeaseContext;
  private root: MySqlNamedExecutor;

  constructor(context: MySqlLeaseContext, root: MySqlNamedExecutor) {
    this.context = context;
    this.root = root;
  }

  execute(sql: string, parameters: MySqlNamedParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    return this.context.runOperation(
      (): Promise<MySqlQueryResult> =>
        this.root.execute(sql, parameters, options));
  }

  executeStream(sql: string, parameters: MySqlNamedParameter[],
    options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.context.runOperation(
      (): Promise<MySqlQueryExecutionSummary> =>
        this.root.executeStream(sql, parameters, options, sink));
  }
}

class LeaseProcedureCaller implements MySqlProcedureCaller {
  private context: MySqlLeaseContext;
  private root: MySqlProcedureCaller;

  constructor(context: MySqlLeaseContext, root: MySqlProcedureCaller) {
    this.context = context;
    this.root = root;
  }

  call(procedure: string[], procedureArguments: MySqlProcedureArgument[],
    options?: QueryOptions): Promise<MySqlProcedureResult> {
    return this.context.runOperation(
      (): Promise<MySqlProcedureResult> =>
        this.root.call(procedure, procedureArguments, options));
  }
}

class LeaseTransactionRunner implements MySqlTransactionRunner {
  private context: MySqlLeaseContext;
  private root: MySqlTransactionRunner;

  constructor(context: MySqlLeaseContext, root: MySqlTransactionRunner) {
    this.context = context;
    this.root = root;
  }

  run<T>(options: MySqlTransactionOptions,
    body: (session: MySqlSession) => Promise<T>): Promise<T> {
    return this.context.runOperation(
      (): Promise<T> => this.root.run<T>(options,
        (session: MySqlSession): Promise<T> =>
          body(new LeaseScopedTransactionSession(this.context, session))));
  }
}

function leaseFeatures(context: MySqlLeaseContext,
  root: MySqlConnectionFeatures): MySqlConnectionFeatures {
  const features = new MySqlConnectionFeatures();
  if (root.batch !== undefined) {
    features.batch = new LeaseBatchExecutor(context, root.batch);
  }
  if (root.cursors !== undefined) {
    features.cursors = new LeaseCursorExecutor(context, root.cursors);
  }
  if (root.deadlines !== undefined) {
    features.deadlines = new LeaseDeadlineExecutor(context, root.deadlines);
  }
  if (root.insertRows !== undefined) {
    features.insertRows = new LeaseInsertRowsExecutor(context, root.insertRows);
  }
  if (root.longData !== undefined) {
    features.longData = new LeaseLongDataExecutor(context, root.longData);
  }
  if (root.named !== undefined) {
    features.named = new LeaseNamedExecutor(context, root.named);
  }
  if (root.prepared !== undefined) {
    features.prepared = new LeasePreparedExecutor(context, root.prepared);
  }
  if (root.procedures !== undefined) {
    features.procedures = new LeaseProcedureCaller(context, root.procedures);
  }
  if (root.transactions !== undefined) {
    features.transactions = new LeaseTransactionRunner(context, root.transactions);
  }
  return features;
}

function cloneServerInfo(value: MySqlServerInfo): MySqlServerInfo {
  const copy = new MySqlServerInfo();
  copy.driverId = value.driverId;
  copy.productName = value.productName;
  copy.connectionHandle = value.connectionHandle;
  copy.defaultEncoding = value.defaultEncoding;
  copy.version = value.version;
  copy.tlsActive = value.tlsActive;
  copy.family = value.family;
  copy.nativeCapabilities = value.nativeCapabilities;
  copy.protocolVersion = value.protocolVersion;
  copy.connectionId = value.connectionId;
  copy.capabilities = value.capabilities;
  copy.charset = value.charset;
  copy.authPlugin = value.authPlugin;
  return copy;
}
