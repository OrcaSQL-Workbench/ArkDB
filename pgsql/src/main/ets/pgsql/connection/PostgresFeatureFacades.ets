import {
  ArkDbError, ConnectionState, DbConnection, DbConnectionFeatures, DbConnectionHealth,
  DbStreamingConnection, QueryExecutionSummary, QueryOptions, QueryResult, QueryResultSink, ServerInfo
} from '@arkdb/core';

type StreamRunner = (sql: string, options: QueryOptions, sink: QueryResultSink) => Promise<QueryExecutionSummary>;
interface StreamingDelegate { readonly connection: DbConnection; readonly runStream: StreamRunner; }
const streamingDelegates: WeakMap<PostgresConnectionStreaming, StreamingDelegate> = new WeakMap<PostgresConnectionStreaming, StreamingDelegate>();

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
