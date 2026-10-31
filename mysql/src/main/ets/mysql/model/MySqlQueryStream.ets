import {
  ArkDbError, DatabaseSessionStatus, DbConnection, DbConnectionFeatures, DbStreamingConnection,
  QueryExecutionSummary, QueryOptions, QueryResult, QueryResultMeta, QueryResultSink,
  QueryResultSummary, QueryRowChunk, QueryTruncation, ConnectionState, ServerInfo
} from '@arkdb/core';
import { MySqlColumnDef, MySqlValue, mysqlValues } from './MySqlQueryResult';

export class MySqlDatabaseSessionStatus extends DatabaseSessionStatus {
  autocommit: boolean = true;

  clone(): MySqlDatabaseSessionStatus {
    return mysqlSessionStatus(this);
  }
}

export function mysqlSessionStatus(value: DatabaseSessionStatus): MySqlDatabaseSessionStatus {
  const status = new MySqlDatabaseSessionStatus();
  status.known = value.known;
  status.autocommit = value.autocommit;
  status.inTransaction = value.inTransaction;
  return status;
}

export class MySqlQueryResultMeta extends QueryResultMeta {
  columns: MySqlColumnDef[] = [];
}

export class MySqlQueryRowChunk extends QueryRowChunk {
  rows: MySqlValue[][] = [];
}

export class MySqlQueryResultSummary extends QueryResultSummary {
  affectedRowsExact?: bigint;
  lastInsertId: bigint = 0n;
  warningCount: number = 0;
  statusKnown: boolean = true;
  status: MySqlDatabaseSessionStatus = new MySqlDatabaseSessionStatus();
}

export class MySqlQueryExecutionSummary extends QueryExecutionSummary {
  statusKnown: boolean = true;
  status: MySqlDatabaseSessionStatus = new MySqlDatabaseSessionStatus();
}

export function mysqlExecutionSummary(value: QueryExecutionSummary): MySqlQueryExecutionSummary {
  const summary = new MySqlQueryExecutionSummary();
  summary.resultSetCount = value.resultSetCount;
  summary.rowCount = value.rowCount;
  summary.rowCountKnown = value.rowCountKnown;
  summary.loadedRowCount = value.loadedRowCount;
  summary.loadedBytes = value.loadedBytes;
  summary.executionTimeMs = value.executionTimeMs;
  summary.statusKnown = value.statusKnown;
  summary.truncationInterrupted = value.truncationInterrupted;
  summary.synchronizationDeadlineMs = value.synchronizationDeadlineMs;
  summary.status = mysqlSessionStatus(value.status);
  return summary;
}

export interface MySqlQueryResultSink {
  onResultStart(meta: MySqlQueryResultMeta): Promise<void>;
  onRows(chunk: MySqlQueryRowChunk): Promise<void>;
  onTruncation?(truncation: QueryTruncation): Promise<boolean>;
  onResultEnd(summary: MySqlQueryResultSummary): Promise<void>;
}

/** Native callbacks keep 1.0.1 defaults; the core stream retains unknown/optional observations. */
export class MySqlResultSinkAdapter implements QueryResultSink {
  private sink: MySqlQueryResultSink;

  constructor(sink: MySqlQueryResultSink) {
    this.sink = sink;
  }

  async onResultStart(value: QueryResultMeta): Promise<void> {
    const meta = new MySqlQueryResultMeta();
    meta.resultIndex = value.resultIndex;
    meta.hasRows = value.hasRows;
    for (const column of value.columns) {
      if (!(column instanceof MySqlColumnDef)) {
        throw ArkDbError.protocol('MySQL stream contains non-MySQL column metadata.');
      }
      meta.columns.push(column);
    }
    await this.sink.onResultStart(meta);
  }

  async onRows(value: QueryRowChunk): Promise<void> {
    const chunk = new MySqlQueryRowChunk();
    chunk.resultIndex = value.resultIndex;
    chunk.rowOffset = value.rowOffset;
    chunk.encodedBytes = value.encodedBytes;
    for (const row of value.rows) chunk.rows.push(mysqlValues(row));
    await this.sink.onRows(chunk);
  }

  async onTruncation(value: QueryTruncation): Promise<boolean> {
    if (this.sink.onTruncation === undefined) return false;
    return await this.sink.onTruncation(value);
  }

  async onResultEnd(value: QueryResultSummary): Promise<void> {
    const summary = new MySqlQueryResultSummary();
    summary.resultIndex = value.resultIndex;
    summary.rowCount = value.rowCount;
    summary.rowCountKnown = value.rowCountKnown;
    summary.loadedRowCount = value.loadedRowCount;
    summary.loadedBytes = value.loadedBytes;
    summary.affectedRows = value.affectedRows;
    if (value instanceof MySqlQueryResultSummary && value.affectedRowsExact !== undefined) {
      summary.affectedRowsExact = value.affectedRowsExact;
    }
    if (value.lastInsertId !== undefined) summary.lastInsertId = value.lastInsertId;
    if (value.warningCount !== undefined) summary.warningCount = value.warningCount;
    summary.truncated = value.truncated;
    summary.truncationReason = value.truncationReason;
    summary.statusKnown = value.statusKnown;
    summary.status = mysqlSessionStatus(value.status);
    await this.sink.onResultEnd(summary);
  }
}

export class MySqlCoreStreamingConnection implements DbStreamingConnection {
  private connection: DbConnection;
  private stream: (sql: string, options: QueryOptions, sink: QueryResultSink) => Promise<QueryExecutionSummary>;

  constructor(connection: DbConnection,
    stream: (sql: string, options: QueryOptions, sink: QueryResultSink) => Promise<QueryExecutionSummary>) {
    this.connection = connection;
    this.stream = stream;
  }

  get state(): ConnectionState { return this.connection.state; }
  get serverInfo(): ServerInfo { return this.connection.serverInfo; }
  get features(): DbConnectionFeatures | undefined { return this.connection.features; }
  connect(): Promise<void> { return this.connection.connect(); }
  query(sql: string): Promise<QueryResult> { return this.connection.query(sql); }
  close(): Promise<void> { return this.connection.close(); }
  queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return this.stream(sql, options, sink);
  }
}
