import { DatabaseContext } from '../model/DatabaseContext';
import { ConnectionState, ServerInfo } from '../model/ServerInfo';
import { QueryResult } from '../model/QueryResult';
import { DatabaseSessionStatus, QueryExecutionSummary, QueryOptions, QueryResultSink } from '../model/QueryStream';

export interface DbConnection {
  connect(): Promise<void>;
  ping(): Promise<void>;
  query(sql: string): Promise<QueryResult>;
  queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary>;
  changeContext(context: DatabaseContext): Promise<void>;
  setAutocommit(enabled: boolean): Promise<DatabaseSessionStatus>;
  commit(): Promise<DatabaseSessionStatus>;
  rollback(): Promise<DatabaseSessionStatus>;
  close(): Promise<void>;
  readonly state: ConnectionState;
  readonly serverInfo: ServerInfo;
  readonly sessionStatus: DatabaseSessionStatus;
}
