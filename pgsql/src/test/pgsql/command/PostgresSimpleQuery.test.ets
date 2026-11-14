import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, Logger, LogLevel, LogSink, QueryOptions } from '@arkdb/core';
import { PostgresConnection } from '../../../main/ets/pgsql/PostgresConnection';
import { PostgresSimpleQueryHost, runPostgresPing, runPostgresSimpleQuery } from '../../../main/ets/pgsql/command/PostgresSimpleQuery';
import { PostgresConnectionLifecycle, PostgresLifecycleTransport } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandKind, PostgresCommandScope } from '../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement } from '../../../main/ets/pgsql/execution/PostgresSettlements';
import { PostgresConnectionConfig, PostgresSslMode } from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
import { PostgresDatabaseSessionStatus, PostgresError, PostgresQueryResult, PostgresServerInfo, PostgresTransactionState } from '../../../main/ets/pgsql/model/PostgresModels';
import { PostgresMessage, PostgresMessageChannel, PostgresReadyStatus } from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresSimpleQueryTest(): void {
  describe('PostgresSimpleQuery', () => {
    it('executesEmptyRowAndCommandTagQueriesWithExactCounts', 0, async () => {
      const timers = new StepTimers(); const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openReady(tp, timers); await conn.connect();
      tp.writes.length = 0; tp.rawWrites.length = 0;
      tp.enqueue([concatFrames([msgEmptyQuery(), msgReady(0x49)])]); timers.stepMs = 7;
      const emptyRes = await conn.query('   ');
      assertBytes(tp.writes[0], expectedQueryFrame('   '));
      expect(emptyRes.commandTag === '' && emptyRes.columns.length === 0 && emptyRes.rows.length === 0 &&
        emptyRes.affectedRows === 0 && emptyRes.affectedRowsExact === undefined && emptyRes.rowCountExact === undefined &&
        emptyRes.loadedBytes === 0 && emptyRes.executionTimeMs === 7 && emptyRes.statusKnown === true &&
        emptyRes.autocommit && !emptyRes.inTransaction && emptyRes.additionalResults.length === 0).assertTrue();
      const firstRowFrame = msgDataRow(['42', 'ok']); const ownedFirstRowPayload = firstRowFrame.slice(5);
      tp.enqueue([msgRowDesc([colSpec('id', 16384, 1, 23, 4, -1, 0), colSpec('label', 16384, 2, 25, -1, -1, 0)]),
        firstRowFrame.slice(0, 5), ownedFirstRowPayload, concatFrames([msgDataRow(['7', null]), msgCmd('SELECT 2'), msgReady(0x49)])]);
      const selRes = await conn.query("SELECT 42 AS id, 'ok; --' AS label");
      assertBytes(tp.writes[1], expectedQueryFrame("SELECT 42 AS id, 'ok; --' AS label"));
      assertZeroed(tp.rawWrites[0]); assertZeroed(tp.rawWrites[1]); assertZeroed(ownedFirstRowPayload);
      expect(selRes.commandTag === 'SELECT 2' && selRes.rowCountExact === 2n && selRes.affectedRowsExact === undefined &&
        selRes.affectedRows === 0 && selRes.columns.length === 2 && selRes.columns[0].name === 'id' &&
        selRes.columns[0].typeOid === 23 && selRes.columns[0].tableOid === 16384 && selRes.columns[0].columnAttributeNumber === 1 &&
        selRes.rows.length === 2 && selRes.rows[0][0] === 42 && selRes.rows[0][1] === 'ok' &&
        selRes.rows[1][0] === 7 && selRes.rows[1][1] === null && selRes.loadedBytes === 21).assertTrue();
      tp.enqueue([concatFrames([msgRowDesc([colSpec('id', 20000, 1, 20, 8, -1, 0)]),
        msgDataRow(['9007199254740995']), msgDataRow(['9007199254740996']), msgCmd('INSERT 16384 2'), msgReady(0x49)])]);
      const retRes = await conn.query('INSERT INTO items DEFAULT VALUES RETURNING id');
      expect(retRes.commandTag === 'INSERT 16384 2' && retRes.rows.length === 2 && retRes.rows[0][0] === 9007199254740995n &&
        retRes.rowCountExact === 2n && retRes.affectedRowsExact === 2n && retRes.affectedRows === 2 && retRes.loadedBytes === 64).assertTrue();
      const tagCases: Array<[string, bigint | undefined, bigint | undefined, number]> = [
        ['SELECT 0', 0n, undefined, 0], ['MOVE 3', 3n, undefined, 0], ['FETCH 4', 4n, undefined, 0],
        ['INSERT 0 9007199254740993', 9007199254740993n, 9007199254740993n, Number(9007199254740993n)],
        ['UPDATE 12', 12n, 12n, 12], ['DELETE 0', 0n, 0n, 0], ['MERGE 8', 8n, 8n, 8],
        ['CREATE TABLE', undefined, undefined, 0], ['BEGIN', undefined, undefined, 0], ['COMMIT', undefined, undefined, 0],
        ['ROLLBACK', undefined, undefined, 0], ['SET', undefined, undefined, 0], ['COPY 5', undefined, undefined, 0],
        ['SELECT', undefined, undefined, 0], ['SELECT -1', undefined, undefined, 0], ['SELECT 1 2', undefined, undefined, 0],
        ['INSERT 0', undefined, undefined, 0], ['INSERT -1 2', undefined, undefined, 0], ['UPDATE  1', undefined, undefined, 0]
      ];
      for (const tc of tagCases) {
        tp.enqueue([concatFrames([msgCmd(tc[0]), msgReady(0x49)])]);
        const r = await conn.query('TAG');
        expect(r.commandTag === tc[0] && r.rowCountExact === tc[1] && r.affectedRowsExact === tc[2] && r.affectedRows === tc[3]).assertTrue();
      }
      await conn.close();
    });

    it('ordersMultiStatementResultsAndAppliesAsyncNoticesNotificationsAndParameters', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect();
      const sink = new CaptureLogSink(); const prevLevel = Logger.level; Logger.setLevel(LogLevel.DEBUG); Logger.addSink(sink);
      tp.enqueue([concatFrames([msgCmd('BEGIN'), msgNotice('NOTICE', '00000', 'quiet-notice'), msgNotification(55, 'events', 'secret-event'),
        msgParam('TimeZone', 'Asia/Shanghai'), msgParam('DateStyle', 'ISO, YMD'), msgParam('client_encoding', 'UTF8'),
        msgRowDesc([colSpec('n', 0, 0, 23, 4, -1, 0)]), msgDataRow(['10']), msgCmd('SELECT 1'), msgEmptyQuery(),
        msgRowDesc([colSpec('msg', 0, 0, 25, -1, -1, 0)]), msgDataRow(['done']), msgCmd('INSERT 0 1'), msgReady(0x54)])]);
      let primary: PostgresQueryResult;
      try { primary = await conn.query("BEGIN; SELECT 10; ; INSERT INTO log VALUES ('done') RETURNING msg"); }
      finally { Logger.removeSink(sink); Logger.setLevel(prevLevel); }
      expect(sink.messages.length === 1 && sink.messages[0].indexOf(Logger.mask('events')) >= 0 &&
        sink.messages[0].indexOf('events') === -1 && sink.messages[0].indexOf('secret-event') === -1).assertTrue();
      expect(primary.commandTag === 'BEGIN' && primary.additionalResults.length === 3 &&
        primary.additionalResults[0].commandTag === 'SELECT 1' && primary.additionalResults[0].rows[0][0] === 10 &&
        !primary.additionalResults[0].statusKnown && primary.additionalResults[1].commandTag === '' &&
        primary.additionalResults[2].commandTag === 'INSERT 0 1' && primary.additionalResults[2].rows[0][0] === 'done' &&
        primary.additionalResults[2].affectedRows === 1 && primary.statusKnown && primary.autocommit &&
        primary.inTransaction && primary.additionalResults[2].statusKnown && primary.additionalResults[2].inTransaction &&
        conn.sessionStatus.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction &&
        conn.serverInfo.timeZone === 'Asia/Shanghai' && conn.serverInfo.dateStyle === 'ISO, YMD' &&
        conn.serverInfo.defaultEncoding === 'UTF8').assertTrue();
      tp.enqueue([msgReady(0x54)]);
      const zeroItem = await conn.query('-- defensive empty');
      expect(zeroItem.commandTag === '' && zeroItem.rows.length === 0 && zeroItem.inTransaction).assertTrue();
      tp.enqueue([concatFrames([msgParam('client_encoding', 'LATIN1'), msgReady(0x54)])]);
      expect((await asyncFail((): Promise<Object> => conn.query('SET client_encoding = LATIN1'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(conn.state).assertEqual(ConnectionState.Error);
    });

    it('drainsMidScriptErrorToReadyForQueryKeepingConnectionReusableVsFatalEofRetirement', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x54)]); const conn = openReady(tp); await conn.connect();
      tp.enqueue([concatFrames([msgRowDesc([colSpec('ok', 0, 0, 23, 4, -1, 0)]), msgDataRow(['1']), msgCmd('SELECT 1'),
        msgError('ERROR', 'ERROR', '22012', 'division by zero'), msgNotice('NOTICE', '00000', 'aborted'), msgParam('TimeZone', 'UTC'), msgReady(0x45)])]);
      const err = await asyncFail((): Promise<Object> => conn.query('SELECT 1; SELECT 1/0'));
      expect(err instanceof PostgresError && err.kind === ArkDbErrorKind.Server && err.sqlState === '22012' &&
        err.severity === 'ERROR' && conn.state === ConnectionState.Ready && conn.sessionStatus.known &&
        conn.sessionStatus.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction &&
        conn.serverInfo.timeZone === 'UTC').assertTrue();
      tp.enqueue([concatFrames([msgCmd('ROLLBACK'), msgReady(0x49)])]);
      const rb = await conn.query('ROLLBACK');
      expect(rb.commandTag === 'ROLLBACK' && !rb.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();
      for (const isPing of [false, true]) {
        for (const sev of ['FATAL', 'PANIC']) {
          const fConn = openReady(new QueueTransport([bootFrames(0x49), msgError(sev, sev, '57P01', 'terminating connection')])); await fConn.connect();
          const fpErr = isPing ? await asyncFail((): Promise<void> => fConn.ping()) : await asyncFail((): Promise<Object> => fConn.query('SELECT 1'));
          expect(fpErr instanceof PostgresError && fpErr.sqlState === '57P01' && fpErr.severity === sev && fConn.state === ConnectionState.Error).assertTrue();
        }
        for (const postErr of [[null, ArkDbErrorKind.Protocol], [ArkDbError.network('reset'), ArkDbErrorKind.Network],
          [ArkDbError.tls('tls closed'), ArkDbErrorKind.Tls], [ArkDbError.protocol('PostgreSQL receive buffer exceeds client limit'), ArkDbErrorKind.Protocol]] as Array<[ArkDbError | null, ArkDbErrorKind]>) {
          const dTp = new QueueTransport([bootFrames(0x49), msgError('ERROR', 'ERROR', '22012', 'boom')]); dTp.readErrorAtEmpty = postErr[0];
          const dConn = openReady(dTp); await dConn.connect();
          const dErr = isPing ? await asyncFail((): Promise<void> => dConn.ping()) : await asyncFail((): Promise<Object> => dConn.query('SELECT 1'));
          expect(dErr.kind === postErr[1] && dConn.state === ConnectionState.Error).assertTrue();
        }
        for (const tail of [[0x4e, 0x7f, 0xff, 0xff, 0xff], [0x4e, 0, 0], [0x4e, 0, 0, 0, 6, 0x53]]) {
          await expectProtocolError(concatFrames([msgError('ERROR', 'ERROR', '22012', 'boom'), new Uint8Array(tail)]), isPing);
          const tTp = new QueueTransport([bootFrames(0x49), concatFrames([msgError('ERROR', 'ERROR', '22012', 'boom'), new Uint8Array(tail)])]);
          tTp.readErrorAtEmpty = ArkDbError.network('PostgreSQL socket closed by server');
          const tConn = openReady(tTp); await tConn.connect();
          const tErr = isPing ? await asyncFail((): Promise<void> => tConn.ping()) : await asyncFail((): Promise<Object> => tConn.query('SELECT 1'));
          expect((tErr.kind === ArkDbErrorKind.Protocol || tErr.kind === ArkDbErrorKind.Network) && !(tErr instanceof PostgresError) && tConn.state === ConnectionState.Error).assertTrue();
        }
      }
      const hangTp = new QueueTransport([bootFrames(0x49)]); const hangConn = openReady(hangTp); await hangConn.connect();
      hangTp.rawWrites.length = 0; hangTp.hangNextWrite = true;
      const pendingQ = hangConn.query("SELECT 'secret'");
      while (hangTp.rawWrites.length === 0) await Promise.resolve();
      const closeTask = hangConn.close();
      expect((await asyncFail((): Promise<Object> => pendingQ)).kind).assertEqual(ArkDbErrorKind.Cancelled);
      await closeTask; assertZeroed(hangTp.rawWrites[0]);
      const racedPayload = new Uint8Array([0, 1, 0, 0, 0, 6, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74]);
      const raceLife = await openReadyLife(concatFrames([msgRowDesc([colSpec('s', 0, 0, 25, -1, -1, 0)])]));
      expect((await asyncFail((): Promise<Object> => raceLife.runCommand<PostgresQueryResult>(PostgresCommandKind.Query,
        (sc: PostgresCommandScope, _ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresQueryResult> =>
          runPostgresSimpleQuery(new LifecycleQueryHost(raceLife, sc), new PreResolvedCloseRaceChannel(st, racedPayload), st, 'SELECT 1')
      ))).kind).assertEqual(ArkDbErrorKind.Cancelled);
      assertZeroed(racedPayload);
    });

    it('rejectsAndDrainsCopySubprotocolsBinaryFormatAndPreDispatchValidation', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x54)]); const conn = openReady(tp); await conn.connect();
      tp.writes.length = 0; tp.rawWrites.length = 0;
      for (const badSql of ['SELECT \u0000', String.fromCharCode(0xD800), '\u{1F600}'.repeat(8388607)]) {
        expect((await asyncFail((): Promise<Object> => conn.query(badSql))).kind).assertEqual(ArkDbErrorKind.Validation);
      }
      expect(tp.writes.length === 0 && conn.state === ConnectionState.Ready &&
        conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction).assertTrue();
      tp.enqueue([concatFrames([msgRowDesc([colSpec('bin', 0, 0, 23, 4, -1, 1)]), msgCmd('SELECT 0'), msgReady(0x49)])]);
      expect((await asyncFail((): Promise<Object> => conn.query('SELECT 1'))).kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(conn.state === ConnectionState.Ready && conn.sessionStatus.transactionState === PostgresTransactionState.Idle).assertTrue();
      const ownedDrainedRow = new Uint8Array([0, 1, 0, 0, 0, 2, 0xff, 0x77]);
      tp.enqueue([msgRowDesc([colSpec('bin', 0, 0, 17, -1, -1, 1)]), backendFrame(0x44, [0, 1, 255, 255, 255, 255]),
        new Uint8Array([0x44, 0, 0, 0, 12]), ownedDrainedRow, concatFrames([msgCmd('SELECT 2'), msgCopyOut(), msgCopyDone(), msgCmd('COPY 0'), msgCopyIn()]),
        concatFrames([msgError('ERROR', 'ERROR', '57014', 'COPY aborted'), msgReady(0x49)])]);
      const binErr = await asyncFail((): Promise<Object> => conn.query('SELECT bytea_bin; COPY t TO STDOUT; COPY t FROM STDIN'));
      expect(binErr.kind === ArkDbErrorKind.Unsupported && binErr.message.indexOf('format code 1') >= 0 && conn.state === ConnectionState.Ready).assertTrue();
      assertZeroed(ownedDrainedRow);
      tp.writes.length = 0; tp.rawWrites.length = 0;
      tp.enqueue([msgCopyIn(), concatFrames([msgError('ERROR', 'ERROR', '57014', 'COPY aborted'), msgReady(0x49)])]);
      expect((await asyncFail((): Promise<Object> => conn.query('COPY t FROM STDIN'))).kind).assertEqual(ArkDbErrorKind.Unsupported);
      assertBytes(tp.writes[1], expectedCopyFailFrame('PostgreSQL COPY is not supported.')); assertZeroed(tp.rawWrites[1]);
      expect(conn.state).assertEqual(ConnectionState.Ready);
      const ownedCopyData = new Uint8Array([9, 8, 7]);
      tp.enqueue([msgCopyOut(), new Uint8Array([0x64, 0, 0, 0, 7]), ownedCopyData, concatFrames([msgCopyDone(), msgCmd('COPY 1'), msgReady(0x54)])]);
      expect((await asyncFail((): Promise<Object> => conn.query('COPY t TO STDOUT'))).kind).assertEqual(ArkDbErrorKind.Unsupported);
      assertZeroed(ownedCopyData);
      expect(conn.state === ConnectionState.Ready && conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction).assertTrue();
      const copyDrainOpts = new QueryOptions(); copyDrainOpts.maxDrainBytes = 16;
      const copyDrainLife = await openReadyLife(concatFrames([msgCopyOut(), msgCopyData(new Uint8Array([1, 2, 3, 4, 5, 6])),
        msgCopyData(new Uint8Array([7, 8, 9, 10, 11, 12])), msgCopyDone(), msgCmd('COPY 2'), msgReady(0x49)]));
      expect((await asyncFail((): Promise<Object> => runWithOptions(copyDrainLife, 'COPY huge TO STDOUT', copyDrainOpts))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(copyDrainLife.state).assertEqual(ConnectionState.Error);
      const bothConn = openReady(new QueueTransport([bootFrames(0x49), msgCopyBoth()])); await bothConn.connect();
      expect((await asyncFail((): Promise<Object> => bothConn.query('START_REPLICATION'))).kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(bothConn.state).assertEqual(ConnectionState.Error);
    });

    it('enforcesBufferedResultCapsProtocolFramingInvariantsAndPingAcrossTransactionStates', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect(); tp.writes.length = 0;
      for (const st of [[0x49, PostgresTransactionState.Idle, false], [0x54, PostgresTransactionState.InTransaction, true],
        [0x45, PostgresTransactionState.FailedTransaction, true]] as Array<[number, PostgresTransactionState, boolean]>) {
        tp.enqueue([concatFrames([msgNotice('NOTICE', '00000', 'n'), msgParam('TimeZone', 'UTC'), msgEmptyQuery(), msgReady(st[0])])]);
        await conn.features.health!.ping();
        expect(conn.state === ConnectionState.Ready && conn.sessionStatus.transactionState === st[1] && conn.sessionStatus.inTransaction === st[2]).assertTrue();
      }
      assertBytes(tp.writes[0], expectedQueryFrame(''));
      tp.enqueue([concatFrames([msgError('ERROR', 'ERROR', '57014', 'canceling statement'), msgReady(0x45)])]);
      const pingErr = await asyncFail((): Promise<void> => conn.ping());
      expect(pingErr instanceof PostgresError && pingErr.sqlState === '57014' && conn.state === ConnectionState.Ready).assertTrue();
      const subConn = new CustomPingConnection(baseConfig(), '', new StepTimers(), (): PostgresLifecycleTransport => new QueueTransport([]));
      await subConn.features.health!.ping(); expect(subConn.pingCalls).assertEqual(1);
      tp.enqueue([repeatCmdFrames(64)]); expect((await conn.query('SELECT 0;')).additionalResults.length).assertEqual(63);
      tp.enqueue([repeatCmdFrames(65)]);
      expect((await asyncFail((): Promise<Object> => conn.query('TOO MANY'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(conn.state).assertEqual(ConnectionState.Error);
      const defaults = new QueryOptions();
      expect(defaults.maxResultSets === 64 && defaults.maxResultBytes === 33554432 && defaults.maxDrainBytes === 33554432).assertTrue();
      const memOpts = new QueryOptions(); memOpts.maxResultBytes = 32;
      for (const frames of [concatFrames([msgRowDesc([colSpec('t', 0, 0, 25, -1, -1, 0)]), msgDataRow(['abcd']), msgDataRow(['efgh']), msgCmd('SELECT 2'), msgReady(0x49)]),
        concatFrames([msgRowDesc([colSpec('t', 0, 0, 25, -1, -1, 0)]), msgDataRow(['']), msgDataRow(['']), msgCmd('SELECT 2'), msgReady(0x49)]),
        concatFrames([msgRowDesc([colSpec('a', 0, 0, 25, -1, -1, 0), colSpec('b', 0, 0, 25, -1, -1, 0)]), msgCmd('SELECT 0'), msgReady(0x49)]), repeatCmdFrames(4)]) {
        const memLife = await openReadyLife(frames);
        expect((await asyncFail((): Promise<Object> => runWithOptions(memLife, 'SELECT cap', memOpts.clone()))).kind === ArkDbErrorKind.Protocol && memLife.state === ConnectionState.Error).assertTrue();
      }
      const mutOpts = new QueryOptions(); mutOpts.maxResultBytes = 4;
      const mutLife = await openReadyLife(concatFrames([msgRowDesc([colSpec('t', 0, 0, 25, -1, -1, 0)]), msgDataRow(['abcd']), msgCmd('SELECT 1'), msgReady(0x49)]));
      const mutTask = runWithOptions(mutLife, 'SELECT mut', mutOpts); mutOpts.maxResultBytes = Number.NaN;
      expect((await asyncFail((): Promise<Object> => mutTask)).kind === ArkDbErrorKind.Protocol && mutLife.state === ConnectionState.Error).assertTrue();
      for (const stallPing of [false, true]) {
        const stallTimers = new StepTimers(); const stallTp = new QueueTransport([bootFrames(0x49), msgError('ERROR', 'ERROR', '57014', 'stalled')]); stallTp.hangAtEmpty = true;
        const stallLife = new PostgresConnectionLifecycle(baseConfig(), '', stallTimers, (): PostgresLifecycleTransport => stallTp); await stallLife.connect();
        const dOpts = new QueryOptions(); dOpts.maxDrainTimeMs = 25;
        const stallTask = stallPing ? pingWithOptions(stallLife, dOpts) : runWithOptions(stallLife, 'SELECT stall', dOpts);
        for (let i = 0; i < 64 && !stallTp.waitingRead; i += 1) await Promise.resolve();
        expect(stallTp.waitingRead && stallTimers.pendingCount === 1).assertTrue();
        stallTimers.now += 30; stallTimers.fireAll();
        expect((await asyncFail((): Promise<Object> => stallTask as Promise<Object>)).kind === ArkDbErrorKind.Protocol && stallLife.state === ConnectionState.Error).assertTrue();
      }
      const badOpts = new QueryOptions(); badOpts.maxResultSets = 0; const validLife = await openReadyLife(msgReady(0x49));
      expect((await asyncFail((): Promise<Object> => runWithOptions(validLife, 'SELECT 1', badOpts))).kind).assertEqual(ArkDbErrorKind.Validation);
      expect((await asyncFail((): Promise<void> => pingWithOptions(validLife, badOpts))).kind === ArkDbErrorKind.Validation && validLife.state === ConnectionState.Ready).assertTrue();
      const pingDrainOpts = new QueryOptions(); pingDrainOpts.maxDrainBytes = 12;
      const bigNotice = msgNotice('NOTICE', '00000', 'oversized-notice');
      const hdrOnlyTp = new QueueTransport([bootFrames(0x49), concatFrames([msgError('ERROR', 'ERROR', '57014', 'cancelled'), bigNotice.slice(0, 5)]), bigNotice.slice(5), msgReady(0x49)]);
      const pingDrainLife = new PostgresConnectionLifecycle(baseConfig(), '', new StepTimers(), (): PostgresLifecycleTransport => hdrOnlyTp); await pingDrainLife.connect();
      const pingDrainTask = pingWithOptions(pingDrainLife, pingDrainOpts); pingDrainOpts.maxDrainBytes = Number.NaN;
      expect((await asyncFail((): Promise<void> => pingDrainTask)).kind === ArkDbErrorKind.Protocol && hdrOnlyTp.remainingChunks === 2 && pingDrainLife.state === ConnectionState.Error).assertTrue();
      const unexpectedAuthSalt = new Uint8Array([0, 0, 0, 5, 1, 2, 3, 4]);
      const authTp = new QueueTransport([bootFrames(0x49), new Uint8Array([0x52, 0, 0, 0, 12]), unexpectedAuthSalt]);
      const authConn = openReady(authTp); await authConn.connect();
      expect((await asyncFail((): Promise<Object> => authConn.query('SELECT 1'))).kind === ArkDbErrorKind.Protocol && authConn.state === ConnectionState.Error).assertTrue();
      assertZeroed(unexpectedAuthSalt);
      const colA = [colSpec('a', 0, 0, 23, 4, -1, 0)];
      for (const badFrames of [[msgDataRow(['1']), msgReady(0x49)], [msgRowDesc(colA), msgRowDesc(colA), msgReady(0x49)], [msgRowDesc(colA), msgEmptyQuery(), msgReady(0x49)],
        [msgRowDesc(colA), msgReady(0x49)], [msgCopyData(new Uint8Array([1])), msgReady(0x49)], [msgCopyOut(), msgCopyDone(), msgReady(0x49)],
        [msgError('ERROR', 'ERROR', '22012', 'boom'), msgError('ERROR', 'ERROR', '22012', 'boom2'), msgReady(0x49)], [msgError('ERROR', 'ERROR', '22012', 'boom'), msgCmd('SELECT 1'), msgReady(0x49)],
        [msgError('ERROR', 'ERROR', '22012', 'boom'), msgRowDesc(colA), msgCmd('SELECT 0'), msgReady(0x49)], [msgError('ERROR', 'ERROR', '22012', 'boom'), msgEmptyQuery(), msgReady(0x49)]]) {
        await expectProtocolError(concatFrames(badFrames), false);
      }
      for (const badPing of [[msgCmd('SELECT 0'), msgReady(0x49)], [msgRowDesc(colA), msgCmd('SELECT 0'), msgReady(0x49)],
        [msgError('ERROR', 'ERROR', '57014', 'e1'), msgError('ERROR', 'ERROR', '57014', 'e2'), msgReady(0x49)], [msgReady(0x49)]]) await expectProtocolError(concatFrames(badPing), true);
    });
  });
}
class CaptureLogSink implements LogSink { readonly messages: string[] = []; write(_l: LogLevel, _t: string, m: string, _ts: number): void { this.messages.push(m); } }
class CustomPingConnection extends PostgresConnection { pingCalls: number = 0; async ping(): Promise<void> { this.pingCalls += 1; } }
class LifecycleQueryHost implements PostgresSimpleQueryHost {
  private readonly life: PostgresConnectionLifecycle; private readonly scope: PostgresCommandScope;
  constructor(life: PostgresConnectionLifecycle, scope: PostgresCommandScope) { this.life = life; this.scope = scope; }
  get serverInfo(): PostgresServerInfo { return this.life.serverInfo; } get sessionStatus(): PostgresDatabaseSessionStatus { return this.life.sessionStatus; }
  get timers(): ConnectionTimerPort { return this.life.timers; }
  applyReadyStatus(ready: PostgresReadyStatus): void { this.life.applyReadyStatus(this.scope, ready); } retire(reason: ArkDbError): Promise<void> { return this.life.retire(this.scope, reason); }
}
async function openReadyLife(frames: Uint8Array): Promise<PostgresConnectionLifecycle> {
  const life = new PostgresConnectionLifecycle(baseConfig(), '', new StepTimers(), (): PostgresLifecycleTransport => new QueueTransport([bootFrames(0x49), frames])); await life.connect(); return life;
}
async function expectProtocolError(frames: Uint8Array, isPing: boolean): Promise<void> {
  const conn = openReady(new QueueTransport([bootFrames(0x49), frames])); await conn.connect();
  const err = isPing ? await asyncFail((): Promise<void> => conn.ping()) : await asyncFail((): Promise<Object> => conn.query('BAD'));
  expect(err.kind === ArkDbErrorKind.Protocol && conn.state === ConnectionState.Error).assertTrue();
}
function runWithOptions(life: PostgresConnectionLifecycle, sql: string, opts: QueryOptions): Promise<PostgresQueryResult> {
  return life.runCommand<PostgresQueryResult>(PostgresCommandKind.Query, (sc: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresQueryResult> => runPostgresSimpleQuery(new LifecycleQueryHost(life, sc), ch, st, sql, opts));
}
function pingWithOptions(life: PostgresConnectionLifecycle, opts: QueryOptions): Promise<void> {
  return life.runCommand<void>(PostgresCommandKind.Ping, (sc: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<void> => runPostgresPing(new LifecycleQueryHost(life, sc), ch, st, opts));
}
function repeatCmdFrames(count: number): Uint8Array { const frames: Uint8Array[] = []; for (let i = 0; i < count; i += 1) frames.push(msgCmd('SELECT 0')); frames.push(msgReady(0x49)); return concatFrames(frames); }
class StepTimers implements ConnectionTimerPort {
  now: number = 100; stepMs: number = 1; private id: number = 1; private readonly handlers: Map<number, () => void> = new Map<number, () => void>();
  get pendingCount(): number { return this.handlers.size; } nowMs(): number { const v = this.now; this.now += this.stepMs; return v; }
  schedule(h: () => void, _ms: number): number { const k = this.id++; this.handlers.set(k, h); return k; } cancel(id: number): void { this.handlers.delete(id); }
  fireAll(): void { const fns = Array.from(this.handlers.values()); this.handlers.clear(); for (const fn of fns) fn(); }
}
class PreResolvedCloseRaceChannel extends PostgresMessageChannel {
  private readonly st: PostgresCommandCloseSettlement; private readonly p: Uint8Array;
  constructor(st: PostgresCommandCloseSettlement, p: Uint8Array) { super(new QueueTransport([])); this.st = st; this.p = p; }
  async writeMessage(_t: number, _p: Uint8Array): Promise<void> {}
  readMessage(_maxFrameBytes?: number): Promise<PostgresMessage> {
    return Promise.resolve().then((): PostgresMessage => { this.st.signalClose(ArkDbError.cancelled('PostgreSQL connection closed during operation.')); return { type: 0x44, payload: this.p }; });
  }
}
class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; readonly rawWrites: Uint8Array[] = []; readErrorAtEmpty: ArkDbError | null = null;
  hangNextWrite: boolean = false; hangAtEmpty: boolean = false; waitingRead: boolean = false;
  private rejectHungWrite: ((e: Object) => void) | null = null; private rejectHungRead: ((e: Object) => void) | null = null; private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  get remainingChunks(): number { return this.reads.length; }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) {
      if (this.hangAtEmpty) { this.waitingRead = true; return new Promise<Uint8Array | null>((_r: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => { this.rejectHungRead = rej; }); }
      if (this.readErrorAtEmpty !== null) throw this.readErrorAtEmpty; return null;
    }
    const head = this.reads[0]; if (head.length <= max) return this.reads.shift()!;
    this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  write(data: Uint8Array): Promise<number> {
    this.rawWrites.push(data); const cp = new Uint8Array(data.length); cp.set(data); this.writes.push(cp);
    if (!this.hangNextWrite) return Promise.resolve(data.length);
    this.hangNextWrite = false; return new Promise<number>((_r: (v: number) => void, rej: (e: Object) => void): void => { this.rejectHungWrite = rej; });
  }
  async close(): Promise<void> {}
  async abort(e: ArkDbError): Promise<void> {
    if (this.rejectHungWrite !== null) { const r = this.rejectHungWrite; this.rejectHungWrite = null; r(e); }
    if (this.rejectHungRead !== null) { const r = this.rejectHungRead; this.rejectHungRead = null; this.waitingRead = false; r(e); }
  }
}
function baseConfig(): PostgresConnectionConfig { const c = new PostgresConnectionConfig(); c.host = 'pg.local'; c.user = 'postgres'; c.ssl.mode = PostgresSslMode.DISABLED; return c; }
function openReady(tp: QueueTransport, timers: ConnectionTimerPort = new StepTimers()): PostgresConnection { return new PostgresConnection(baseConfig(), '', timers, (): PostgresLifecycleTransport => tp); }
function bootFrames(ready: number): Uint8Array { return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]); }
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array {
  const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload);
  const out = new Uint8Array(src.length + 5); out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5); return out;
}
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
function msgCopyIn(): Uint8Array { return backendFrame(0x47, [0, 0, 0]); } function msgCopyOut(): Uint8Array { return backendFrame(0x48, [0, 0, 0]); }
function msgCopyBoth(): Uint8Array { return backendFrame(0x57, [0, 0, 0]); } function msgCopyData(bytes: Uint8Array): Uint8Array { return backendFrame(0x64, bytes); }
function msgCopyDone(): Uint8Array { return backendFrame(0x63, []); }
function pushCStr(dst: number[], text: string): void { for (let i = 0; i < text.length; i += 1) dst.push(text.charCodeAt(i)); dst.push(0); }
function concatFrames(frames: Uint8Array[]): Uint8Array { let len = 0; for (const f of frames) len += f.length; const out = new Uint8Array(len); let off = 0; for (const f of frames) { out.set(f, off); off += f.length; } return out; }
function assertBytes(actual: Uint8Array, expected: Uint8Array): void { expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]); }
function assertZeroed(buf: Uint8Array): void { for (let i = 0; i < buf.length; i += 1) expect(buf[i]).assertEqual(0); }
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> { let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; } expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError; }
