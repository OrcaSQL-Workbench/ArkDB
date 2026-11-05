import {
  ConnectionState, DatabaseContext, DatabaseSessionStatus, DbConnection,
  QueryExecutionSummary, QueryOptions, QueryResult, QueryResultSink, ServerInfo
} from '@arkdb/mysql';

export class LegacyCustomConnection implements DbConnection {
  readonly state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();

  async connect(): Promise<void> {}
  async ping(): Promise<void> {}
  async query(_sql: string): Promise<QueryResult> { return new QueryResult(); }
  async queryStream(_sql: string, _options: QueryOptions,
    _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return new QueryExecutionSummary();
  }
  async changeContext(_context: DatabaseContext): Promise<void> {}
  async setAutocommit(_enabled: boolean): Promise<DatabaseSessionStatus> {
    return this.sessionStatus;
  }
  async commit(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async rollback(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async close(): Promise<void> {}
}
