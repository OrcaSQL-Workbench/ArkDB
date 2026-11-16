import { ArkDbError, ConnectionTimerPort, QueryExecutionSummary, QueryOptions, QueryResultSink } from '@arkdb/core';
import { PostgresConnectionFeatures, PostgresSession, PostgresTransactionRunner } from '../../api/PostgresContracts';
import { PostgresPreparedExecutor } from '../../api/PostgresPreparedContracts';
import { PostgresExtendedQueryHost, runPostgresExtendedQuery } from '../../command/PostgresExtendedQuery';
import { runPostgresPortalStream } from '../../command/PostgresPortalStream';
import { PostgresQueryStreamHost, runPostgresQueryStream } from '../../command/PostgresResultStream';
import { PostgresSimpleQueryHost, runPostgresSimpleQuery } from '../../command/PostgresSimpleQuery';
import { runPostgresBegin, runPostgresCommit, runPostgresRollback } from '../../command/PostgresTransactionCommand';
import { PostgresCommandCloseSettlement, postgresAppendCleanupError, toPostgresArkDbError } from '../../execution/PostgresSettlements';
import { PostgresParameter } from '../prepared/PostgresParameter';
import { PostgresPreparedFrames } from '../prepared/PostgresParameterEncoder';
import { PostgresConnectionPreparedExecutor } from '../prepared/PostgresPreparedExecutor';
import { PostgresDatabaseSessionStatus, PostgresError, PostgresQueryResult, PostgresServerInfo, PostgresTransactionState } from '../../model/PostgresModels';
import { PostgresMessageChannel, PostgresReadyStatus } from '../../protocol/PostgresMessageChannel';
import { quotePostgresIdentifier } from '../../value/PostgresSqlHelpers';
import { buildPostgresBeginSql, PostgresTransactionOptions } from './PostgresTransactionOptions';

export interface PostgresTransactionCommandHost extends PostgresSimpleQueryHost, PostgresQueryStreamHost, PostgresExtendedQueryHost {
  enterExecuting(): void; clearConsumerError(): void; isSynchronized(): boolean;
}
export class PostgresTransactionFailure {
  readonly error: Object | null | undefined;
  constructor(error: Object | null | undefined) { this.error = error; }
}
export type PostgresTransactionScopeExecutor = (
  op: (host: PostgresTransactionCommandHost, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement) => Promise<PostgresTransactionFailure | null>
) => Promise<PostgresTransactionFailure | null>;

interface SessionPreparedDelegate { readonly session: ScopedPostgresTransactionSession; readonly inner: PostgresPreparedExecutor; }
type StepExecutor = <R>(fn: (stepHost: StepCommandHost, stepSettlement: PostgresCommandCloseSettlement) => Promise<R>) => Promise<R>;

const transactionScopeExecutors = new WeakMap<PostgresConnectionTransactionRunner, PostgresTransactionScopeExecutor>();
const sessionPreparedDelegates = new WeakMap<ScopedSessionPreparedExecutor, SessionPreparedDelegate>();

export class PostgresConnectionTransactionRunner implements PostgresTransactionRunner {
  constructor(executeScope: PostgresTransactionScopeExecutor) {
    if (typeof executeScope !== 'function') throw ArkDbError.validation('PostgreSQL transaction scope executor is required.');
    transactionScopeExecutors.set(this, executeScope);
  }
  run<T>(options: PostgresTransactionOptions, body: (session: PostgresSession) => Promise<T>): Promise<T> {
    let executeScope: PostgresTransactionScopeExecutor; let beginSql: string;
    try {
      const stored = transactionScopeExecutors.get(this);
      if (stored === undefined) throw ArkDbError.protocol('PostgreSQL transaction runner is uninitialized.');
      executeScope = stored; beginSql = buildPostgresBeginSql(options);
      if (typeof body !== 'function') throw ArkDbError.validation('PostgreSQL transaction callback is required.');
    } catch (err) { return Promise.reject<T>(toPostgresArkDbError(err as Object)); }
    let resultValue: T | undefined = undefined;
    return executeScope((h: PostgresTransactionCommandHost, ch: PostgresMessageChannel, ps: PostgresCommandCloseSettlement): Promise<PostgresTransactionFailure | null> =>
      executeTransactionScope<T>(h, ch, ps, beginSql, body, (val: T): void => { resultValue = val; })
    ).then((f: PostgresTransactionFailure | null): Promise<T> => f !== null ? Promise.reject<T>(f.error as Object) : Promise.resolve<T>(resultValue as T));
  }
}

class StepCommandHost implements PostgresSimpleQueryHost, PostgresQueryStreamHost, PostgresExtendedQueryHost {
  private readonly inner: PostgresTransactionCommandHost;
  consumerLatched: boolean = false;
  constructor(inner: PostgresTransactionCommandHost) { this.inner = inner; }
  get serverInfo(): PostgresServerInfo { return this.inner.serverInfo; }
  get sessionStatus(): PostgresDatabaseSessionStatus { return this.inner.sessionStatus; }
  get timers(): ConnectionTimerPort { return this.inner.timers; }
  applyReadyStatus(ready: PostgresReadyStatus): void { this.inner.applyReadyStatus(ready); }
  retire(reason: ArkDbError): Promise<void> { return this.inner.retire(reason); }
  enterStreaming(): void { this.inner.enterStreaming(); }
  enterDraining(): void { this.inner.enterDraining(); }
  latchConsumerError(error: ArkDbError, synchronized: boolean = false): void {
    this.inner.latchConsumerError(error, synchronized); this.consumerLatched = true;
  }
}

class ScopedSessionPreparedExecutor implements PostgresPreparedExecutor {
  constructor(session: ScopedPostgresTransactionSession, inner: PostgresPreparedExecutor) { sessionPreparedDelegates.set(this, { session: session, inner: inner }); }
  execute(sql: string, parameters: PostgresParameter[], options: QueryOptions): Promise<PostgresQueryResult> {
    try { const d = this.delegate(); d.session.assertActive(); return observePromise<PostgresQueryResult>(d.inner.execute(sql, parameters, options)); }
    catch (err) { return rejectObserved<PostgresQueryResult>(toPostgresArkDbError(err as Object)); }
  }
  queryStream(sql: string, parameters: PostgresParameter[], options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    try { const d = this.delegate(); d.session.assertActive(); return observePromise<QueryExecutionSummary>(d.inner.queryStream(sql, parameters, options, sink)); }
    catch (err) { return rejectObserved<QueryExecutionSummary>(toPostgresArkDbError(err as Object)); }
  }
  private delegate(): SessionPreparedDelegate {
    const d = sessionPreparedDelegates.get(this);
    if (d === undefined) throw ArkDbError.protocol('PostgreSQL transaction prepared executor is uninitialized.');
    return d;
  }
}

class ScopedPostgresTransactionSession implements PostgresSession {
  private readonly host: PostgresTransactionCommandHost; private readonly channel: PostgresMessageChannel; private readonly executeStep: StepExecutor;
  private readonly featuresView: PostgresConnectionFeatures = new PostgresConnectionFeatures();
  private expired: boolean = false; private activeSettlementTask: Promise<ArkDbError | null> | null = null;
  constructor(host: PostgresTransactionCommandHost, channel: PostgresMessageChannel, executeStep: StepExecutor) {
    this.host = host; this.channel = channel; this.executeStep = executeStep;
    const innerPrepared = new PostgresConnectionPreparedExecutor(
      (f: PostgresPreparedFrames, o: QueryOptions): Promise<PostgresQueryResult> =>
        this.runActiveStep<PostgresQueryResult>((sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<PostgresQueryResult> => runPostgresExtendedQuery(sh, this.channel, ss, f, o)),
      (f: PostgresPreparedFrames, o: QueryOptions, sk: QueryResultSink): Promise<QueryExecutionSummary> =>
        this.runActiveStep<QueryExecutionSummary>((sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<QueryExecutionSummary> => runPostgresPortalStream(sh, this.channel, ss, f, o, sk)));
    this.featuresView.prepared = new ScopedSessionPreparedExecutor(this, innerPrepared);
  }
  get postgresFeatures(): PostgresConnectionFeatures { this.assertActive(); return this.featuresView; }
  get serverInfo(): PostgresServerInfo { this.assertActive(); return this.host.serverInfo; }
  get sessionStatus(): PostgresDatabaseSessionStatus { this.assertActive(); return this.host.sessionStatus.clone(); }
  get hasActiveCommand(): boolean { return this.activeSettlementTask !== null; }
  assertActive(): void { if (this.expired) throw ArkDbError.validation('PostgreSQL transaction session is no longer active.'); }
  expire(): void { this.expired = true; }
  waitForActiveCommand(): Promise<ArkDbError | null> { return this.activeSettlementTask !== null ? this.activeSettlementTask : Promise.resolve<ArkDbError | null>(null); }
  private runActiveStep<R>(op: (sh: StepCommandHost, ss: PostgresCommandCloseSettlement) => Promise<R>): Promise<R> {
    return this.runSerialized<R>((): Promise<R> => this.executeStep<R>(async (sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<R> => {
      await ensureActiveTransaction(sh, false); return op(sh, ss);
    }));
  }
  query(sql: string): Promise<PostgresQueryResult> {
    return this.runActiveStep<PostgresQueryResult>((sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<PostgresQueryResult> => runPostgresSimpleQuery(sh, this.channel, ss, sql));
  }
  queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return this.runActiveStep<QueryExecutionSummary>((sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<QueryExecutionSummary> => runPostgresQueryStream(sh, this.channel, ss, sql, options, sink));
  }
  savepoint(name: string): Promise<void> { return this.runSavepoint(name, 'SAVEPOINT ', 'SAVEPOINT'); }
  rollbackTo(name: string): Promise<void> { return this.runSavepoint(name, 'ROLLBACK TO SAVEPOINT ', 'ROLLBACK'); }
  releaseSavepoint(name: string): Promise<void> { return this.runSavepoint(name, 'RELEASE SAVEPOINT ', 'RELEASE'); }

  private runSavepoint(name: string, sqlPrefix: string, expectedTag: string): Promise<void> {
    return this.runSerialized<void>(async (): Promise<void> => {
      if (typeof name !== 'string') throw ArkDbError.validation('PostgreSQL savepoint name must be a non-empty string.');
      const quoted = quotePostgresIdentifier([name]);
      return this.executeStep<void>(async (sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<void> => {
        await ensureActiveTransaction(sh, true);
        const res = await runPostgresSimpleQuery(sh, this.channel, ss, sqlPrefix + quoted);
        throwIfClosed(ss);
        if (res.commandTag !== expectedTag || res.columns.length !== 0 || res.rows.length !== 0 || res.additionalResults.length !== 0 ||
          !sh.sessionStatus.known || !sh.sessionStatus.inTransaction || sh.sessionStatus.transactionState !== PostgresTransactionState.InTransaction) {
          const err = ArkDbError.protocol('Unexpected PostgreSQL savepoint completion state.'); await sh.retire(err); throw err;
        }
      });
    });
  }
  private runSerialized<R>(op: () => Promise<R>): Promise<R> {
    if (this.expired) return rejectObserved<R>(ArkDbError.validation('PostgreSQL transaction session is no longer active.'));
    if (this.activeSettlementTask !== null) return rejectObserved<R>(ArkDbError.protocol('Another PostgreSQL transaction session command is already active.'));
    let settleDone: (err: ArkDbError | null) => void = (_e: ArkDbError | null): void => {};
    const barrier = new Promise<ArkDbError | null>((res: (v: ArkDbError | null) => void): void => { settleDone = res; });
    this.activeSettlementTask = barrier;
    let task: Promise<R>;
    try { task = op(); } catch (syncErr) {
      this.activeSettlementTask = null; const typedSync = toPostgresArkDbError(syncErr as Object); settleDone(typedSync); return rejectObserved<R>(typedSync);
    }
    return observePromise<R>(task.then(
      (val: R): R => { if (this.activeSettlementTask === barrier) this.activeSettlementTask = null; settleDone(null); return val; },
      (err: Object): Promise<R> => { if (this.activeSettlementTask === barrier) this.activeSettlementTask = null; settleDone(toPostgresArkDbError(err)); return Promise.reject<R>(err); }));
  }
}

async function executeTransactionScope<T>(
  host: PostgresTransactionCommandHost, channel: PostgresMessageChannel, parentSettlement: PostgresCommandCloseSettlement,
  beginSql: string, body: (session: PostgresSession) => Promise<T>, onSuccess: (val: T) => void
): Promise<PostgresTransactionFailure | null> {
  let activeStepSettlement: PostgresCommandCloseSettlement | null = null;
  let lastUnsyncStepError: ArkDbError | null = null;
  const runStep: StepExecutor = async <R>(fn: (stepHost: StepCommandHost, stepSettlement: PostgresCommandCloseSettlement) => Promise<R>): Promise<R> => {
    throwIfClosed(parentSettlement);
    if (!host.isSynchronized()) throw lastUnsyncStepError !== null ? lastUnsyncStepError : ArkDbError.protocol('PostgreSQL transaction lost synchronization.');
    host.enterExecuting();
    const stepSettlement = new PostgresCommandCloseSettlement(parentSettlement.scope); const stepHost = new StepCommandHost(host);
    activeStepSettlement = stepSettlement;
    if (parentSettlement.closeReason !== null) stepSettlement.signalClose(parentSettlement.closeReason);
    let delivered = false;
    try {
      const out = await fn(stepHost, stepSettlement);
      throwIfClosed(parentSettlement); stepSettlement.markDelivered(); delivered = true; return out;
    } catch (stepErr) {
      const typedStep = toPostgresArkDbError(stepErr as Object);
      if (parentSettlement.closeReason === null && !host.isSynchronized() && lastUnsyncStepError === null) lastUnsyncStepError = typedStep;
      throw typedStep;
    } finally {
      if (activeStepSettlement === stepSettlement) activeStepSettlement = null;
      if (!delivered) stepSettlement.discardUndelivered();
      stepSettlement.markSettled();
      if (stepHost.consumerLatched && parentSettlement.closeReason === null) host.clearConsumerError();
    }
  };
  const session = new ScopedPostgresTransactionSession(host, channel, runStep);
  parentSettlement.onCloseRequested((err: ArkDbError): void => { session.expire(); if (activeStepSettlement !== null) activeStepSettlement.signalClose(err); });
  await runStep<PostgresDatabaseSessionStatus>((sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> => runPostgresBegin(sh, channel, ss, beginSql));

  let hasCallbackFailure = false; let callbackFailure: Object | null | undefined = undefined;
  try {
    const val = await body(session);
    if (session.hasActiveCommand) {
      hasCallbackFailure = true; callbackFailure = ArkDbError.protocol('PostgreSQL transaction callback settled while a session command was still active.');
    } else onSuccess(val);
  } catch (err) { hasCallbackFailure = true; callbackFailure = err as Object | null | undefined; } finally { session.expire(); }

  if (hasCallbackFailure && session.hasActiveCommand) host.latchConsumerError(composeCallbackFailure(callbackFailure, null), false);
  const abandonedErr = await session.waitForActiveCommand();
  if (parentSettlement.closeReason === null) host.clearConsumerError();
  throwIfClosed(parentSettlement);
  if (!host.isSynchronized()) {
    const unsyncCause = abandonedErr !== null ? abandonedErr : lastUnsyncStepError;
    throw hasCallbackFailure ? composeCallbackFailure(callbackFailure, unsyncCause)
      : (unsyncCause !== null ? unsyncCause : ArkDbError.protocol('PostgreSQL transaction lost synchronization.'));
  }

  if (hasCallbackFailure) {
    const baseFailure = composeCallbackFailure(callbackFailure, abandonedErr);
    if (!isKnownTransactionState(host.sessionStatus)) {
      const err = postgresAppendCleanupError(baseFailure, ArkDbError.protocol('PostgreSQL transaction state is unknown.'));
      await host.retire(err); throw err;
    }
    if (host.sessionStatus.inTransaction) await runRollbackCleanup(host, channel, parentSettlement, runStep, baseFailure);
    if (!host.isSynchronized() || !isIdleTransactionState(host.sessionStatus)) {
      if (host.isSynchronized()) await host.retire(baseFailure);
      throw baseFailure;
    }
    return new PostgresTransactionFailure(abandonedErr !== null ? baseFailure : callbackFailure);
  }

  try {
    await runStep<PostgresDatabaseSessionStatus>((sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> => runPostgresCommit(sh, channel, ss));
    return null;
  } catch (commitErr) {
    throwIfClosed(parentSettlement); const typedCommit = toPostgresArkDbError(commitErr as Object);
    if (!host.isSynchronized() || isFatalError(typedCommit)) throw typedCommit;
    if (isIdleTransactionState(host.sessionStatus)) return new PostgresTransactionFailure(typedCommit);
    if (isKnownTransactionState(host.sessionStatus) && host.sessionStatus.inTransaction &&
      await runRollbackCleanup(host, channel, parentSettlement, runStep, typedCommit)) {
      return new PostgresTransactionFailure(typedCommit);
    }
    if (host.isSynchronized()) await host.retire(typedCommit);
    throw typedCommit;
  }
}

async function runRollbackCleanup(host: PostgresTransactionCommandHost, channel: PostgresMessageChannel,
  parentSettlement: PostgresCommandCloseSettlement, runStep: StepExecutor, primary: ArkDbError): Promise<boolean> {
  host.latchConsumerError(primary, false);
  try {
    await runStep<PostgresDatabaseSessionStatus>((sh: StepCommandHost, ss: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> => runPostgresRollback(sh, channel, ss));
  } catch (rbErr) {
    if (parentSettlement.closeReason !== null) throw parentSettlement.closeReason;
    host.clearConsumerError(); const typedRb = toPostgresArkDbError(rbErr as Object);
    const composed = typedRb !== primary ? postgresAppendCleanupError(primary, typedRb) : primary;
    if (host.isSynchronized() && !isIdleTransactionState(host.sessionStatus)) await host.retire(composed);
    throw composed;
  }
  if (parentSettlement.closeReason === null) host.clearConsumerError();
  return host.isSynchronized() && isIdleTransactionState(host.sessionStatus);
}

async function ensureActiveTransaction(sh: StepCommandHost, savepointMode: boolean): Promise<void> {
  if (!isKnownTransactionState(sh.sessionStatus)) {
    const err = ArkDbError.protocol('PostgreSQL transaction state is unknown.'); await sh.retire(err); throw err;
  }
  if (!sh.sessionStatus.inTransaction || sh.sessionStatus.transactionState === PostgresTransactionState.Idle) {
    throw ArkDbError.validation(savepointMode ? 'PostgreSQL savepoints require an active transaction.' : 'PostgreSQL connection is not in an active transaction.');
  }
}
function throwIfClosed(settlement: PostgresCommandCloseSettlement): void {
  const err = settlement.closeReason; if (err !== null) throw err;
}
function observePromise<R>(p: Promise<R>): Promise<R> { p.then((_v: R): void => {}, (_e: Object): void => {}); return p; }
function rejectObserved<R>(err: Object): Promise<R> { return observePromise<R>(Promise.reject<R>(err)); }
function composeCallbackFailure(err: Object | null | undefined, cleanupErr: ArkDbError | null): ArkDbError {
  const base = err === null || err === undefined ? ArkDbError.protocol('PostgreSQL transaction callback failed.') : toPostgresArkDbError(err);
  return cleanupErr !== null && cleanupErr !== base ? postgresAppendCleanupError(base, cleanupErr) : base;
}
function isKnownTransactionState(status: PostgresDatabaseSessionStatus): boolean {
  const s = status.transactionState;
  const valid = s === PostgresTransactionState.Idle || s === PostgresTransactionState.InTransaction || s === PostgresTransactionState.FailedTransaction;
  return status.known === true && valid && status.inTransaction === (s === PostgresTransactionState.InTransaction || s === PostgresTransactionState.FailedTransaction);
}
function isIdleTransactionState(status: PostgresDatabaseSessionStatus): boolean {
  return status.known === true && !status.inTransaction && status.transactionState === PostgresTransactionState.Idle;
}
function isFatalError(err: Object | null | undefined): boolean {
  if (!(err instanceof PostgresError)) return false;
  return err.severity === 'FATAL' || err.severity === 'PANIC' || err.localizedSeverity === 'FATAL' || err.localizedSeverity === 'PANIC';
}
