import {
  ArkDbError, DriverCapabilities, QueryExecutionSummary, QueryOptions, QueryResultSink
} from '@arkdb/core';
import { PostgresTransactionOptions } from '../features/transaction/PostgresTransactionOptions';
import {
  PostgresDatabaseSessionStatus, PostgresQueryResult, PostgresServerInfo
} from '../model/PostgresModels';
import { PostgresPreparedExecutor } from './PostgresPreparedContracts';

export class PostgresDriverCapabilities extends DriverCapabilities {
  supportsTransactions: boolean = true;
  supportsCatalogs: boolean = true;
  supportsSchemas: boolean = true;
  supportsPreparedStatements: boolean = true;
  supportsSsl: boolean = true;
  supportsMultipleResults: boolean = true;
  supportsStreamingResults: boolean = true;
  supportsGracefulCancel: boolean = true;
}

export interface PostgresSession extends PostgresFeatureConnection {
  readonly postgresFeatures: PostgresConnectionFeatures;
  readonly serverInfo: PostgresServerInfo;
  readonly sessionStatus: PostgresDatabaseSessionStatus;
  query(sql: string): Promise<PostgresQueryResult>;
  queryStream(sql: string, options: QueryOptions,
    sink: QueryResultSink): Promise<QueryExecutionSummary>;
  savepoint(name: string): Promise<void>;
  rollbackTo(name: string): Promise<void>;
  releaseSavepoint(name: string): Promise<void>;
}

export interface PostgresTransactionRunner {
  run<T>(options: PostgresTransactionOptions,
    body: (session: PostgresSession) => Promise<T>): Promise<T>;
}

export class PostgresConnectionFeatures {
  prepared?: PostgresPreparedExecutor;
  transactions?: PostgresTransactionRunner;
}

export interface PostgresFeatureConnection {
  readonly postgresFeatures?: PostgresConnectionFeatures;
}

export function requirePostgresFeatures(
  connection: PostgresFeatureConnection): PostgresConnectionFeatures {
  const features = connection.postgresFeatures;
  if (features === undefined) {
    throw ArkDbError.unsupported('This connection does not provide PostgreSQL features.');
  }
  return features;
}
