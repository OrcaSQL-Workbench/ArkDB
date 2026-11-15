import {
  ArkDbError, ConnectionState, ContextChangeMode, DatabaseContext, DatabaseContextPolicy,
  DatabaseSessionStatus, DbConnection, DbConnectionFeatures, DbConnectionHealth,
  DbContextController, DbStreamingConnection, DbTransactionController,
  QueryExecutionSummary, QueryOptions, QueryResult, QueryResultSink, ServerInfo
} from '@arkdb/core';

type StreamRunner = (sql: string, options: QueryOptions, sink: QueryResultSink) => Promise<QueryExecutionSummary>;
interface StreamingDelegate { readonly connection: DbConnection; readonly runStream: StreamRunner; }
const streamingDelegates: WeakMap<PostgresConnectionStreaming, StreamingDelegate> = new WeakMap<PostgresConnectionStreaming, StreamingDelegate>();
interface ContextDelegate {
  readonly getPolicy: () => DatabaseContextPolicy;
  readonly runChangeContext: (context: DatabaseContext) => Promise<void>;
}
const contextDelegates: WeakMap<PostgresConnectionContext, ContextDelegate> =
  new WeakMap<PostgresConnectionContext, ContextDelegate>();
const transactionDelegates: WeakMap<PostgresConnectionTransactions, DbTransactionController> =
  new WeakMap<PostgresConnectionTransactions, DbTransactionController>();

export function createPostgresContextPolicy(): DatabaseContextPolicy {
  const policy = new DatabaseContextPolicy();
  policy.catalogChange = ContextChangeMode.Reconnect;
  policy.schemaChange = ContextChangeMode.InPlace;
  policy.catalogsAreSchemas = false;
  return policy;
}

export class PostgresConnectionStreaming implements DbStreamingConnection {
  constructor(connection: DbConnection, runStream: StreamRunner) {
    streamingDelegates.set(this, { connection: connection, runStream: runStream });
  }
  get state(): ConnectionState { return this.delegate().connection.state; }
  get serverInfo(): ServerInfo { return this.delegate().connection.serverInfo; }
  get features(): DbConnectionFeatures | undefined { return this.delegate().connection.features; }
  connect(): Promise<void> { return this.delegate().connection.connect(); }
  query(sql: string): Promise<QueryResult> { return this.delegate().connection.query(sql); }
  close(): Promise<void> { return this.delegate().connection.close(); }
  queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> { return this.delegate().runStream(sql, options, sink); }
  private delegate(): StreamingDelegate {
    const d = streamingDelegates.get(this);
    if (d === undefined) throw ArkDbError.protocol('PostgreSQL streaming facade is uninitialized.');
    return d;
  }
}

export class PostgresConnectionHealth implements DbConnectionHealth {
  private readonly runPing: () => Promise<void>;
  constructor(runPing: () => Promise<void>) { this.runPing = runPing; }
  ping(): Promise<void> { return this.runPing(); }
}

export class PostgresConnectionContext implements DbContextController {
  constructor(getPolicy: () => DatabaseContextPolicy,
    runChangeContext: (context: DatabaseContext) => Promise<void>) {
    contextDelegates.set(this, { getPolicy: getPolicy, runChangeContext: runChangeContext });
  }
  get contextPolicy(): DatabaseContextPolicy { return this.delegate().getPolicy(); }
  changeContext(context: DatabaseContext): Promise<void> {
    return this.delegate().runChangeContext(context);
  }
  private delegate(): ContextDelegate {
    const d = contextDelegates.get(this);
    if (d === undefined) throw ArkDbError.protocol('PostgreSQL context facade is uninitialized.');
    return d;
  }
}

export class PostgresConnectionTransactions implements DbTransactionController {
  constructor(controller: DbTransactionController) {
    if (controller === null || controller === undefined) {
      throw ArkDbError.validation('PostgreSQL transaction controller is required.');
    }
    transactionDelegates.set(this, controller);
  }
  get sessionStatus(): DatabaseSessionStatus {
    return this.delegate().sessionStatus.clone();
  }
  begin(): Promise<DatabaseSessionStatus> { return this.delegate().begin(); }
  commit(): Promise<DatabaseSessionStatus> { return this.delegate().commit(); }
  rollback(): Promise<DatabaseSessionStatus> { return this.delegate().rollback(); }
  private delegate(): DbTransactionController {
    const d = transactionDelegates.get(this);
    if (d === undefined) throw ArkDbError.protocol('PostgreSQL transaction facade is uninitialized.');
    return d;
  }
}
