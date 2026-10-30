import { ArkDbError, ConnectionState, QueryOptions } from '@arkdb/core';
import { MySqlConnectionFeatures } from '../driver/MySqlConnectionFeatures';
import { MySqlSession } from '../driver/MySqlSession';
import { MySqlServerInfo } from '../model/MySqlServerInfo';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../model/MySqlOperationError';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';
import {
  MySqlTransactionIsolation, MySqlTransactionOptions, validateMySqlTransactionOptions
} from '../model/MySqlTransactionOptions';
import { quoteMySqlIdentifier } from '../value/MySqlSqlHelpers';
import { MySqlCommandScope } from './MySqlCommandGate';

export const MYSQL_COMMIT_NO_CHAIN_NO_RELEASE = 'COMMIT AND NO CHAIN NO RELEASE';
export const MYSQL_ROLLBACK_NO_CHAIN_NO_RELEASE = 'ROLLBACK AND NO CHAIN NO RELEASE';

export interface MySqlTransactionRunner {
  run<T>(options: MySqlTransactionOptions,
    body: (session: MySqlSession) => Promise<T>): Promise<T>;
}

export interface MySqlTransactionRunnerHost {
  readonly state: ConnectionState;
  readonly mysqlFeatures: MySqlConnectionFeatures;
  readonly serverInfo: MySqlServerInfo;
  readonly sessionStatus: MySqlDatabaseSessionStatus;
  reserveTransaction(): MySqlCommandScope;
  settleTransaction(scope: MySqlCommandScope): Promise<ArkDbError[]>;
  finishTransaction(scope: MySqlCommandScope): Promise<ArkDbError[]>;
  refreshTransactionStatus(scope: MySqlCommandScope): Promise<void>;
  retireTransaction(scope: MySqlCommandScope, error: ArkDbError): Promise<void>;
  query(scope: MySqlCommandScope, sql: string): Promise<MySqlQueryResult>;
  queryStream(scope: MySqlCommandScope, sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
}

export class MySqlConnectionTransactionRunner implements MySqlTransactionRunner {
  private host: MySqlTransactionRunnerHost;

  constructor(host: MySqlTransactionRunnerHost) {
    this.host = host;
  }

  async run<T>(options: MySqlTransactionOptions,
    body: (session: MySqlSession) => Promise<T>): Promise<T> {
    const snapshot = snapshotTransactionOptions(options);
    const scope = this.host.reserveTransaction();
    const session = new ScopedMySqlTransactionSession(this.host, scope);
    let value: T | undefined;
    let primary: Object | null = null;
    let exactCallbackFailure: Object | null = null;
    let outcome = MySqlExecutionOutcome.NotDispatched;
    const cleanup: ArkDbError[] = [];
    try {
      const setup = transactionSetupSql(snapshot);
      if (setup !== null) {
        await this.host.query(scope, setup);
        const setupCleanup = await this.host.settleTransaction(scope);
        if (cleanupBlocksLaterTransactionSql(setupCleanup)) {
          throw transactionCleanupFailure(setupCleanup);
        }
        for (const failure of setupCleanup) cleanup.push(failure);
      }
      await this.host.query(scope, startTransactionSql(snapshot));

      let callbackFailure: Object | null = null;
      try {
        value = await body(session);
        if (session.hasActiveCommand) {
          callbackFailure = ArkDbError.protocol(
            'The transaction callback settled while a session command was still active.');
        }
      } catch (error) {
        callbackFailure = error === null ?
          ArkDbError.protocol('The transaction callback rejected with null.') : error as Object;
      }
      session.expire();
      const outstandingFailure = await session.waitForActiveCommand();
      const childCleanup = session.takeRetainedCleanup();
      for (const failure of childCleanup) cleanup.push(failure);
      if (outstandingFailure !== null) {
        cleanup.push(toTransactionCleanupError(outstandingFailure));
      }

      const cancellationCleanup = await this.host.settleTransaction(scope);
      if (cleanupBlocksLaterTransactionSql(cancellationCleanup)) {
        if (callbackFailure !== null) {
          primary = callbackFailure;
          outcome = transactionFailureOutcome(callbackFailure, MySqlExecutionOutcome.Unknown);
          for (const failure of cancellationCleanup) cleanup.push(failure);
        } else {
          primary = cancellationCleanup[0];
          outcome = transactionFailureOutcome(primary, MySqlExecutionOutcome.Completed);
          for (let index = 1; index < cancellationCleanup.length; index += 1) {
            cleanup.push(cancellationCleanup[index]);
          }
        }
      } else {
        for (const failure of cancellationCleanup) cleanup.push(failure);
      }
      if (primary === null && callbackFailure !== null) {
        const retained = callbackFailure;
        if (failureBlocksLaterTransactionSql(retained)) {
          primary = retained;
          outcome = transactionFailureOutcome(retained, MySqlExecutionOutcome.Unknown);
        } else if (this.canRollback()) {
          try {
            await this.host.query(scope, MYSQL_ROLLBACK_NO_CHAIN_NO_RELEASE);
            exactCallbackFailure = retained;
          } catch (rollbackError) {
            primary = retained;
            cleanup.push(toTransactionCleanupError(rollbackError as Object));
            outcome = MySqlExecutionOutcome.Unknown;
          }
        } else if (this.transactionKnownEnded()) {
          primary = retained;
          outcome = MySqlExecutionOutcome.Completed;
        } else {
          primary = retained;
          outcome = MySqlExecutionOutcome.Unknown;
        }
      } else if (primary === null) {
        try {
          await this.host.query(scope, MYSQL_COMMIT_NO_CHAIN_NO_RELEASE);
          outcome = MySqlExecutionOutcome.Completed;
        } catch (commitError) {
          const retained = commitError as Object;
          primary = retained;
          outcome = transactionFailureOutcome(retained, MySqlExecutionOutcome.Unknown);
          if (outcome === MySqlExecutionOutcome.ServerRejected) {
            await this.recoverRejectedCommit(scope, retained, cleanup);
          }
        }
      }
      if (primary !== null && outcome === MySqlExecutionOutcome.Unknown) {
        await this.retireReadyUnresolvedTransaction(scope, primary, cleanup);
      }
    } catch (error) {
      const caught = error as Object;
      if (primary === null && exactCallbackFailure === null) {
        primary = caught;
        outcome = transactionFailureOutcome(caught, MySqlExecutionOutcome.Unknown);
      } else {
        cleanup.push(toTransactionCleanupError(caught));
      }
    } finally {
      session.expire();
      try {
        const finalCleanup = await this.host.finishTransaction(scope);
        for (const failure of finalCleanup) cleanup.push(failure);
      } catch (error) {
        cleanup.push(toTransactionCleanupError(error as Object));
      }
    }

    if (primary !== null) {
      throw transactionFailure(primary, cleanup, outcomeWithCleanup(outcome, cleanup));
    }
    if (exactCallbackFailure !== null) {
      const retained = exactCallbackFailure;
      if (cleanup.length > 0) {
        throw transactionFailure(retained, cleanup,
          outcomeWithCleanup(
            transactionFailureOutcome(retained, MySqlExecutionOutcome.Completed), cleanup));
      }
      throw retained as Error;
    }
    if (cleanup.length > 0) {
      throw transactionFailure(cleanup[0], cleanup.slice(1),
        outcomeWithCleanup(outcome, cleanup));
    }
    return value!;
  }

  private canRollback(): boolean {
    const status = this.host.sessionStatus;
    return this.host.state === ConnectionState.Ready &&
      !(status.known === true && !status.inTransaction);
  }

  private transactionKnownEnded(): boolean {
    const status = this.host.sessionStatus;
    return this.host.state === ConnectionState.Ready &&
      status.known === true && !status.inTransaction;
  }

  private async retireReadyUnresolvedTransaction(scope: MySqlCommandScope,
    primary: Object, cleanup: ArkDbError[]): Promise<void> {
    if (this.host.state !== ConnectionState.Ready || this.transactionKnownEnded()) return;
    try {
      await this.host.retireTransaction(scope, toTransactionArkDbError(primary));
    } catch (retireError) {
      cleanup.push(toTransactionCleanupError(retireError as Object));
    }
  }

  private async recoverRejectedCommit(scope: MySqlCommandScope,
    commitError: Object, cleanup: ArkDbError[]): Promise<void> {
    const settlement = await this.host.settleTransaction(scope);
    for (const failure of settlement) cleanup.push(failure);
    if (!cleanupBlocksLaterTransactionSql(settlement) &&
      this.host.state === ConnectionState.Ready) {
      try {
        await this.host.query(scope, MYSQL_ROLLBACK_NO_CHAIN_NO_RELEASE);
      } catch (rollbackError) {
        cleanup.push(toTransactionCleanupError(rollbackError as Object));
      }
    }
    if (this.host.state === ConnectionState.Ready && !this.transactionKnownEnded()) {
      try {
        await this.host.retireTransaction(scope, toTransactionArkDbError(commitError));
      } catch (retireError) {
        cleanup.push(toTransactionCleanupError(retireError as Object));
      }
    }
  }
}

class ScopedMySqlTransactionSession implements MySqlSession {
  private host: MySqlTransactionRunnerHost;
  private scope: MySqlCommandScope;
  private readonly scopedFeatures: MySqlConnectionFeatures = new MySqlConnectionFeatures();
  private active: boolean = true;
  private activeCommand: Promise<Object | null> | null = null;
  private retainedCleanup: ArkDbError[] = [];

  constructor(host: MySqlTransactionRunnerHost, scope: MySqlCommandScope) {
    this.host = host;
    this.scope = scope;
  }

  get mysqlFeatures(): MySqlConnectionFeatures {
    this.requireActive();
    return this.scopedFeatures;
  }

  get serverInfo(): MySqlServerInfo {
    this.requireActive();
    return this.host.serverInfo;
  }

  get sessionStatus(): MySqlDatabaseSessionStatus {
    this.requireActive();
    return this.host.sessionStatus;
  }

  get hasActiveCommand(): boolean {
    return this.activeCommand !== null;
  }

  query(sql: string): Promise<MySqlQueryResult> {
    return this.runCommand<MySqlQueryResult>(
      (): Promise<MySqlQueryResult> => this.host.query(this.scope, sql));
  }

  queryStream(sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.runCommand<MySqlQueryExecutionSummary>(
      (): Promise<MySqlQueryExecutionSummary> =>
        this.host.queryStream(this.scope, sql, options, sink));
  }

  savepoint(name: string): Promise<void> {
    return this.runCommand<void>(
      async (): Promise<void> => {
        await this.requireActiveTransaction();
        await this.host.query(this.scope, 'SAVEPOINT ' + quoteMySqlIdentifier([name]));
      });
  }

  rollbackTo(name: string): Promise<void> {
    return this.runCommand<void>(
      async (): Promise<void> => {
        await this.requireActiveTransaction();
        await this.host.query(this.scope, 'ROLLBACK TO SAVEPOINT ' + quoteMySqlIdentifier([name]));
      });
  }

  releaseSavepoint(name: string): Promise<void> {
    return this.runCommand<void>(
      async (): Promise<void> => {
        await this.requireActiveTransaction();
        await this.host.query(this.scope, 'RELEASE SAVEPOINT ' + quoteMySqlIdentifier([name]));
      });
  }

  expire(): void {
    this.active = false;
  }

  async waitForActiveCommand(): Promise<Object | null> {
    const command = this.activeCommand;
    return command === null ? null : await command;
  }

  takeRetainedCleanup(): ArkDbError[] {
    const cleanup = this.retainedCleanup;
    this.retainedCleanup = [];
    return cleanup;
  }

  private requireActive(): void {
    if (!this.active) {
      throw ArkDbError.validation('The transaction callback session is no longer active.');
    }
  }

  private async requireActiveTransaction(): Promise<void> {
    this.requireActive();
    if (this.host.state !== ConnectionState.Ready) {
      throw ArkDbError.validation('Savepoints require an active callback transaction.');
    }
    let status = this.host.sessionStatus;
    if (status.known !== true) {
      await this.host.refreshTransactionStatus(this.scope);
      status = this.host.sessionStatus;
    }
    if (this.host.state !== ConnectionState.Ready ||
      status.known !== true || !status.inTransaction) {
      throw ArkDbError.validation('Savepoints require an active callback transaction.');
    }
  }

  private runCommand<T>(operation: () => Promise<T>): Promise<T> {
    const tracksActiveCommand = this.active && this.activeCommand === null;
    const task = this.runSettledCommand<T>(operation);
    if (tracksActiveCommand) {
      const settlement = task.then(
        (): Object | null => null,
        (error: Object): Object | null => error);
      this.activeCommand = settlement;
      settlement.then((): void => {
        if (this.activeCommand === settlement) this.activeCommand = null;
      });
    }
    task.catch((_error: Object): void => {});
    return task;
  }

  private async runSettledCommand<T>(operation: () => Promise<T>): Promise<T> {
    this.requireActive();
    if (this.activeCommand !== null) {
      throw ArkDbError.protocol('Another transaction callback command is already active.');
    }
    try {
      const cleanup = await this.host.settleTransaction(this.scope);
      if (cleanupBlocksLaterTransactionSql(cleanup)) throw transactionCleanupFailure(cleanup);
      for (const failure of cleanup) this.retainedCleanup.push(failure);
      return await operation();
    } finally {
      this.activeCommand = null;
    }
  }
}

function snapshotTransactionOptions(options: MySqlTransactionOptions): MySqlTransactionOptions {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    throw ArkDbError.validation('Transaction options must be a non-null, non-array object.');
  }
  const snapshot = new MySqlTransactionOptions();
  snapshot.isolation = options.isolation === undefined ?
    MySqlTransactionIsolation.Default : options.isolation;
  snapshot.readOnly = options.readOnly;
  snapshot.consistentSnapshot = options.consistentSnapshot === undefined ?
    false : options.consistentSnapshot;
  const errors = validateMySqlTransactionOptions(snapshot);
  if (errors.length > 0) throw errors[0];
  return snapshot;
}

function transactionSetupSql(options: MySqlTransactionOptions): string | null {
  const characteristics: string[] = [];
  const isolation = isolationSql(options.isolation);
  if (isolation.length > 0) characteristics.push('ISOLATION LEVEL ' + isolation);
  if (options.readOnly !== undefined) {
    characteristics.push(options.readOnly ? 'READ ONLY' : 'READ WRITE');
  }
  return characteristics.length === 0 ? null : 'SET TRANSACTION ' + characteristics.join(', ');
}

function startTransactionSql(options: MySqlTransactionOptions): string {
  return options.consistentSnapshot ?
    'START TRANSACTION WITH CONSISTENT SNAPSHOT' : 'START TRANSACTION';
}

function isolationSql(isolation: MySqlTransactionIsolation): string {
  switch (isolation) {
    case MySqlTransactionIsolation.Default:
      return '';
    case MySqlTransactionIsolation.ReadCommitted:
      return 'READ COMMITTED';
    case MySqlTransactionIsolation.RepeatableRead:
      return 'REPEATABLE READ';
    case MySqlTransactionIsolation.Serializable:
      return 'SERIALIZABLE';
    case MySqlTransactionIsolation.ReadUncommitted:
      return 'READ UNCOMMITTED';
  }
}

function transactionFailureOutcome(error: Object,
  fallback: MySqlExecutionOutcome): MySqlExecutionOutcome {
  return error instanceof MySqlOperationError ? error.outcome : fallback;
}

function outcomeWithCleanup(outcome: MySqlExecutionOutcome,
  cleanup: ArkDbError[]): MySqlExecutionOutcome {
  if (outcome === MySqlExecutionOutcome.Unknown) return outcome;
  for (const failure of cleanup) {
    if (failure instanceof MySqlOperationError &&
      failure.outcome === MySqlExecutionOutcome.Unknown) {
      return MySqlExecutionOutcome.Unknown;
    }
  }
  return outcome;
}

function cleanupBlocksLaterTransactionSql(cleanup: ArkDbError[]): boolean {
  for (const failure of cleanup) {
    if (!(failure instanceof MySqlOperationError) ||
      failure.outcome === MySqlExecutionOutcome.Unknown) return true;
  }
  return false;
}

function failureBlocksLaterTransactionSql(error: Object): boolean {
  return error instanceof MySqlOperationError &&
    error.outcome === MySqlExecutionOutcome.Unknown;
}

function transactionCleanupFailure(cleanup: ArkDbError[]): MySqlOperationError {
  const primary = cleanup[0];
  return transactionFailure(primary, cleanup.slice(1),
    outcomeWithCleanup(transactionFailureOutcome(primary, MySqlExecutionOutcome.Completed), cleanup));
}

function toTransactionArkDbError(error: Object): ArkDbError {
  if (error instanceof ArkDbError) return error;
  const typed = error as Error;
  const message = typed !== null && typed !== undefined && typed.message !== undefined ?
    typed.message : String(error);
  return ArkDbError.protocol(message);
}

function toTransactionCleanupError(error: Object): ArkDbError {
  return error instanceof ArkDbError ? error :
    transactionFailure(error, [], MySqlExecutionOutcome.Unknown);
}

function transactionFailure(error: Object, cleanup: ArkDbError[],
  outcome: MySqlExecutionOutcome): MySqlOperationError {
  if (error instanceof MySqlOperationError) {
    const combined = error.cleanupErrors.slice();
    for (const failure of cleanup) combined.push(failure);
    return new MySqlOperationError(error.primary, combined, outcome, error.originalCause);
  }
  return new MySqlOperationError(toTransactionArkDbError(error), cleanup, outcome,
    error instanceof ArkDbError ? undefined : error);
}
