import {
  ArkDbError, ConnectionState, ConnectionTimerPort, DatabaseContext,
  DatabaseContextPolicy, DbConnection, DbConnectionFeatures, DbConnectionHealth,
  DbContextController, DbExecutionController, DbStreamingConnection,
  DbTransactionController, QueryCancellationResult, QueryExecutionSummary,
  QueryOptions, QueryResultSink
} from '@arkdb/core';
import {
  PostgresConnectionFeatures, PostgresFeatureConnection
} from './api/PostgresContracts';
import {
  PostgresConnectionLifecycle, PostgresLifecycleTransport, PostgresStartupRunner
} from './connection/PostgresConnectionLifecycle';
import {
  PostgresConnectionConfig
} from './model/PostgresConnectionConfig';
import {
  PostgresDatabaseSessionStatus, PostgresQueryResult, PostgresServerInfo
} from './model/PostgresModels';

export class PostgresConnection implements DbConnection, DbStreamingConnection,
  DbConnectionHealth, DbContextController, DbTransactionController,
  DbExecutionController, PostgresFeatureConnection {
  readonly features: DbConnectionFeatures = new DbConnectionFeatures();
  readonly postgresFeatures: PostgresConnectionFeatures =
    new PostgresConnectionFeatures();
  readonly contextPolicy: DatabaseContextPolicy = new DatabaseContextPolicy();
  private readonly lifecycle: PostgresConnectionLifecycle;

  constructor(config: PostgresConnectionConfig, password: string,
    timers?: ConnectionTimerPort,
    transportFactory?: () => PostgresLifecycleTransport,
    startupRunner?: PostgresStartupRunner) {
    this.lifecycle = new PostgresConnectionLifecycle(
      config, password, timers, transportFactory, startupRunner);
  }

  get state(): ConnectionState {
    return this.lifecycle.state;
  }

  get serverInfo(): PostgresServerInfo {
    return this.lifecycle.serverInfo;
  }

  get sessionStatus(): PostgresDatabaseSessionStatus {
    return this.lifecycle.sessionStatus.clone();
  }

  connect(): Promise<void> {
    return this.lifecycle.connect();
  }

  async query(_sql: string): Promise<PostgresQueryResult> {
    throw ArkDbError.unsupported('PostgreSQL query execution is not implemented.');
  }

  async queryStream(_sql: string, _options: QueryOptions,
    _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    throw ArkDbError.unsupported('PostgreSQL streaming is not implemented.');
  }

  async ping(): Promise<void> {
    throw ArkDbError.unsupported('PostgreSQL health checks are not implemented.');
  }

  async changeContext(_context: DatabaseContext): Promise<void> {
    throw ArkDbError.unsupported('PostgreSQL context changes are not implemented.');
  }

  async begin(): Promise<PostgresDatabaseSessionStatus> {
    throw ArkDbError.unsupported('PostgreSQL transactions are not implemented.');
  }

  async commit(): Promise<PostgresDatabaseSessionStatus> {
    throw ArkDbError.unsupported('PostgreSQL transactions are not implemented.');
  }

  async rollback(): Promise<PostgresDatabaseSessionStatus> {
    throw ArkDbError.unsupported('PostgreSQL transactions are not implemented.');
  }

  async cancel(): Promise<QueryCancellationResult> {
    throw ArkDbError.unsupported('PostgreSQL cancellation is not implemented.');
  }

  isInterruptionError(_error: ArkDbError): boolean {
    throw ArkDbError.unsupported('PostgreSQL interruption classification is not implemented.');
  }

  close(): Promise<void> {
    return this.lifecycle.close();
  }
}
