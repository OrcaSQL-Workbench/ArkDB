import {
  ArkDbError, ConnectionState, DatabaseContext, DatabaseContextPolicy,
  DbConnection, DbConnectionFeatures, DbConnectionHealth, DbContextController,
  DbExecutionController, DbStreamingConnection, DbTransactionController,
  QueryCancellationResult, QueryExecutionSummary, QueryOptions, QueryResultSink
} from '@arkdb/core';
import {
  PostgresConnectionFeatures, PostgresFeatureConnection
} from './api/PostgresContracts';
import {
  PostgresConnectionConfig
} from './model/PostgresConnectionConfig';
import {
  PostgresDatabaseSessionStatus, PostgresQueryResult, PostgresServerInfo
} from './model/PostgresModels';

const postgresConnectionPasswords: WeakMap<PostgresConnection, string> =
  new WeakMap<PostgresConnection, string>();

export class PostgresConnection implements DbConnection, DbStreamingConnection,
  DbConnectionHealth, DbContextController, DbTransactionController,
  DbExecutionController, PostgresFeatureConnection {
  readonly features: DbConnectionFeatures = new DbConnectionFeatures();
  readonly postgresFeatures: PostgresConnectionFeatures =
    new PostgresConnectionFeatures();
  readonly contextPolicy: DatabaseContextPolicy = new DatabaseContextPolicy();
  readonly serverInfo: PostgresServerInfo = new PostgresServerInfo();
  readonly sessionStatus: PostgresDatabaseSessionStatus =
    new PostgresDatabaseSessionStatus();
  private readonly config: PostgresConnectionConfig;
  private currentState: ConnectionState = ConnectionState.Idle;

  constructor(config: PostgresConnectionConfig, password: string) {
    const errors = config.validate();
    if (errors.length > 0) throw errors[0];
    this.config = config.clone();
    postgresConnectionPasswords.set(this, password);
    this.serverInfo.driverId = 'pgsql';
    this.serverInfo.productName = 'PostgreSQL';
  }

  get state(): ConnectionState {
    return this.currentState;
  }

  async connect(): Promise<void> {
    throw ArkDbError.unsupported('PostgreSQL connection is not implemented.');
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

  async close(): Promise<void> {
    postgresConnectionPasswords.delete(this);
    this.currentState = ConnectionState.Closed;
  }
}
