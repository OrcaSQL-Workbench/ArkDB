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
import { PostgresQueryStreamHost, runPostgresQueryStream } from './command/PostgresResultStream';
import { PostgresSimpleQueryHost, runPostgresPing, runPostgresSimpleQuery } from './command/PostgresSimpleQuery';
import {
  PostgresConnectionLifecycle, PostgresLifecycleTransport, PostgresStartupRunner
} from './connection/PostgresConnectionLifecycle';
import { PostgresConnectionHealth, PostgresConnectionStreaming } from './connection/PostgresFeatureFacades';
import {
  PostgresCommandGate, PostgresCommandKind, PostgresCommandPhase, PostgresCommandScope
} from './execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement } from './execution/PostgresSettlements';
import {
  PostgresConnectionConfig
} from './model/PostgresConnectionConfig';
import {
  PostgresDatabaseSessionStatus, PostgresQueryResult, PostgresServerInfo
} from './model/PostgresModels';
import { PostgresMessageChannel, PostgresReadyStatus } from './protocol/PostgresMessageChannel';

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
    startupRunner?: PostgresStartupRunner,
    commandGate?: PostgresCommandGate) {
    this.lifecycle = new PostgresConnectionLifecycle(
      config, password, timers, transportFactory, startupRunner, commandGate);
    this.features.streaming = new PostgresConnectionStreaming(this,
      (sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> =>
        this.queryStream(sql, options, sink));
    this.features.health = new PostgresConnectionHealth((): Promise<void> => this.ping());
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

  query(sql: string): Promise<PostgresQueryResult> {
    return this.lifecycle.runCommand<PostgresQueryResult>(PostgresCommandKind.Query,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresQueryResult> =>
        runPostgresSimpleQuery(new SimpleQueryLifecycleHost(this.lifecycle, s), ch, st, sql));
  }

  queryStream(sql: string, options: QueryOptions,
    sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return this.lifecycle.runCommand<QueryExecutionSummary>(PostgresCommandKind.QueryStream,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<QueryExecutionSummary> =>
        runPostgresQueryStream(new QueryStreamLifecycleHost(this.lifecycle, s), ch, st, sql, options, sink));
  }

  ping(): Promise<void> {
    return this.lifecycle.runCommand<void>(PostgresCommandKind.Ping,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<void> =>
        runPostgresPing(new SimpleQueryLifecycleHost(this.lifecycle, s), ch, st));
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

class SimpleQueryLifecycleHost implements PostgresSimpleQueryHost {
  protected readonly lifecycle: PostgresConnectionLifecycle;
  protected readonly scope: PostgresCommandScope;
  constructor(lifecycle: PostgresConnectionLifecycle, scope: PostgresCommandScope) { this.lifecycle = lifecycle; this.scope = scope; }
  get serverInfo(): PostgresServerInfo { return this.lifecycle.serverInfo; }
  get sessionStatus(): PostgresDatabaseSessionStatus { return this.lifecycle.sessionStatus; }
  get timers(): ConnectionTimerPort { return this.lifecycle.timers; }
  applyReadyStatus(ready: PostgresReadyStatus): void { this.lifecycle.applyReadyStatus(this.scope, ready); }
  retire(reason: ArkDbError): Promise<void> { return this.lifecycle.retire(this.scope, reason); }
}

class QueryStreamLifecycleHost extends SimpleQueryLifecycleHost implements PostgresQueryStreamHost {
  private setPhase(phase: PostgresCommandPhase): void {
    if (this.lifecycle.commandGate.isOwner(this.scope) && this.scope.phase !== PostgresCommandPhase.Closing) this.lifecycle.commandGate.setPhase(this.scope, phase);
  }
  enterStreaming(): void { this.setPhase(PostgresCommandPhase.Streaming); }
  enterDraining(): void { this.setPhase(PostgresCommandPhase.Draining); }
  latchConsumerError(error: ArkDbError, synchronized: boolean = false): void { this.lifecycle.latchConsumerError(this.scope, error, synchronized); }
}
