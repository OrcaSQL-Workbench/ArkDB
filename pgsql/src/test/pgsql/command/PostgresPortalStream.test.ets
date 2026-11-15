import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, Logger, LogLevel, LogSink, QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation } from '@arkdb/core';
import { PostgresConnection, PostgresConnectionConfig, PostgresError, PostgresParameter, PostgresParameterType, PostgresParameterValue, PostgresQueryResult, PostgresSslMode, PostgresTransactionState } from '../../../../Index';
import { PostgresLifecycleTransport } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandPhase } from '../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresPreparedFrames } from '../../../main/ets/pgsql/features/prepared/PostgresParameterEncoder';
import { PostgresConnectionPreparedExecutor } from '../../../main/ets/pgsql/features/prepared/PostgresPreparedExecutor';

export default function postgresPortalStreamTest(): void {
  describe('PostgresPortalStream', () => {
    it('validatesGuardsSnapshotsScrubsAndPreservesCycleFreeJson', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp, new StepTimers(), 'secret-p19-pw');
      expect(JSON.stringify(conn.postgresFeatures) === '{"prepared":{}}' && JSON.stringify(conn).indexOf('secret-p19-pw') === -1).assertTrue();
      await conn.connect(); tp.writes.length = 0; tp.rawWrites.length = 0;
      const uninit = new PostgresConnectionPreparedExecutor((_f: PostgresPreparedFrames, _o: QueryOptions): Promise<PostgresQueryResult> => Promise.resolve(new PostgresQueryResult()));
      expect((await asyncFail((): Promise<Object> => uninit.queryStream('SELECT 1', [], new QueryOptions(), new RecSink()))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.queryStream('SELECT 1', [], asQueryOpts(null), new RecSink()))).message).assertEqual('QueryOptions is required.');
      for (const mut of [(o: QueryOptions): void => { o.maxRows = -1; }, (o: QueryOptions): void => { o.maxChunkRows = 0; }, (o: QueryOptions): void => { o.maxDrainBytes = 0; }, (o: QueryOptions): void => { o.maxDrainTimeMs = 0; }]) {
        const bad = new QueryOptions(); mut(bad);
        expect((await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.queryStream('SELECT 1', [], bad, new RecSink()))).kind).assertEqual(ArkDbErrorKind.Validation);
      }
      const dlOpts = new QueryOptions(); dlOpts.statementTimeoutMs = 25;
      expect((await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.queryStream('SELECT 1', [], dlOpts, new RecSink()))).kind).assertEqual(ArkDbErrorKind.Unsupported);
      const untouchedParam = new ForgedInt4Parameter();
      for (const badSink of [asSink(null), asSink(undefined), asSink('not-sink')]) {
        const se = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.queryStream('SELECT $1', [untouchedParam], new QueryOptions(), badSink));
        expect(se.kind === ArkDbErrorKind.Validation && se.message === 'QueryResultSink is required.').assertTrue();
      }
      expect(untouchedParam.reads === 0 && tp.writes.length === 0).assertTrue();
      const inspectedBad = new InspectableByteaParameter(new Uint8Array([0xca, 0xfe]));
      expect((await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.queryStream('SELECT $1, $2', [inspectedBad, new ForgedInt4Parameter()], new QueryOptions(), new RecSink()))).kind).assertEqual(ArkDbErrorKind.Validation);
      expect(inspectedBad.lastRead !== null && tp.writes.length === 0 && conn.state === ConnectionState.Ready).assertTrue();
      assertZeroed(inspectedBad.lastRead!);
      let capFrames: PostgresPreparedFrames | null = null;
      const scrubExec = new PostgresConnectionPreparedExecutor(
        (_f: PostgresPreparedFrames, _o: QueryOptions): Promise<PostgresQueryResult> => Promise.resolve(new PostgresQueryResult()),
        (f: PostgresPreparedFrames, _o: QueryOptions, _s: QueryResultSink): Promise<QueryExecutionSummary> => { capFrames = f; return Promise.reject(ArkDbError.protocol('stream rejected')); });
      const callerBuf = new Uint8Array([0x12, 0x34]); const ownedParam = new InspectableByteaParameter(callerBuf);
      expect((await asyncFail((): Promise<Object> => scrubExec.queryStream('SELECT $1, $2', [ownedParam, new PostgresParameter(PostgresParameterType.Text, 'k€y')], new QueryOptions(), new RecSink()))).kind).assertEqual(ArkDbErrorKind.Protocol);
      assertZeroed(capFrames!.parseFrame); assertZeroed(capFrames!.bindFrame); assertZeroed(capFrames!.parameters.parameterValues[0]!); assertZeroed(capFrames!.parameters.parameterValues[1]!); assertZeroed(ownedParam.lastRead!);
      assertBytes(callerBuf, new Uint8Array([0x12, 0x34]));
      const snapBytes = new Uint8Array([0xab, 0xcd]); const snapParams = [new PostgresParameter(PostgresParameterType.Bytea, snapBytes)];
      const snapOpts = new QueryOptions(); snapOpts.maxChunkRows = 2;
      tp.enqueue([concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc([colSpec('v', 0, 0, 23, 4, -1, 0)]), msgDataRow(['7']), msgCmd('SELECT 1'), msgReady(0x49)])]);
      const sink = new RecSink(); const run = conn.postgresFeatures.prepared!.queryStream('SELECT $1', snapParams, snapOpts, sink);
      snapParams.length = 0; snapBytes.fill(0xff); snapOpts.maxRows = 0; snapOpts.maxChunkRows = 99; snapOpts.statementTimeoutMs = 500;
      const summary = await run;
      expect(summary.loadedRowCount === 1 && sink.chunks[0].rows[0][0] === 7 && tp.writes.length === 6).assertTrue();
      assertBytes(tp.writes[2], expectedDescribePortal()); assertBytes(tp.writes[3], expectedExecute(2)); assertBytes(tp.writes[4], expectedFlush()); assertBytes(tp.writes[5], expectedSync());
      for (const raw of tp.rawWrites) assertZeroed(raw);
      await conn.close(); expect(JSON.stringify(conn).indexOf('secret-p19-pw')).assertEqual(-1);
    });

    it('streamsMultiBatchPortalSuspendedCappingExecuteWireBytesAndBackpressure', 0, async () => {
      const logSink = new StreamLogSink(); const prevLevel = Logger.level; Logger.setLevel(LogLevel.DEBUG); Logger.addSink(logSink);
      try {
        const cols = [colSpec('t', 0, 0, 25, -1, -1, 0)]; const r1 = msgDataRow(['aa']); const r2 = msgDataRow(['bb']); const r3 = msgDataRow(['cccccc']);
        const gate = new PostgresCommandGate(); const timers = new StepTimers(); timers.stepMs = 4;
        const tp = new PhaseTransport([bootFrames(0x49),
          concatFrames([msgNotice('NOTICE', '00000', 'n1'), msgParseComplete(), msgNotification(12, 'sec_ch', 'sec_pay'), msgBindComplete(),
            msgParam('TimeZone', 'UTC'), msgRowDesc(cols), r1, r2, msgPortalSuspended()]),
          concatFrames([r3, msgDataRow(['dd']), msgPortalSuspended()]),
          concatFrames([msgDataRow(['ee']), msgCmd('SELECT 1'), msgReady(0x54)]),
          concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(cols), r1, r2, r3, msgCmd('SELECT 3'), msgReady(0x49)]),
          concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(cols), r1, r2, r3, msgCmd('SELECT 9007199254740992'), msgReady(0x49)]),
          concatFrames([msgCmd('SELECT 1'), msgReady(0x49)])], gate);
        const conn = new PostgresConnection(baseConfig(), '', timers, (): PostgresLifecycleTransport => tp, undefined, gate);
        await conn.connect(); tp.writes.length = 0; tp.writePhases.length = 0;
        const opts = new QueryOptions(); opts.maxChunkRows = 2;
        const sink = new RecSink(gate); sink.mutateDelivered = true;
        const exec = await conn.postgresFeatures.prepared!.queryStream('SELECT $1', [new PostgresParameter(PostgresParameterType.Int4, 5)], opts, sink);
        expect(tp.writes.length).assertEqual(10);
        assertBytes(tp.writes[2], expectedDescribePortal()); assertBytes(tp.writes[3], expectedExecute(2)); assertBytes(tp.writes[4], expectedFlush());
        assertBytes(tp.writes[5], expectedExecute(2)); assertBytes(tp.writes[6], expectedFlush());
        assertBytes(tp.writes[7], expectedExecute(2)); assertBytes(tp.writes[8], expectedFlush()); assertBytes(tp.writes[9], expectedSync());
        expect(tp.writePhases[0] === PostgresCommandKind.Prepared + ':' + PostgresCommandPhase.Executing &&
          tp.writePhases[5] === PostgresCommandKind.Prepared + ':' + PostgresCommandPhase.Streaming &&
          sink.phases[0] === 'prepared:streaming' && sink.events.join(',') === 'start:0:true,rows:0:0:2,rows:0:2:2,rows:0:4:1,end:0').assertTrue();
        expect(exec.resultSetCount === 1 && exec.loadedRowCount === 5 && exec.rowCount === 5 && exec.rowCountKnown &&
          exec.statusKnown && exec.status.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction &&
          conn.serverInfo.timeZone === 'UTC' && logSink.messages.join('\n').indexOf('sec_ch') === -1 && logSink.messages.join('\n').indexOf('sec_pay') === -1).assertTrue();
        tp.writes.length = 0; const capOpts = new QueryOptions(); capOpts.maxChunkRows = 15000;
        const capSink = new RecSink(); const capExec = await conn.postgresFeatures.prepared!.queryStream('SELECT 1', [], capOpts, capSink);
        assertBytes(tp.writes[3], expectedExecute(10000)); assertBytes(tp.writes[5], expectedSync());
        expect(tp.writes.length === 6 && capSink.chunks.length === 1 && capSink.chunks[0].rows.length === 3 && capExec.rowCount === 3).assertTrue();
        const byteOpts = new QueryOptions(); byteOpts.maxChunkRows = 10; byteOpts.maxChunkBytes = (r1.length - 5) + (r2.length - 5);
        const byteSink = new RecSink(); const byteExec = await conn.postgresFeatures.prepared!.queryStream('SELECT 1', [], byteOpts, byteSink);
        expect(byteSink.chunks.length === 2 && byteSink.chunks[0].rows.length === 2 && byteSink.chunks[1].rows.length === 1 &&
          !byteSink.ends[0].rowCountKnown && byteSink.ends[0].rowCount === 3 && !byteExec.rowCountKnown && byteExec.rowCount === 3).assertTrue();
        expect((await conn.query('SELECT 1')).commandTag).assertEqual('SELECT 1');

        const bpTp = new QueueTransport([bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(cols), r1, msgPortalSuspended()])]);
        bpTp.hangAtEmpty = true; const bpConn = openReady(bpTp); await bpConn.connect(); bpTp.writes.length = 0;
        const bpOpts = new QueryOptions(); bpOpts.maxChunkRows = 15000; const gateSink = new GatedSink('rows');
        const bpTask = bpConn.postgresFeatures.prepared!.queryStream('SELECT 1', [], bpOpts, gateSink);
        await gateSink.waitReached('rows', bpTask); await flushTicks(6);
        expect(bpTp.writes.length).assertEqual(5); assertBytes(bpTp.writes[3], expectedExecute(10000));
        bpTp.enqueue([concatFrames([r2, msgCmd('SELECT 1'), msgReady(0x49)])]); bpTp.hangAtEmpty = false;
        gateSink.release('rows'); await gateSink.waitReached('rows', bpTask);
        expect(bpTp.writes.length).assertEqual(7); assertBytes(bpTp.writes[5], expectedExecute(10000)); assertBytes(bpTp.writes[6], expectedFlush());
        gateSink.release('rows'); const bpExec = await bpTask;
        expect(bpExec.loadedRowCount === 2 && bpExec.rowCount === 2 && bpTp.writes.length === 8 && bpConn.state === ConnectionState.Ready).assertTrue();
        assertBytes(bpTp.writes[7], expectedSync());
        const srTp = new QueueTransport([bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(cols), r1, msgPortalSuspended(), msgCloseComplete(), msgReady(0x49)]), concatFrames([msgCmd('SELECT 7'), msgReady(0x49)])]);
        const srConn = openReady(srTp); await srConn.connect(); srTp.writes.length = 0; const srOpts = new QueryOptions(); srOpts.maxRows = 1; srOpts.maxChunkRows = 4;
        expect((await asyncFail((): Promise<Object> => srConn.postgresFeatures.prepared!.queryStream('SUSP_REJ', [], srOpts, new FailingStageSink('rows', ArkDbError.validation('susp rows err'))))).kind === ArkDbErrorKind.Validation && srTp.writes.length === 7 && srConn.state === ConnectionState.Ready).assertTrue();
        assertBytes(srTp.writes[5], expectedClosePortal()); assertBytes(srTp.writes[6], expectedSync());
        expect((await srConn.query('SELECT 7')).commandTag).assertEqual('SELECT 7');
      } finally { Logger.removeSink(logSink); Logger.setLevel(prevLevel); }
    });

    it('handlesNoDataPortalAndRejectsUnexpectedFramesFailClosed', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49),
        concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), msgCmd('INSERT 0 4'), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), msgEmptyQuery(), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), msgCmd('MOVE 9007199254740992'), msgReady(0x49)]),
        concatFrames([msgCmd('SELECT 1'), msgReady(0x49)])]);
      const conn = openReady(tp); await conn.connect(); tp.writes.length = 0;
      const sIns = new RecSink(); const eIns = await conn.postgresFeatures.prepared!.queryStream('INSERT', [], new QueryOptions(), sIns);
      expect(sIns.events.join(',') === 'start:0:false,end:0' && sIns.ends[0].affectedRows === 4 && sIns.ends[0].rowCount === 0 && eIns.rowCount === 0 && tp.writes.length === 6).assertTrue();
      assertBytes(tp.writes[5], expectedSync());
      const sEmp = new RecSink(); await conn.postgresFeatures.prepared!.queryStream('', [], new QueryOptions(), sEmp);
      expect(sEmp.events.join(',') === 'start:0:false,end:0' && sEmp.ends[0].affectedRows === 0).assertTrue();
      const sMove = new RecSink(); const eMove = await conn.postgresFeatures.prepared!.queryStream('MOVE', [], new QueryOptions(), sMove);
      expect(!sMove.ends[0].rowCountKnown && !eMove.rowCountKnown && conn.state === ConnectionState.Ready).assertTrue();
      expect((await conn.query('SELECT 1')).commandTag).assertEqual('SELECT 1');

      const badFrames: Uint8Array[] = [
        concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), msgPortalSuspended()]),
        concatFrames([msgParseComplete(), msgBindComplete(), backendFrame(0x74, [0, 0])]),
        concatFrames([msgBindComplete()]),
        concatFrames([msgParseComplete(), msgRowDesc([colSpec('v', 0, 0, 23, 4, -1, 0)])]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc([colSpec('v', 0, 0, 23, 4, -1, 0)]), msgPortalSuspended()]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc([colSpec('v', 0, 0, 23, 4, -1, 0)]), msgDataRow(['1', '2'])])
      ];
      for (const bad of badFrames) {
        const bConn = openReady(new QueueTransport([bootFrames(0x49), bad])); await bConn.connect();
        expect((await asyncFail((): Promise<Object> => bConn.postgresFeatures.prepared!.queryStream('SELECT 1', [], new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Protocol && bConn.state === ConnectionState.Error).assertTrue();
      }
    });

    it('probesExactMaxRowsEofAndClosesPortalOnMaxRowsAndResultBytesTruncation', 0, async () => {
      const cols = [colSpec('t', 0, 0, 25, -1, -1, 0)]; const byteaCol = [colSpec('b', 0, 0, 17, -1, -1, 0)];
      const badUtf8Row4 = backendFrame(0x44, [0, 1, 0, 0, 0, 1, 0xff]);
      const tp = new QueueTransport([bootFrames(0x49),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(cols), msgDataRow(['r1']), msgDataRow(['r2']), msgPortalSuspended(),
          msgDataRow(['r3']), msgPortalSuspended(), msgCmd('SELECT 0'), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(cols), msgDataRow(['r1']), msgDataRow(['r2']), msgPortalSuspended(),
          msgDataRow(['r3']), msgPortalSuspended(), badUtf8Row4, msgPortalSuspended(), msgCloseComplete(), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgDataRow(['\\x010203040506']), msgDataRow(['\\xff']),
          msgPortalSuspended(), msgCloseComplete(), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgDataRow(['\\x010203040506']), msgCmd('SELECT 2'), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc([colSpec('bin', 0, 0, 23, 4, -1, 1)]), msgDataRow(['1']), msgPortalSuspended(), msgCloseComplete(), msgReady(0x49)]),
        concatFrames([msgCmd('SELECT 9'), msgReady(0x49)])]);
      const conn = openReady(tp); await conn.connect(); tp.writes.length = 0;

      const exactOpts = new QueryOptions(); exactOpts.maxRows = 3; exactOpts.maxChunkRows = 2;
      const exactSink = new RecSink(); const exactExec = await conn.postgresFeatures.prepared!.queryStream('EXACT_3', [], exactOpts, exactSink);
      expect(tp.writes.length).assertEqual(10);
      assertBytes(tp.writes[3], expectedExecute(2)); assertBytes(tp.writes[4], expectedFlush());
      assertBytes(tp.writes[5], expectedExecute(1)); assertBytes(tp.writes[6], expectedFlush());
      assertBytes(tp.writes[7], expectedExecute(1)); assertBytes(tp.writes[8], expectedFlush()); assertBytes(tp.writes[9], expectedSync());
      expect(!exactSink.ends[0].truncated && exactSink.ends[0].truncationReason === '' && exactSink.ends[0].rowCountKnown && exactSink.ends[0].rowCount === 3 &&
        exactSink.truncations.length === 0 && exactExec.rowCountKnown && exactExec.rowCount === 3 && execChunksTotal(exactSink) === 3).assertTrue();

      tp.writes.length = 0; const overSink = new RecSink();
      const overExec = await conn.postgresFeatures.prepared!.queryStream('OVER_3', [], exactOpts, overSink);
      expect(tp.writes.length).assertEqual(11);
      assertBytes(tp.writes[3], expectedExecute(2)); assertBytes(tp.writes[5], expectedExecute(1)); assertBytes(tp.writes[7], expectedExecute(1));
      assertBytes(tp.writes[9], expectedClosePortal()); assertBytes(tp.writes[10], expectedSync());
      expect(overSink.events.join(',') === 'start:0:true,rows:0:0:2,rows:0:2:1,trunc:0:rowLimit:3,end:0' &&
        overSink.ends[0].truncated && overSink.ends[0].truncationReason === 'rowLimit' && !overSink.ends[0].rowCountKnown && overSink.ends[0].rowCount === 3 &&
        !overExec.rowCountKnown && overExec.rowCount === 3 && overExec.loadedRowCount === 3).assertTrue();

      tp.writes.length = 0; const byteOpts = new QueryOptions(); byteOpts.maxChunkRows = 3; byteOpts.maxResultBytes = 4;
      const bSink1 = new RecSink(); bSink1.cancelOnTruncation = true;
      const bExec1 = await conn.postgresFeatures.prepared!.queryStream('BYTES_SUSP', [], byteOpts, bSink1);
      assertBytes(tp.writes[5], expectedClosePortal()); assertBytes(tp.writes[6], expectedSync());
      expect(bSink1.events.join(',') === 'start:0:true,rows:0:0:1,trunc:0:resultBytes:1,end:0' &&
        bSink1.ends[0].truncated && !bSink1.ends[0].rowCountKnown && bSink1.ends[0].rowCount === 1 &&
        bExec1.truncationInterrupted && !bExec1.rowCountKnown && bExec1.rowCount === 1).assertTrue();

      tp.writes.length = 0; const bSink2 = new RecSink();
      const bExec2 = await conn.postgresFeatures.prepared!.queryStream('BYTES_CMD', [], byteOpts, bSink2);
      assertBytes(tp.writes[5], expectedSync());
      expect(bSink2.ends[0].truncated && bSink2.ends[0].truncationReason === 'resultBytes' && bSink2.ends[0].rowCountKnown && bSink2.ends[0].rowCount === 2 &&
        bExec2.rowCountKnown && bExec2.rowCount === 2).assertTrue();

      tp.writes.length = 0; const binSink = new RecSink();
      expect((await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.queryStream('BIN_COL', [], new QueryOptions(), binSink))).kind === ArkDbErrorKind.Unsupported &&
        binSink.starts.length === 0 && conn.state === ConnectionState.Ready).assertTrue();
      assertBytes(tp.writes[5], expectedClosePortal()); assertBytes(tp.writes[6], expectedSync());
      expect((await conn.query('SELECT 9')).commandTag).assertEqual('SELECT 9');
    });

    it('RecoversAndSynchronizesFromSinkErrorsServerErrorsDrainBudgetsAndCopy', 0, async () => {
      const byteaCol = [colSpec('b', 0, 0, 17, -1, -1, 0)];
      for (const sc of [['start', new Error('sink start err')], ['rows', ArkDbError.cancelled('sink rows cancel')],
        ['trunc', ArkDbError.validation('sink trunc err')], ['end', ArkDbError.network('sink end net')]] as Array<[string, Object]>) {
        const r1 = msgDataRow(['\\xdead']); const ownedR1 = r1.slice(5); const r2 = msgDataRow(['\\xbeef']); const ownedR2 = r2.slice(5);
        const reads: Uint8Array[] = sc[0] === 'end'
          ? [bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), r1, msgCmd('SELECT 1'), msgReady(0x49)]), concatFrames([msgCmd('SELECT 4'), msgReady(0x49)])]
          : sc[0] === 'trunc'
            ? [bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol)]), r1.slice(0, 5), ownedR1, msgPortalSuspended(), r2.slice(0, 5), ownedR2, concatFrames([msgPortalSuspended(), msgCloseComplete(), msgReady(0x49)]), concatFrames([msgCmd('SELECT 4'), msgReady(0x49)])]
            : [bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol)]), r1.slice(0, 5), ownedR1, r2.slice(0, 5), ownedR2, concatFrames([msgPortalSuspended(), msgCloseComplete(), msgReady(0x49)]), concatFrames([msgCmd('SELECT 4'), msgReady(0x49)])];
        const sTp = new QueueTransport(reads); const sConn = openReady(sTp); await sConn.connect(); sTp.writes.length = 0;
        const sOpts = new QueryOptions(); sOpts.maxChunkRows = 2; if (sc[0] === 'trunc') sOpts.maxRows = 1;
        const fSink = new FailingStageSink(sc[0], sc[1]);
        const caught = await asyncFail((): Promise<Object> => sConn.postgresFeatures.prepared!.queryStream('SINK_' + sc[0], [], sOpts, fSink));
        expect(caught.message.indexOf((sc[1] as Error).message) >= 0 && fSink.callsAfterFailure === 0 && sConn.state === ConnectionState.Ready).assertTrue();
        if (sc[0] !== 'end') {
          const closeIdx = sc[0] === 'trunc' ? 7 : 5;
          assertBytes(sTp.writes[closeIdx], expectedClosePortal()); assertBytes(sTp.writes[closeIdx + 1], expectedSync()); assertZeroed(ownedR1); assertZeroed(ownedR2);
        }
        expect((await sConn.query('SELECT 4')).commandTag).assertEqual('SELECT 4');
      }

      const srvStages: Array<[Uint8Array, number, ArkDbErrorKind]> = [
        [concatFrames([msgError('ERROR', 'ERROR', '42601', 'parse err'), msgReady(0x49)]), 6, ArkDbErrorKind.Server],
        [concatFrames([msgParseComplete(), msgError('ERROR', 'ERROR', '22P02', 'bind err'), msgReady(0x49)]), 6, ArkDbErrorKind.Server],
        [concatFrames([msgParseComplete(), msgBindComplete(), msgError('ERROR', 'ERROR', '42P01', 'desc err'), msgReady(0x49)]), 6, ArkDbErrorKind.Server],
        [concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), msgError('ERROR', 'ERROR', '23505', 'nodata err'), msgReady(0x49)]), 6, ArkDbErrorKind.Server],
        [concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), msgCopyOut(), msgError('ERROR', 'ERROR', '57014', 'copyout err'), msgReady(0x49)]), 6, ArkDbErrorKind.Unsupported],
        [concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), msgCmd('INSERT 0 1'), msgError('ERROR', 'ERROR', '40001', 'commit err'), msgReady(0x49)]), 6, ArkDbErrorKind.Server],
        [concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgError('ERROR', 'ERROR', '22012', 'exec1 err'), msgReady(0x49)]), 6, ArkDbErrorKind.Server],
        [concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgPortalSuspended(), msgError('ERROR', 'ERROR', '22012', 'exec2 err'), msgReady(0x49)]), 8, ArkDbErrorKind.Server]
      ];
      for (const st of srvStages) {
        const eTp = new QueueTransport([bootFrames(0x49), st[0], concatFrames([msgCmd('SELECT 2'), msgReady(0x49)])]);
        const eConn = openReady(eTp); await eConn.connect(); eTp.writes.length = 0;
        const pIn = new InspectableByteaParameter(new Uint8Array([0x55, 0x66]));
        const o = new QueryOptions(); o.maxChunkRows = 1;
        const err = await asyncFail((): Promise<Object> => eConn.postgresFeatures.prepared!.queryStream('SELECT $1', [pIn], o, new RecSink()));
        expect(err.kind === st[2] && eTp.writes.length === st[1] && eConn.state === ConnectionState.Ready).assertTrue();
        assertBytes(eTp.writes[st[1] - 1], expectedSync()); assertZeroed(pIn.lastRead!);
        expect((await eConn.query('SELECT 2')).commandTag).assertEqual('SELECT 2');
      }

      const closePortalErrTp = new QueueTransport([bootFrames(0x49),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgPortalSuspended(),
          msgError('ERROR', 'ERROR', '34000', 'close portal err'), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgPortalSuspended(), msgDataRow(['\\xbb']), msgPortalSuspended(),
          msgError('ERROR', 'ERROR', '57014', 'canceled during close'), msgReady(0x49)]),
        concatFrames([msgCmd('SELECT 8'), msgReady(0x49)])]);
      const cpConn = openReady(closePortalErrTp); await cpConn.connect(); closePortalErrTp.writes.length = 0;
      const cpOpts = new QueryOptions(); cpOpts.maxChunkRows = 1;
      const cpErr = await asyncFail((): Promise<Object> => cpConn.postgresFeatures.prepared!.queryStream('CLOSE_ERR', [], cpOpts, new FailingStageSink('rows', ArkDbError.validation('sink primary'))));
      expect(cpErr.kind === ArkDbErrorKind.Validation && cpErr.message.indexOf('sink primary') === 0 && cpErr.message.indexOf('close portal err') > 0 &&
        closePortalErrTp.writes.length === 7 && cpConn.state === ConnectionState.Ready).assertTrue();
      assertBytes(closePortalErrTp.writes[5], expectedClosePortal()); assertBytes(closePortalErrTp.writes[6], expectedSync());
      closePortalErrTp.writes.length = 0; const cancelSink = new RecSink(); cancelSink.cancelOnTruncation = true;
      const cancelOpts = new QueryOptions(); cancelOpts.maxRows = 1; cancelOpts.maxChunkRows = 2;
      const cancelExec = await cpConn.postgresFeatures.prepared!.queryStream('CANCEL_57014', [], cancelOpts, cancelSink);
      expect(cancelSink.ends.length === 1 && cancelSink.ends[0].truncated && !cancelSink.ends[0].rowCountKnown && cancelExec.truncationInterrupted &&
        closePortalErrTp.writes.length === 9 && cpConn.state === ConnectionState.Ready).assertTrue();
      expect((await cpConn.query('SELECT 8')).commandTag).assertEqual('SELECT 8');

      const fatalConn = openReady(new QueueTransport([bootFrames(0x49), concatFrames([msgError('FATAL', 'FATAL', '57P01', 'terminating')])])); await fatalConn.connect();
      expect((await asyncFail((): Promise<Object> => fatalConn.postgresFeatures.prepared!.queryStream('SELECT 1', [], new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Server && fatalConn.state === ConnectionState.Error).assertTrue();
      const dupConn = openReady(new QueueTransport([bootFrames(0x49), concatFrames([msgError('ERROR', 'ERROR', '22012', 'e1'), msgError('ERROR', 'ERROR', '22012', 'e2'), msgReady(0x49)])])); await dupConn.connect();
      expect((await asyncFail((): Promise<Object> => dupConn.postgresFeatures.prepared!.queryStream('SELECT 1', [], new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Protocol && dupConn.state === ConnectionState.Error).assertTrue();

      const pureDbOpts = new QueryOptions(); pureDbOpts.maxRows = 1; pureDbOpts.maxDrainBytes = 8;
      const pureDbConn = openReady(new QueueTransport([bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgPortalSuspended(), msgDataRow(['\\x0102030405']), msgPortalSuspended()])]));
      await pureDbConn.connect();
      expect((await asyncFail((): Promise<Object> => pureDbConn.postgresFeatures.prepared!.queryStream('PURE_DRAIN_BYTES', [], pureDbOpts, new RecSink()))).kind === ArkDbErrorKind.Protocol && pureDbConn.state === ConnectionState.Error).assertTrue();
      const dbOpts = new QueryOptions(); dbOpts.maxRows = 1; dbOpts.maxDrainBytes = 25;
      const dbTp = new QueueTransport([bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgPortalSuspended(), msgDataRow(['\\x0102030405']), msgPortalSuspended()])]);
      dbTp.abortFailure = ArkDbError.network('abort boom'); const dbConn = openReady(dbTp); await dbConn.connect();
      const dbErr = await asyncFail((): Promise<Object> => dbConn.postgresFeatures.prepared!.queryStream('DRAIN_BYTES', [], dbOpts, new FailingStageSink('trunc', ArkDbError.validation('trunc primary'))));
      expect(dbErr.kind === ArkDbErrorKind.Validation && dbErr.message.indexOf('trunc primary') === 0 && dbErr.message.indexOf('maxDrainBytes') > 0 && dbErr.message.indexOf('abort boom') > 0 && dbConn.state === ConnectionState.Error).assertTrue();

      const rfqTimers = new StepTimers(); rfqTimers.stepMs = 15;
      const rfqConn = openReady(new QueueTransport([bootFrames(0x49), concatFrames([msgError('ERROR', 'ERROR', '22012', 'slow drain'), msgReady(0x49)])]), rfqTimers);
      await rfqConn.connect(); const rfqOpts = new QueryOptions(); rfqOpts.maxDrainTimeMs = 10;
      expect((await asyncFail((): Promise<Object> => rfqConn.postgresFeatures.prepared!.queryStream('RFQ_DEADLINE', [], rfqOpts, new RecSink()))).kind === ArkDbErrorKind.Protocol && rfqConn.state === ConnectionState.Error).assertTrue();
      const hTimers = new StepTimers(); const hTp = new QueueTransport([bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgPortalSuspended(), msgDataRow(['\\xbb']), msgPortalSuspended(), msgCloseComplete(), msgReady(0x49)])]);
      const hConn = openReady(hTp, hTimers); await hConn.connect(); const hOpts = new QueryOptions(); hOpts.maxRows = 1; hOpts.maxDrainTimeMs = 20;
      const hSink = new GatedSink('trunc'); const hTask = hConn.postgresFeatures.prepared!.queryStream('DEADLINE_SINK', [], hOpts, hSink);
      await hSink.waitReached('trunc', hTask); hTimers.now += 25; hTimers.fireAll(); hSink.fail('trunc', ArkDbError.validation('late sink after deadline'));
      expect((await asyncFail((): Promise<Object> => hTask)).kind === ArkDbErrorKind.Protocol && hConn.state === ConnectionState.Error).assertTrue();

      const closeTp = new QueueTransport([bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgPortalSuspended()])]);
      const closeConn = openReady(closeTp); await closeConn.connect(); const closeSink = new GatedSink('rows');
      const closeOpts = new QueryOptions(); closeOpts.maxChunkRows = 1;
      const closeTask = closeConn.postgresFeatures.prepared!.queryStream('CLOSE_SINK', [], closeOpts, closeSink);
      await closeSink.waitReached('rows', closeTask); const closing = closeConn.close(); closeSink.fail('rows', ArkDbError.validation('late sink after close'));
      expect((await asyncFail((): Promise<Object> => closeTask)).kind === ArkDbErrorKind.Cancelled && closeConn.state === ConnectionState.Closed).assertTrue();
      await closing;

      const copyFrame = msgCopyData(new Uint8Array([4, 3, 2, 1])); const ownedCopyPayload = copyFrame.slice(5);
      const cpOutTp = new QueueTransport([bootFrames(0x49), msgParseComplete(), msgBindComplete(), msgNoData(), msgCopyOut(),
        copyFrame.slice(0, 5), ownedCopyPayload, concatFrames([msgCopyDone(), msgCmd('COPY 1'), msgReady(0x49)]), concatFrames([msgCmd('SELECT 6'), msgReady(0x49)])]);
      const cpOutConn = openReady(cpOutTp); await cpOutConn.connect(); cpOutTp.writes.length = 0;
      expect((await asyncFail((): Promise<Object> => cpOutConn.postgresFeatures.prepared!.queryStream('COPY_OUT', [], new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Unsupported &&
        cpOutTp.writes.length === 6 && cpOutConn.state === ConnectionState.Ready).assertTrue();
      assertBytes(cpOutTp.writes[5], expectedSync()); assertZeroed(ownedCopyPayload);
      expect((await cpOutConn.query('SELECT 6')).commandTag).assertEqual('SELECT 6');
      for (const copyFailClosed of [msgCopyIn(), msgCopyBoth()]) {
        const fcConn = openReady(new QueueTransport([bootFrames(0x49), concatFrames([msgParseComplete(), msgBindComplete(), msgNoData(), copyFailClosed])])); await fcConn.connect();
        expect((await asyncFail((): Promise<Object> => fcConn.postgresFeatures.prepared!.queryStream('COPY_FC', [], new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Unsupported && fcConn.state === ConnectionState.Error).assertTrue();
      }
    });
  });
}

function execChunksTotal(s: RecSink): number { let n = 0; for (const c of s.chunks) n += c.rows.length; return n; }
class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; readonly rawWrites: Uint8Array[] = []; abortFailure: ArkDbError | null = null;
  hangAtEmpty: boolean = false; private rejectHungRead: ((e: Object) => void) | null = null; private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) return !this.hangAtEmpty ? null : new Promise<Uint8Array | null>((_r: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => { this.rejectHungRead = rej; });
    const head = this.reads[0]; if (head.length <= max) return this.reads.shift()!; this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  write(data: Uint8Array): Promise<number> { this.rawWrites.push(data); const cp = new Uint8Array(data.length); cp.set(data); this.writes.push(cp); return Promise.resolve(data.length); }
  async close(): Promise<void> {}
  async abort(e: ArkDbError): Promise<void> { if (this.rejectHungRead !== null) { const r = this.rejectHungRead; this.rejectHungRead = null; r(e); } if (this.abortFailure !== null) throw this.abortFailure; }
}
class PhaseTransport extends QueueTransport {
  readonly writePhases: string[] = []; private readonly gate: PostgresCommandGate;
  constructor(reads: Uint8Array[], gate: PostgresCommandGate) { super(reads); this.gate = gate; }
  write(bytes: Uint8Array): Promise<number> { if (this.gate.current !== null) this.writePhases.push(this.gate.current.kind + ':' + this.gate.current.phase); return super.write(bytes); }
}
class StreamLogSink implements LogSink { readonly messages: string[] = []; write(_l: LogLevel, _t: string, m: string): void { this.messages.push(m); } }
class RecSink implements QueryResultSink {
  readonly events: string[] = []; readonly phases: string[] = []; readonly starts: QueryResultMeta[] = []; readonly chunks: QueryRowChunk[] = [];
  readonly truncations: QueryTruncation[] = []; readonly ends: QueryResultSummary[] = []; cancelOnTruncation: boolean = false; mutateDelivered: boolean = false;
  private readonly gate: PostgresCommandGate | null; constructor(gate: PostgresCommandGate | null = null) { this.gate = gate; }
  private recPhase(): void { if (this.gate !== null && this.gate.current !== null) this.phases.push(this.gate.current.kind + ':' + this.gate.current.phase); }
  async onResultStart(m: QueryResultMeta): Promise<void> { this.recPhase(); this.starts.push(m); this.events.push('start:' + m.resultIndex + ':' + m.hasRows); if (this.mutateDelivered) m.columns.pop(); }
  async onRows(c: QueryRowChunk): Promise<void> { this.recPhase(); this.chunks.push(c); this.events.push('rows:' + c.resultIndex + ':' + c.rowOffset + ':' + c.rows.length); }
  async onTruncation(t: QueryTruncation): Promise<boolean> { this.recPhase(); this.truncations.push(t); this.events.push('trunc:' + t.resultIndex + ':' + t.reason + ':' + t.loadedRowCount); return this.cancelOnTruncation; }
  async onResultEnd(s: QueryResultSummary): Promise<void> { this.recPhase(); this.ends.push(s); this.events.push('end:' + s.resultIndex); }
}
class GatedSink implements QueryResultSink {
  private readonly reached: Map<string, () => void> = new Map<string, () => void>(); private readonly arrived: Set<string> = new Set<string>();
  private readonly gates: Map<string, [() => void, (e: Object) => void]> = new Map<string, [() => void, (e: Object) => void]>();
  private readonly onlyStage: string; constructor(onlyStage: string = '') { this.onlyStage = onlyStage; }
  waitReached(stage: string, inflight: Promise<Object>): Promise<void> {
    if (this.arrived.has(stage)) return Promise.resolve();
    return Promise.race([new Promise<void>((r: () => void): void => { this.reached.set(stage, r); }), inflight.then((): void => { throw new Error('settled before ' + stage); })]);
  }
  release(stage: string): void { const p = this.gates.get(stage); if (p !== undefined) { this.gates.delete(stage); this.arrived.delete(stage); p[0](); } }
  fail(stage: string, err: Object): void { const p = this.gates.get(stage); if (p !== undefined) { this.gates.delete(stage); this.arrived.delete(stage); p[1](err); } }
  private hold(stage: string): Promise<void> {
    if (this.onlyStage.length > 0 && this.onlyStage !== stage) return Promise.resolve();
    return new Promise<void>((res: () => void, rej: (e: Object) => void): void => {
      this.gates.set(stage, [res, rej]); this.arrived.add(stage); const n = this.reached.get(stage); if (n !== undefined) { this.reached.delete(stage); n(); }
    });
  }
  onResultStart(_m: QueryResultMeta): Promise<void> { return this.hold('start'); }
  onRows(_c: QueryRowChunk): Promise<void> { return this.hold('rows'); }
  onTruncation(_t: QueryTruncation): Promise<boolean> { return this.hold('trunc').then((): boolean => false); }
  onResultEnd(_s: QueryResultSummary): Promise<void> { return this.hold('end'); }
}
class FailingStageSink implements QueryResultSink {
  private failed: boolean = false; callsAfterFailure: number = 0; private readonly stage: string; private readonly err: Object;
  constructor(stage: string, err: Object) { this.stage = stage; this.err = err; }
  private step(cur: string): void { if (this.failed) { this.callsAfterFailure += 1; return; } if (this.stage === cur) { this.failed = true; throw this.err as Error; } }
  async onResultStart(_m: QueryResultMeta): Promise<void> { this.step('start'); }
  async onRows(_c: QueryRowChunk): Promise<void> { this.step('rows'); }
  async onTruncation(_t: QueryTruncation): Promise<boolean> { this.step('trunc'); return false; }
  async onResultEnd(_s: QueryResultSummary): Promise<void> { this.step('end'); }
}
class StepTimers implements ConnectionTimerPort {
  now: number = 100; stepMs: number = 1; private id: number = 1; private readonly handlers: Map<number, () => void> = new Map<number, () => void>();
  nowMs(): number { const v = this.now; this.now += this.stepMs; return v; }
  schedule(h: () => void, _ms: number): number { const k = this.id++; this.handlers.set(k, h); return k; }
  cancel(id: number): void { this.handlers.delete(id); }
  fireAll(): void { const fns = Array.from(this.handlers.values()); this.handlers.clear(); for (const fn of fns) fn(); }
}
class ForgedInt4Parameter extends PostgresParameter { reads: number = 0; constructor() { super(PostgresParameterType.Int4, 1); } get value(): PostgresParameterValue { this.reads += 1; return 'bad'; } }
class InspectableByteaParameter extends PostgresParameter { lastRead: Uint8Array | null = null; constructor(b: Uint8Array) { super(PostgresParameterType.Bytea, b); } get value(): PostgresParameterValue { const v = super.value as Uint8Array; this.lastRead = v; return v; } }
async function flushTicks(count: number): Promise<void> { for (let i = 0; i < count; i += 1) await Promise.resolve(); }
function baseConfig(): PostgresConnectionConfig { const c = new PostgresConnectionConfig(); c.host = 'pg.local'; c.user = 'postgres'; c.ssl.mode = PostgresSslMode.DISABLED; return c; }
function openReady(tp: QueueTransport, timers: ConnectionTimerPort = new StepTimers(), pw: string = ''): PostgresConnection { return new PostgresConnection(baseConfig(), pw, timers, (): PostgresLifecycleTransport => tp); }
function bootFrames(ready: number): Uint8Array { return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]); }
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array { const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload); const out = new Uint8Array(src.length + 5); out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5); return out; }
function pushCStr(dst: number[], text: string): void { for (let i = 0; i < text.length; i += 1) dst.push(text.charCodeAt(i)); dst.push(0); }
function cstrFrame(type: number, text: string): Uint8Array { const p: number[] = []; pushCStr(p, text); return backendFrame(type, p); }
function expectedDescribePortal(): Uint8Array { return new Uint8Array([0x44, 0, 0, 0, 6, 0x50, 0]); }
function expectedExecute(maxRows: number): Uint8Array { const f = new Uint8Array([0x45, 0, 0, 0, 9, 0, 0, 0, 0, 0]); new DataView(f.buffer).setInt32(6, maxRows, false); return f; }
function expectedFlush(): Uint8Array { return new Uint8Array([0x48, 0, 0, 0, 4]); }
function expectedClosePortal(): Uint8Array { return new Uint8Array([0x43, 0, 0, 0, 6, 0x50, 0]); }
function expectedSync(): Uint8Array { return new Uint8Array([0x53, 0, 0, 0, 4]); }
function msgParseComplete(): Uint8Array { return backendFrame(0x31, []); } function msgBindComplete(): Uint8Array { return backendFrame(0x32, []); }
function msgCloseComplete(): Uint8Array { return backendFrame(0x33, []); } function msgNoData(): Uint8Array { return backendFrame(0x6e, []); }
function msgPortalSuspended(): Uint8Array { return backendFrame(0x73, []); } function msgEmptyQuery(): Uint8Array { return backendFrame(0x49, []); }
function msgCmd(tag: string): Uint8Array { return cstrFrame(0x43, tag); } function msgReady(status: number): Uint8Array { return backendFrame(0x5a, [status]); }
function msgParam(name: string, val: string): Uint8Array { const p: number[] = []; pushCStr(p, name); pushCStr(p, val); return backendFrame(0x53, p); }
function msgNotice(loc: string, st: string, m: string): Uint8Array { const p: number[] = [0x53]; pushCStr(p, loc); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0); return backendFrame(0x4e, p); }
function msgError(loc: string, sev: string, st: string, m: string): Uint8Array { const p: number[] = [0x53]; pushCStr(p, loc); p.push(0x56); pushCStr(p, sev); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0); return backendFrame(0x45, p); }
function msgNotification(pid: number, ch: string, pay: string): Uint8Array { const h = new Uint8Array(4); new DataView(h.buffer).setInt32(0, pid, false); const p = Array.from(h); pushCStr(p, ch); pushCStr(p, pay); return backendFrame(0x41, p); }
function colSpec(name: string, tbl: number, attr: number, oid: number, sz: number, mod: number, fmt: number): Uint8Array {
  const p: number[] = []; pushCStr(p, name); const t = new Uint8Array(18); const v = new DataView(t.buffer);
  v.setUint32(0, tbl, false); v.setInt16(4, attr, false); v.setUint32(6, oid, false); v.setInt16(10, sz, false); v.setInt32(12, mod, false); v.setInt16(16, fmt, false);
  const out = new Uint8Array(p.length + 18); out.set(p, 0); out.set(t, p.length); return out;
}
function msgRowDesc(cols: Uint8Array[]): Uint8Array { let len = 2; for (const c of cols) len += c.length; const p = new Uint8Array(len); new DataView(p.buffer).setInt16(0, cols.length, false); let off = 2; for (const c of cols) { p.set(c, off); off += c.length; } return backendFrame(0x54, p); }
function msgDataRow(vals: Array<string | null>): Uint8Array {
  let len = 2; for (const v of vals) len += v === null ? 4 : 4 + v.length; const p = new Uint8Array(len); const dv = new DataView(p.buffer); dv.setInt16(0, vals.length, false);
  let off = 2; for (const v of vals) { if (v === null) { dv.setInt32(off, -1, false); off += 4; } else { dv.setInt32(off, v.length, false); for (let i = 0; i < v.length; i += 1) p[off + 4 + i] = v.charCodeAt(i); off += 4 + v.length; } }
  return backendFrame(0x44, p);
}
function msgCopyIn(): Uint8Array { return backendFrame(0x47, [0, 0, 0]); } function msgCopyOut(): Uint8Array { return backendFrame(0x48, [0, 0, 0]); }
function msgCopyBoth(): Uint8Array { return backendFrame(0x57, [0, 0, 0]); } function msgCopyData(bytes: Uint8Array): Uint8Array { return backendFrame(0x64, bytes); }
function msgCopyDone(): Uint8Array { return backendFrame(0x63, []); }
function concatFrames(frames: Uint8Array[]): Uint8Array { let len = 0; for (const f of frames) len += f.length; const out = new Uint8Array(len); let off = 0; for (const f of frames) { out.set(f, off); off += f.length; } return out; }
function assertBytes(actual: Uint8Array, expected: Uint8Array): void { expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]); }
function assertZeroed(buf: Uint8Array): void { for (let i = 0; i < buf.length; i += 1) expect(buf[i]).assertEqual(0); }
function asQueryOpts(v: QueryOptions | null): QueryOptions { return v as QueryOptions; } function asSink(v: Object | null | undefined): QueryResultSink { return v as QueryResultSink; }
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> { let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; } expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError; }
