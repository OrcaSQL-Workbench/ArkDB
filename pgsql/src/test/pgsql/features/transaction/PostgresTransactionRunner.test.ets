import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, SqlValue } from '@arkdb/core';
import { PostgresConnection, PostgresConnectionConfig, PostgresDatabaseSessionStatus, PostgresError, PostgresParameter, PostgresParameterType, PostgresPreparedExecutor, PostgresQueryResult, PostgresSession, PostgresSslMode, PostgresTransactionIsolation, PostgresTransactionOptions, PostgresTransactionState, requirePostgresFeatures } from '../../../../../Index';
import { PostgresLifecycleTransport } from '../../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandLifecycleObserver, PostgresCommandScope } from '../../../../main/ets/pgsql/execution/PostgresCommandGate';

export default function postgresTransactionRunnerTest(): void {
  describe('PostgreSQL transaction runner and scoped session', () => {
    it('runsHappyPathSessionQueriesStreamsAndPreparedUnderSingleTransactionScope', 0, async () => {
      const kinds: PostgresCommandKind[] = []; const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openReady(tp, new PostgresCommandGate(new KindObserver(kinds)));
      expect(conn.postgresFeatures.transactions !== undefined && conn.features.transactions !== undefined).assertTrue();
      await conn.connect(); tp.writes.length = 0;
      for (const badRun of [
        (): Promise<void> => conn.postgresFeatures.transactions!.run<void>(asTxOpts(null), async (_s: PostgresSession): Promise<void> => {}),
        (): Promise<void> => conn.postgresFeatures.transactions!.run<void>(makeOpts(PostgresTransactionIsolation.ReadCommitted, false, true), async (_s: PostgresSession): Promise<void> => {}),
        (): Promise<void> => conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), ('bad' as Object) as (s: PostgresSession) => Promise<void>)
      ]) expect((await asyncFail<void>(badRun)).kind === ArkDbErrorKind.Validation && tp.writes.length === 0 && kinds.length === 1).assertTrue();

      const opts = makeOpts(PostgresTransactionIsolation.Serializable, true, true); const col = [colSpec('v', 25)];
      tp.enqueue([rxCmd('BEGIN', 0x54), concatFrames([msgRowDesc(col), msgDataRow(['q1']), msgCmd('SELECT 1'), msgReady(0x54)]),
        concatFrames([msgRowDesc(col), msgDataRow(['s1']), msgCmd('SELECT 1'), msgReady(0x54)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(col), msgDataRow(['p1']), msgCmd('SELECT 1'), msgReady(0x54)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(col), msgDataRow(['ps1']), msgCmd('SELECT 1'), msgReady(0x54)]), rxCmd('COMMIT', 0x49)]);
      const out = await conn.postgresFeatures.transactions!.run<string>(opts, async (s: PostgresSession): Promise<string> => {
        opts.isolation = PostgresTransactionIsolation.ReadCommitted; opts.readOnly = false; opts.deferrable = false;
        const st: PostgresDatabaseSessionStatus = s.sessionStatus; st.inTransaction = false;
        expect(s.sessionStatus.inTransaction && s.sessionStatus.transactionState === PostgresTransactionState.InTransaction &&
          s.serverInfo.driverId === 'pgsql' && requirePostgresFeatures(s).prepared !== undefined &&
          s.postgresFeatures.transactions === undefined && JSON.stringify(s.postgresFeatures) === '{"prepared":{}}').assertTrue();
        const r1 = await s.query('SELECT 1'); const sink1 = new CollectSink();
        const sum1 = await s.queryStream('SELECT 2', new QueryOptions(), sink1);
        const r2 = await s.postgresFeatures.prepared!.execute('SELECT $1', [new PostgresParameter(PostgresParameterType.Text, 'a')], new QueryOptions());
        const sink2 = new CollectSink();
        const sum2 = await s.postgresFeatures.prepared!.queryStream('SELECT $1', [new PostgresParameter(PostgresParameterType.Text, 'b')], new QueryOptions(), sink2);
        expect(sum1.loadedRowCount === 1 && sum2.loadedRowCount === 1).assertTrue();
        return String(r1.rows[0][0]) + ',' + sink1.values[0] + ',' + String(r2.rows[0][0]) + ',' + sink2.values[0];
      });
      expect(out).assertEqual('q1,s1,p1,ps1');
      assertBytes(tp.writes[0], expectedQueryFrame('BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE'));
      assertBytes(tp.writes[tp.writes.length - 1], expectedQueryFrame('COMMIT'));
      expect(kinds.length === 2 && kinds[1] === PostgresCommandKind.Transaction && conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();

      tp.enqueue([rxCmd('BEGIN', 0x54), rxCmd('ROLLBACK', 0x49)]); await conn.features.transactions!.begin();
      const activeErr = await asyncFail<void>((): Promise<void> => conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (_s: PostgresSession): Promise<void> => {}));
      expect(activeErr.kind === ArkDbErrorKind.Validation && conn.state === ConnectionState.Ready && conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction).assertTrue();
      await conn.features.transactions!.rollback(); await conn.close();
    });

    it('preservesExactCallbackErrorIdentityOnRollbackAndHandlesAbortedOrManualEndings', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect(); tp.writes.length = 0;
      const domainErr = new TypeError('domain failure');
      tp.enqueue([rxCmd('BEGIN', 0x54), rxCmd('INSERT 0 1', 0x54), rxCmd('ROLLBACK', 0x49),
        concatFrames([msgRowDesc([colSpec('ok', 25)]), msgDataRow(['yes']), msgCmd('SELECT 1'), msgReady(0x49)])]);
      const caughtDomain = await rawFail<void>((): Promise<void> =>
        conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
          await s.query('INSERT INTO t VALUES (1)'); throw domainErr;
        }));
      expect(caughtDomain === domainErr && tp.writes.length === 3 && conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();
      assertBytes(tp.writes[2], expectedQueryFrame('ROLLBACK'));
      expect((await conn.query('SELECT 9')).rows[0][0]).assertEqual('yes');

      const userProtoErr = ArkDbError.protocol('caller protocol style error');
      tp.enqueue([rxCmd('BEGIN', 0x54), rxErr('23505', 'dup', 0x45), rxCmd('ROLLBACK', 0x49)]);
      const caughtProto = await rawFail<void>((): Promise<void> =>
        conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
          try { await s.query('INSERT dup'); } catch (_e) {}
          expect(s.sessionStatus.transactionState).assertEqual(PostgresTransactionState.FailedTransaction); throw userProtoErr;
        }));
      expect(caughtProto === userProtoErr && conn.state === ConnectionState.Ready && conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();

      const manualErr = new Error('after manual rollback'); tp.writes.length = 0; tp.enqueue([rxCmd('BEGIN', 0x54), rxCmd('ROLLBACK', 0x49)]);
      const caughtManual = await rawFail<void>((): Promise<void> =>
        conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => { await s.query('ROLLBACK'); throw manualErr; }));
      expect(caughtManual === manualErr && tp.writes.length === 2 && conn.state === ConnectionState.Ready).assertTrue();

      tp.writes.length = 0; tp.enqueue([rxCmd('BEGIN', 0x54), rxErr('22012', 'div zero', 0x45), rxCmd('ROLLBACK', 0x49)]);
      const abortedCommit = await asyncFail<string>((): Promise<string> =>
        conn.postgresFeatures.transactions!.run<string>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<string> => {
          try { await s.query('SELECT 1/0'); } catch (_e) {} return 'swallowed';
        }));
      expect(abortedCommit instanceof PostgresError && abortedCommit.sqlState === '25P02' && abortedCommit.kind === ArkDbErrorKind.Server &&
        tp.writes.length === 3 && conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();
      assertBytes(tp.writes[2], expectedQueryFrame('ROLLBACK'));

      tp.writes.length = 0; tp.enqueue([rxCmd('BEGIN', 0x54), rxCmd('COMMIT', 0x49)]);
      const manualCommitErr = await asyncFail<void>((): Promise<void> =>
        conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
          await s.query('COMMIT');
          expect((await asyncFail<PostgresQueryResult>((): Promise<PostgresQueryResult> => s.query('SELECT escape'))).kind).assertEqual(ArkDbErrorKind.Validation);
        }));
      expect(manualCommitErr.kind === ArkDbErrorKind.Validation && tp.writes.length === 2 && conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();
      await conn.close();
    });

    it('supportsSavepointLifecycleFailedStateRecoveryAndIdentifierValidation', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect(); tp.writes.length = 0;
      tp.enqueue([rxCmd('BEGIN', 0x54), rxCmd('SAVEPOINT', 0x54), rxErr('23505', 'dup', 0x45), rxErr('25P02', 'aborted', 0x45),
        rxCmd('ROLLBACK', 0x54), rxCmd('INSERT 0 1', 0x54), rxCmd('RELEASE', 0x54), rxCmd('COMMIT', 0x49)]);
      const res = await conn.postgresFeatures.transactions!.run<string>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<string> => {
        const writesBefore = tp.writes.length;
        for (const badName of ['', 'bad\u0000sp', 'x'.repeat(64), (123 as Object) as string]) {
          expect((await asyncFail<void>((): Promise<void> => s.savepoint(badName))).kind).assertEqual(ArkDbErrorKind.Validation);
          expect((await asyncFail<void>((): Promise<void> => s.rollbackTo(badName))).kind).assertEqual(ArkDbErrorKind.Validation);
          expect((await asyncFail<void>((): Promise<void> => s.releaseSavepoint(badName))).kind).assertEqual(ArkDbErrorKind.Validation);
        }
        expect(tp.writes.length).assertEqual(writesBefore); await s.savepoint('sp"1');
        try { await s.query('INSERT dup'); } catch (_e) {}
        expect(s.sessionStatus.transactionState).assertEqual(PostgresTransactionState.FailedTransaction);
        const spInErr = await asyncFail<void>((): Promise<void> => s.savepoint('sp2'));
        expect(spInErr instanceof PostgresError && spInErr.sqlState === '25P02').assertTrue();
        await s.rollbackTo('sp"1'); expect(s.sessionStatus.transactionState).assertEqual(PostgresTransactionState.InTransaction);
        await s.query('INSERT good'); await s.releaseSavepoint('sp"1'); return 'recovered';
      });
      expect(res).assertEqual('recovered');
      assertBytes(tp.writes[1], expectedQueryFrame('SAVEPOINT "sp""1"'));
      assertBytes(tp.writes[4], expectedQueryFrame('ROLLBACK TO SAVEPOINT "sp""1"'));
      assertBytes(tp.writes[6], expectedQueryFrame('RELEASE SAVEPOINT "sp""1"'));
      expect(conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();

      tp.writes.length = 0; tp.enqueue([rxCmd('BEGIN', 0x54), rxCmd('ROLLBACK', 0x49)]);
      const spIdleErr = await asyncFail<void>((): Promise<void> =>
        conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
          await s.query('ROLLBACK');
          const e = await asyncFail<void>((): Promise<void> => s.savepoint('sp_idle'));
          expect(e.kind === ArkDbErrorKind.Validation && e.message === 'PostgreSQL savepoints require an active transaction.').assertTrue();
          throw e;
        }));
      expect(spIdleErr.kind === ArkDbErrorKind.Validation && tp.writes.length === 2).assertTrue();
      await conn.close();
    });

    it('handlesDeferredCommitErrorsRollbackCleanupCompositionAndStreamSinkErrors', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect();
      tp.enqueue([rxCmd('BEGIN', 0x54), rxErr('23505', 'deferred fk', 0x49)]);
      const defErr = await asyncFail<void>((): Promise<void> => conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (_s: PostgresSession): Promise<void> => {}));
      expect(defErr instanceof PostgresError && defErr.sqlState === '23505' && conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();

      const sinkBoom = ArkDbError.protocol('sink boom'); const col = [colSpec('v', 25)];
      tp.enqueue([rxCmd('BEGIN', 0x54), concatFrames([msgRowDesc(col), msgDataRow(['a']), msgCmd('SELECT 1'), msgReady(0x54)]),
        rxCmd('SELECT 1', 0x54), rxCmd('COMMIT', 0x49), rxCmd('BEGIN', 0x54),
        concatFrames([msgRowDesc(col), msgDataRow(['b']), msgCmd('SELECT 1'), msgReady(0x54)]), rxCmd('ROLLBACK', 0x49)]);
      const recovered = await conn.postgresFeatures.transactions!.run<string>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<string> => {
        const caught = await rawFail<void>(async (): Promise<void> => { await s.queryStream('SELECT 1', new QueryOptions(), new ThrowingSink(sinkBoom)); });
        expect(caught === sinkBoom).assertTrue(); await s.query('SELECT 1'); return 'ok';
      });
      expect(recovered === 'ok' && conn.state === ConnectionState.Ready).assertTrue();

      const uncaughtSink = await rawFail<void>((): Promise<void> =>
        conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
          await s.queryStream('SELECT 1', new QueryOptions(), new ThrowingSink(sinkBoom));
        }));
      expect(uncaughtSink === sinkBoom && conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();
      await conn.close();

      const failRbConn = openReady(new QueueTransport([bootFrames(0x49), rxCmd('BEGIN', 0x54), rxErr('XX000', 'rollback disk error', 0x45)]));
      await failRbConn.connect();
      const composed = await asyncFail<void>((): Promise<void> =>
        failRbConn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (_s: PostgresSession): Promise<void> => { throw new Error('callback boom'); }));
      expect(composed.message.indexOf('callback boom (cleanup failed:') === 0 && failRbConn.state === ConnectionState.Error).assertTrue();
      await failRbConn.close();

      const eofConn = openReady(new QueueTransport([bootFrames(0x49), rxCmd('BEGIN', 0x54), concatFrames([msgRowDesc(col), msgDataRow(['z'])])]));
      await eofConn.connect(); const oneRowOpts = new QueryOptions(); oneRowOpts.maxChunkRows = 1;
      const eofErr = await asyncFail<string>((): Promise<string> =>
        eofConn.postgresFeatures.transactions!.run<string>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<string> => {
          try { await s.queryStream('SELECT 1', oneRowOpts, new ThrowingSink(sinkBoom)); }
          catch (_e) { try { await s.rollbackTo('sp_after_eof'); } catch (_e2) {} }
          return 'swallowed';
        }));
      expect(eofErr.message.indexOf('sink boom (cleanup failed:') === 0 && eofConn.state === ConnectionState.Error).assertTrue();
      await eofConn.close();
    });

    it('enforcesSessionExpiryOverlapGuardsAbandonedCommandWaitAndCloseIsolation', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect();
      let leakedSession: PostgresSession | null = null; let leakedPrep: PostgresPreparedExecutor | null = null;
      tp.enqueue([rxCmd('BEGIN', 0x54), rxCmd('COMMIT', 0x49)]);
      await conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
        leakedSession = s; leakedPrep = s.postgresFeatures.prepared!;
        for (const op of [
          async (): Promise<void> => { await conn.query('SELECT 1'); }, async (): Promise<void> => { await conn.begin(); },
          async (): Promise<void> => { await conn.commit(); }, async (): Promise<void> => { await conn.rollback(); }, (): Promise<void> => conn.ping(),
          async (): Promise<void> => { await conn.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()); },
          async (): Promise<void> => { await conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (_n: PostgresSession): Promise<void> => {}); }
        ]) expect((await asyncFail<void>(op)).kind).assertEqual(ArkDbErrorKind.Protocol);
      });
      const writesAfterCommit = tp.writes.length;
      for (const acc of [(): void => { const _f = leakedSession!.postgresFeatures; }, (): void => { const _i = leakedSession!.serverInfo; }, (): void => { const _st = leakedSession!.sessionStatus; }]) {
        expect(syncFail(acc).kind).assertEqual(ArkDbErrorKind.Validation);
      }
      for (const op of [
        async (): Promise<void> => { await leakedSession!.query('SELECT 1'); }, async (): Promise<void> => { await leakedSession!.queryStream('SELECT 1', new QueryOptions(), new CollectSink()); },
        (): Promise<void> => leakedSession!.savepoint('sp'), (): Promise<void> => leakedSession!.rollbackTo('sp'), (): Promise<void> => leakedSession!.releaseSavepoint('sp'),
        async (): Promise<void> => { await leakedPrep!.execute('SELECT 1', [], new QueryOptions()); }, async (): Promise<void> => { await leakedPrep!.queryStream('SELECT 1', [], new QueryOptions(), new CollectSink()); }
      ]) {
        const err = await asyncFail<void>(op);
        expect(err.kind === ArkDbErrorKind.Validation && err.message === 'PostgreSQL transaction session is no longer active.').assertTrue();
      }
      expect(tp.writes.length).assertEqual(writesAfterCommit);

      tp.writes.length = 0; tp.hangAtEmpty = true; tp.enqueue([rxCmd('BEGIN', 0x54)]);
      let releaseAbandoned: (() => void) | null = null;
      const raceTask = conn.postgresFeatures.transactions!.run<string>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<string> => {
        s.query('SELECT slow'); await waitUntil((): boolean => tp.waitingRead);
        const o1 = await asyncFail<PostgresQueryResult>((): Promise<PostgresQueryResult> => s.query('SELECT overlap'));
        const o2 = await asyncFail<void>((): Promise<void> => s.savepoint('sp_overlap'));
        const o3 = await asyncFail<PostgresQueryResult>((): Promise<PostgresQueryResult> => s.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()));
        expect(o1.kind === ArkDbErrorKind.Protocol && o2.kind === ArkDbErrorKind.Protocol && o3.kind === ArkDbErrorKind.Protocol).assertTrue();
        releaseAbandoned = (): void => { tp.hangAtEmpty = false; tp.deliverHung(rxCmd('SELECT 1', 0x54)); };
        return 'early';
      });
      await waitUntil((): boolean => releaseAbandoned !== null);
      expect(tp.writes.length).assertEqual(2);
      tp.enqueue([rxCmd('ROLLBACK', 0x49)]); releaseAbandoned!();
      const abandonedErr = await asyncFail<string>((): Promise<string> => raceTask);
      expect(abandonedErr.kind === ArkDbErrorKind.Protocol && tp.writes.length === 3 &&
        abandonedErr.message === 'PostgreSQL transaction callback settled while a session command was still active.' &&
        conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();
      await conn.close();

      const closeIoTp = new QueueTransport([bootFrames(0x49), rxCmd('BEGIN', 0x54),
        concatFrames([msgRowDesc([colSpec('b', 17)]), msgDataRow(['\\xdead']), msgCmd('SELECT 1'), msgReady(0x54)])]);
      closeIoTp.hangAtEmpty = true; const closeIoConn = openReady(closeIoTp); await closeIoConn.connect();
      let deliveredResult: PostgresQueryResult | null = null;
      const closeIoRun = closeIoConn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
        deliveredResult = await s.query('SELECT bytea_row'); await s.query('SELECT hung_row');
      });
      await waitUntil((): boolean => deliveredResult !== null && closeIoTp.waitingRead);
      const closeIoDone = closeIoConn.close(); const closeIoErr = await asyncFail<void>((): Promise<void> => closeIoRun); await closeIoDone;
      const keptBytes = deliveredResult!.rows[0][0] as Uint8Array;
      expect(closeIoErr.kind === ArkDbErrorKind.Cancelled && closeIoConn.state === ConnectionState.Closed &&
        keptBytes.length === 2 && keptBytes[0] === 0xde && keptBytes[1] === 0xad).assertTrue();

      const idleCloseTp = new QueueTransport([bootFrames(0x49), rxCmd('BEGIN', 0x54)]);
      const idleCloseConn = openReady(idleCloseTp); await idleCloseConn.connect(); idleCloseTp.writes.length = 0;
      let capturedIdleSession: PostgresSession | null = null; let wakeExternal: (() => void) | null = null;
      const idleCloseRun = idleCloseConn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
        capturedIdleSession = s; await new Promise<void>((res: () => void): void => { wakeExternal = res; });
      });
      await waitUntil((): boolean => wakeExternal !== null);
      const idleClosing = idleCloseConn.close();
      expect(syncFail((): void => { const _s = capturedIdleSession!.sessionStatus; }).kind).assertEqual(ArkDbErrorKind.Validation);
      await idleClosing;
      const idleCloseErr = await asyncFail<void>((): Promise<void> => idleCloseRun);
      wakeExternal!();
      expect(idleCloseErr.kind === ArkDbErrorKind.Cancelled && idleCloseConn.state === ConnectionState.Closed && idleCloseTp.writes.length === 1).assertTrue();
    });
  });
}

function asTxOpts(v: PostgresTransactionOptions | null): PostgresTransactionOptions { return v as PostgresTransactionOptions; }
function makeOpts(iso: PostgresTransactionIsolation, ro: boolean, def: boolean): PostgresTransactionOptions {
  const o = new PostgresTransactionOptions(); o.isolation = iso; o.readOnly = ro; o.deferrable = def; return o;
}
class CollectSink implements QueryResultSink {
  readonly values: string[] = [];
  async onResultStart(_m: QueryResultMeta): Promise<void> {}
  async onRows(chunk: QueryRowChunk): Promise<void> { for (const r of chunk.rows) this.values.push(String(r[0] as SqlValue)); }
  async onResultEnd(_s: QueryResultSummary): Promise<void> {}
}
class ThrowingSink implements QueryResultSink {
  private readonly err: ArkDbError;
  constructor(err: ArkDbError) { this.err = err; }
  async onResultStart(_m: QueryResultMeta): Promise<void> {}
  async onRows(_c: QueryRowChunk): Promise<void> { throw this.err; }
  async onResultEnd(_s: QueryResultSummary): Promise<void> {}
}
class KindObserver implements PostgresCommandLifecycleObserver {
  private readonly kinds: PostgresCommandKind[];
  constructor(kinds: PostgresCommandKind[]) { this.kinds = kinds; }
  onStart(scope: PostgresCommandScope): void { this.kinds.push(scope.kind); }
  onTerminal(_s: PostgresCommandScope): void {}
}
class FixedTimers implements ConnectionTimerPort {
  private now: number = 100; private id: number = 1;
  nowMs(): number { return ++this.now; }
  schedule(_h: () => void, _ms: number): number { return this.id++; }
  cancel(_id: number): void {}
}
class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; hangAtEmpty: boolean = false; waitingRead: boolean = false;
  private hungMax: number = 0;
  private resolveHung: ((v: Uint8Array | null) => void) | null = null;
  private rejectHung: ((e: Object) => void) | null = null; private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  deliverHung(chunk: Uint8Array): void {
    if (this.resolveHung !== null) {
      const r = this.resolveHung; const m = this.hungMax;
      this.resolveHung = null; this.rejectHung = null; this.waitingRead = false;
      if (chunk.length <= m) r(chunk); else { this.reads.unshift(chunk.subarray(m)); r(chunk.subarray(0, m)); }
    }
  }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) {
      if (!this.hangAtEmpty) return null;
      this.waitingRead = true; this.hungMax = max;
      return new Promise<Uint8Array | null>((res: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => {
        this.resolveHung = res; this.rejectHung = rej;
      });
    }
    const head = this.reads[0]; if (head.length <= max) return this.reads.shift()!;
    this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  write(data: Uint8Array): Promise<number> { const cp = new Uint8Array(data.length); cp.set(data); this.writes.push(cp); return Promise.resolve(data.length); }
  async close(): Promise<void> {}
  async abort(e: ArkDbError): Promise<void> {
    if (this.rejectHung !== null) { const r = this.rejectHung; this.resolveHung = null; this.rejectHung = null; this.waitingRead = false; r(e); }
  }
}
function openReady(tp: QueueTransport, gate?: PostgresCommandGate): PostgresConnection {
  const c = new PostgresConnectionConfig(); c.host = 'pg.local'; c.user = 'alice'; c.database = 'app_db'; c.ssl.mode = PostgresSslMode.DISABLED;
  return new PostgresConnection(c, '', new FixedTimers(), (): PostgresLifecycleTransport => tp, undefined, gate);
}
function bootFrames(ready: number): Uint8Array { return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]); }
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array {
  const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload); const out = new Uint8Array(src.length + 5);
  out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5); return out;
}
function expectedQueryFrame(sql: string): Uint8Array { const p: number[] = []; pushCStr(p, sql); return backendFrame(0x51, p); }
function msgParseComplete(): Uint8Array { return backendFrame(0x31, []); }
function msgBindComplete(): Uint8Array { return backendFrame(0x32, []); }
function msgCmd(tag: string): Uint8Array { const p: number[] = []; pushCStr(p, tag); return backendFrame(0x43, p); }
function msgReady(status: number): Uint8Array { return backendFrame(0x5a, [status]); }
function rxCmd(tag: string, ready: number): Uint8Array { return concatFrames([msgCmd(tag), msgReady(ready)]); }
function rxErr(st: string, m: string, ready: number): Uint8Array { return concatFrames([msgError(st, m), msgReady(ready)]); }
function msgParam(n: string, v: string): Uint8Array { const p: number[] = []; pushCStr(p, n); pushCStr(p, v); return backendFrame(0x53, p); }
function msgError(st: string, m: string): Uint8Array {
  const p: number[] = [0x53]; pushCStr(p, 'ERROR'); p.push(0x56); pushCStr(p, 'ERROR'); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0); return backendFrame(0x45, p);
}
function colSpec(name: string, oid: number): Uint8Array {
  const p: number[] = []; pushCStr(p, name); const t = new Uint8Array(18); const v = new DataView(t.buffer);
  v.setUint32(6, oid, false); v.setInt16(10, -1, false); v.setInt32(12, -1, false); v.setInt16(16, 0, false);
  const out = new Uint8Array(p.length + 18); out.set(p, 0); out.set(t, p.length); return out;
}
function msgRowDesc(cols: Uint8Array[]): Uint8Array {
  let len = 2; for (const c of cols) len += c.length; const p = new Uint8Array(len); new DataView(p.buffer).setInt16(0, cols.length, false);
  let off = 2; for (const c of cols) { p.set(c, off); off += c.length; } return backendFrame(0x54, p);
}
function msgDataRow(vals: Array<string | null>): Uint8Array {
  let len = 2; for (const v of vals) len += v === null ? 4 : 4 + v.length; const p = new Uint8Array(len); const dv = new DataView(p.buffer); dv.setInt16(0, vals.length, false);
  let off = 2;
  for (const v of vals) {
    if (v === null) { dv.setInt32(off, -1, false); off += 4; }
    else { dv.setInt32(off, v.length, false); for (let i = 0; i < v.length; i += 1) p[off + 4 + i] = v.charCodeAt(i); off += 4 + v.length; }
  }
  return backendFrame(0x44, p);
}
function pushCStr(dst: number[], text: string): void { for (let i = 0; i < text.length; i += 1) dst.push(text.charCodeAt(i)); dst.push(0); }
function concatFrames(frames: Uint8Array[]): Uint8Array {
  let len = 0; for (const f of frames) len += f.length; const out = new Uint8Array(len); let off = 0;
  for (const f of frames) { out.set(f, off); off += f.length; } return out;
}
function assertBytes(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]);
}
async function waitUntil(pred: () => boolean): Promise<void> {
  for (let i = 0; i < 512 && !pred(); i += 1) await Promise.resolve();
  expect(pred()).assertTrue();
}
function syncFail(op: () => void): ArkDbError {
  let err: Object | null = null; try { op(); } catch (e) { err = e as Object; }
  expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError;
}
async function rawFail<T>(op: () => Promise<T>): Promise<Object> {
  let caught = false; let err: Object | null = null;
  try { await op(); } catch (e) { caught = true; err = e as Object; }
  expect(caught).assertTrue(); return err as Object;
}
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> {
  const err = await rawFail<T>(op); expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError;
}
