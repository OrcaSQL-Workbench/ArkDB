import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, Logger, LogLevel, LogSink, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk } from '@arkdb/core';
import { PostgresConnection, PostgresConnectionConfig, PostgresDriverCapabilities, PostgresDriverFactory, PostgresError, PostgresParameter, PostgresParameterType, PostgresParameterValue, PostgresQueryResult, PostgresSslMode, PostgresTransactionState, requirePostgresFeatures } from '../../../../../Index';
import { PostgresExtendedQueryHost, runPostgresExtendedQuery } from '../../../../main/ets/pgsql/command/PostgresExtendedQuery';
import { PostgresConnectionLifecycle, PostgresLifecycleTransport } from '../../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandKind, PostgresCommandScope } from '../../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement } from '../../../../main/ets/pgsql/execution/PostgresSettlements';
import { encodePostgresPreparedFrames, POSTGRES_PARAMETER_FORMAT_TEXT, PostgresPreparedFrames } from '../../../../main/ets/pgsql/features/prepared/PostgresParameterEncoder';
import { PostgresConnectionPreparedExecutor } from '../../../../main/ets/pgsql/features/prepared/PostgresPreparedExecutor';
import { PostgresDatabaseSessionStatus, PostgresServerInfo } from '../../../../main/ets/pgsql/model/PostgresModels';
import { PostgresFrontendSerializer } from '../../../../main/ets/pgsql/protocol/PostgresByteCodec';
import { PostgresMessageChannel, PostgresReadyStatus } from '../../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresExtendedQueryTest(): void {
  describe('PostgresExtendedQuery', () => {
    it('executesUnnamedPipelineAndDecodesTypedParametersAndResults', 0, async () => {
      expect(new PostgresDriverCapabilities().supportsPreparedStatements).assertFalse();
      expect(new PostgresDriverFactory().capabilities.supportsPreparedStatements).assertFalse();
      const timers = new StepTimers(); const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openReady(tp, timers, 'secret-pw-p18');
      expect(conn.postgresFeatures.prepared !== undefined && requirePostgresFeatures(conn).prepared === conn.postgresFeatures.prepared &&
        JSON.stringify(conn.postgresFeatures) === '{"prepared":{}}' && JSON.stringify(conn).indexOf('secret-pw-p18') === -1).assertTrue();
      await conn.connect(); tp.writes.length = 0; tp.rawWrites.length = 0; timers.stepMs = 9;
      const byteaIn = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
      const sql = 'SELECT $1, $2::int4, $3::bytea, $4::bool, $5::int8, $6::numeric, $7::float4, $8::timestamp, $9::jsonb, $10::uuid';
      const params = [
        new PostgresParameter(PostgresParameterType.Unspecified, null), new PostgresParameter(PostgresParameterType.Int4, null),
        new PostgresParameter(PostgresParameterType.Bytea, byteaIn), new PostgresParameter(PostgresParameterType.Boolean, true),
        new PostgresParameter(PostgresParameterType.Int8, 9007199254740995n), new PostgresParameter(PostgresParameterType.Numeric, '12345.6789'),
        new PostgresParameter(PostgresParameterType.Float4, 1.5), new PostgresParameter(PostgresParameterType.Timestamp, '2026-04-20 12:34:56.789'),
        new PostgresParameter(PostgresParameterType.Jsonb, '{"k":1}'), new PostgresParameter(PostgresParameterType.Uuid, '550e8400-e29b-41d4-a716-446655440000')
      ];
      const row1Frame = msgDataRow(['9007199254740995', '\\xcafe', 't', 'ok', null]); const ownedRow1Payload = row1Frame.slice(5);
      tp.enqueue([msgParseComplete(), msgBindComplete(),
        msgRowDesc([colSpec('big', 16384, 1, 20, 8, -1, 0), colSpec('raw', 16384, 2, 17, -1, -1, 0),
          colSpec('flag', 16384, 3, 16, 1, -1, 0), colSpec('txt', 16384, 4, 25, -1, -1, 0), colSpec('opt', 0, 0, 23, 4, -1, 0)]),
        row1Frame.slice(0, 5), ownedRow1Payload, concatFrames([msgDataRow(['7', '\\x00', 'f', 'done', '42']), msgCmd('SELECT 2'), msgReady(0x49)])]);
      const res = await conn.postgresFeatures.prepared!.execute(sql, params, new QueryOptions());
      expect(tp.writes.length).assertEqual(5);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', sql, [0, 23, 17, 16, 20, 1700, 700, 1114, 3802, 2950]));
      assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [0, 0, 1, 0, 0, 0, 0, 0, 0, 0],
        [null, null, new Uint8Array([0xde, 0xad, 0xbe, 0xef]), ascii('true'), ascii('9007199254740995'),
          ascii('12345.6789'), ascii('1.5'), ascii('2026-04-20 12:34:56.789'), ascii('{"k":1}'), ascii('550e8400-e29b-41d4-a716-446655440000')], [0]));
      assertBytes(tp.writes[2], new Uint8Array([0x44, 0x00, 0x00, 0x00, 0x06, 0x50, 0x00]));
      assertBytes(tp.writes[3], PostgresFrontendSerializer.execute('', 0));
      assertBytes(tp.writes[4], new Uint8Array([0x53, 0x00, 0x00, 0x00, 0x04]));
      for (const rawWrite of tp.rawWrites) assertZeroed(rawWrite);
      assertZeroed(ownedRow1Payload); assertBytes(byteaIn, new Uint8Array([0xde, 0xad, 0xbe, 0xef]));
      expect(res.commandTag === 'SELECT 2' && res.rowCountExact === 2n && res.affectedRowsExact === undefined &&
        res.affectedRows === 0 && res.columns.length === 5 && res.columns[0].name === 'big' &&
        res.columns[0].tableOid === 16384 && res.columns[0].columnAttributeNumber === 1 && res.columns[0].typeOid === 20 &&
        res.columns[1].typeOid === 17 && res.rows.length === 2 && res.rows[0][0] === 9007199254740995n &&
        res.rows[0][2] === true && res.rows[0][3] === 'ok' && res.rows[0][4] === null && res.rows[1][0] === 7n &&
        res.rows[1][2] === false && res.rows[1][4] === 42 && res.executionTimeMs === 9 && res.statusKnown &&
        res.autocommit && !res.inTransaction && !res.truncated && res.truncationReason === '' && res.additionalResults.length === 0).assertTrue();
      assertBytes(res.rows[0][1] as Uint8Array, new Uint8Array([0xca, 0xfe]));
      await conn.close();
      expect(JSON.stringify(conn).indexOf('secret-pw-p18')).assertEqual(-1);
    });

    it('snapshotsPreDispatchInputsAndValidatesWithoutWireWritesOrRetirement', 0, async () => {
      const idleTp = new QueueTransport([]); const idle = openReady(idleTp);
      const idleErr = await asyncFail((): Promise<Object> => idle.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()));
      expect(idleErr.kind === ArkDbErrorKind.Protocol && idleErr.message === 'PostgreSQL connection is not connected.' && idleTp.writes.length === 0).assertTrue();
      const idleStreamErr = await asyncFail((): Promise<Object> => idle.postgresFeatures.prepared!.queryStream('SELECT 1', [], new QueryOptions(), new NoopSink()));
      expect(idleStreamErr.kind === ArkDbErrorKind.Unsupported && idleStreamErr.message === 'PostgreSQL parameterized result streaming is not implemented.' && idleTp.writes.length === 0).assertTrue();

      let capturedFrames: PostgresPreparedFrames | null = null;
      const failExec = new PostgresConnectionPreparedExecutor((f: PostgresPreparedFrames, _o: QueryOptions): Promise<PostgresQueryResult> => {
        capturedFrames = f; return Promise.reject(ArkDbError.protocol('PostgreSQL connection is not connected.'));
      });
      const callerSecret = new Uint8Array([0xaa, 0xbb, 0xcc]);
      const inspectedRun = new InspectableByteaParameter(callerSecret);
      const liveBytes = new Uint8Array([0x11, 0x22]);
      const scrubErr = await asyncFail((): Promise<Object> => failExec.execute('SELECT $1, $2, $3',
        [inspectedRun, new PostgresParameter(PostgresParameterType.Text, 'päss🔐'), new LiveByteaParameter(liveBytes)], new QueryOptions()));
      expect(scrubErr.kind === ArkDbErrorKind.Protocol && capturedFrames !== null && inspectedRun.lastRead !== null).assertTrue();
      assertZeroed(capturedFrames!.parseFrame); assertZeroed(capturedFrames!.bindFrame);
      assertZeroed(capturedFrames!.parameters.parameterValues[0]!); assertZeroed(capturedFrames!.parameters.parameterValues[1]!); assertZeroed(capturedFrames!.parameters.parameterValues[2]!);
      assertZeroed(inspectedRun.lastRead!);
      assertBytes(callerSecret, new Uint8Array([0xaa, 0xbb, 0xcc])); assertBytes(liveBytes, new Uint8Array([0x11, 0x22]));

      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect(); tp.writes.length = 0;
      const streamErr = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.queryStream('SELECT $1', [new PostgresParameter(PostgresParameterType.Int4, 1)], new QueryOptions(), new NoopSink()));
      expect(streamErr.kind === ArkDbErrorKind.Unsupported && streamErr.message === 'PostgreSQL parameterized result streaming is not implemented.').assertTrue();
      const nonOptsErr = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT 1', [], asQueryOpts(null)));
      expect(nonOptsErr.kind === ArkDbErrorKind.Validation && nonOptsErr.message === 'QueryOptions is required.').assertTrue();
      for (const mut of [(o: QueryOptions): void => { o.maxRows = -1; }, (o: QueryOptions): void => { o.maxResultBytes = 0; }, (o: QueryOptions): void => { o.maxDrainBytes = 0; }, (o: QueryOptions): void => { o.maxDrainTimeMs = 0; }]) {
        const bad = new QueryOptions(); mut(bad);
        expect((await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT 1', [], bad))).kind).assertEqual(ArkDbErrorKind.Validation);
      }
      const deadlineOpts = new QueryOptions(); deadlineOpts.statementTimeoutMs = 50;
      const dlErr = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT 1', [], deadlineOpts));
      expect(dlErr.kind === ArkDbErrorKind.Unsupported && dlErr.message === 'PostgreSQL statement deadlines are not implemented.').assertTrue();
      const tooMany = new Array<PostgresParameter>(65536);
      const inspectedErr = new InspectableByteaParameter(new Uint8Array([0xde, 0xad]));
      for (const badCall of [
        (): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT \u0000', [], new QueryOptions()),
        (): Promise<Object> => conn.postgresFeatures.prepared!.execute(asSql(123), [], new QueryOptions()),
        (): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT 1', asParamList(null), new QueryOptions()),
        (): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT 1', tooMany, new QueryOptions()),
        (): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT $1', [asParam(null)], new QueryOptions()),
        (): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT $1, $2', [inspectedErr, new ForgedInt4Parameter()], new QueryOptions())
      ]) expect((await asyncFail(badCall)).kind).assertEqual(ArkDbErrorKind.Validation);
      expect(inspectedErr.lastRead !== null && tp.writes.length === 0 && conn.state === ConnectionState.Ready).assertTrue();
      assertZeroed(inspectedErr.lastRead!);

      const snapBytea = new Uint8Array([0xca, 0xfe]); const snapOpts = new QueryOptions();
      const snapParams = [new PostgresParameter(PostgresParameterType.Bytea, snapBytea), new PostgresParameter(PostgresParameterType.Int4, 9)];
      tp.enqueue([extOk([msgRowDesc([colSpec('v', 0, 0, 23, 4, -1, 0)]), msgDataRow(['1']), msgDataRow(['2']), msgCmd('SELECT 2')])]);
      const pending = conn.postgresFeatures.prepared!.execute('SELECT $1, $2', snapParams, snapOpts);
      snapParams.length = 0; snapBytea.fill(0x99); snapOpts.maxRows = 1; snapOpts.statementTimeoutMs = 999;
      const snapRes = await pending;
      expect(snapRes.rows.length === 2 && !snapRes.truncated && conn.state === ConnectionState.Ready).assertTrue();
      assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [1, 0], [new Uint8Array([0xca, 0xfe]), ascii('9')], [0]));

      await conn.close(); const closedWrites = tp.writes.length;
      const closedErr = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()));
      expect(closedErr.kind === ArkDbErrorKind.Protocol && closedErr.message === 'PostgreSQL connection is closed.' && tp.writes.length === closedWrites).assertTrue();
    });

    it('handlesEmptyQueryDmlCommandTagsAndAsyncMessagesAtEveryStage', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect();
      tp.enqueue([extOk([msgNoData(), msgEmptyQuery()])]);
      const emptyRes = await conn.postgresFeatures.prepared!.execute('   ', [], new QueryOptions());
      expect(emptyRes.commandTag === '' && emptyRes.columns.length === 0 && emptyRes.rows.length === 0 &&
        emptyRes.affectedRows === 0 && emptyRes.rowCountExact === undefined && emptyRes.affectedRowsExact === undefined).assertTrue();

      for (const tc of [['INSERT 0 3', 3n, 3n, 3], ['INSERT 0 9007199254740993', 9007199254740993n, 9007199254740993n, Number(9007199254740993n)],
        ['UPDATE 12', 12n, 12n, 12], ['DELETE 0', 0n, 0n, 0], ['MERGE 8', 8n, 8n, 8], ['SELECT 9007199254740993', 9007199254740993n, undefined, 0],
        ['MOVE 4', 4n, undefined, 0], ['CREATE TABLE', undefined, undefined, 0]] as Array<[string, bigint | undefined, bigint | undefined, number]>) {
        tp.enqueue([extOk([msgNoData(), msgCmd(tc[0])])]);
        const r = await conn.postgresFeatures.prepared!.execute('DML', [], new QueryOptions());
        expect(r.commandTag === tc[0] && r.rowCountExact === tc[1] && r.affectedRowsExact === tc[2] && r.affectedRows === tc[3]).assertTrue();
      }

      const sink = new CaptureLogSink(); const prev = Logger.level; Logger.setLevel(LogLevel.DEBUG); Logger.addSink(sink);
      try {
        tp.enqueue([concatFrames([msgNotice('NOTICE', '00000', 'n1'), msgParseComplete(), msgNotification(77, 'chan_sec', 'pay_sec'), msgBindComplete(),
          msgParam('TimeZone', 'Asia/Shanghai'), msgRowDesc([colSpec('v', 0, 0, 23, 4, -1, 0)]), msgNotice('NOTICE', '00000', 'n2'),
          msgDataRow(['11']), msgParam('DateStyle', 'ISO, YMD'), msgCmd('SELECT 1'), msgParam('client_encoding', 'UTF8'), msgReady(0x54)])]);
        const asyncRes = await conn.postgresFeatures.prepared!.execute('SELECT 11', [], new QueryOptions());
        expect(asyncRes.rows[0][0] === 11 && asyncRes.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction &&
          conn.serverInfo.timeZone === 'Asia/Shanghai' && conn.serverInfo.dateStyle === 'ISO, YMD' &&
          sink.messages.length === 1 && sink.messages[0].indexOf('chan_sec') === -1 && sink.messages[0].indexOf('pay_sec') === -1).assertTrue();
      } finally { Logger.removeSink(sink); Logger.setLevel(prev); }

      tp.enqueue([concatFrames([msgParseComplete(), msgParam('client_encoding', 'LATIN1'), msgBindComplete(), msgNoData(), msgCmd('SET'), msgReady(0x54)])]);
      expect((await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('SET', [], new QueryOptions()))).kind === ArkDbErrorKind.Protocol &&
        conn.state === ConnectionState.Error).assertTrue();
    });

    it('recoversFromErrorResponseAtAllFiveStagesWithSingleReadyForQueryAndReuse', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect();
      for (const sc of [
        [concatFrames([msgError('ERROR', 'ERROR', '42601', 'multiple commands'), msgReady(0x49)]), '42601', PostgresTransactionState.Idle],
        [concatFrames([msgError('ERROR', 'ERROR', '42P18', 'indeterminate datatype'), msgReady(0x49)]), '42P18', PostgresTransactionState.Idle],
        [concatFrames([msgParseComplete(), msgError('ERROR', 'ERROR', '08P01', 'bind parameter count'), msgReady(0x54)]), '08P01', PostgresTransactionState.InTransaction],
        [concatFrames([msgParseComplete(), msgError('ERROR', 'ERROR', '22P02', 'invalid input syntax'), msgReady(0x54)]), '22P02', PostgresTransactionState.InTransaction],
        [extOk([msgError('ERROR', 'ERROR', '42P01', 'missing table')], 0x45), '42P01', PostgresTransactionState.FailedTransaction],
        [extOk([msgRowDesc([colSpec('b', 0, 0, 17, -1, -1, 0)]), msgDataRow(['\\xdeadbeef']), msgError('ERROR', 'ERROR', '22012', 'division by zero'),
          msgNotice('NOTICE', '00000', 'post-err'), msgParam('TimeZone', 'UTC')], 0x45), '22012', PostgresTransactionState.FailedTransaction],
        [extOk([msgNoData(), msgCmd('COMMIT'), msgError('ERROR', 'ERROR', '23505', 'deferred constraint')], 0x49), '23505', PostgresTransactionState.Idle]
      ] as Array<[Uint8Array, string, PostgresTransactionState]>) {
        tp.enqueue([sc[0]]);
        const err = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT $1', [new PostgresParameter(PostgresParameterType.Int4, 1)], new QueryOptions()));
        expect(err instanceof PostgresError && err.sqlState === sc[1] && conn.state === ConnectionState.Ready && conn.sessionStatus.transactionState === sc[2]).assertTrue();
      }
      expect(conn.serverInfo.timeZone).assertEqual('UTC');
      tp.enqueue([extOk([msgRowDesc([colSpec('ok', 0, 0, 23, 4, -1, 0)]), msgDataRow(['77']), msgCmd('SELECT 1')])]);
      const reused = await conn.postgresFeatures.prepared!.execute('SELECT $1::int4', [new PostgresParameter(PostgresParameterType.Int4, 77)], new QueryOptions());
      expect(reused.rows[0][0] === 77 && conn.state === ConnectionState.Ready).assertTrue();
      await conn.close();
    });

    it('truncatesMaxRowsAndMaxResultBytesAndDrainsUnsupportedFormatsWithReuse', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const conn = openReady(tp); await conn.connect();
      const rowOpts = new QueryOptions(); rowOpts.maxRows = 2;
      tp.enqueue([extOk([msgRowDesc([colSpec('n', 0, 0, 23, 4, -1, 0)]), msgDataRow(['1']), msgDataRow(['2']), msgDataRow(['3']), msgDataRow(['4']), msgCmd('SELECT 4')])]);
      const rowTrunc = await conn.postgresFeatures.prepared!.execute('SELECT n', [], rowOpts);
      expect(rowTrunc.rows.length === 2 && rowTrunc.rows[0][0] === 1 && rowTrunc.rows[1][0] === 2 && rowTrunc.truncated &&
        rowTrunc.truncationReason === 'rowLimit' && rowTrunc.commandTag === 'SELECT 4' && rowTrunc.rowCountExact === 4n && conn.state === ConnectionState.Ready).assertTrue();

      const byteOpts = new QueryOptions(); byteOpts.maxResultBytes = 10;
      tp.enqueue([extOk([msgRowDesc([colSpec('b', 0, 0, 17, -1, -1, 0)]), msgDataRow(['\\x01020304']), msgDataRow(['\\x0102030405060708090a0b0c0d0e0f10']), msgDataRow(['\\xaa']), msgCmd('SELECT 3')])]);
      const byteTrunc = await conn.postgresFeatures.prepared!.execute('SELECT b', [], byteOpts);
      expect(byteTrunc.rows.length === 1 && byteTrunc.loadedBytes === 4 && byteTrunc.truncated &&
        byteTrunc.truncationReason === 'resultBytes' && byteTrunc.commandTag === 'SELECT 3' && conn.state === ConnectionState.Ready).assertTrue();
      assertBytes(byteTrunc.rows[0][0] as Uint8Array, new Uint8Array([1, 2, 3, 4]));

      tp.enqueue([extOk([msgRowDesc([colSpec('bin', 0, 0, 23, 4, -1, 1)]), msgDataRow(['\u0000\u0000\u0000\u0001']), msgCmd('SELECT 1')])]);
      const binErr = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('SELECT bin', [], new QueryOptions()));
      expect(binErr.kind === ArkDbErrorKind.Unsupported && binErr.message === 'PostgreSQL non-text result format code 1 is not supported.' && conn.state === ConnectionState.Ready).assertTrue();

      const copyDataFrame = msgCopyData(new Uint8Array([0x51, 0x52, 0x53])); const copyPayload = copyDataFrame.slice(5);
      tp.enqueue([msgParseComplete(), msgBindComplete(), msgNoData(), msgCopyOut(), copyDataFrame.slice(0, 5), copyPayload, concatFrames([msgCopyDone(), msgCmd('COPY 1'), msgReady(0x49)])]);
      const copyOutErr = await asyncFail((): Promise<Object> => conn.postgresFeatures.prepared!.execute('COPY t TO STDOUT', [], new QueryOptions()));
      assertZeroed(copyPayload);
      expect(copyOutErr.kind === ArkDbErrorKind.Unsupported && copyOutErr.message === 'PostgreSQL COPY TO STDOUT is not supported.' && conn.state === ConnectionState.Ready).assertTrue();

      tp.enqueue([extOk([msgNoData(), msgCmd('SELECT 0')])]);
      expect((await conn.postgresFeatures.prepared!.execute('SELECT 0', [], new QueryOptions())).commandTag).assertEqual('SELECT 0');
      await conn.close();

      let undelivBytes = new Uint8Array(0); let closeP: Promise<void> = Promise.resolve();
      const life = new PostgresConnectionLifecycle(baseConfig(), '', new StepTimers(),
        (): PostgresLifecycleTransport => new QueueTransport([bootFrames(0x49), extOk([msgRowDesc([colSpec('b', 0, 0, 17, -1, -1, 0)]), msgDataRow(['\\xdeadbeef']), msgCmd('SELECT 1')])]));
      await life.connect();
      const closeRaceErr = await asyncFail((): Promise<Object> => life.runCommand<PostgresQueryResult>(PostgresCommandKind.ExtendedQuery,
        async (sc: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<PostgresQueryResult> => {
          const completed = await runPostgresExtendedQuery(new DirectExtHost(life, sc), ch, st,
            encodePostgresPreparedFrames('SELECT 1', [], '', '', [POSTGRES_PARAMETER_FORMAT_TEXT]), new QueryOptions());
          undelivBytes = completed.rows[0][0] as Uint8Array;
          assertBytes(undelivBytes, new Uint8Array([0xde, 0xad, 0xbe, 0xef]));
          closeP = life.close();
          return completed;
        }));
      await closeP;
      expect(closeRaceErr.kind === ArkDbErrorKind.Cancelled && life.state === ConnectionState.Closed).assertTrue();
      assertZeroed(undelivBytes);
    });

    it('retiresFailClosedOnFatalProtocolMismatchesCopyInAndDrainViolations', 0, async () => {
      for (const sev of ['FATAL', 'PANIC']) {
        const c = openReady(new QueueTransport([bootFrames(0x49), msgError(sev, sev, '57P01', 'terminated')])); await c.connect();
        const e = await asyncFail((): Promise<Object> => c.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()));
        expect(e instanceof PostgresError && e.severity === sev && c.state === ConnectionState.Error).assertTrue();
      }
      for (const copyCase of [[msgCopyIn(), 'PostgreSQL COPY FROM STDIN is not supported.'], [msgCopyBoth(), 'PostgreSQL COPY BOTH is not supported.']] as Array<[Uint8Array, string]>) {
        const c = openReady(new QueueTransport([bootFrames(0x49), extOk([msgNoData(), copyCase[0]])])); await c.connect();
        const e = await asyncFail((): Promise<Object> => c.postgresFeatures.prepared!.execute('COPY', [], new QueryOptions()));
        expect(e.kind === ArkDbErrorKind.Unsupported && e.message === copyCase[1] && c.state === ConnectionState.Error).assertTrue();
        expect((await asyncFail((): Promise<Object> => c.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      const col1 = [colSpec('a', 0, 0, 23, 4, -1, 0)];
      for (const seq of [
        extOk([msgRowDesc(col1), msgPortalSuspended()]),
        concatFrames([msgParseComplete(), backendFrame(0x74, [0, 0]), msgBindComplete(), msgNoData(), msgCmd('SELECT 0'), msgReady(0x49)]),
        concatFrames([backendFrame(0x33, []), msgReady(0x49)]), concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgReady(0x49)]),
        concatFrames([msgBindComplete(), msgNoData(), msgCmd('SELECT 0'), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgRowDesc(col1), msgCmd('SELECT 0'), msgReady(0x49)]),
        extOk([]), extOk([msgRowDesc(col1)]), extOk([msgNoData(), msgDataRow(['1']), msgCmd('SELECT 1')]),
        extOk([msgRowDesc(col1), msgDataRow(['1', '2']), msgCmd('SELECT 1')]),
        concatFrames([msgError('ERROR', 'ERROR', '22012', 'e1'), msgError('ERROR', 'ERROR', '22012', 'e2'), msgReady(0x49)]),
        concatFrames([msgError('ERROR', 'ERROR', '22012', 'e1'), msgCmd('SELECT 0'), msgReady(0x49)]),
        concatFrames([msgParseComplete(), msgError('ERROR', 'ERROR', '22012', 'e1'), msgBindComplete(), msgReady(0x49)]),
        extOk([msgNoData(), msgCopyOut(), msgError('ERROR', 'ERROR', '22012', 'e1'), msgCopyData(new Uint8Array([1]))])
      ]) {
        const c = openReady(new QueueTransport([bootFrames(0x49), seq])); await c.connect();
        const e = await asyncFail((): Promise<Object> => c.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()));
        expect(e.kind === ArkDbErrorKind.Protocol && c.state === ConnectionState.Error).assertTrue();
      }
      const drainByteOpts = new QueryOptions(); drainByteOpts.maxRows = 1; drainByteOpts.maxDrainBytes = 10;
      const dc = openReady(new QueueTransport([bootFrames(0x49), extOk([msgRowDesc(col1), msgDataRow(['1']), msgDataRow(['1234567890']), msgCmd('SELECT 2')])]));
      await dc.connect();
      const dbe = await asyncFail((): Promise<Object> => dc.postgresFeatures.prepared!.execute('SELECT 1', [], drainByteOpts));
      expect(dbe.kind === ArkDbErrorKind.Protocol && dbe.message === 'PostgreSQL post-error drain exceeded maxDrainBytes.' && dc.state === ConnectionState.Error).assertTrue();

      const stallTimers = new StepTimers();
      const stallTp = new QueueTransport([bootFrames(0x49), msgError('ERROR', 'ERROR', '57014', 'stalled')]); stallTp.hangAtEmpty = true;
      const stallConn = openReady(stallTp, stallTimers); await stallConn.connect();
      const stallOpts = new QueryOptions(); stallOpts.maxDrainTimeMs = 20;
      const stallTask = stallConn.postgresFeatures.prepared!.execute('SELECT 1', [], stallOpts);
      for (let i = 0; i < 256 && !stallTp.waitingRead; i += 1) await Promise.resolve();
      expect(stallTp.waitingRead).assertTrue(); stallTimers.now += 25; stallTimers.fireAll();
      const ste = await asyncFail((): Promise<Object> => stallTask);
      expect(ste.kind === ArkDbErrorKind.Protocol && ste.message === 'PostgreSQL drain exceeded maxDrainTimeMs.' && stallConn.state === ConnectionState.Error).assertTrue();

      const lateTimers = new StepTimers(); lateTimers.stepMs = 30;
      const lateConn = openReady(new QueueTransport([bootFrames(0x49), concatFrames([msgError('ERROR', 'ERROR', '57014', 'slow'), msgReady(0x49)])]), lateTimers);
      await lateConn.connect();
      const lateOpts = new QueryOptions(); lateOpts.maxDrainTimeMs = 10;
      const lte = await asyncFail((): Promise<Object> => lateConn.postgresFeatures.prepared!.execute('SELECT 1', [], lateOpts));
      expect(lte.kind === ArkDbErrorKind.Protocol && lte.message === 'PostgreSQL drain exceeded maxDrainTimeMs.' && lateConn.state === ConnectionState.Error).assertTrue();
    });
  });
}

function extOk(mid: Uint8Array[], ready: number = 0x49): Uint8Array {
  return concatFrames([msgParseComplete(), msgBindComplete(), ...mid, msgReady(ready)]);
}

class NoopSink implements QueryResultSink {
  async onResultStart(_m: QueryResultMeta): Promise<void> {}
  async onRows(_c: QueryRowChunk): Promise<void> {}
  async onResultEnd(_s: QueryResultSummary): Promise<void> {}
}
class DirectExtHost implements PostgresExtendedQueryHost {
  private readonly life: PostgresConnectionLifecycle; private readonly sc: PostgresCommandScope;
  constructor(life: PostgresConnectionLifecycle, sc: PostgresCommandScope) { this.life = life; this.sc = sc; }
  get serverInfo(): PostgresServerInfo { return this.life.serverInfo; }
  get sessionStatus(): PostgresDatabaseSessionStatus { return this.life.sessionStatus; }
  get timers(): ConnectionTimerPort { return this.life.timers; }
  enterDraining(): void {}
  applyReadyStatus(r: PostgresReadyStatus): void { this.life.applyReadyStatus(this.sc, r); }
  retire(e: ArkDbError): Promise<void> { return this.life.retire(this.sc, e); }
}
class CaptureLogSink implements LogSink { readonly messages: string[] = []; write(_l: LogLevel, _t: string, m: string, _ts: number): void { this.messages.push(m); } }
class StepTimers implements ConnectionTimerPort {
  now: number = 100; stepMs: number = 1; private id: number = 1; private readonly handlers: Map<number, () => void> = new Map<number, () => void>();
  nowMs(): number { const v = this.now; this.now += this.stepMs; return v; }
  schedule(h: () => void, _ms: number): number { const k = this.id++; this.handlers.set(k, h); return k; }
  cancel(id: number): void { this.handlers.delete(id); }
  fireAll(): void { const fns = Array.from(this.handlers.values()); this.handlers.clear(); for (const fn of fns) fn(); }
}
class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; readonly rawWrites: Uint8Array[] = []; hangAtEmpty: boolean = false; waitingRead: boolean = false;
  private rejectHungRead: ((e: Object) => void) | null = null; private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) {
      if (!this.hangAtEmpty) return null;
      this.waitingRead = true;
      return new Promise<Uint8Array | null>((_r: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => { this.rejectHungRead = rej; });
    }
    const head = this.reads[0]; if (head.length <= max) return this.reads.shift()!;
    this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  write(data: Uint8Array): Promise<number> {
    this.rawWrites.push(data); const cp = new Uint8Array(data.length); cp.set(data); this.writes.push(cp); return Promise.resolve(data.length);
  }
  async close(): Promise<void> {}
  async abort(e: ArkDbError): Promise<void> {
    if (this.rejectHungRead !== null) { const r = this.rejectHungRead; this.rejectHungRead = null; this.waitingRead = false; r(e); }
  }
}
function baseConfig(): PostgresConnectionConfig { const c = new PostgresConnectionConfig(); c.host = 'pg.local'; c.user = 'postgres'; c.ssl.mode = PostgresSslMode.DISABLED; return c; }
function openReady(tp: QueueTransport, timers: ConnectionTimerPort = new StepTimers(), pw: string = ''): PostgresConnection {
  return new PostgresConnection(baseConfig(), pw, timers, (): PostgresLifecycleTransport => tp);
}
function bootFrames(ready: number): Uint8Array { return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]); }
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array {
  const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload); const out = new Uint8Array(src.length + 5);
  out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5); return out;
}
function cstrFrame(type: number, text: string): Uint8Array { const p: number[] = []; pushCStr(p, text); return backendFrame(type, p); }
function msgParseComplete(): Uint8Array { return backendFrame(0x31, []); }
function msgBindComplete(): Uint8Array { return backendFrame(0x32, []); }
function msgNoData(): Uint8Array { return backendFrame(0x6e, []); }
function msgPortalSuspended(): Uint8Array { return backendFrame(0x73, []); }
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
function ascii(text: string): Uint8Array { const out = new Uint8Array(text.length); for (let i = 0; i < text.length; i += 1) out[i] = text.charCodeAt(i); return out; }
function pushCStr(dst: number[], text: string): void { for (let i = 0; i < text.length; i += 1) dst.push(text.charCodeAt(i)); dst.push(0); }
function concatFrames(frames: Uint8Array[]): Uint8Array { let len = 0; for (const f of frames) len += f.length; const out = new Uint8Array(len); let off = 0; for (const f of frames) { out.set(f, off); off += f.length; } return out; }
function assertBytes(actual: Uint8Array, expected: Uint8Array): void { expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]); }
function assertZeroed(buf: Uint8Array): void { for (let i = 0; i < buf.length; i += 1) expect(buf[i]).assertEqual(0); }
function asQueryOpts(v: QueryOptions | null): QueryOptions { return v as QueryOptions; }
function asSql(v: string | number): string { return v as string; }
function asParamList(v: PostgresParameter[] | null): PostgresParameter[] { return v as PostgresParameter[]; }
function asParam(v: PostgresParameter | null): PostgresParameter { return v as PostgresParameter; }
class ForgedInt4Parameter extends PostgresParameter {
  private reads: number = 0; constructor() { super(PostgresParameterType.Int4, 1); }
  get value(): PostgresParameterValue { this.reads += 1; return this.reads >= 1 ? 'bad' : 1; }
}
class InspectableByteaParameter extends PostgresParameter {
  lastRead: Uint8Array | null = null; constructor(b: Uint8Array) { super(PostgresParameterType.Bytea, b); }
  get value(): PostgresParameterValue { const v = super.value as Uint8Array; this.lastRead = v; return v; }
}
class LiveByteaParameter extends PostgresParameter {
  private readonly live: Uint8Array; constructor(live: Uint8Array) { super(PostgresParameterType.Bytea, new Uint8Array(0)); this.live = live; }
  get value(): PostgresParameterValue { return this.live; }
}
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> { let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; } expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError; }
