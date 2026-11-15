import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, Logger, LogLevel, LogSink, QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation } from '@arkdb/core';
import { PostgresConnection, PostgresConnectionConfig, PostgresDriverFactory, PostgresError, PostgresQueryResultSummary, PostgresSslMode, PostgresTransactionState } from '../../../../Index';
import { PostgresLifecycleTransport } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandPhase } from '../../../main/ets/pgsql/execution/PostgresCommandGate';

export default function postgresResultStreamTest(): void {
  describe('PostgresResultStream', () => {
    it('validatesFacadeCycleFreeJsonAndPreDispatchGuards', 0, async () => {
      expect(new PostgresDriverFactory().capabilities.supportsStreamingResults).assertTrue();
      const sub = new CustomStreamConnection(baseConfig(), 'secret-pw-123');
      expect(sub.features.streaming !== undefined && JSON.stringify(sub.features) === '{"streaming":{},"health":{},"context":{}}' && JSON.stringify(sub).indexOf('secret-pw-123') === -1 &&
        sub.features.streaming!.state === ConnectionState.Idle && sub.features.streaming!.features === sub.features && sub.features.streaming!.serverInfo === sub.serverInfo).assertTrue();
      await sub.features.streaming!.queryStream('SELECT 1', new QueryOptions(), new RecSink()); expect(sub.customCalls).assertEqual(1);
      await sub.features.streaming!.close(); expect(sub.state === ConnectionState.Closed && JSON.stringify(sub).indexOf('secret-pw-123') === -1).assertTrue();
      const tp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc([colSpec('v', 0, 0, 23, 4, -1, 0)]), msgDataRow(['1']), msgDataRow(['2']), msgCmd('SELECT 2'), msgReady(0x49)]), concatFrames([msgCmd('SELECT 1'), msgReady(0x49)])]);
      const conn = openReady(tp); await conn.features.streaming!.connect(); tp.writes.length = 0;
      expect(conn.state === ConnectionState.Ready && JSON.stringify(conn).length > 0).assertTrue();
      for (const mut of [(o: QueryOptions): void => { o.maxRows = -1; }, (o: QueryOptions): void => { o.maxChunkRows = 0; }, (o: QueryOptions): void => { o.maxDrainBytes = 0; }, (o: QueryOptions): void => { o.maxDrainTimeMs = 0; }]) {
        const bad = new QueryOptions(); mut(bad); expect((await asyncFail((): Promise<Object> => conn.queryStream('SELECT 1', bad, new RecSink()))).kind).assertEqual(ArkDbErrorKind.Validation);
      }
      const timeoutOpts = new QueryOptions(); timeoutOpts.statementTimeoutMs = 250;
      expect((await asyncFail((): Promise<Object> => conn.queryStream('SELECT 1', timeoutOpts, new RecSink()))).kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect((await asyncFail((): Promise<Object> => conn.queryStream('SELECT \u0000', new QueryOptions(), new RecSink()))).kind).assertEqual(ArkDbErrorKind.Validation);
      expect(tp.writes.length === 0 && conn.state === ConnectionState.Ready).assertTrue();
      const snapOpts = new QueryOptions(); snapOpts.maxChunkRows = 1; snapOpts.maxRows = 1;
      const sink = new RecSink(); const runTask = conn.features.streaming!.queryStream('SELECT 1', snapOpts, sink); snapOpts.maxRows = -1; snapOpts.statementTimeoutMs = 999;
      const exec = await runTask; expect(exec.loadedRowCount === 1 && sink.chunks[0].rows[0][0] === 1 && tp.writes.length === 1).assertTrue();
      assertBytes(tp.writes[0], expectedQueryFrame('SELECT 1')); expect((await conn.features.streaming!.query('SELECT 1')).affectedRows).assertEqual(0);
    });
    it('streamsMultiStatementsSafeIntegerCountsAndAsyncMessages', 0, async () => {
      const logSink = new StreamLogSink(); const prevLevel = Logger.level; Logger.setLevel(LogLevel.DEBUG); Logger.addSink(logSink);
      try {
        const cols = [colSpec('n', 0, 0, 23, 4, -1, 0)];
        const batch = concatFrames([msgEmptyQuery(), msgCmd('INSERT 0 3'), msgCmd('MOVE 5'), msgCmd('CREATE TABLE'), msgNotice('NOTICE', '00000', 'note'),
          msgNotification(99, 'secret_ch', 'secret_pay'), msgParam('TimeZone', 'Asia/Tokyo'), msgRowDesc(cols), msgDataRow(['10']), msgDataRow(['20']), msgCmd('SELECT 2'),
          msgRowDesc(cols), msgDataRow(['30']), msgDataRow(['40']), msgCmd('INSERT 0 2'), msgReady(0x54)]);
        const tp = new QueueTransport([bootFrames(0x49), batch]); const conn = openReady(tp); await conn.connect();
        const sink = new RecSink(); const exec = await conn.queryStream('BATCH', new QueryOptions(), sink);
        expect(sink.events.join(',')).assertEqual('start:0:false,end:0,start:1:false,end:1,start:2:false,end:2,start:3:false,end:3,start:4:true,rows:4:0:2,end:4,start:5:true,rows:5:0:2,end:5');
        expect(sink.ends[0].rowCount === 0 && sink.ends[0].rowCountKnown && sink.ends[0].affectedRows === 0 && (sink.ends[0] as PostgresQueryResultSummary).affectedRowsKnown && !sink.ends[0].statusKnown &&
          sink.ends[1].rowCount === 0 && sink.ends[1].rowCountKnown && sink.ends[1].affectedRows === 3 && (sink.ends[1] as PostgresQueryResultSummary).affectedRowsKnown && (sink.ends[1] as PostgresQueryResultSummary).rowCountExact === undefined && (sink.ends[1] as PostgresQueryResultSummary).affectedRowsExact === 3n && !sink.ends[1].statusKnown &&
          sink.ends[2].rowCount === 5 && sink.ends[2].rowCountKnown && sink.ends[2].affectedRows === 0 && !(sink.ends[2] as PostgresQueryResultSummary).affectedRowsKnown && (sink.ends[2] as PostgresQueryResultSummary).rowCountExact === 5n && !sink.ends[2].statusKnown &&
          sink.ends[3].rowCount === 0 && sink.ends[3].rowCountKnown && sink.ends[3].affectedRows === 0 && !(sink.ends[3] as PostgresQueryResultSummary).affectedRowsKnown &&
          sink.ends[4].rowCount === 2 && sink.ends[4].loadedRowCount === 2 && sink.ends[4].rowCountKnown && sink.ends[4].affectedRows === 0 && !(sink.ends[4] as PostgresQueryResultSummary).affectedRowsKnown &&
          sink.ends[5].rowCount === 2 && sink.ends[5].loadedRowCount === 2 && sink.ends[5].rowCountKnown && sink.ends[5].affectedRows === 2 && (sink.ends[5] as PostgresQueryResultSummary).affectedRowsKnown && (sink.ends[5] as PostgresQueryResultSummary).rowCountExact === 2n && !sink.ends[5].status.known).assertTrue();
        expect(exec.resultSetCount === 6 && exec.loadedRowCount === 4 && exec.rowCount === 9 && exec.rowCountKnown && exec.statusKnown && exec.status.inTransaction &&
          exec.status.autocommit && conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction && conn.serverInfo.timeZone === 'Asia/Tokyo').assertTrue();
        const joinedLogs = logSink.messages.join('\n'); expect(joinedLogs.indexOf('secret_ch') === -1 && joinedLogs.indexOf('secret_pay') === -1).assertTrue();
        tp.enqueue([concatFrames([msgCmd('MOVE 9007199254740992'), msgReady(0x49)]),
          concatFrames([msgRowDesc(cols), msgDataRow(['1']), msgDataRow(['2']), msgCmd('SELECT 9007199254740992'), msgReady(0x49)]),
          concatFrames([msgCmd('MOVE 9007199254740990'), msgRowDesc(cols), msgDataRow(['7']), msgDataRow(['8']), msgCmd('SELECT 2'), msgReady(0x49)])]);
        const s1 = new RecSink(); const e1 = await conn.queryStream('M1', new QueryOptions(), s1);
        expect(!s1.ends[0].rowCountKnown && s1.ends[0].rowCount === 0 && !e1.rowCountKnown && e1.rowCount === 0).assertTrue();
        const trunc1 = new QueryOptions(); trunc1.maxRows = 1;
        const s2 = new RecSink(); const e2 = await conn.queryStream('M2', trunc1, s2);
        expect(!s2.ends[0].rowCountKnown && s2.ends[0].rowCount === 1 && !e2.rowCountKnown && e2.rowCount === 1).assertTrue();
        const s3 = new RecSink(); const e3 = await conn.queryStream('M3', new QueryOptions(), s3);
        expect(s3.ends[0].rowCountKnown && s3.ends[0].rowCount === 9007199254740990 && s3.ends[1].rowCountKnown && s3.ends[1].rowCount === 2 && !e3.rowCountKnown && e3.rowCount === 2 && e3.loadedRowCount === 2).assertTrue();
        tp.enqueue([concatFrames([msgCmd('MOVE 3'), msgRowDesc(cols), msgDataRow(['11']), msgDataRow(['22']), msgCmd('SELECT 2'), msgReady(0x49)])]);
        const mutSink = new RecSink(); mutSink.mutateDelivered = true; const mutExec = await conn.queryStream('M4', new QueryOptions(), mutSink);
        expect(mutSink.chunks[0].rows[0][0] === 11 && mutSink.chunks[0].rows[1][0] === 22 && mutExec.rowCountKnown && mutExec.rowCount === 5 && conn.state === ConnectionState.Ready).assertTrue();
      } finally { Logger.removeSink(logSink); Logger.setLevel(prevLevel); }
    });
    it('chunksByRowsAndWireBytesWithRealSinkBackpressure', 0, async () => {
      const cols = [colSpec('t', 0, 0, 25, -1, -1, 0)];
      const r1 = msgDataRow(['aa']); const r2 = msgDataRow(['bb']); const r3 = msgDataRow(['cccccc']);
      const tp = new QueueTransport([bootFrames(0x49),
        concatFrames([msgRowDesc(cols), r1, r2, r3, msgDataRow(['dd']), msgDataRow(['ee']), msgCmd('SELECT 5'), msgReady(0x49)]),
        concatFrames([msgRowDesc(cols), r1, r2, r3, msgCmd('SELECT 3'), msgReady(0x49)]),
        concatFrames([msgRowDesc(cols), r3, msgCmd('SELECT 1'), msgReady(0x49)])]);
      const conn = openReady(tp); await conn.connect();
      const rowOpts = new QueryOptions(); rowOpts.maxChunkRows = 2; const sRows = new RecSink(); await conn.queryStream('Q1', rowOpts, sRows);
      expect(sRows.chunks.length === 3 && sRows.chunks[0].rowOffset === 0 && sRows.chunks[0].rows.length === 2 &&
        sRows.chunks[0].encodedBytes === (r1.length - 5) + (r2.length - 5) &&
        sRows.chunks[1].rowOffset === 2 && sRows.chunks[1].rows.length === 2 && sRows.chunks[2].rowOffset === 4 && sRows.chunks[2].rows.length === 1).assertTrue();
      const byteOpts = new QueryOptions(); byteOpts.maxChunkRows = 10; byteOpts.maxChunkBytes = (r1.length - 5) + (r2.length - 5);
      const sBytes = new RecSink(); await conn.queryStream('Q2', byteOpts, sBytes);
      expect(sBytes.chunks.length === 2 && sBytes.chunks[0].rows.length === 2 && sBytes.chunks[1].rows.length === 1 &&
        sBytes.chunks[1].rowOffset === 2 && sBytes.chunks[1].encodedBytes === r3.length - 5).assertTrue();
      const tinyByteOpts = new QueryOptions(); tinyByteOpts.maxChunkBytes = 1; const sTiny = new RecSink(); await conn.queryStream('Q3', tinyByteOpts, sTiny);
      expect(sTiny.chunks.length === 1 && sTiny.chunks[0].rows[0][0] === 'cccccc').assertTrue();
      const bpTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(cols), r1])]); bpTp.hangAtEmpty = true;
      const bpConn = openReady(bpTp); await bpConn.connect(); const gateSink = new GatedSink();
      const bpOpts = new QueryOptions(); bpOpts.maxChunkRows = 1; bpOpts.maxRows = 1; let settled = false;
      const task = bpConn.queryStream('Q4', bpOpts, gateSink).then((v: QueryExecutionSummary): QueryExecutionSummary => { settled = true; return v; });
      await gateSink.waitReached('start', task); expect(!settled && gateSink.events.join(',') === 'start').assertTrue(); gateSink.release('start');
      await gateSink.waitReached('rows', task); expect(!settled && gateSink.events.join(',') === 'start,rows').assertTrue();
      bpTp.enqueue([concatFrames([r2, msgCmd('SELECT 2'), msgReady(0x49)])]); bpTp.hangAtEmpty = false;
      await flushTicks(8); expect(!settled && gateSink.events.join(',') === 'start,rows').assertTrue(); gateSink.release('rows');
      await gateSink.waitReached('trunc', task); expect(!settled && gateSink.events.join(',') === 'start,rows,trunc').assertTrue(); gateSink.release('trunc');
      await gateSink.waitReached('end', task); expect(!settled && gateSink.events.join(',') === 'start,rows,trunc,end').assertTrue(); gateSink.release('end');
      const bpExec = await task;
      expect(settled && bpExec.loadedRowCount === 1 && bpExec.rowCount === 2 && bpConn.state === ConnectionState.Ready).assertTrue();
    });
    it('truncatesByRowAndResultByteLimitsWithCancellationAndMultiStatementDrain', 0, async () => {
      const textCol = [colSpec('t', 0, 0, 25, -1, -1, 0)]; const byteaCol = [colSpec('b', 0, 0, 17, -1, -1, 0)];
      const badUtf8TriggerRow = backendFrame(0x44, [0, 1, 0, 0, 0, 1, 0xff]);
      const timers = new StepTimers(); const phaseGate = new PostgresCommandGate();
      const phaseTp = new PhaseTransport([bootFrames(0x49),
        concatFrames([msgRowDesc(textCol), msgDataRow(['r1']), msgDataRow(['r2']), badUtf8TriggerRow, msgCmd('SELECT 3'),
          msgRowDesc(textCol), badUtf8TriggerRow, msgCmd('SELECT 1'), msgCmd('UPDATE 4'), msgReady(0x49)]),
        concatFrames([msgCmd('SELECT 9'), msgReady(0x49)])], phaseGate);
      const conn = new PostgresConnection(baseConfig(), '', timers, (): PostgresLifecycleTransport => phaseTp, undefined, phaseGate);
      await conn.connect(); phaseTp.writePhases.length = 0;
      const rowLimOpts = new QueryOptions(); rowLimOpts.maxRows = 2; rowLimOpts.maxChunkRows = 5;
      const sRowLim = new RecSink(phaseGate); sRowLim.cancelOnTruncation = false;
      const eRowLim = await conn.queryStream('TRUNC_ROW', rowLimOpts, sRowLim);
      expect(phaseTp.writePhases.join(',')).assertEqual(PostgresCommandKind.QueryStream + ':' + PostgresCommandPhase.Executing);
      expect(sRowLim.events.join(',')).assertEqual('start:0:true,rows:0:0:2,trunc:0:rowLimit:2,end:0,start:1:true,end:1,start:2:false,end:2');
      expect(sRowLim.phases.join(',')).assertEqual('query_stream:streaming,query_stream:draining,query_stream:draining,query_stream:draining,query_stream:draining,query_stream:draining,query_stream:draining,query_stream:draining');
      expect(phaseGate.current === null && sRowLim.ends[0].truncated && sRowLim.ends[0].truncationReason === 'rowLimit' && sRowLim.ends[0].rowCount === 3 &&
        sRowLim.ends[1].truncated && sRowLim.ends[1].truncationReason === 'rowLimit' && sRowLim.ends[1].loadedRowCount === 0 && sRowLim.ends[1].rowCount === 1 &&
        !sRowLim.ends[2].truncated && sRowLim.ends[2].affectedRows === 4 &&
        !eRowLim.truncationInterrupted && eRowLim.synchronizationDeadlineMs === -1 && eRowLim.rowCount === 4 && eRowLim.loadedRowCount === 2 && conn.state === ConnectionState.Ready).assertTrue();
      expect((await conn.query('SELECT 9')).commandTag).assertEqual('SELECT 9');
      const rawRow2 = msgDataRow(['\\x0102030405060708090a']); const ownedRow2Payload = rawRow2.slice(5);
      const tpBytes = new QueueTransport([bootFrames(0x49),
        msgRowDesc(byteaCol), msgDataRow(['\\xaa']), rawRow2.slice(0, 5), ownedRow2Payload, concatFrames([msgCmd('SELECT 2'), msgReady(0x49)]),
        concatFrames([msgRowDesc(textCol), msgDataRow(['a']), msgDataRow(['b']), msgError('ERROR', 'ERROR', '57014', 'canceling statement due to user request'), msgReady(0x49)]),
        concatFrames([msgRowDesc(textCol), msgDataRow(['a']), msgDataRow(['b']), msgCmd('SELECT 2'), msgError('ERROR', 'ERROR', '57014', 'canceled between statements'), msgReady(0x49)]),
        concatFrames([msgCmd('SELECT 1'), msgReady(0x49)])]);
      const cTimers = new StepTimers(); const cGate = new PostgresCommandGate();
      const cConn = new PostgresConnection(baseConfig(), '', cTimers, (): PostgresLifecycleTransport => tpBytes, undefined, cGate); await cConn.connect();
      const byteLimOpts = new QueryOptions(); byteLimOpts.maxChunkRows = 1; byteLimOpts.maxResultBytes = 4; byteLimOpts.maxDrainTimeMs = 700;
      const sByteLim = new RecSink(cGate); sByteLim.cancelOnTruncation = true;
      const eByteLim = await cConn.queryStream('TRUNC_BYTES', byteLimOpts, sByteLim);
      assertZeroed(ownedRow2Payload); assertZeroed(tpBytes.rawWrites[1]);
      expect(sByteLim.phases.join(',')).assertEqual('query_stream:streaming,query_stream:streaming,query_stream:draining,query_stream:draining');
      expect((sByteLim.chunks[0].rows[0][0] as Uint8Array)[0] === 0xaa && sByteLim.truncations[0].reason === 'resultBytes' &&
        eByteLim.truncationInterrupted && eByteLim.synchronizationDeadlineMs > 700 && eByteLim.rowCountKnown && eByteLim.rowCount === 2).assertTrue();
      const cancelOpts = new QueryOptions(); cancelOpts.maxRows = 1; cancelOpts.maxDrainTimeMs = 500;
      const sMid57014 = new RecSink(); sMid57014.cancelOnTruncation = true;
      const eMid57014 = await cConn.queryStream('CANCEL_MID', cancelOpts, sMid57014);
      expect(sMid57014.ends.length === 1 && sMid57014.ends[0] instanceof PostgresQueryResultSummary && !(sMid57014.ends[0] as PostgresQueryResultSummary).affectedRowsKnown && sMid57014.ends[0].truncated && !sMid57014.ends[0].rowCountKnown && sMid57014.ends[0].rowCount === 1 &&
        !eMid57014.rowCountKnown && eMid57014.rowCount === 1 && eMid57014.truncationInterrupted && eMid57014.statusKnown && cConn.state === ConnectionState.Ready).assertTrue();
      const sBetween57014 = new RecSink(); sBetween57014.cancelOnTruncation = true;
      const eBetween57014 = await cConn.queryStream('CANCEL_BETWEEN', cancelOpts, sBetween57014);
      expect(sBetween57014.ends.length === 1 && sBetween57014.ends[0].rowCountKnown && sBetween57014.ends[0].rowCount === 2 &&
        !eBetween57014.rowCountKnown && eBetween57014.rowCount === 1 && eBetween57014.truncationInterrupted && cConn.state === ConnectionState.Ready).assertTrue();
      expect((await cConn.query('SELECT 1')).commandTag).assertEqual('SELECT 1');
      for (const errCase of [[true, msgError('ERROR', 'ERROR', '22012', 'div zero'), ConnectionState.Ready],
        [false, msgError('ERROR', 'ERROR', '57014', 'unexpected cancel'), ConnectionState.Ready],
        [true, msgError('FATAL', 'FATAL', '57014', 'fatal cancel'), ConnectionState.Error]] as Array<[boolean, Uint8Array, ConnectionState]>) {
        const eTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(textCol), msgDataRow(['a']), msgDataRow(['b']), errCase[1], msgReady(0x49)])]);
        const eConn = openReady(eTp); await eConn.connect(); const sk = new RecSink(); sk.cancelOnTruncation = errCase[0];
        const caught = await asyncFail((): Promise<Object> => eConn.queryStream('ERR_AFTER_TRUNC', cancelOpts, sk));
        expect(caught instanceof PostgresError && eConn.state === errCase[2]).assertTrue();
      }
    });
    it('enforcesResultSetAndDrainByteAndTimeBudgetsRetiringConnection', 0, async () => {
      const cols = [colSpec('t', 0, 0, 25, -1, -1, 0)];
      for (const truncFirst of [false, true]) {
        const rsTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(cols), msgDataRow(['a']), msgDataRow(['b']), msgCmd('SELECT 2'), msgRowDesc(cols), msgCmd('SELECT 0'), msgReady(0x49)])]);
        const rsConn = openReady(rsTp); await rsConn.connect();
        const rsOpts = new QueryOptions(); rsOpts.maxResultSets = 1; if (truncFirst) rsOpts.maxRows = 1; const rsSink = new RecSink();
        expect((await asyncFail((): Promise<Object> => rsConn.queryStream('RS_CAP', rsOpts, rsSink))).kind === ArkDbErrorKind.Protocol && rsSink.starts.length === 1 && rsConn.state === ConnectionState.Error).assertTrue();
      }
      const trigRow = msgDataRow(['trigger-bytes']); const cmd2 = msgCmd('SELECT 2'); const rdy = msgReady(0x49);
      for (const cap of [trigRow.length - 1, trigRow.length + cmd2.length + rdy.length - 1]) {
        const dbTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(cols), msgDataRow(['ok']), trigRow, cmd2, rdy])]);
        const dbConn = openReady(dbTp); await dbConn.connect(); const dbOpts = new QueryOptions(); dbOpts.maxRows = 1; dbOpts.maxDrainBytes = cap;
        expect((await asyncFail((): Promise<Object> => dbConn.queryStream('DRAIN_BYTES', dbOpts, new RecSink()))).kind === ArkDbErrorKind.Protocol && dbConn.state === ConnectionState.Error).assertTrue();
      }
      const exactTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(cols), msgDataRow(['ok']), trigRow, cmd2, rdy])]);
      const exactConn = openReady(exactTp); await exactConn.connect(); const exactOpts = new QueryOptions(); exactOpts.maxRows = 1; exactOpts.maxDrainBytes = trigRow.length + cmd2.length + rdy.length;
      expect((await exactConn.queryStream('EXACT_DRAIN', exactOpts, new RecSink())).rowCount === 2 && exactConn.state === ConnectionState.Ready).assertTrue();
      const stallTimers = new StepTimers(); const stallTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(cols), msgDataRow(['1']), msgDataRow(['2'])])]); stallTp.hangAtEmpty = true;
      const stallConn = openReady(stallTp, stallTimers); await stallConn.connect(); const stallOpts = new QueryOptions(); stallOpts.maxRows = 1; stallOpts.maxDrainTimeMs = 25;
      const stallTask = stallConn.queryStream('STALL_DRAIN', stallOpts, new RecSink()); await stallTp.waitHungRead(stallTask); expect(stallTp.waitingRead).assertTrue();
      await flushTicks(2); stallTimers.now += 30; stallTimers.fireAll();
      expect((await asyncFail((): Promise<Object> => stallTask)).kind === ArkDbErrorKind.Protocol && stallConn.state === ConnectionState.Error).assertTrue();
      for (const drainBudget of [5, 15, 50, 55]) {
        const boundaryTimers = new StepTimers(); boundaryTimers.stepMs = 5; const bSink = new RecSink();
        const boundaryTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc([colSpec('b', 0, 0, 17, -1, -1, 0)]), msgDataRow(['\\xdead']), msgDataRow(['\\xbeef']), msgCmd('SELECT 2'), msgReady(0x49)])]);
        const boundaryConn = openReady(boundaryTp, boundaryTimers); await boundaryConn.connect(); const boundaryOpts = new QueryOptions(); boundaryOpts.maxRows = 1; boundaryOpts.maxDrainTimeMs = drainBudget;
        expect((await asyncFail((): Promise<Object> => boundaryConn.queryStream('EXACT_DEADLINE', boundaryOpts, bSink))).kind === ArkDbErrorKind.Protocol && (drainBudget > 5 || bSink.chunks.length === 0) && boundaryConn.state === ConnectionState.Error).assertTrue();
      }
      for (const hangStage of ['rows', 'trunc', 'end']) {
        const hTimers = new StepTimers(); const hTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(cols), msgDataRow(['1']), msgDataRow(['2']), msgCmd('SELECT 2'), msgReady(0x49)])]);
        const hConn = openReady(hTp, hTimers); await hConn.connect(); const hOpts = new QueryOptions(); hOpts.maxRows = 1; hOpts.maxChunkRows = 5; hOpts.maxDrainTimeMs = 20;
        const hSink = new GatedSink(hangStage); const hTask = hConn.queryStream('HANG_' + hangStage, hOpts, hSink); await hSink.waitReached(hangStage, hTask);
        hTimers.now += 25; hTimers.fireAll(); hSink.fail(hangStage, ArkDbError.validation('late sink after deadline'));
        expect((await asyncFail((): Promise<Object> => hTask)).kind === ArkDbErrorKind.Protocol && hConn.state === ConnectionState.Error).assertTrue();
      }
    });
    it('handlesSinkErrorsServerErrorsCopyCloseRaceAndScrubbing', 0, async () => {
      const byteaCol = [colSpec('b', 0, 0, 17, -1, -1, 0)]; const undeliveredPayload = msgDataRow(['\\xdeadbeef']);
      const sinkCases: Array<[string, Object]> = [['start', new Error('sink start failed')], ['rows', ArkDbError.cancelled('consumer cancelled')],
        ['trunc', new PostgresError(ArkDbErrorKind.Server, 'consumer 57014', '57014', '57014')], ['end', ArkDbError.network('downstream webhook down')]];
      for (const sc of sinkCases) {
        const stage = sc[0]; const thrown = sc[1];
        const r1 = msgDataRow(['\\xdead']); const ownedR1 = r1.slice(5); const r2 = msgDataRow(['\\xbeef']); const ownedR2 = r2.slice(5);
        const tp = new QueueTransport([bootFrames(0x49),
          msgRowDesc(byteaCol), r1.slice(0, 5), ownedR1, r2.slice(0, 5), ownedR2, concatFrames([msgCmd('SELECT 2'), msgReady(0x49)]),
          concatFrames([msgCmd('SELECT 7'), msgReady(0x49)])]);
        const conn = openReady(tp); await conn.connect();
        const opts = new QueryOptions(); opts.maxChunkRows = 1; if (stage === 'trunc') opts.maxRows = 1;
        const fSink = new FailingStageSink(stage, thrown);
        const caught = await asyncFail((): Promise<Object> => conn.queryStream('SINK_ERR_' + stage, opts, fSink));
        expect(caught.message.indexOf((thrown as Error).message) >= 0 && fSink.callsAfterFailure === 0 && conn.state === ConnectionState.Ready).assertTrue();
        if (fSink.deliveredBytea !== null) expect(fSink.deliveredBytea[0] === 0xde && fSink.deliveredBytea[1] === 0xad).assertTrue();
        assertZeroed(ownedR1); assertZeroed(ownedR2);
        expect((await conn.query('SELECT 7')).commandTag).assertEqual('SELECT 7');
      }
      const failDrainTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(byteaCol), msgDataRow(['\\xaa']), undeliveredPayload, msgCmd('SELECT 2'), msgReady(0x49)])]);
      failDrainTp.abortFailure = ArkDbError.network('abort socket boom'); const failDrainConn = openReady(failDrainTp); await failDrainConn.connect();
      const failDrainOpts = new QueryOptions(); failDrainOpts.maxChunkRows = 1; failDrainOpts.maxDrainBytes = 4;
      const composed = await asyncFail((): Promise<Object> => failDrainConn.queryStream('SINK_DRAIN_FAIL', failDrainOpts, new FailingStageSink('rows', ArkDbError.validation('primary sink validation'))));
      expect(composed.kind === ArkDbErrorKind.Validation && composed.message.indexOf('primary sink validation') === 0 && composed.message.indexOf('abort socket boom') >= 0 && failDrainConn.state === ConnectionState.Error).assertTrue();
      const srvAfterSinkTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgError('ERROR', 'ERROR', '22012', 'div by zero'), msgReady(0x49)]), concatFrames([msgCmd('SELECT 3'), msgReady(0x49)])]);
      const srvAfterSinkConn = openReady(srvAfterSinkTp); await srvAfterSinkConn.connect();
      const srvAfterSinkOpts = new QueryOptions(); srvAfterSinkOpts.maxChunkRows = 1;
      const srvAfterSinkErr = await asyncFail((): Promise<Object> => srvAfterSinkConn.queryStream('SINK_PLUS_SRV', srvAfterSinkOpts, new FailingStageSink('rows', new Error('sink boom'))));
      expect(srvAfterSinkErr.message.indexOf('sink boom') === 0 && srvAfterSinkErr.message.lastIndexOf('sink boom') === 0 && srvAfterSinkErr.message.indexOf('div by zero') > 0 && srvAfterSinkConn.state === ConnectionState.Ready).assertTrue();
      expect((await srvAfterSinkConn.query('SELECT 3')).commandTag).assertEqual('SELECT 3');
      const closeDrainTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgError('ERROR', 'ERROR', '22012', 'srv before close')])]); closeDrainTp.hangAtEmpty = true;
      const closeDrainConn = openReady(closeDrainTp); await closeDrainConn.connect();
      const closeDrainOpts = new QueryOptions(); closeDrainOpts.maxChunkRows = 1;
      const closeDrainTask = closeDrainConn.queryStream('SINK_THEN_CLOSE', closeDrainOpts, new FailingStageSink('rows', ArkDbError.validation('sink primary before close')));
      await closeDrainTp.waitHungRead(closeDrainTask); const closeDrainClosing = closeDrainConn.close();
      const closeDrainErr = await asyncFail((): Promise<Object> => closeDrainTask); await closeDrainClosing;
      expect(closeDrainErr.kind === ArkDbErrorKind.Validation && closeDrainErr.message.indexOf('sink primary before close') === 0 && closeDrainErr.message.indexOf('srv before close') > 0 && closeDrainErr.message.indexOf('closed during operation') > 0 && closeDrainConn.state === ConnectionState.Closed).assertTrue();
      const cbSinkTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgCmd('SELECT 1'), msgCopyBoth(), msgReady(0x49)])]); cbSinkTp.abortFailure = ArkDbError.network('abort copyboth boom');
      const cbSinkConn = openReady(cbSinkTp); await cbSinkConn.connect(); const cbSinkOpts = new QueryOptions(); cbSinkOpts.maxChunkRows = 1;
      const cbSinkErr = await asyncFail((): Promise<Object> => cbSinkConn.queryStream('SINK_COPYBOTH_ABORT', cbSinkOpts, new FailingStageSink('rows', ArkDbError.validation('sink cb primary'))));
      expect(cbSinkErr.kind === ArkDbErrorKind.Validation && cbSinkErr.message.indexOf('sink cb primary') === 0 && cbSinkErr.message.lastIndexOf('sink cb primary') === 0 && cbSinkErr.message.indexOf('COPY BOTH') > 0 && cbSinkErr.message.indexOf('COPY BOTH') === cbSinkErr.message.lastIndexOf('COPY BOTH') && cbSinkErr.message.indexOf('abort copyboth boom') > 0 && cbSinkConn.state === ConnectionState.Error).assertTrue();
      const cancelFailTimers = new StepTimers();
      const cancelFailTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgDataRow(['\\xbb']), msgCmd('SELECT 2'), msgReady(0x49)])]);
      const cancelFailConn = openReady(cancelFailTp, cancelFailTimers); await cancelFailConn.connect(); cancelFailTimers.cancelFailure = new Error('timer cancel boom');
      const cancelFailOpts = new QueryOptions(); cancelFailOpts.maxChunkRows = 1; cancelFailOpts.maxRows = 1;
      const cancelFailErr = await asyncFail((): Promise<Object> => cancelFailConn.queryStream('TIMER_CANCEL_FAIL', cancelFailOpts, new FailingStageSink('trunc', ArkDbError.validation('trunc sink err'))));
      expect(cancelFailErr.kind === ArkDbErrorKind.Validation && cancelFailErr.message.indexOf('trunc sink err') === 0 && cancelFailErr.message.indexOf('timer cancel boom') > 0 && cancelFailConn.state === ConnectionState.Error).assertTrue();
      const copyFrame = msgCopyData(new Uint8Array([9, 8, 7, 6])); const ownedCopyPayload = copyFrame.slice(5);
      const miscTp = new QueueTransport([bootFrames(0x49),
        concatFrames([msgRowDesc([colSpec('bin', 0, 0, 23, 4, -1, 1)]), msgDataRow(['1']), msgCmd('SELECT 1'), msgReady(0x49)]),
        concatFrames([msgRowDesc(byteaCol), msgDataRow(['\\xaa']), msgError('ERROR', 'ERROR', '22012', 'mid stream err'), msgReady(0x49)]),
        concatFrames([msgCopyIn(), msgError('ERROR', 'ERROR', '57014', 'copy aborted'), msgReady(0x49)]),
        msgCopyOut(), copyFrame.slice(0, 5), ownedCopyPayload, concatFrames([msgCopyDone(), msgCmd('COPY 1'), msgReady(0x49)]),
        concatFrames([msgCmd('SELECT 1'), msgReady(0x49)]), concatFrames([msgCopyBoth(), msgReady(0x49)])]);
      const miscConn = openReady(miscTp); await miscConn.connect(); miscTp.writes.length = 0; const binSink = new RecSink();
      expect((await asyncFail((): Promise<Object> => miscConn.queryStream('BIN_FMT', new QueryOptions(), binSink))).kind === ArkDbErrorKind.Unsupported && binSink.starts.length === 0 && miscConn.state === ConnectionState.Ready).assertTrue();
      const midSink = new RecSink();
      expect((await asyncFail((): Promise<Object> => miscConn.queryStream('MID_ERR', new QueryOptions(), midSink))).kind === ArkDbErrorKind.Server && midSink.ends.length === 0 && miscConn.state === ConnectionState.Ready).assertTrue();
      expect((await asyncFail((): Promise<Object> => miscConn.queryStream('COPY_IN', new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Unsupported && miscConn.state === ConnectionState.Ready).assertTrue();
      assertBytes(miscTp.writes[3], expectedCopyFailFrame('PostgreSQL COPY is not supported.'));
      expect((await asyncFail((): Promise<Object> => miscConn.queryStream('COPY_OUT', new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Unsupported && miscConn.state === ConnectionState.Ready).assertTrue();
      assertZeroed(ownedCopyPayload); expect((await miscConn.query('SELECT 1')).commandTag).assertEqual('SELECT 1');
      expect((await asyncFail((): Promise<Object> => miscConn.queryStream('COPY_BOTH', new QueryOptions(), new RecSink()))).kind === ArkDbErrorKind.Unsupported && miscConn.state === ConnectionState.Error).assertTrue();
      const closeTp = new QueueTransport([bootFrames(0x49), concatFrames([msgRowDesc(byteaCol), msgDataRow(['\\x11']), msgDataRow(['\\xdead']), msgCmd('SELECT 2'), msgReady(0x49)])]);
      const closeConn = openReady(closeTp); await closeConn.connect(); closeTp.writes.length = 0; const closeSink = new GatedSink('rows');
      const closeOpts = new QueryOptions(); closeOpts.maxChunkBytes = 1;
      const closeQuery = closeConn.queryStream('CLOSE_HUNG_SINK', closeOpts, closeSink);
      await closeSink.waitReached('rows', closeQuery); const closing = closeConn.close(); closeSink.fail('rows', ArkDbError.validation('late sink after close'));
      expect((await asyncFail((): Promise<Object> => closeQuery)).kind === ArkDbErrorKind.Cancelled && closeConn.state === ConnectionState.Closed).assertTrue();
      await closing; expect(closeTp.writes.length).assertEqual(1);
    });
  });
}

class CustomStreamConnection extends PostgresConnection {
  customCalls: number = 0;
  async queryStream(_sql: string, _options: QueryOptions, _sink: QueryResultSink): Promise<QueryExecutionSummary> { this.customCalls += 1; return new QueryExecutionSummary(); }
}
class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; readonly rawWrites: Uint8Array[] = []; abortFailure: ArkDbError | null = null;
  hangAtEmpty: boolean = false; waitingRead: boolean = false;
  private rejectHungRead: ((e: Object) => void) | null = null; private resolveHungReadFn: ((v: Uint8Array | null) => void) | null = null;
  private hungReadWaiter: (() => void) | null = null;
  private hungReadMax: number = 0; private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  waitHungRead(inflight: Promise<Object>): Promise<void> {
    if (this.waitingRead) return Promise.resolve();
    const parked = new Promise<void>((r: () => void): void => { this.hungReadWaiter = r; });
    const done = inflight.then((): void => { throw new Error('settled before hung read'); });
    return Promise.race([parked, done]);
  }
  resolveHungRead(chunk: Uint8Array): void {
    const fn = this.resolveHungReadFn; const max = this.hungReadMax; this.resolveHungReadFn = null; this.rejectHungRead = null; this.waitingRead = false; this.hangAtEmpty = false;
    if (chunk.length > max) this.reads.unshift(chunk.subarray(max)); if (fn !== null) fn(chunk.length > max ? chunk.subarray(0, max) : chunk);
  }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) {
      if (this.hangAtEmpty) {
        this.waitingRead = true; this.hungReadMax = max;
        const wake = this.hungReadWaiter; this.hungReadWaiter = null; if (wake !== null) wake();
        return new Promise<Uint8Array | null>((res: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => { this.resolveHungReadFn = res; this.rejectHungRead = rej; });
      }
      return null;
    }
    const head = this.reads[0]; if (head.length <= max) return this.reads.shift()!; this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  write(data: Uint8Array): Promise<number> { this.rawWrites.push(data); const cp = new Uint8Array(data.length); cp.set(data); this.writes.push(cp); return Promise.resolve(data.length); }
  async close(): Promise<void> {}
  async abort(e: ArkDbError): Promise<void> {
    if (this.rejectHungRead !== null) { const r = this.rejectHungRead; this.rejectHungRead = null; this.waitingRead = false; r(e); }
    if (this.abortFailure !== null) throw this.abortFailure;
  }
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
  private readonly gate: PostgresCommandGate | null;
  constructor(gate: PostgresCommandGate | null = null) { this.gate = gate; }
  private recPhase(): void { if (this.gate !== null && this.gate.current !== null) this.phases.push(this.gate.current.kind + ':' + this.gate.current.phase); }
  async onResultStart(meta: QueryResultMeta): Promise<void> { this.recPhase(); this.starts.push(meta); this.events.push('start:' + meta.resultIndex + ':' + meta.hasRows); if (this.mutateDelivered) meta.columns.pop(); }
  async onRows(chunk: QueryRowChunk): Promise<void> { this.recPhase(); this.chunks.push(chunk); this.events.push('rows:' + chunk.resultIndex + ':' + chunk.rowOffset + ':' + chunk.rows.length); }
  async onTruncation(t: QueryTruncation): Promise<boolean> { this.recPhase(); this.truncations.push(t); this.events.push('trunc:' + t.resultIndex + ':' + t.reason + ':' + t.loadedRowCount); return this.cancelOnTruncation; }
  async onResultEnd(s: QueryResultSummary): Promise<void> { this.recPhase(); this.ends.push(s); this.events.push('end:' + s.resultIndex); if (this.mutateDelivered) s.rowCount = 1.5; }
}
class GatedSink implements QueryResultSink {
  readonly events: string[] = []; private readonly onlyStage: string;
  private readonly reached: Map<string, () => void> = new Map<string, () => void>();
  private readonly arrived: Set<string> = new Set<string>();
  private readonly gates: Map<string, [() => void, (e: Object) => void]> = new Map<string, [() => void, (e: Object) => void]>();
  constructor(onlyStage: string = '') { this.onlyStage = onlyStage; }
  waitReached(stage: string, inflight: Promise<Object>): Promise<void> {
    if (this.arrived.has(stage)) return Promise.resolve();
    const arrivedTask = new Promise<void>((r: () => void): void => { this.reached.set(stage, r); });
    const earlyDone = inflight.then((): void => { throw new Error('settled before ' + stage); });
    return Promise.race([arrivedTask, earlyDone]);
  }
  release(stage: string): void { const pair = this.gates.get(stage); if (pair !== undefined) { this.gates.delete(stage); pair[0](); } }
  fail(stage: string, err: Object): void { const pair = this.gates.get(stage); if (pair !== undefined) { this.gates.delete(stage); pair[1](err); } }
  private hold(stage: string): Promise<void> {
    this.events.push(stage);
    if (this.onlyStage.length > 0 && this.onlyStage !== stage) return Promise.resolve();
    return new Promise<void>((res: () => void, rej: (e: Object) => void): void => {
      this.gates.set(stage, [res, rej]); this.arrived.add(stage); const notify = this.reached.get(stage); if (notify !== undefined) notify();
    });
  }
  onResultStart(_m: QueryResultMeta): Promise<void> { return this.hold('start'); }
  onRows(_c: QueryRowChunk): Promise<void> { return this.hold('rows'); }
  onTruncation(_t: QueryTruncation): Promise<boolean> { return this.hold('trunc').then((): boolean => false); }
  onResultEnd(_s: QueryResultSummary): Promise<void> { return this.hold('end'); }
}
class FailingStageSink implements QueryResultSink {
  private readonly stage: string; private readonly err: Object; private failed: boolean = false;
  callsAfterFailure: number = 0; deliveredBytea: Uint8Array | null = null;
  constructor(stage: string, err: Object) { this.stage = stage; this.err = err; }
  private step(cur: string): void { if (this.failed) { this.callsAfterFailure += 1; return; } if (this.stage === cur) { this.failed = true; throw this.err as Error; } }
  async onResultStart(_m: QueryResultMeta): Promise<void> { this.step('start'); }
  async onRows(c: QueryRowChunk): Promise<void> {
    if (!this.failed && this.deliveredBytea === null && c.rows.length > 0 && c.rows[0][0] instanceof Uint8Array) this.deliveredBytea = c.rows[0][0] as Uint8Array;
    this.step('rows');
  }
  async onTruncation(_t: QueryTruncation): Promise<boolean> { this.step('trunc'); return true; }
  async onResultEnd(_s: QueryResultSummary): Promise<void> { this.step('end'); }
}
async function flushTicks(count: number): Promise<void> { for (let i = 0; i < count; i += 1) await Promise.resolve(); }
class StepTimers implements ConnectionTimerPort {
  now: number = 100; stepMs: number = 1; cancelFailure: Error | null = null; private id: number = 1; private readonly handlers: Map<number, () => void> = new Map<number, () => void>();
  nowMs(): number { const v = this.now; this.now += this.stepMs; return v; }
  schedule(h: () => void, _ms: number): number { const k = this.id++; this.handlers.set(k, h); return k; }
  cancel(id: number): void { this.handlers.delete(id); if (this.cancelFailure !== null) throw this.cancelFailure; }
  fireAll(): void { const fns = Array.from(this.handlers.values()); this.handlers.clear(); for (const fn of fns) fn(); }
}
function baseConfig(): PostgresConnectionConfig { const c = new PostgresConnectionConfig(); c.host = 'pg.local'; c.user = 'postgres'; c.ssl.mode = PostgresSslMode.DISABLED; return c; }
function openReady(tp: QueueTransport, timers: ConnectionTimerPort = new StepTimers()): PostgresConnection { return new PostgresConnection(baseConfig(), '', timers, (): PostgresLifecycleTransport => tp); }
function bootFrames(ready: number): Uint8Array { return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]); }
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array {
  const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload); const out = new Uint8Array(src.length + 5);
  out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5); return out;
}
function pushCStr(dst: number[], text: string): void { for (let i = 0; i < text.length; i += 1) dst.push(text.charCodeAt(i)); dst.push(0); }
function cstrFrame(type: number, text: string): Uint8Array { const p: number[] = []; pushCStr(p, text); return backendFrame(type, p); }
function expectedQueryFrame(sql: string): Uint8Array { return cstrFrame(0x51, sql); }
function expectedCopyFailFrame(msg: string): Uint8Array { return cstrFrame(0x66, msg); }
function msgEmptyQuery(): Uint8Array { return backendFrame(0x49, []); }
function msgCmd(tag: string): Uint8Array { return cstrFrame(0x43, tag); }
function msgReady(status: number): Uint8Array { return backendFrame(0x5a, [status]); }
function msgParam(name: string, val: string): Uint8Array { const p: number[] = []; pushCStr(p, name); pushCStr(p, val); return backendFrame(0x53, p); }
function msgNotice(loc: string, st: string, m: string): Uint8Array { const p: number[] = [0x53]; pushCStr(p, loc); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0); return backendFrame(0x4e, p); }
function msgError(loc: string, sev: string, st: string, m: string): Uint8Array { const p: number[] = [0x53]; pushCStr(p, loc); p.push(0x56); pushCStr(p, sev); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0); return backendFrame(0x45, p); }
function msgNotification(pid: number, ch: string, pay: string): Uint8Array { const h = new Uint8Array(4); new DataView(h.buffer).setInt32(0, pid, false); const p = Array.from(h); pushCStr(p, ch); pushCStr(p, pay); return backendFrame(0x41, p); }
function colSpec(name: string, tbl: number, attr: number, oid: number, sz: number, mod: number, fmt: number): Uint8Array {
  const p: number[] = []; pushCStr(p, name); const t = new Uint8Array(18); const v = new DataView(t.buffer);
  v.setUint32(0, tbl, false); v.setInt16(4, attr, false); v.setUint32(6, oid, false); v.setInt16(10, sz, false); v.setInt32(12, mod, false); v.setInt16(16, fmt, false);
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
function msgCopyIn(): Uint8Array { return backendFrame(0x47, [0, 0, 0]); }
function msgCopyOut(): Uint8Array { return backendFrame(0x48, [0, 0, 0]); }
function msgCopyBoth(): Uint8Array { return backendFrame(0x57, [0, 0, 0]); }
function msgCopyData(bytes: Uint8Array): Uint8Array { return backendFrame(0x64, bytes); }
function msgCopyDone(): Uint8Array { return backendFrame(0x63, []); }
function concatFrames(frames: Uint8Array[]): Uint8Array { let len = 0; for (const f of frames) len += f.length; const out = new Uint8Array(len); let off = 0; for (const f of frames) { out.set(f, off); off += f.length; } return out; }
function assertBytes(actual: Uint8Array, expected: Uint8Array): void { expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]); }
function assertZeroed(buf: Uint8Array): void { for (let i = 0; i < buf.length; i += 1) expect(buf[i]).assertEqual(0); }
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> { let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; } expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError; }
