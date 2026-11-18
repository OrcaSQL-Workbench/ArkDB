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
import { PostgresExtendedQueryHost, runPostgresExtendedQuery } from './command/PostgresExtendedQuery';
import { runPostgresPortalStream } from './command/PostgresPortalStream';
import { encodePostgresSimpleQuery, PostgresQueryStreamHost, runPostgresQueryStream } from './command/PostgresResultStream';
import { PostgresSimpleQueryHost, runPostgresPing, runPostgresSimpleQuery, scrubQueryResult, snapshotQueryOptions } from './command/PostgresSimpleQuery';
import {
  runPostgresBegin, runPostgresCommit, runPostgresRollback
} from './command/PostgresTransactionCommand';
import {
  PostgresConnectionLifecycle, PostgresLifecycleTransport, PostgresStartupRunner
} from './connection/PostgresConnectionLifecycle';
import {
  PostgresConnectionCancellation, PostgresConnectionContext, PostgresConnectionHealth,
  PostgresConnectionStreaming, PostgresConnectionTransactions, createPostgresContextPolicy
} from './connection/PostgresFeatureFacades';
import {
  PostgresCommandGate, PostgresCommandKind, PostgresCommandPhase, PostgresCommandScope
} from './execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement } from './execution/PostgresSettlements';
import { PostgresPreparedFrames } from './features/prepared/PostgresParameterEncoder';
import { PostgresConnectionPreparedExecutor } from './features/prepared/PostgresPreparedExecutor';
import { PostgresConnectionTransactionRunner, PostgresTransactionCommandHost, PostgresTransactionFailure } from './features/transaction/PostgresTransactionRunner';
import {
  PostgresConnectionConfig, isWellFormedPostgresText, resolvePostgresDatabaseName
} from './model/PostgresConnectionConfig';
import {
  PostgresDatabaseSessionStatus, PostgresQueryResult, PostgresServerInfo
} from './model/PostgresModels';
import { PostgresMessageChannel, PostgresReadyStatus } from './protocol/PostgresMessageChannel';
import { quotePostgresIdentifier } from './value/PostgresSqlHelpers';

export class PostgresConnection implements DbConnection, DbStreamingConnection,
  DbConnectionHealth, DbContextController, DbTransactionController,
  DbExecutionController, PostgresFeatureConnection {
  readonly features: DbConnectionFeatures = new DbConnectionFeatures();
  readonly postgresFeatures: PostgresConnectionFeatures =
    new PostgresConnectionFeatures();
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
    this.features.context = new PostgresConnectionContext(
      (): DatabaseContextPolicy => this.contextPolicy,
      (context: DatabaseContext): Promise<void> => this.changeContext(context));
    this.features.transactions = new PostgresConnectionTransactions(this);
    this.features.cancellation = new PostgresConnectionCancellation(this);
    this.postgresFeatures.prepared = new PostgresConnectionPreparedExecutor(
      (frames: PostgresPreparedFrames, options: QueryOptions): Promise<PostgresQueryResult> =>
        this.executeExtendedQuery(frames, options),
      (frames: PostgresPreparedFrames, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> =>
        this.streamPreparedQuery(frames, options, sink),
      (): void => this.lifecycle.assertCommandDispatchable());
    this.postgresFeatures.transactions = new PostgresConnectionTransactionRunner(
      (op: (h: PostgresTransactionCommandHost, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement) => Promise<PostgresTransactionFailure | null>): Promise<PostgresTransactionFailure | null> => this.runTransactionScope(op));
  }

  get contextPolicy(): DatabaseContextPolicy {
    return createPostgresContextPolicy();
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
    let qFrame: Uint8Array | undefined = undefined;
    return this.lifecycle.runDeadlineCommand<QueryExecutionSummary>(PostgresCommandKind.QueryStream, (): QueryOptions => {
      const snap = snapshotQueryOptions(options); if (sink === null || sink === undefined || typeof sink !== 'object') throw ArkDbError.validation('QueryResultSink is required.');
      qFrame = encodePostgresSimpleQuery(sql); return snap;
    }, (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement, opts: QueryOptions): Promise<QueryExecutionSummary> =>
      runPostgresQueryStream(new QueryStreamLifecycleHost(this.lifecycle, s), ch, st, sql, opts, sink, qFrame)).finally((): void => { if (qFrame !== undefined) qFrame.fill(0); });
  }

  ping(): Promise<void> {
    return this.lifecycle.runCommand<void>(PostgresCommandKind.Ping,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<void> =>
        runPostgresPing(new SimpleQueryLifecycleHost(this.lifecycle, s), ch, st));
  }

  changeContext(context: DatabaseContext): Promise<void> {
    if (context === null || context === undefined || !(context instanceof DatabaseContext) ||
      typeof context.catalog !== 'string' || typeof context.schema !== 'string') {
      return Promise.reject<void>(ArkDbError.validation('A PostgreSQL database context is required.'));
    }
    const snapshot = context.clone();
    return this.lifecycle.runCommand<void>(PostgresCommandKind.Context,
      async (s: PostgresCommandScope, ch: PostgresMessageChannel,
        st: PostgresCommandCloseSettlement): Promise<void> => {
        if (!isWellFormedPostgresText(snapshot.catalog)) {
          throw ArkDbError.validation(
            'PostgreSQL catalog name must not contain NUL or unpaired UTF-16 surrogates.');
        }
        const connectedCatalog = resolvePostgresDatabaseName(this.lifecycle.config);
        if (snapshot.catalog.length > 0 && snapshot.catalog !== connectedCatalog) {
          throw ArkDbError.unsupported(
            'Changing the PostgreSQL catalog requires reconnecting to the target database.');
        }
        if (snapshot.schema.length === 0) {
          throw ArkDbError.validation('A PostgreSQL schema name is required.');
        }
        if (snapshot.schema === '$user') {
          throw ArkDbError.validation(
            'PostgreSQL search_path cannot target a literal "$user" schema.');
        }
        const quotedSchema = quotePostgresIdentifier([snapshot.schema]);
        await runPostgresSimpleQuery(new SimpleQueryLifecycleHost(this.lifecycle, s), ch, st,
          'SET search_path TO ' + quotedSchema);
      });
  }

  begin(): Promise<PostgresDatabaseSessionStatus> {
    return this.lifecycle.runCommand<PostgresDatabaseSessionStatus>(PostgresCommandKind.Transaction,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> =>
        runPostgresBegin(new SimpleQueryLifecycleHost(this.lifecycle, s), ch, st));
  }

  commit(): Promise<PostgresDatabaseSessionStatus> {
    return this.lifecycle.runCommand<PostgresDatabaseSessionStatus>(PostgresCommandKind.Transaction,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> =>
        runPostgresCommit(new SimpleQueryLifecycleHost(this.lifecycle, s), ch, st));
  }

  rollback(): Promise<PostgresDatabaseSessionStatus> {
    return this.lifecycle.runCommand<PostgresDatabaseSessionStatus>(PostgresCommandKind.Transaction,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> =>
        runPostgresRollback(new SimpleQueryLifecycleHost(this.lifecycle, s), ch, st));
  }

  cancel(): Promise<QueryCancellationResult> {
    return this.lifecycle.cancel();
  }

  isInterruptionError(error: ArkDbError): boolean {
    return this.lifecycle.isInterruptionError(error);
  }

  close(): Promise<void> {
    return this.lifecycle.close();
  }

  private executeExtendedQuery(frames: PostgresPreparedFrames,
    options: QueryOptions): Promise<PostgresQueryResult> {
    return this.lifecycle.runDeadlineCommand<PostgresQueryResult>(PostgresCommandKind.ExtendedQuery, (): QueryOptions => options,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement, opts: QueryOptions): Promise<PostgresQueryResult> =>
        runPostgresExtendedQuery(new QueryStreamLifecycleHost(this.lifecycle, s), ch, st, frames, opts), scrubQueryResult);
  }

  private streamPreparedQuery(frames: PostgresPreparedFrames, options: QueryOptions,
    sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return this.lifecycle.runDeadlineCommand<QueryExecutionSummary>(PostgresCommandKind.Prepared, (): QueryOptions => options,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement, opts: QueryOptions): Promise<QueryExecutionSummary> =>
        runPostgresPortalStream(new QueryStreamLifecycleHost(this.lifecycle, s), ch, st, frames, opts, sink));
  }

  private runTransactionScope(op: (h: PostgresTransactionCommandHost, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement) => Promise<PostgresTransactionFailure | null>): Promise<PostgresTransactionFailure | null> {
    return this.lifecycle.runCommand<PostgresTransactionFailure | null>(PostgresCommandKind.Transaction,
      (s: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresTransactionFailure | null> => op(new TransactionRunnerLifecycleHost(this.lifecycle, s), ch, st));
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

class QueryStreamLifecycleHost extends SimpleQueryLifecycleHost
  implements PostgresQueryStreamHost, PostgresExtendedQueryHost {
  protected setPhase(phase: PostgresCommandPhase): void {
    if (this.lifecycle.commandGate.isOwner(this.scope) && this.scope.phase !== PostgresCommandPhase.Closing) this.lifecycle.commandGate.setPhase(this.scope, phase);
  }
  enterStreaming(): void { this.setPhase(PostgresCommandPhase.Streaming); }
  enterDraining(): void { this.setPhase(PostgresCommandPhase.Draining); }
  latchConsumerError(error: ArkDbError, synchronized: boolean = false): void { this.lifecycle.latchConsumerError(this.scope, error, synchronized); }
  beginPortalBatch(settlement: PostgresCommandCloseSettlement, prepareNext: boolean = true): Promise<void> { return this.lifecycle.beginPortalBatch(this.scope, settlement, prepareNext); }
}

class TransactionRunnerLifecycleHost extends QueryStreamLifecycleHost implements PostgresTransactionCommandHost {
  enterExecuting(): void { this.setPhase(PostgresCommandPhase.Executing); }
  clearConsumerError(): void { this.lifecycle.clearConsumerError(this.scope); }
  isSynchronized(): boolean { return this.lifecycle.isCommandSynchronized(this.scope); }
  waitBeforeStep(settlement: PostgresCommandCloseSettlement): Promise<void> | null { return this.lifecycle.waitForStepReady(this.scope, settlement); }
  runStepWithDeadline<R>(settlement: PostgresCommandCloseSettlement, options: QueryOptions, op: () => Promise<R>, scrub?: (value: R) => void, canLatch?: () => boolean): Promise<R> { return this.lifecycle.runStepWithDeadline<R>(this.scope, settlement, options, op, scrub, canLatch); }
}
