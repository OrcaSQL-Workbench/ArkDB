import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, DatabaseSessionStatus,
  DbTransactionController, QueryExecutionSummary, QueryOptions, QueryResultSink
} from '@arkdb/core';
import {
  PostgresConnectionConfig, PostgresConnectionFeatures, PostgresConnectionOptions,
  PostgresDatabaseSessionStatus, PostgresDriverCapabilities, PostgresDriverFactory, PostgresError,
  PostgresQueryResult, PostgresServerInfo, PostgresSession, PostgresSslMode,
  PostgresTransactionIsolation, PostgresTransactionOptions, PostgresTransactionRunner, PostgresTransactionState
} from '../../../../../Index';
import { PostgresConnection } from '../../../../main/ets/pgsql/PostgresConnection';
import { PostgresSimpleQueryHost } from '../../../../main/ets/pgsql/command/PostgresSimpleQuery';
import { runPostgresBegin, runPostgresCommit, runPostgresRollback } from '../../../../main/ets/pgsql/command/PostgresTransactionCommand';
import { PostgresConnectionLifecycle, PostgresLifecycleTransport } from '../../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresConnectionTransactions } from '../../../../main/ets/pgsql/connection/PostgresFeatureFacades';
import {
  PostgresCommandGate, PostgresCommandKind, PostgresCommandLifecycleObserver, PostgresCommandScope
} from '../../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement } from '../../../../main/ets/pgsql/execution/PostgresSettlements';
import { buildPostgresBeginSql, validatePostgresTransactionOptions } from '../../../../main/ets/pgsql/features/transaction/PostgresTransactionOptions';
import { PostgresMessageChannel, PostgresReadyStatus } from '../../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresTransactionControlTest(): void {
  describe('PostgresTransactionControl', () => {
    it('validatesClonesAndBuildsPostgresTransactionBeginSqlAndContracts', 0, async () => {
      const defaults = new PostgresTransactionOptions();
      expect(defaults.isolation === PostgresTransactionIsolation.ReadCommitted && !defaults.readOnly &&
        !defaults.deferrable && defaults.validate().length === 0).assertTrue();
      expect(buildPostgresBeginSql(defaults)).assertEqual('BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE');
      const rrReadOnly = defaults.clone();
      rrReadOnly.isolation = PostgresTransactionIsolation.RepeatableRead; rrReadOnly.readOnly = true;
      expect(defaults.isolation === PostgresTransactionIsolation.ReadCommitted && !defaults.readOnly &&
        rrReadOnly.validate().length === 0).assertTrue();
      expect(buildPostgresBeginSql(rrReadOnly)).assertEqual('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      expect(buildPostgresBeginSql(makeOpts(PostgresTransactionIsolation.ReadCommitted, true, false)))
        .assertEqual('BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY');
      expect(buildPostgresBeginSql(makeOpts(PostgresTransactionIsolation.RepeatableRead, false, false)))
        .assertEqual('BEGIN ISOLATION LEVEL REPEATABLE READ READ WRITE');
      expect(buildPostgresBeginSql(makeOpts(PostgresTransactionIsolation.Serializable, false, false)))
        .assertEqual('BEGIN ISOLATION LEVEL SERIALIZABLE READ WRITE');
      expect(buildPostgresBeginSql(makeOpts(PostgresTransactionIsolation.Serializable, true, false)))
        .assertEqual('BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY');
      const serDeferrable = makeOpts(PostgresTransactionIsolation.Serializable, true, true);
      expect(serDeferrable.validate().length === 0 && buildPostgresBeginSql(serDeferrable) ===
        'BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE').assertTrue();

      const nullOpts: PostgresTransactionOptions | null = null;
      const undefOpts: PostgresTransactionOptions | undefined = undefined;
      for (const missing of [nullOpts!, undefOpts!, (new Object()) as PostgresTransactionOptions]) {
        const errs = validatePostgresTransactionOptions(missing);
        expect(errs.length === 1 && errs[0].kind === ArkDbErrorKind.Validation &&
          errs[0].message === 'PostgreSQL transaction options are required.').assertTrue();
        expect(syncFail((): void => { buildPostgresBeginSql(missing); }).message)
          .assertEqual('PostgreSQL transaction options are required.');
      }
      const badFields = new PostgresTransactionOptions();
      badFields.isolation = 'read_uncommitted' as PostgresTransactionIsolation;
      badFields.readOnly = ('yes' as Object) as boolean; badFields.deferrable = (1 as Object) as boolean;
      const fieldErrs = badFields.validate();
      expect(fieldErrs.length === 3 &&
        fieldErrs[0].message === 'Unsupported PostgreSQL transaction isolation level.' &&
        fieldErrs[1].message === 'PostgreSQL transaction readOnly must be a boolean.' &&
        fieldErrs[2].message === 'PostgreSQL transaction deferrable must be a boolean.' &&
        syncFail((): void => { buildPostgresBeginSql(badFields); }).kind === ArkDbErrorKind.Validation).assertTrue();

      for (const badDef of [
        makeOpts(PostgresTransactionIsolation.ReadCommitted, false, true),
        makeOpts(PostgresTransactionIsolation.ReadCommitted, true, true),
        makeOpts(PostgresTransactionIsolation.RepeatableRead, true, true),
        makeOpts(PostgresTransactionIsolation.Serializable, false, true)
      ]) {
        const errs = badDef.validate();
        expect(errs.length === 1 && errs[0].kind === ArkDbErrorKind.Validation && errs[0].message ===
          'PostgreSQL DEFERRABLE transactions require SERIALIZABLE isolation and READ ONLY mode.' &&
          syncFail((): void => { buildPostgresBeginSql(badDef); }).kind === ArkDbErrorKind.Validation).assertTrue();
      }
      const conn = new PostgresDriverFactory().create(new PostgresConnectionOptions(makeConfig(), 'pw'));
      const caps: PostgresDriverCapabilities = new PostgresDriverFactory().capabilities;
      const txRunner: PostgresTransactionRunner | undefined = conn.postgresFeatures.transactions;
      expect(!caps.supportsTransactions && conn.features.transactions === undefined && txRunner === undefined).assertTrue();
      const ranTag = await new StubTransactionRunner().run<string>(serDeferrable, async (s: PostgresSession): Promise<string> => {
        await s.savepoint('sp1'); await s.rollbackTo('sp1'); await s.releaseSavepoint('sp1');
        return s.serverInfo.driverId;
      });
      expect(ranTag).assertEqual('pgsql');
    });

    it('beginsTransactionsGuardsActiveStatesAndDelegatesCycleFreeFacade', 0, async () => {
      const nullCtrl: DbTransactionController | null = null;
      expect(syncFail((): void => { new PostgresConnectionTransactions(nullCtrl!); }).kind).assertEqual(ArkDbErrorKind.Validation);
      const sub = new CustomTxConnection(makeConfig());
      const subFacade = new PostgresConnectionTransactions(sub);
      expect(JSON.stringify(subFacade)).assertEqual('{}');
      const subStatus = subFacade.sessionStatus as PostgresDatabaseSessionStatus;
      expect(subStatus.transactionState).assertEqual(PostgresTransactionState.InTransaction);
      subStatus.transactionState = PostgresTransactionState.Idle;
      expect((subFacade.sessionStatus as PostgresDatabaseSessionStatus).transactionState).assertEqual(PostgresTransactionState.InTransaction);
      await subFacade.begin(); await subFacade.commit(); await subFacade.rollback();
      expect(sub.calls.join(',')).assertEqual('begin,commit,rollback');

      const kinds: PostgresCommandKind[] = [];
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openReady(tp, new PostgresCommandGate(new KindObserver(kinds)));
      await conn.connect();
      const facade = new PostgresConnectionTransactions(conn);
      expect(JSON.stringify(facade) === '{}' && conn.features.transactions === undefined &&
        conn.postgresFeatures.transactions === undefined).assertTrue();
      tp.writes.length = 0; tp.rawWrites.length = 0;

      tp.enqueue([concatFrames([msgCmd('BEGIN'), msgReady(0x54)])]);
      const st = await conn.begin();
      assertBytes(tp.writes[0], expectedQueryFrame('BEGIN')); assertZeroed(tp.rawWrites[0]);
      expect(kinds.length === 2 && kinds[1] === PostgresCommandKind.Transaction && st.known &&
        st.autocommit && st.inTransaction && st.transactionState === PostgresTransactionState.InTransaction).assertTrue();
      st.inTransaction = false; st.transactionState = PostgresTransactionState.Idle;
      expect(conn.sessionStatus.inTransaction &&
        (facade.sessionStatus as PostgresDatabaseSessionStatus).transactionState === PostgresTransactionState.InTransaction).assertTrue();
      const dupErr = await asyncFail((): Promise<DatabaseSessionStatus> => facade.begin());
      expect(dupErr.kind === ArkDbErrorKind.Validation &&
        dupErr.message === 'PostgreSQL connection is already in a transaction.' &&
        tp.writes.length === 1 && conn.state === ConnectionState.Ready).assertTrue();
      await conn.close();

      const failedTp = new QueueTransport([bootFrames(0x45)]);
      const failedConn = openReady(failedTp);
      await failedConn.connect(); failedTp.writes.length = 0;
      const failedBeginErr = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => failedConn.begin());
      expect(failedBeginErr.kind === ArkDbErrorKind.Validation &&
        failedBeginErr.message === 'PostgreSQL connection is already in a transaction.' &&
        failedTp.writes.length === 0 && failedConn.state === ConnectionState.Ready &&
        failedConn.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();
      await failedConn.close();

      const customSql = buildPostgresBeginSql(makeOpts(PostgresTransactionIsolation.Serializable, true, true));
      const customTp = new QueueTransport([bootFrames(0x49)]);
      const customLife = openLifecycle(customTp);
      await customLife.connect(); customTp.writes.length = 0;
      const blankBeginErr = await asyncFail((): Promise<PostgresDatabaseSessionStatus> =>
        runOnLifecycle(customLife, (h: PostgresSimpleQueryHost, ch: PostgresMessageChannel,
          cst: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> => runPostgresBegin(h, ch, cst, '   ')));
      expect(blankBeginErr.kind === ArkDbErrorKind.Validation && customTp.writes.length === 0).assertTrue();
      customTp.enqueue([concatFrames([msgCmd('BEGIN'), msgReady(0x54)])]);
      const customSt = await runOnLifecycle(customLife, (h: PostgresSimpleQueryHost,
        ch: PostgresMessageChannel, cst: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> =>
        runPostgresBegin(h, ch, cst, customSql));
      assertBytes(customTp.writes[0], expectedQueryFrame(customSql));
      expect(customSt.transactionState).assertEqual(PostgresTransactionState.InTransaction);
      await customLife.close();

      await assertUnknownStateRetires(runPostgresBegin);
      await assertDesyncRetires(0x49, [concatFrames([msgCmd('BEGIN'), msgReady(0x49)]),
        concatFrames([msgCmd('SET'), msgReady(0x54)])],
        (dc: PostgresConnection): Promise<PostgresDatabaseSessionStatus> => dc.begin(),
        'PostgreSQL BEGIN did not enter an active transaction.');
    });

    it('recoversFailedTransactionsWithRollbackAndEnforcesRollbackInvariants', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openReady(tp);
      await conn.connect();
      const facade = new PostgresConnectionTransactions(conn);
      tp.writes.length = 0; tp.rawWrites.length = 0;
      tp.enqueue([
        concatFrames([msgCmd('BEGIN'), msgReady(0x54)]),
        concatFrames([msgError('23505', 'duplicate key value'), msgReady(0x45)]),
        concatFrames([msgError('25P02', 'current transaction is aborted'), msgReady(0x45)]),
        concatFrames([msgCmd('ROLLBACK'), msgReady(0x49)]),
        concatFrames([msgCmd('SELECT 1'), msgReady(0x49)])
      ]);
      await conn.begin();
      const dupKeyErr = await asyncFail((): Promise<PostgresQueryResult> => conn.query('INSERT INTO t VALUES (1)'));
      expect(dupKeyErr instanceof PostgresError && dupKeyErr.sqlState === '23505' &&
        conn.state === ConnectionState.Ready && conn.sessionStatus.known && conn.sessionStatus.inTransaction &&
        conn.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();
      const abortedErr = await asyncFail((): Promise<PostgresQueryResult> => conn.query('SELECT 1'));
      expect(abortedErr instanceof PostgresError && abortedErr.sqlState === '25P02' &&
        abortedErr.nativeCode === '25P02' && conn.sessionStatus.inTransaction &&
        conn.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();

      const rbSt = await conn.rollback();
      assertBytes(tp.writes[3], expectedQueryFrame('ROLLBACK')); assertZeroed(tp.rawWrites[3]);
      expect(rbSt.known && rbSt.autocommit && !rbSt.inTransaction &&
        rbSt.transactionState === PostgresTransactionState.Idle && conn.state === ConnectionState.Ready).assertTrue();
      rbSt.inTransaction = true;
      expect(!conn.sessionStatus.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();
      expect((await conn.query('SELECT 1')).commandTag).assertEqual('SELECT 1');

      tp.writes.length = 0; tp.rawWrites.length = 0;
      tp.enqueue([
        concatFrames([msgCmd('BEGIN'), msgReady(0x54)]),
        concatFrames([msgCmd('ROLLBACK'), msgReady(0x49)]),
        concatFrames([msgNotice('25P01', 'there is no transaction in progress'), msgCmd('ROLLBACK'), msgReady(0x49)])
      ]);
      await facade.begin();
      const activeRb = await facade.rollback() as PostgresDatabaseSessionStatus;
      assertBytes(tp.writes[1], expectedQueryFrame('ROLLBACK'));
      expect(!activeRb.inTransaction && activeRb.transactionState === PostgresTransactionState.Idle).assertTrue();
      const idleRb = await conn.rollback();
      assertBytes(tp.writes[2], expectedQueryFrame('ROLLBACK'));
      expect(idleRb.known && !idleRb.inTransaction && idleRb.transactionState === PostgresTransactionState.Idle &&
        conn.state === ConnectionState.Ready).assertTrue();
      await conn.close();

      await assertUnknownStateRetires(runPostgresRollback);
      await assertDesyncRetires(0x54, [concatFrames([msgCmd('ROLLBACK'), msgReady(0x54)]),
        concatFrames([msgCmd('ROLLBACK'), msgReady(0x45)]), concatFrames([msgCmd('COMMIT'), msgReady(0x49)])],
        (dc: PostgresConnection): Promise<PostgresDatabaseSessionStatus> => dc.rollback(),
        'PostgreSQL ROLLBACK did not finish the transaction.');
    });

    it('enforcesCommitGuardsAbortedRollbackTrapAndLifecycleInvariants', 0, async () => {
      await assertAllTxOpsProtocol(openReady(new QueueTransport([])), 'PostgreSQL connection is not connected.');
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openReady(tp);
      await conn.connect();
      const facade = new PostgresConnectionTransactions(conn);
      tp.writes.length = 0; tp.rawWrites.length = 0;

      const idleCommitErr = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => conn.commit());
      expect(idleCommitErr.kind === ArkDbErrorKind.Validation &&
        idleCommitErr.message === 'PostgreSQL connection is not in an active transaction.' &&
        tp.writes.length === 0 && conn.state === ConnectionState.Ready &&
        conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();

      tp.enqueue([concatFrames([msgCmd('BEGIN'), msgReady(0x54)]), concatFrames([msgCmd('COMMIT'), msgReady(0x49)])]);
      await conn.begin();
      const committed = await facade.commit() as PostgresDatabaseSessionStatus;
      assertBytes(tp.writes[1], expectedQueryFrame('COMMIT')); assertZeroed(tp.rawWrites[1]);
      expect(committed.known && committed.autocommit && !committed.inTransaction &&
        committed.transactionState === PostgresTransactionState.Idle && conn.state === ConnectionState.Ready).assertTrue();
      committed.inTransaction = true;
      expect(!conn.sessionStatus.inTransaction).assertTrue();

      tp.writes.length = 0; tp.rawWrites.length = 0;
      tp.enqueue([
        concatFrames([msgCmd('BEGIN'), msgReady(0x54)]),
        concatFrames([msgError('23505', 'duplicate key'), msgReady(0x45)]),
        concatFrames([msgCmd('ROLLBACK'), msgReady(0x49)]),
        concatFrames([msgCmd('ROLLBACK'), msgReady(0x49)])
      ]);
      await conn.begin();
      await asyncFail((): Promise<PostgresQueryResult> => conn.query('INSERT INTO t VALUES (1)'));
      const failedCommitErr = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => conn.commit());
      assertBytes(tp.writes[2], expectedQueryFrame('ROLLBACK')); assertZeroed(tp.rawWrites[2]);
      expect(isAbortedCommitError(failedCommitErr) && conn.state === ConnectionState.Ready &&
        !conn.sessionStatus.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();
      const catchRb = await conn.rollback();
      expect(!catchRb.inTransaction && catchRb.transactionState === PostgresTransactionState.Idle).assertTrue();

      tp.writes.length = 0;
      tp.enqueue([
        concatFrames([msgCmd('BEGIN'), msgReady(0x54)]), concatFrames([msgCmd('ROLLBACK'), msgReady(0x49)]),
        concatFrames([msgCmd('BEGIN'), msgReady(0x54)]), concatFrames([msgError('23505', 'deferred unique'), msgReady(0x49)]),
        concatFrames([msgCmd('ROLLBACK'), msgReady(0x49)])
      ]);
      await conn.begin();
      const trapErr = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => conn.commit());
      assertBytes(tp.writes[1], expectedQueryFrame('COMMIT'));
      expect(isAbortedCommitError(trapErr) && conn.state === ConnectionState.Ready &&
        !conn.sessionStatus.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();
      await conn.begin();
      const deferredErr = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => conn.commit());
      expect(deferredErr instanceof PostgresError && deferredErr.sqlState === '23505' &&
        conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction &&
        conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();
      expect((await conn.rollback()).transactionState).assertEqual(PostgresTransactionState.Idle);
      await conn.close();

      await assertUnknownStateRetires(runPostgresCommit);
      await assertDesyncRetires(0x45, [concatFrames([msgCmd('ROLLBACK'), msgReady(0x45)]),
        concatFrames([msgCmd('COMMIT'), msgReady(0x49)])],
        (fc: PostgresConnection): Promise<PostgresDatabaseSessionStatus> => fc.commit(),
        'PostgreSQL ROLLBACK did not exit the failed transaction.');
      await assertDesyncRetires(0x54, [concatFrames([msgCmd('COMMIT'), msgReady(0x54)])],
        (dc: PostgresConnection): Promise<PostgresDatabaseSessionStatus> => dc.commit(),
        'PostgreSQL COMMIT did not finish the active transaction.');
      await assertDesyncRetires(0x54, [concatFrames([msgCmd('SET'), msgReady(0x49)])],
        (dc: PostgresConnection): Promise<PostgresDatabaseSessionStatus> => dc.commit(),
        'Unexpected PostgreSQL COMMIT command tag: SET');

      const hangTp = new QueueTransport([bootFrames(0x54)]);
      const hangConn = openReady(hangTp);
      await hangConn.connect(); hangTp.hangAtEmpty = true;
      const inFlightCommit = hangConn.commit();
      for (let i = 0; i < 64 && !hangTp.waitingRead; i += 1) { await Promise.resolve(); }
      expect(hangTp.waitingRead).assertTrue();
      const closeDone = hangConn.close();
      const cancelErr = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => inFlightCommit);
      await closeDone;
      expect(cancelErr.kind === ArkDbErrorKind.Cancelled && hangConn.state === ConnectionState.Closed).assertTrue();
      await assertAllTxOpsProtocol(hangConn, 'PostgreSQL connection is closed.');
    });
  });
}

async function assertAllTxOpsProtocol(conn: PostgresConnection, expectedMsg: string): Promise<void> {
  for (const op of [(): Promise<PostgresDatabaseSessionStatus> => conn.begin(),
    (): Promise<PostgresDatabaseSessionStatus> => conn.commit(),
    (): Promise<PostgresDatabaseSessionStatus> => conn.rollback()]) {
    const err = await asyncFail(op);
    expect(err.kind === ArkDbErrorKind.Protocol && err.message === expectedMsg).assertTrue();
  }
}
async function assertDesyncRetires(bootReady: number, framesList: Uint8Array[],
  op: (c: PostgresConnection) => Promise<PostgresDatabaseSessionStatus>, expectedMsg: string): Promise<void> {
  for (const frames of framesList) {
    const dc = openReady(new QueueTransport([bootFrames(bootReady), frames]));
    await dc.connect();
    const err = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => op(dc));
    expect(err.kind === ArkDbErrorKind.Protocol && err.message === expectedMsg && dc.state === ConnectionState.Error).assertTrue();
  }
}

function isAbortedCommitError(err: ArkDbError): boolean {
  return err instanceof PostgresError && err.kind === ArkDbErrorKind.Server && err.sqlState === '25P02' &&
    err.nativeCode === '25P02' && err.severity === 'ERROR' &&
    err.message === 'PostgreSQL cannot commit a failed transaction; transaction was rolled back.';
}
function openLifecycle(tp: QueueTransport): PostgresConnectionLifecycle {
  return new PostgresConnectionLifecycle(makeConfig(), '', new FixedTimers(), (): PostgresLifecycleTransport => tp);
}
function runOnLifecycle(life: PostgresConnectionLifecycle,
  op: (h: PostgresSimpleQueryHost, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement) => Promise<PostgresDatabaseSessionStatus>
): Promise<PostgresDatabaseSessionStatus> {
  return life.runCommand<PostgresDatabaseSessionStatus>(PostgresCommandKind.Transaction,
    (sc: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> =>
      op(new TestSimpleHost(life, sc), ch, st));
}
async function assertUnknownStateRetires(
  op: (h: PostgresSimpleQueryHost, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement) => Promise<PostgresDatabaseSessionStatus>
): Promise<void> {
  for (const mutate of [(s: PostgresDatabaseSessionStatus): void => { s.known = false; },
    (s: PostgresDatabaseSessionStatus): void => { s.inTransaction = true; }]) {
    const life = openLifecycle(new QueueTransport([bootFrames(0x49)]));
    await life.connect(); mutate(life.sessionStatus);
    const err = await asyncFail((): Promise<PostgresDatabaseSessionStatus> => runOnLifecycle(life, op));
    expect(err.kind === ArkDbErrorKind.Protocol && err.message === 'PostgreSQL transaction state is unknown.' &&
      life.state === ConnectionState.Error).assertTrue();
  }
}
function makeOpts(isolation: PostgresTransactionIsolation, readOnly: boolean, deferrable: boolean): PostgresTransactionOptions {
  const opts = new PostgresTransactionOptions();
  opts.isolation = isolation; opts.readOnly = readOnly; opts.deferrable = deferrable;
  return opts;
}
function syncFail(op: () => void): ArkDbError {
  let err: Object | null = null;
  try { op(); } catch (e) { err = e as Object; }
  expect(err instanceof ArkDbError).assertTrue();
  return err as ArkDbError;
}
class StubSession implements PostgresSession {
  readonly postgresFeatures: PostgresConnectionFeatures = new PostgresConnectionFeatures();
  readonly serverInfo: PostgresServerInfo = stubServerInfo();
  readonly sessionStatus: PostgresDatabaseSessionStatus = new PostgresDatabaseSessionStatus();
  async query(_sql: string): Promise<PostgresQueryResult> { return new PostgresQueryResult(); }
  async queryStream(_sql: string, _o: QueryOptions, _s: QueryResultSink): Promise<QueryExecutionSummary> { return new QueryExecutionSummary(); }
  async savepoint(_n: string): Promise<void> {}
  async rollbackTo(_n: string): Promise<void> {}
  async releaseSavepoint(_n: string): Promise<void> {}
}
class StubTransactionRunner implements PostgresTransactionRunner {
  run<T>(_o: PostgresTransactionOptions, body: (s: PostgresSession) => Promise<T>): Promise<T> { return body(new StubSession()); }
}
function stubServerInfo(): PostgresServerInfo { const info = new PostgresServerInfo(); info.driverId = 'pgsql'; return info; }
class CustomTxConnection extends PostgresConnection {
  readonly calls: string[] = [];
  constructor(config: PostgresConnectionConfig) { super(config, ''); }
  get sessionStatus(): PostgresDatabaseSessionStatus {
    const st = new PostgresDatabaseSessionStatus();
    st.known = true; st.autocommit = true; st.inTransaction = true; st.transactionState = PostgresTransactionState.InTransaction;
    return st;
  }
  async begin(): Promise<PostgresDatabaseSessionStatus> { this.calls.push('begin'); return this.sessionStatus; }
  async commit(): Promise<PostgresDatabaseSessionStatus> { this.calls.push('commit'); return this.sessionStatus; }
  async rollback(): Promise<PostgresDatabaseSessionStatus> { this.calls.push('rollback'); return this.sessionStatus; }
}
class TestSimpleHost implements PostgresSimpleQueryHost {
  private readonly life: PostgresConnectionLifecycle; private readonly sc: PostgresCommandScope;
  constructor(life: PostgresConnectionLifecycle, sc: PostgresCommandScope) { this.life = life; this.sc = sc; }
  get serverInfo(): PostgresServerInfo { return this.life.serverInfo; }
  get sessionStatus(): PostgresDatabaseSessionStatus { return this.life.sessionStatus; }
  get timers(): ConnectionTimerPort { return this.life.timers; }
  applyReadyStatus(ready: PostgresReadyStatus): void { this.life.applyReadyStatus(this.sc, ready); }
  retire(reason: ArkDbError): Promise<void> { return this.life.retire(this.sc, reason); }
}
class KindObserver implements PostgresCommandLifecycleObserver {
  private readonly kinds: PostgresCommandKind[];
  constructor(kinds: PostgresCommandKind[]) { this.kinds = kinds; }
  onStart(scope: PostgresCommandScope): void { this.kinds.push(scope.kind); }
  onTerminal(_scope: PostgresCommandScope): void {}
}
class FixedTimers implements ConnectionTimerPort {
  private now: number = 100; private id: number = 1;
  nowMs(): number { this.now += 1; return this.now; }
  schedule(_h: () => void, _ms: number): number { return this.id++; }
  cancel(_id: number): void {}
}
class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; readonly rawWrites: Uint8Array[] = [];
  hangAtEmpty: boolean = false; waitingRead: boolean = false;
  private rejectHung: ((e: Object) => void) | null = null;
  private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) {
      if (!this.hangAtEmpty) return null;
      this.waitingRead = true;
      return new Promise<Uint8Array | null>((_res: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => { this.rejectHung = rej; });
    }
    const head = this.reads[0];
    if (head.length <= max) return this.reads.shift()!;
    this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  write(data: Uint8Array): Promise<number> {
    this.rawWrites.push(data); const cp = new Uint8Array(data.length); cp.set(data); this.writes.push(cp);
    return Promise.resolve(data.length);
  }
  async close(): Promise<void> {}
  async abort(e: ArkDbError): Promise<void> {
    if (this.rejectHung !== null) { const r = this.rejectHung; this.rejectHung = null; this.waitingRead = false; r(e); }
  }
}
function makeConfig(): PostgresConnectionConfig {
  const c = new PostgresConnectionConfig();
  c.host = 'pg.local'; c.user = 'alice'; c.database = 'app_db'; c.ssl.mode = PostgresSslMode.DISABLED;
  return c;
}
function openReady(tp: QueueTransport, gate?: PostgresCommandGate): PostgresConnection {
  return new PostgresConnection(makeConfig(), '', new FixedTimers(), (): PostgresLifecycleTransport => tp, undefined, gate);
}
function bootFrames(ready: number): Uint8Array {
  return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]);
}
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array {
  const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload);
  const out = new Uint8Array(src.length + 5);
  out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5);
  return out;
}
function expectedQueryFrame(sql: string): Uint8Array { const p: number[] = []; pushCStr(p, sql); return backendFrame(0x51, p); }
function msgCmd(tag: string): Uint8Array { const p: number[] = []; pushCStr(p, tag); return backendFrame(0x43, p); }
function msgReady(status: number): Uint8Array { return backendFrame(0x5a, [status]); }
function msgParam(n: string, v: string): Uint8Array { const p: number[] = []; pushCStr(p, n); pushCStr(p, v); return backendFrame(0x53, p); }
function msgNotice(st: string, m: string): Uint8Array {
  const p: number[] = [0x53]; pushCStr(p, 'WARNING'); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0); return backendFrame(0x4e, p);
}
function msgError(st: string, m: string): Uint8Array {
  const p: number[] = [0x53]; pushCStr(p, 'ERROR'); p.push(0x56); pushCStr(p, 'ERROR'); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0); return backendFrame(0x45, p);
}
function pushCStr(dst: number[], text: string): void { for (let i = 0; i < text.length; i += 1) dst.push(text.charCodeAt(i)); dst.push(0); }
function concatFrames(frames: Uint8Array[]): Uint8Array {
  let len = 0; for (const f of frames) len += f.length;
  const out = new Uint8Array(len); let off = 0;
  for (const f of frames) { out.set(f, off); off += f.length; }
  return out;
}
function assertBytes(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length);
  for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]);
}
function assertZeroed(buf: Uint8Array): void { for (let i = 0; i < buf.length; i += 1) expect(buf[i]).assertEqual(0); }
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> {
  let err: Object | null = null;
  try { await op(); } catch (e) { err = e as Object; }
  expect(err instanceof ArkDbError).assertTrue();
  return err as ArkDbError;
}
