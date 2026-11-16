import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionReuse, ConnectionState, ConnectionTimerPort, QueryCancellationResult, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation } from '@arkdb/core';
import { PostgresConnection, PostgresConnectionConfig, PostgresDriverFactory, PostgresError, PostgresParameter, PostgresParameterType, PostgresSession, PostgresSslConfig, PostgresSslMode, PostgresTransactionOptions, PostgresTransactionState } from '../../../../Index';
import { PostgresLifecycleTransport } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { postgresAppendCleanupError } from '../../../main/ets/pgsql/execution/PostgresSettlements';

export default function postgresCancellationTest(): void {
  describe('PostgresCancellation', () => {
    it('cancelsActiveSimpleExtendedStreamingTruncationAndTransactionQueriesAcrossSeparateSocket', 0, async () => {
      expect(new PostgresDriverFactory().capabilities.supportsGracefulCancel).assertTrue();
      const sub = new CustomCancelConnection(plainConfig(), 'pw');
      expect(sub.features.cancellation !== undefined && JSON.stringify(sub.features) === '{"streaming":{},"health":{},"context":{},"transactions":{},"cancellation":{}}').assertTrue();
      const customRes = await sub.features.cancellation!.cancel();
      expect(customRes.outcome === CancellationOutcome.Requested && sub.cancelCalls === 1 && sub.features.cancellation!.isInterruptionError(serverErr('57014', 'ERROR')) && sub.interruptCalls === 1).assertTrue();
      const primary = new ScriptedTransport([bootFrames(-2147483640, [0x89, 0xab, 0xcd, 0xef], 0x49)]);
      const cancels: ScriptedTransport[] = []; let finishCancelWrite: (() => void) | null = null; let inFlightRef: Uint8Array | null = null;
      const conn = new PostgresConnection(plainConfig(), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => {
        if (cancels.length === 0 && !primary.connectedOnce) return primary;
        const c = new ScriptedTransport([]);
        if (cancels.length === 0) { c.maxWriteChunk = 5; c.onWriteGate = (buf: Uint8Array): Promise<void> | null => { if (c.writes.length !== 1) return null; inFlightRef = buf; return new Promise<void>((r: () => void): void => { finishCancelWrite = r; }); }; }
        cancels.push(c); return c;
      });
      await conn.connect(); primary.writes.length = 0; const q1 = conn.query('SELECT pg_sleep(10)'); await primary.waitWriteCount(1);
      const cancelTask1 = conn.cancel(); await waitUntil((): boolean => finishCancelWrite !== null);
      const midSendNonZero = hasNonZero(inFlightRef!); finishCancelWrite!(); const res1 = await cancelTask1;
      expect(res1.outcome === CancellationOutcome.Requested && res1.connectionReuse === ConnectionReuse.AwaitingCompletion && cancels.length === 1 && cancels[0] !== primary && cancels[0].closed && cancels[0].readCalls === 0 && midSendNonZero && !hasNonZero(inFlightRef!)).assertTrue();
      assertBytes(concatChunks(cancels[0].writes), [0x00, 0x00, 0x00, 0x10, 0x04, 0xd2, 0x16, 0x2e, 0x80, 0x00, 0x00, 0x08, 0x89, 0xab, 0xcd, 0xef]);
      primary.deliver(concatFrames([msgError('ERROR', '57014', 'canceling statement due to user request'), msgReady(0x49)]));
      const err1 = await asyncFail((): Promise<Object> => q1);
      expect(conn.isInterruptionError(err1) && conn.features.cancellation!.isInterruptionError(err1) && conn.state === ConnectionState.Ready).assertTrue();
      primary.deliver(singleRowQuery('after-simple', 0x49)); expect((await conn.query('SELECT 2')).rows[0][0]).assertEqual('after-simple');
      primary.writes.length = 0; let releasePrimaryWrite: (() => void) | null = null;
      primary.onWriteGate = (_b: Uint8Array): Promise<void> | null => primary.writes.length === 2 ? new Promise<void>((r: () => void): void => { releasePrimaryWrite = r; }) : null;
      const extTask = conn.postgresFeatures.prepared!.execute('SELECT $1', [new PostgresParameter(PostgresParameterType.Text, 'x')], new QueryOptions());
      await waitUntil((): boolean => releasePrimaryWrite !== null);
      const extCancel = conn.features.cancellation!.cancel(); await flushMicrotasks();
      expect(cancels.length === 2 && cancels[1].writes.length === 0).assertTrue();
      primary.onWriteGate = null; releasePrimaryWrite!();
      expect((await extCancel).outcome === CancellationOutcome.Requested && cancels[1].writes.length === 1).assertTrue();
      primary.deliver(concatFrames([msgParseComplete(), msgError('ERROR', '57014', 'canceled'), msgReady(0x49)]));
      expect(conn.isInterruptionError(await asyncFail((): Promise<Object> => extTask))).assertTrue();
      const truncOpts = new QueryOptions(); truncOpts.maxRows = 1;
      const simpleSink = new TruncCancelSink((): Promise<QueryCancellationResult> => conn.features.cancellation!.cancel());
      primary.writes.length = 0; const sStream = conn.queryStream('SELECT g', truncOpts, simpleSink); await primary.waitWriteCount(1);
      primary.deliver(concatFrames([msgRowDesc('v'), msgDataRow('1'), msgDataRow('2')])); await waitUntil((): boolean => simpleSink.cancelResult !== null);
      expect(simpleSink.cancelResult!.outcome === CancellationOutcome.Requested && cancels.length === 3).assertTrue();
      primary.deliver(concatFrames([msgError('ERROR', '57014', 'canceled'), msgReady(0x49)]));
      expect((await sStream).loadedRowCount === 1 && simpleSink.endedSummary!.truncated && conn.state === ConnectionState.Ready).assertTrue();
      const portalSink = new TruncCancelSink((): Promise<QueryCancellationResult> => conn.cancel()); primary.writes.length = 0;
      const pStream = conn.postgresFeatures.prepared!.queryStream('SELECT $1', [new PostgresParameter(PostgresParameterType.Int4, 7)], truncOpts, portalSink);
      await primary.waitWriteCount(5); primary.deliver(concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc('v'), msgDataRow('1'), msgPortalSuspended()]));
      await primary.waitWriteCount(7); primary.deliver(msgDataRow('2')); await waitUntil((): boolean => portalSink.cancelResult !== null);
      expect(portalSink.cancelResult!.outcome === CancellationOutcome.Requested && cancels.length === 4).assertTrue();
      primary.deliver(concatFrames([msgError('ERROR', '57014', 'canceled'), msgReady(0x49)]));
      expect((await pStream).loadedRowCount === 1 && portalSink.endedSummary!.truncated && conn.state === ConnectionState.Ready).assertTrue();
      primary.deliver(rxCmd('BEGIN', 0x54)); let txCancelRes: QueryCancellationResult | null = null;
      const txTask = conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
        primary.writes.length = 0; const sq = s.query('SELECT slow_in_tx()'); const txCancelTask = conn.cancel();
        await primary.waitWriteCount(1); txCancelRes = await txCancelTask;
        primary.deliver(concatFrames([msgError('ERROR', '57014', 'canceled in tx'), msgReady(0x45)]));
        const sqErr = await asyncFail((): Promise<Object> => sq);
        expect(conn.isInterruptionError(sqErr) && s.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();
        primary.deliver(rxCmd('ROLLBACK', 0x49)); throw sqErr;
      });
      expect(conn.isInterruptionError(await asyncFail((): Promise<void> => txTask)) && txCancelRes!.outcome === CancellationOutcome.Requested && cancels.length === 5 && conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();
      primary.deliver(singleRowQuery('post-tx', 0x49)); expect((await conn.query('SELECT 3')).rows[0][0]).assertEqual('post-tx'); await conn.close();
    });

    it('enforcesTlsPostureParityAndIsolatesPrimaryConnectionFromCancelFailures', 0, async () => {
      const primary = new ScriptedTransport([new Uint8Array([0x53]), bootFrames(7701, [0x01, 0x02, 0x03, 0x04], 0x49)]);
      let nextCancel: () => ScriptedTransport = (): ScriptedTransport => new ScriptedTransport([new Uint8Array([0x53])]);
      const timers = new ManualTimerPort();
      const conn = new PostgresConnection(tlsConfig(PostgresSslMode.VERIFY_FULL), 'pw', timers, (): PostgresLifecycleTransport => !primary.connectedOnce ? primary : nextCancel());
      await conn.connect();
      const caPrimary = new ScriptedTransport([new Uint8Array([0x53]), bootFrames(7702, [1, 2, 3, 4], 0x49)]);
      const caCancel = new ScriptedTransport([new Uint8Array([0x53])]); let caMode: string = '';
      caCancel.onUpgradeTls = (_h: string, _p: number, ssl: PostgresSslConfig): void => { caMode = ssl.mode; };
      const caConn = new PostgresConnection(tlsConfig(PostgresSslMode.VERIFY_CA), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => !caPrimary.connectedOnce ? caPrimary : caCancel);
      await caConn.connect(); caPrimary.writes.length = 0; const caQ = caConn.query('SELECT 1'); await caPrimary.waitWriteCount(1);
      expect((await caConn.cancel()).outcome === CancellationOutcome.Requested && caMode === PostgresSslMode.VERIFY_CA).assertTrue();
      caPrimary.deliver(concatFrames([msgError('ERROR', '57014', 'c'), msgReady(0x49)])); await asyncFail((): Promise<Object> => caQ); await caConn.close();
      const tlsCancel = new ScriptedTransport([new Uint8Array([0x53])]); tlsCancel.maxWriteChunk = 3; const events: string[] = [];
      tlsCancel.onWriteHook = (b: Uint8Array): void => { events.push('w:' + b.length); };
      tlsCancel.onPrepareTls = (): void => { events.push('prep'); };
      tlsCancel.onUpgradeTls = (h: string, p: number, ssl: PostgresSslConfig): void => { events.push('tls:' + h + ':' + p + ':' + ssl.mode); };
      nextCancel = (): ScriptedTransport => tlsCancel; primary.writes.length = 0; const active = conn.query('SELECT slow_tls()'); await primary.waitWriteCount(1);
      expect((await conn.cancel()).outcome === CancellationOutcome.Requested && tlsCancel.closed && events.join(',') === 'w:3,w:3,w:2,prep,tls:db.internal:5432:verify_full,w:3,w:3,w:3,w:3,w:3,w:1').assertTrue();
      assertBytes(concatChunks(tlsCancel.writes.slice(0, 3)), [0x00, 0x00, 0x00, 0x08, 0x04, 0xd2, 0x16, 0x2f]);
      assertBytes(concatChunks(tlsCancel.writes.slice(3)), [0x00, 0x00, 0x00, 0x10, 0x04, 0xd2, 0x16, 0x2e, 0x00, 0x00, 0x1e, 0x15, 0x01, 0x02, 0x03, 0x04]);
      primary.deliver(concatFrames([msgError('ERROR', '57014', 'canceled'), msgReady(0x49)]));
      expect(conn.isInterruptionError(await asyncFail((): Promise<Object> => active))).assertTrue();

      primary.writes.length = 0; const survivor = conn.query('SELECT survives_bad_cancels()'); await primary.waitWriteCount(1);
      for (const tc of [
        new CancelFailCase([new Uint8Array([0x4e])], ArkDbErrorKind.Tls, 'SSL_NOT_SUPPORTED', false, null, 0, false, null),
        new CancelFailCase([new Uint8Array([0x45])], ArkDbErrorKind.Tls, 'SSL_PRE_TLS_ERROR', false, null, 0, false, null),
        new CancelFailCase([null], ArkDbErrorKind.Tls, 'SSL_HANDSHAKE_FAILED', false, null, 0, false, null),
        new CancelFailCase([new Uint8Array(0)], ArkDbErrorKind.Tls, 'SSL_HANDSHAKE_FAILED', false, null, 0, false, null),
        new CancelFailCase([], ArkDbErrorKind.Tls, 'SSL_HANDSHAKE_FAILED', false, null, 0, false, ArkDbError.network('PostgreSQL socket closed by server')),
        new CancelFailCase([new Uint8Array([0x58])], ArkDbErrorKind.Protocol, 'PROTOCOL_VIOLATION', false, null, 0, false, null),
        new CancelFailCase([new Uint8Array([0x53, 0x53])], ArkDbErrorKind.Protocol, 'PROTOCOL_VIOLATION', false, null, 0, true, null),
        new CancelFailCase([new Uint8Array([0x53])], ArkDbErrorKind.Tls, 'SSL_HANDSHAKE_FAILED', true, null, 0, false, null),
        new CancelFailCase([new Uint8Array([0x53])], ArkDbErrorKind.Tls, 'SSL_HANDSHAKE_FAILED', false, null, 1, false, null),
        new CancelFailCase([new Uint8Array([0x53])], ArkDbErrorKind.Tls, 'CERT_INVALID', false, ArkDbError.tls('bad cert', 'CERT_INVALID'), 0, false, null),
        new CancelFailCase([new Uint8Array([0x53])], ArkDbErrorKind.Network, 'CONNECTION_EXCEPTION', false, null, 2, false, null)
      ]) {
        const badTp = new ScriptedTransport(tc.reads); badTp.disableUpgradeMethod = tc.omitTlsUpgrade; badTp.upgradeError = tc.upgradeErr;
        badTp.zeroWriteOnCall = tc.zeroWriteCall; badTp.rawChunks = tc.rawRead; badTp.readError = tc.readErr; nextCancel = (): ScriptedTransport => badTp;
        const err = await asyncFail((): Promise<Object> => conn.cancel());
        expect(err.kind === tc.kind && err.nativeCode === tc.code && badTp.closed && (tc.zeroWriteCall === 2 || badTp.writes.length <= 1)).assertTrue();
      }
      let releaseWriteGate: (() => void) | null = null;
      primary.onWriteGate = (): Promise<void> => new Promise<void>((r: () => void): void => { releaseWriteGate = r; });
      const stalledTp = new ScriptedTransport([new Uint8Array([0x53])]); nextCancel = (): ScriptedTransport => stalledTp;
      primary.deliver(singleRowQuery('still-alive', 0x49)); expect((await survivor).rows[0][0]).assertEqual('still-alive');
      const gatedQuery = conn.query('SELECT gated_write()'); await waitUntil((): boolean => releaseWriteGate !== null);
      const timeoutCancel = conn.cancel(); await waitUntil((): boolean => timers.activeCount > 0 && stalledTp.writes.length === 1); timers.fireNext();
      expect((await asyncFail((): Promise<Object> => timeoutCancel)).kind === ArkDbErrorKind.Timeout && stalledTp.closed && stalledTp.writes.length === 1 && conn.state === ConnectionState.Querying).assertTrue();
      const retryTp = new ScriptedTransport([new Uint8Array([0x53])]); nextCancel = (): ScriptedTransport => retryTp;
      primary.onWriteGate = null; releaseWriteGate!();
      expect((await conn.cancel()).outcome === CancellationOutcome.Requested && retryTp.writes.length === 2).assertTrue();
      primary.deliver(concatFrames([msgError('ERROR', '57014', 'c'), msgReady(0x49)])); expect(conn.isInterruptionError(await asyncFail((): Promise<Object> => gatedQuery))).assertTrue();
      primary.deliver(singleRowQuery('healthy-2', 0x49)); expect((await conn.query('SELECT 2')).rows[0][0]).assertEqual('healthy-2'); await conn.close();
    });

    it('handlesNonRunningStatesReuseMappingBackendKeyValidationAndDistinctTransportCheck', 0, async () => {
      let createdCancels = 0; const primary = new ScriptedTransport([]); let connectMidRes: QueryCancellationResult | null = null;
      primary.onConnect = async (): Promise<void> => { connectMidRes = await conn.cancel(); }; primary.enqueue([bootFrames(55, [9, 8, 7, 6], 0x49)]);
      const conn = new PostgresConnection(plainConfig(), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => { if (!primary.connectedOnce) return primary; createdCancels += 1; return new ScriptedTransport([]); });
      const idleRes = await conn.cancel();
      expect(idleRes.outcome === CancellationOutcome.NotRunning && idleRes.connectionReuse === ConnectionReuse.NotReady && createdCancels === 0).assertTrue();
      await conn.connect();
      expect(connectMidRes!.outcome === CancellationOutcome.NotRunning && connectMidRes!.connectionReuse === ConnectionReuse.NotReady && createdCancels === 0).assertTrue();
      const readyRes = await conn.cancel();
      expect(readyRes.outcome === CancellationOutcome.NotRunning && readyRes.connectionReuse === ConnectionReuse.Ready && createdCancels === 0).assertTrue();
      primary.deliver(concatFrames([rxCmd('BEGIN', 0x54), rxCmd('SELECT 1', 0x54), rxCmd('COMMIT', 0x49)]));
      let pausedTxRes: QueryCancellationResult | null = null;
      await conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => { await s.query('SELECT 1'); pausedTxRes = await conn.cancel(); });
      expect(pausedTxRes!.outcome === CancellationOutcome.NotRunning && pausedTxRes!.connectionReuse === ConnectionReuse.AwaitingCompletion && createdCancels === 0).assertTrue();
      primary.deliver(concatFrames([msgError('FATAL', '57P01', 'admin shutdown')])); await asyncFail((): Promise<Object> => conn.query('SELECT boom'));
      const errStateRes = await conn.cancel();
      expect(conn.state === ConnectionState.Error && errStateRes.outcome === CancellationOutcome.NotRunning && errStateRes.connectionReuse === ConnectionReuse.NotReady && createdCancels === 0).assertTrue();
      await conn.close(); const closedRes = await conn.cancel();
      expect(closedRes.outcome === CancellationOutcome.NotRunning && closedRes.connectionReuse === ConnectionReuse.Closed && createdCancels === 0).assertTrue();
      for (const boot of [bootFramesWithoutKey(0x49), bootFrames(0, [1, 2, 3, 4], 0x49)]) {
        const p = new ScriptedTransport([boot]); let count = 0;
        const c = new PostgresConnection(plainConfig(), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => { if (!p.connectedOnce) return p; count += 1; return new ScriptedTransport([]); });
        await c.connect(); p.writes.length = 0; const q = c.query('SELECT 1'); await p.waitWriteCount(1);
        expect((await asyncFail((): Promise<Object> => c.cancel())).kind === ArkDbErrorKind.Unsupported && count === 0).assertTrue();
        p.deliver(singleRowQuery('ok', 0x49)); expect((await q).rows[0][0]).assertEqual('ok'); await c.close();
      }
      const sameTp = new ScriptedTransport([bootFrames(99, [4, 3, 2, 1], 0x49)]);
      const sameConn = new PostgresConnection(plainConfig(), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => sameTp);
      await sameConn.connect(); sameTp.writes.length = 0; const qSame = sameConn.query('SELECT 1'); await sameTp.waitWriteCount(1);
      expect((await asyncFail((): Promise<Object> => sameConn.cancel())).kind).assertEqual(ArkDbErrorKind.Validation);
      sameTp.deliver(singleRowQuery('same-ok', 0x49)); expect((await qSame).rows[0][0]).assertEqual('same-ok'); await sameConn.close();
    });

    it('deduplicatesSameExecutionRacesCompletionEpochAndCoordinatesCloseAndInterruptionMatrix', 0, async () => {
      const primary = new ScriptedTransport([bootFrames(31337, [0xde, 0xad, 0xbe, 0xef], 0x49)]);
      const cancels: ScriptedTransport[] = []; let unblockConnect: (() => void) | null = null;
      const conn = new PostgresConnection(plainConfig(), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => {
        if (!primary.connectedOnce) return primary;
        const c = new ScriptedTransport([]); c.onConnect = (): Promise<void> => new Promise<void>((r: () => void): void => { unblockConnect = r; });
        cancels.push(c); return c;
      });
      await conn.connect(); primary.writes.length = 0; const qDedup = conn.query('SELECT dedup()'); await primary.waitWriteCount(1);
      const d1 = conn.cancel(); const d2 = conn.features.cancellation!.cancel(); expect(d1 === d2 && cancels.length === 1).assertTrue();
      await waitUntil((): boolean => unblockConnect !== null); const rel1 = unblockConnect!; unblockConnect = null; rel1();
      expect((await d1).outcome === CancellationOutcome.Requested && (await d2).outcome === CancellationOutcome.Requested && cancels.length === 1).assertTrue();
      primary.deliver(concatFrames([msgError('ERROR', '57014', 'canceled'), msgReady(0x49)])); await asyncFail((): Promise<Object> => qDedup);
      primary.writes.length = 0; const qRace = conn.query('SELECT fast()'); await primary.waitWriteCount(1);
      const rCancel = conn.cancel(); await waitUntil((): boolean => unblockConnect !== null);
      primary.deliver(singleRowQuery('finished-first', 0x49)); expect((await qRace).rows[0][0]).assertEqual('finished-first');
      const rel2 = unblockConnect!; unblockConnect = null; rel2(); const raceRes = await rCancel;
      expect(raceRes.outcome === CancellationOutcome.NotRunning && raceRes.connectionReuse === ConnectionReuse.Ready && cancels[1].writes.length === 0 && cancels[1].closed).assertTrue();
      primary.deliver(rxCmd('BEGIN', 0x54)); let freshCancelRes: QueryCancellationResult | null = null;
      const txEpoch = conn.postgresFeatures.transactions!.run<void>(new PostgresTransactionOptions(), async (s: PostgresSession): Promise<void> => {
        primary.writes.length = 0; const s1 = s.query('SELECT stmt1()'); await primary.waitWriteCount(1);
        const staleCancelTask = conn.cancel(); await waitUntil((): boolean => unblockConnect !== null);
        const relStale = unblockConnect!; unblockConnect = null;
        primary.deliver(singleRowQuery('s1-done', 0x54)); expect((await s1).rows[0][0]).assertEqual('s1-done');
        primary.writes.length = 0; const s2 = s.query('SELECT stmt2()'); await primary.waitWriteCount(1);
        relStale(); const staleRes = await staleCancelTask;
        expect(staleRes.outcome === CancellationOutcome.NotRunning && staleRes.connectionReuse === ConnectionReuse.AwaitingCompletion && cancels[2].writes.length === 0).assertTrue();
        const freshCancel = conn.cancel(); await waitUntil((): boolean => unblockConnect !== null);
        const relFresh = unblockConnect!; unblockConnect = null; relFresh(); freshCancelRes = await freshCancel;
        primary.deliver(concatFrames([msgError('ERROR', '57014', 's2 canceled'), msgReady(0x45)]));
        const s2Err = await asyncFail((): Promise<Object> => s2); expect(conn.isInterruptionError(s2Err)).assertTrue();
        primary.deliver(rxCmd('ROLLBACK', 0x49)); throw s2Err;
      });
      expect(conn.isInterruptionError(await asyncFail((): Promise<void> => txEpoch)) && freshCancelRes!.outcome === CancellationOutcome.Requested && cancels[3].writes.length === 1).assertTrue();

      primary.writes.length = 0; const qClose = conn.query('SELECT close_overlap()'); await primary.waitWriteCount(1); cancels.length = 0;
      const cOverlap = conn.cancel(); await waitUntil((): boolean => cancels.length === 1 && cancels[0].connectPending);
      const closePromise = conn.close(); const overlapRes = await cOverlap; await closePromise;
      expect(overlapRes.outcome === CancellationOutcome.NotRunning && overlapRes.connectionReuse === ConnectionReuse.Closed &&
        cancels[0].writes.length === 0 && cancels[0].closed && conn.state === ConnectionState.Closed &&
        (await asyncFail((): Promise<Object> => qClose)).kind === ArkDbErrorKind.Cancelled).assertTrue();

      const pMid = new ScriptedTransport([bootFrames(88, [1, 2, 3, 4], 0x49)]); const midCancel = new ScriptedTransport([]); midCancel.hangWrite = true;
      const cMidConn = new PostgresConnection(plainConfig(), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => !pMid.connectedOnce ? pMid : midCancel);
      await cMidConn.connect(); pMid.writes.length = 0; const qMid = cMidConn.query('SELECT mid_write_close()'); await pMid.waitWriteCount(1);
      const midTask = cMidConn.cancel(); await waitUntil((): boolean => midCancel.writePending);
      const midClose = cMidConn.close();
      expect((await asyncFail((): Promise<Object> => midTask)).kind === ArkDbErrorKind.Cancelled).assertTrue();
      await midClose; await asyncFail((): Promise<Object> => qMid); expect(midCancel.closed && !hasNonZero(midCancel.lastWriteBuf!)).assertTrue();

      const pPost = new ScriptedTransport([bootFrames(89, [5, 6, 7, 8], 0x49)]); const postCancel = new ScriptedTransport([]); postCancel.hangClose = true;
      const cPostConn = new PostgresConnection(plainConfig(), 'pw', new ManualTimerPort(), (): PostgresLifecycleTransport => !pPost.connectedOnce ? pPost : postCancel);
      await cPostConn.connect(); pPost.writes.length = 0; const qPost = cPostConn.query('SELECT post_write_close()'); await pPost.waitWriteCount(1);
      const postTask = cPostConn.cancel(); await waitUntil((): boolean => postCancel.closePending);
      const postClose = cPostConn.close(); postCancel.releaseClose(); const postRes = await postTask; await postClose; await asyncFail((): Promise<Object> => qPost);
      expect(postRes.outcome === CancellationOutcome.Requested && postRes.connectionReuse === ConnectionReuse.Closed).assertTrue();

      expect(conn.isInterruptionError(serverErr('57014', 'ERROR')) && conn.isInterruptionError(new ArkDbError(ArkDbErrorKind.Server, 'canceled', '57014', '57014'))).assertTrue();
      const locFatal = serverErr('57014', 'ERROR'); locFatal.localizedSeverity = 'FATAL';
      const locPanic = serverErr('57014', 'ERROR'); locPanic.localizedSeverity = 'PANIC';
      const fakeClient = ArkDbError.cancelled('local'); fakeClient.sqlState = '57014';
      const composed57014 = postgresAppendCleanupError(serverErr('57014', 'ERROR'), ArkDbError.network('rollback failed'));
      const nullErr: ArkDbError | null = null; const undefErr: ArkDbError | undefined = undefined;
      for (const nonInt of [composed57014, serverErr('57014', 'FATAL'), serverErr('57014', 'PANIC'), locFatal, locPanic, serverErr('57P01', 'FATAL'), serverErr('23505', 'ERROR'), serverErr('', 'ERROR'),
        fakeClient, ArkDbError.timeout('t'), ArkDbError.network('n'), ArkDbError.protocol('p'), ArkDbError.tls('s'), ArkDbError.validation('v'), nullErr!, undefErr!, (new Error('x') as Object) as ArkDbError]) {
        expect(conn.isInterruptionError(nonInt)).assertFalse();
      }
    });
  });
}

class CustomCancelConnection extends PostgresConnection {
  cancelCalls: number = 0; interruptCalls: number = 0;
  async cancel(): Promise<QueryCancellationResult> { this.cancelCalls += 1; return new QueryCancellationResult(CancellationOutcome.Requested, ConnectionReuse.AwaitingCompletion); }
  isInterruptionError(error: ArkDbError): boolean { this.interruptCalls += 1; return super.isInterruptionError(error); }
}
class TruncCancelSink implements QueryResultSink {
  private readonly onTrunc: () => Promise<QueryCancellationResult>;
  cancelResult: QueryCancellationResult | null = null; endedSummary: QueryResultSummary | null = null;
  constructor(onTrunc: () => Promise<QueryCancellationResult>) { this.onTrunc = onTrunc; }
  async onResultStart(_m: QueryResultMeta): Promise<void> {}
  async onRows(_c: QueryRowChunk): Promise<void> {}
  async onTruncation(_t: QueryTruncation): Promise<boolean> { this.cancelResult = await this.onTrunc(); return true; }
  async onResultEnd(s: QueryResultSummary): Promise<void> { this.endedSummary = s; }
}
class CancelFailCase {
  readonly reads: Array<Uint8Array | null>; readonly kind: ArkDbErrorKind; readonly code: string;
  readonly omitTlsUpgrade: boolean; readonly upgradeErr: ArkDbError | null; readonly zeroWriteCall: number; readonly rawRead: boolean; readonly readErr: ArkDbError | null;
  constructor(reads: Array<Uint8Array | null>, kind: ArkDbErrorKind, code: string, omitTlsUpgrade: boolean, upgradeErr: ArkDbError | null, zeroWriteCall: number, rawRead: boolean, readErr: ArkDbError | null) {
    this.reads = reads; this.kind = kind; this.code = code; this.omitTlsUpgrade = omitTlsUpgrade; this.upgradeErr = upgradeErr; this.zeroWriteCall = zeroWriteCall; this.rawRead = rawRead; this.readErr = readErr;
  }
}
class ScriptedTransport implements PostgresLifecycleTransport {
  private readonly rx: Array<Uint8Array | null> = [];
  private waiter: ((chunk: Uint8Array | null) => void) | null = null; private waiterReject: ((err: ArkDbError) => void) | null = null; private waiterMax: number = 0;
  private connectReject: ((err: ArkDbError) => void) | null = null; private writeReject: ((err: ArkDbError) => void) | null = null; private closeResolver: (() => void) | null = null;
  connectedOnce: boolean = false; connectPending: boolean = false; writePending: boolean = false; closePending: boolean = false;
  closed: boolean = false; hangConnect: boolean = false; hangWrite: boolean = false; hangClose: boolean = false;
  disableUpgradeMethod: boolean = false; rawChunks: boolean = false; maxWriteChunk: number = 65536; zeroWriteOnCall: number = 0; readCalls: number = 0;
  upgradeError: ArkDbError | null = null; readError: ArkDbError | null = null; lastWriteBuf: Uint8Array | null = null; readonly writes: Uint8Array[] = [];
  onConnect: (() => Promise<void>) | null = null; onWriteGate: ((buf: Uint8Array) => Promise<void> | null) | null = null;
  onWriteHook: ((buf: Uint8Array) => void) | null = null; onPrepareTls: (() => void) | null = null; onUpgradeTls: ((host: string, port: number, ssl: PostgresSslConfig) => void) | null = null;
  constructor(chunks: Array<Uint8Array | null>) { for (const c of chunks) this.rx.push(c); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.deliver(c); }
  deliver(chunk: Uint8Array): void {
    this.rx.push(chunk);
    if (this.waiter !== null) { const w = this.waiter; const max = this.waiterMax; this.waiter = null; this.waiterReject = null; w(this.takeChunk(max)); }
  }
  async connect(_host: string, _port: number, _timeoutMs: number): Promise<void> {
    this.connectedOnce = true;
    if (this.hangConnect) { this.connectPending = true; await new Promise<void>((_r: () => void, rej: (e: ArkDbError) => void): void => { this.connectReject = rej; }); }
    if (this.onConnect === null) return;
    this.connectPending = true;
    try { await new Promise<void>((res: () => void, rej: (e: ArkDbError) => void): void => { this.connectReject = rej; this.onConnect!().then(res, (e: Object): void => rej(e as ArkDbError)); }); }
    finally { this.connectPending = false; this.connectReject = null; }
  }
  prepareTlsUpgrade(): void { if (this.onPrepareTls !== null) this.onPrepareTls(); }
  get upgradeToTls(): ((host: string, port: number, ssl: PostgresSslConfig, timeoutMs: number) => Promise<void>) | undefined {
    return this.disableUpgradeMethod ? undefined : async (host: string, port: number, ssl: PostgresSslConfig): Promise<void> => {
      if (this.onUpgradeTls !== null) this.onUpgradeTls(host, port, ssl);
      if (this.upgradeError !== null) throw this.upgradeError;
    };
  }
  async read(maxBytes: number, _timeoutMs?: number): Promise<Uint8Array | null> {
    this.readCalls += 1; if (this.readError !== null) throw this.readError; if (this.rx.length > 0) return this.takeChunk(maxBytes); if (this.closed) return null;
    this.waiterMax = maxBytes; return new Promise<Uint8Array | null>((res: (c: Uint8Array | null) => void, rej: (e: ArkDbError) => void): void => { this.waiter = res; this.waiterReject = rej; });
  }
  private takeChunk(maxBytes: number): Uint8Array | null {
    const head = this.rx[0]; if (head === null || this.rawChunks || head.length <= maxBytes) { this.rx.shift(); return head; }
    this.rx[0] = head.subarray(maxBytes); return head.subarray(0, maxBytes);
  }
  async write(bytes: Uint8Array, _timeoutMs?: number): Promise<number> {
    if (this.zeroWriteOnCall === this.writes.length + 1) return 0;
    const take = Math.min(bytes.length, this.maxWriteChunk); this.lastWriteBuf = bytes;
    if (this.hangWrite) { this.writePending = true; await new Promise<void>((_r: () => void, rej: (e: ArkDbError) => void): void => { this.writeReject = rej; }); }
    const gate = this.onWriteGate !== null ? this.onWriteGate(bytes) : null; if (gate !== null) await gate;
    const copy = bytes.slice(0, take); this.writes.push(copy); if (this.onWriteHook !== null) this.onWriteHook(copy); return take;
  }
  async abort(error: ArkDbError): Promise<void> {
    this.closed = true; this.connectPending = false; this.writePending = false;
    if (this.connectReject !== null) { const r = this.connectReject; this.connectReject = null; r(error); }
    if (this.writeReject !== null) { const r = this.writeReject; this.writeReject = null; r(error); }
    if (this.waiterReject !== null) { const r = this.waiterReject; this.waiter = null; this.waiterReject = null; r(error); }
  }
  async close(): Promise<void> {
    this.closed = true; if (this.waiter !== null) { const w = this.waiter; this.waiter = null; this.waiterReject = null; w(null); }
    if (this.hangClose) { this.closePending = true; await new Promise<void>((r: () => void): void => { this.closeResolver = r; }); this.closePending = false; }
  }
  releaseClose(): void { if (this.closeResolver !== null) { const r = this.closeResolver; this.closeResolver = null; r(); } }
  async waitWriteCount(n: number): Promise<void> { await waitUntil((): boolean => this.writes.length >= n); }
}
class ManualTimerPort implements ConnectionTimerPort {
  private nextId: number = 1; private clockMs: number = 1000; private readonly cbMap: Map<number, () => void> = new Map<number, () => void>();
  get activeCount(): number { return this.cbMap.size; }
  nowMs(): number { return this.clockMs; }
  schedule(cb: () => void, _ms: number): number { const id = this.nextId++; this.cbMap.set(id, cb); return id; }
  cancel(handle: number): void { this.cbMap.delete(handle); }
  fireNext(): void { const first = this.cbMap.entries().next(); if (!first.done) { this.clockMs += 10000; this.cbMap.delete(first.value[0]); first.value[1](); } }
}
function plainConfig(): PostgresConnectionConfig { const c = new PostgresConnectionConfig(); c.host = 'db.internal'; c.user = 'postgres'; c.ssl.mode = PostgresSslMode.DISABLED; return c; }
function tlsConfig(mode: PostgresSslMode): PostgresConnectionConfig { const c = plainConfig(); c.ssl.mode = mode; return c; }
function serverErr(sqlState: string, severity: string): PostgresError { const e = new PostgresError(ArkDbErrorKind.Server, 'err', sqlState, sqlState); e.severity = severity; e.localizedSeverity = severity; return e; }
function frame(type: number, payload: number[]): Uint8Array { const l = payload.length + 4; return new Uint8Array([type, (l >>> 24) & 0xff, (l >>> 16) & 0xff, (l >>> 8) & 0xff, l & 0xff, ...payload]); }
function bootFrames(pid: number, key: number[], ready: number): Uint8Array { return concatFrames([frame(0x52, [0, 0, 0, 0]), frame(0x4b, [(pid >>> 24) & 0xff, (pid >>> 16) & 0xff, (pid >>> 8) & 0xff, pid & 0xff, ...key]), msgReady(ready)]); }
function bootFramesWithoutKey(ready: number): Uint8Array { return concatFrames([frame(0x52, [0, 0, 0, 0]), msgReady(ready)]); }
function msgReady(status: number): Uint8Array { return frame(0x5a, [status]); }
function msgParseComplete(): Uint8Array { return frame(0x31, []); }
function msgBindComplete(): Uint8Array { return frame(0x32, []); }
function msgPortalSuspended(): Uint8Array { return frame(0x73, []); }
function msgCmd(tag: string): Uint8Array { return frame(0x43, [...ascii(tag), 0]); }
function rxCmd(tag: string, ready: number): Uint8Array { return concatFrames([msgCmd(tag), msgReady(ready)]); }
function msgRowDesc(name: string): Uint8Array { return frame(0x54, [0, 1, ...ascii(name), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 25, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0]); }
function msgDataRow(val: string): Uint8Array { const b = ascii(val); return frame(0x44, [0, 1, (b.length >>> 24) & 0xff, (b.length >>> 16) & 0xff, (b.length >>> 8) & 0xff, b.length & 0xff, ...b]); }
function singleRowQuery(val: string, ready: number): Uint8Array { return concatFrames([msgRowDesc('v'), msgDataRow(val), msgCmd('SELECT 1'), msgReady(ready)]); }
function msgError(sev: string, code: string, msg: string): Uint8Array { return frame(0x45, [0x53, ...ascii(sev), 0, 0x56, ...ascii(sev), 0, 0x43, ...ascii(code), 0, 0x4d, ...ascii(msg), 0, 0]); }
function ascii(s: string): number[] { const out: number[] = []; for (let i = 0; i < s.length; i += 1) out.push(s.charCodeAt(i) & 0x7f); return out; }
function concatFrames(parts: Uint8Array[]): Uint8Array { return concatChunks(parts); }
function concatChunks(parts: Uint8Array[]): Uint8Array { let n = 0; for (const p of parts) n += p.length; const out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; }
function hasNonZero(b: Uint8Array): boolean { for (let i = 0; i < b.length; i += 1) { if (b[i] !== 0) return true; } return false; }
function assertBytes(actual: Uint8Array, expected: number[]): void { expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]); }
async function flushMicrotasks(): Promise<void> { for (let i = 0; i < 16; i += 1) await Promise.resolve(); }
async function waitUntil(pred: () => boolean): Promise<void> { for (let i = 0; i < 512 && !pred(); i += 1) await Promise.resolve(); expect(pred()).assertTrue(); }
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> { let err: ArkDbError | null = null; try { await op(); } catch (e) { err = e as ArkDbError; } expect(err instanceof ArkDbError).assertTrue(); return err!; }
