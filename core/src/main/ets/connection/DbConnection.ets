import { DatabaseContext, DatabaseContextPolicy } from '../model/DatabaseContext';
import { ConnectionState, ServerInfo } from '../model/ServerInfo';
import { QueryResult } from '../model/QueryResult';
import {
  DatabaseSessionStatus, QueryExecutionSummary, QueryOptions, QueryResultSink
} from '../model/QueryStream';
import { DbExecutionController } from '../execution/DbExecutionController';
import { MetadataProvider } from '../metadata/MetadataProvider';
import { ServerMetricsProvider } from '../metrics/ServerMetricsProvider';

export interface DbConnection {
  connect(): Promise<void>;
  query(sql: string): Promise<QueryResult>;
  close(): Promise<void>;
  readonly state: ConnectionState;
  readonly serverInfo: ServerInfo;
  readonly features?: DbConnectionFeatures;
}

export interface DbStreamingConnection extends DbConnection {
  queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary>;
}

export interface DbConnectionHealth {
  ping(): Promise<void>;
}

export interface DbContextController {
  readonly contextPolicy: DatabaseContextPolicy;
  changeContext(context: DatabaseContext): Promise<void>;
}

export interface DbTransactionController {
  readonly sessionStatus: DatabaseSessionStatus;
  begin(): Promise<DatabaseSessionStatus>;
  commit(): Promise<DatabaseSessionStatus>;
  rollback(): Promise<DatabaseSessionStatus>;
}

export class DbConnectionFeatures {
  streaming?: DbStreamingConnection;
  health?: DbConnectionHealth;
  context?: DbContextController;
  transactions?: DbTransactionController;
  cancellation?: DbExecutionController;
  metadata?: MetadataProvider;
  metrics?: ServerMetricsProvider;
}
