import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresAuthenticationCleartextPassword, PostgresAuthenticationGss,
  PostgresAuthenticationGssContinue, PostgresAuthenticationKerberosV5,
  PostgresAuthenticationMd5Password, PostgresAuthenticationOk,
  PostgresAuthenticationSasl, PostgresAuthenticationSaslContinue,
  PostgresAuthenticationSaslFinal, PostgresAuthenticationSspi,
  PostgresAuthenticationUnsupported, PostgresBackendKeyData,
  PostgresBackendMessage, PostgresBindComplete, PostgresCloseComplete,
  PostgresCommandComplete, PostgresCopyBothResponse, PostgresCopyData,
  PostgresCopyDone, PostgresCopyInResponse, PostgresCopyOutResponse,
  PostgresDataRow,
  PostgresEmptyQueryResponse, PostgresErrorResponse,
  PostgresNegotiateProtocolVersion, PostgresNoData,
  PostgresNoticeResponse, PostgresNotificationResponse,
  PostgresParameterDescription, PostgresParameterStatus, PostgresParseComplete,
  PostgresPortalSuspended, PostgresRowDescription,
  PostgresRowDescriptionColumn,
  PostgresReadyForQuery, PostgresReadyStatus,
  PostgresBackendParser, PostgresByteTransport, PostgresMessageChannel
} from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresBackendParserTest(): void {
  describe('PostgresBackendParser', () => {
    it('parsesAuthenticationOkFromItsLiteralBackendFrame', 0, async () => {
      const message = await parseFrame([
        0x52, 0x00, 0x00, 0x00, 0x08,
        0x00, 0x00, 0x00, 0x00
      ]);
      expect(message instanceof PostgresAuthenticationOk).assertTrue();
    });

    it('parsesEverySupportedAuthenticationRequestAndPreservesChallengeBytes', 0, async () => {
      expect((await parseFrame([
        0x52, 0, 0, 0, 8, 0, 0, 0, 2
      ])) instanceof PostgresAuthenticationKerberosV5).assertTrue();
      expect((await parseFrame([
        0x52, 0, 0, 0, 8, 0, 0, 0, 3
      ])) instanceof PostgresAuthenticationCleartextPassword).assertTrue();
      const md5 = await parseFrame([
        0x52, 0, 0, 0, 12, 0, 0, 0, 5, 0xde, 0xad, 0xbe, 0xef
      ]) as PostgresAuthenticationMd5Password;
      expect(md5 instanceof PostgresAuthenticationMd5Password).assertTrue();
      assertBytes(md5.salt, [0xde, 0xad, 0xbe, 0xef]);
      expect((await parseFrame([
        0x52, 0, 0, 0, 8, 0, 0, 0, 7
      ])) instanceof PostgresAuthenticationGss).assertTrue();
      const gss = await parseFrame([
        0x52, 0, 0, 0, 10, 0, 0, 0, 8, 0xaa, 0xbb
      ]) as PostgresAuthenticationGssContinue;
      expect(gss instanceof PostgresAuthenticationGssContinue).assertTrue();
      assertBytes(gss.data, [0xaa, 0xbb]);
      expect((await parseFrame([
        0x52, 0, 0, 0, 8, 0, 0, 0, 9
      ])) instanceof PostgresAuthenticationSspi).assertTrue();

      const sasl = await parseFrame([
        82, 0, 0, 0, 42, 0, 0, 0, 10,
        83, 67, 82, 65, 77, 45, 83, 72, 65, 45, 50, 53, 54, 0,
        83, 67, 82, 65, 77, 45, 83, 72, 65, 45, 50, 53, 54, 45,
        80, 76, 85, 83, 0, 0
      ]) as PostgresAuthenticationSasl;
      expect(sasl.mechanisms.length).assertEqual(2);
      expect(sasl.mechanisms[0]).assertEqual('SCRAM-SHA-256');
      expect(sasl.mechanisms[1]).assertEqual('SCRAM-SHA-256-PLUS');
      const saslContinue = await parseFrame([
        82, 0, 0, 0, 13, 0, 0, 0, 11, 114, 61, 97, 98, 99
      ]) as PostgresAuthenticationSaslContinue;
      expect(saslContinue instanceof PostgresAuthenticationSaslContinue).assertTrue();
      assertBytes(saslContinue.data, [114, 61, 97, 98, 99]);
      const saslFinal = await parseFrame([
        82, 0, 0, 0, 12, 0, 0, 0, 12, 118, 61, 111, 107
      ]) as PostgresAuthenticationSaslFinal;
      expect(saslFinal instanceof PostgresAuthenticationSaslFinal).assertTrue();
      assertBytes(saslFinal.data, [118, 61, 111, 107]);

      const unsupported = await parseFrame([
        82, 0, 0, 0, 10, 0, 0, 0, 99, 170, 187
      ]) as PostgresAuthenticationUnsupported;
      expect(unsupported instanceof PostgresAuthenticationUnsupported).assertTrue();
      expect(unsupported.code).assertEqual(99);
      assertBytes(unsupported.data, [0xaa, 0xbb]);
    });

    it('rejectsMalformedKnownAuthenticationRequests', 0, async () => {
      for (const frame of [
        [82, 0, 0, 0, 7, 0, 0, 0],
        [82, 0, 0, 0, 9, 0, 0, 0, 0, 1],
        [82, 0, 0, 0, 11, 0, 0, 0, 5, 1, 2, 3],
        [82, 0, 0, 0, 22, 0, 0, 0, 10,
          83, 67, 82, 65, 77, 45, 83, 72, 65, 45, 50, 53, 54, 0],
        [82, 0, 0, 0, 9, 0, 0, 0, 10, 0],
        [82, 0, 0, 0, 12, 0, 0, 0, 10, 192, 175, 0, 0],
        [82, 0, 0, 0, 31, 0, 0, 0, 10,
          65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85,
          0, 0],
        [82, 0, 0, 0, 15, 0, 0, 0, 10, 115, 99, 114, 97, 109, 0, 0],
        [82, 0, 0, 0, 139, 0, 0, 0, 10,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0,
          65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 65, 0, 0],
        [82, 0, 0, 0, 9, 0, 0, 0, 7, 1]
      ]) {
        await assertProtocolFrame(frame);
      }
    });

    it('preservesAllDiagnosticFieldsAndSkipsUnknownFields', 0, async () => {
      const error = await parseFrame([
        69, 0, 0, 0, 164, 83, 69, 82, 82, 79, 82, 0, 86, 69, 82, 82, 79, 82, 0,
        67, 50, 51, 53, 48, 53, 0, 77, 100, 117, 112, 108, 105, 99, 97, 116, 101, 0,
        68, 100, 101, 116, 97, 105, 108, 0, 72, 104, 105, 110, 116, 0, 80, 55, 0,
        112, 50, 0, 113, 115, 101, 108, 101, 99, 116, 32, 49, 0,
        87, 119, 104, 101, 114, 101, 0, 115, 112, 117, 98, 108, 105, 99, 0,
        116, 117, 115, 101, 114, 115, 0, 99, 101, 109, 97, 105, 108, 0,
        100, 116, 101, 120, 116, 0,
        110, 117, 115, 101, 114, 115, 95, 101, 109, 97, 105, 108, 95, 107, 101, 121, 0,
        70, 110, 98, 116, 105, 110, 115, 101, 114, 116, 46, 99, 0, 76, 54, 54, 52, 0,
        82, 95, 98, 116, 95, 99, 104, 101, 99, 107, 95, 117, 110, 105, 113, 117, 101, 0,
        88, 105, 103, 110, 111, 114, 101, 100, 0, 0
      ]) as PostgresErrorResponse;
      expect(error instanceof PostgresErrorResponse).assertTrue();
      expect(error.fields.localizedSeverity).assertEqual('ERROR');
      expect(error.fields.severity).assertEqual('ERROR');
      expect(error.fields.sqlState).assertEqual('23505');
      expect(error.fields.message).assertEqual('duplicate');
      expect(error.fields.detail).assertEqual('detail');
      expect(error.fields.hint).assertEqual('hint');
      expect(error.fields.position).assertEqual('7');
      expect(error.fields.internalPosition).assertEqual('2');
      expect(error.fields.internalQuery).assertEqual('select 1');
      expect(error.fields.where).assertEqual('where');
      expect(error.fields.schemaName).assertEqual('public');
      expect(error.fields.tableName).assertEqual('users');
      expect(error.fields.columnName).assertEqual('email');
      expect(error.fields.dataTypeName).assertEqual('text');
      expect(error.fields.constraintName).assertEqual('users_email_key');
      expect(error.fields.sourceFile).assertEqual('nbtinsert.c');
      expect(error.fields.sourceLine).assertEqual('664');
      expect(error.fields.sourceRoutine).assertEqual('_bt_check_unique');

      const notice = await parseFrame([
        78, 0, 0, 0, 35, 83, 78, 79, 84, 73, 67, 69, 0,
        86, 78, 79, 84, 73, 67, 69, 0, 67, 48, 48, 48, 48, 48, 0,
        77, 104, 101, 108, 108, 111, 0, 0
      ]);
      expect(notice instanceof PostgresNoticeResponse).assertTrue();
      expect((notice as PostgresNoticeResponse).fields.message).assertEqual('hello');

      const legacy = await parseFrame([
        69, 0, 0, 0, 26, 83, 69, 82, 82, 79, 82, 0,
        67, 50, 50, 48, 48, 48, 0, 77, 98, 97, 115, 105, 99, 0, 0
      ]) as PostgresErrorResponse;
      expect(legacy.fields.severity === undefined).assertTrue();
    });

    it('acceptsPresentButEmptyDiagnosticMessages', 0, async () => {
      const error = await parseFrame([
        69, 0, 0, 0, 21, 83, 69, 82, 82, 79, 82, 0,
        67, 48, 48, 48, 48, 48, 0, 77, 0, 0
      ]) as PostgresErrorResponse;
      expect(error.fields.message).assertEqual('');

      const notice = await parseFrame([
        78, 0, 0, 0, 22, 83, 78, 79, 84, 73, 67, 69, 0,
        67, 48, 48, 48, 48, 48, 0, 77, 0, 0
      ]) as PostgresNoticeResponse;
      expect(notice.fields.message).assertEqual('');
    });

    it('rejectsMalformedOrDuplicateDiagnosticFields', 0, async () => {
      for (const frame of [
        [69, 0, 0, 0, 29, 83, 69, 82, 82, 79, 82, 0,
          83, 69, 82, 82, 79, 82, 0, 67, 50, 51, 53, 48, 53, 0, 77, 120, 0, 0],
        [69, 0, 0, 0, 15, 83, 69, 82, 82, 79, 82, 0, 77, 120, 0, 0],
        [69, 0, 0, 0, 19, 83, 69, 82, 82, 79, 82, 0,
          67, 48, 48, 48, 48, 48, 0, 0],
        [78, 0, 0, 0, 20, 83, 78, 79, 84, 73, 67, 69, 0,
          67, 48, 48, 48, 48, 48, 0, 0],
        [69, 0, 0, 0, 15, 67, 48, 48, 48, 48, 48, 0, 77, 120, 0, 0],
        [78, 0, 0, 0, 15, 67, 48, 48, 48, 48, 48, 0, 77, 120, 0, 0],
        [69, 0, 0, 0, 21, 83, 69, 82, 82, 79, 82, 0,
          67, 50, 51, 53, 48, 53, 0, 77, 120, 0],
        [69, 0, 0, 0, 23, 83, 69, 82, 82, 79, 82, 0,
          67, 50, 51, 53, 48, 53, 0, 77, 120, 0, 0, 1],
        [69, 0, 0, 0, 22, 83, 69, 82, 82, 79, 82, 0,
          67, 50, 51, 120, 48, 53, 0, 77, 120, 0, 0],
        [69, 0, 0, 0, 25, 83, 69, 82, 82, 79, 82, 0,
          67, 50, 51, 53, 48, 53, 0, 77, 120, 0, 112, 50, 0, 0],
        [69, 0, 0, 0, 23, 83, 69, 82, 82, 79, 82, 0,
          67, 50, 51, 53, 48, 53, 0, 77, 192, 175, 0, 0]
      ]) {
        await assertProtocolFrame(frame);
      }
    });

    it('parsesSessionControlCompletionAndAsyncMessages', 0, async () => {
      const parameter = await parseFrame([
        83, 0, 0, 0, 25, 99, 108, 105, 101, 110, 116, 95, 101, 110, 99,
        111, 100, 105, 110, 103, 0, 85, 84, 70, 56, 0
      ]) as PostgresParameterStatus;
      expect(parameter.name).assertEqual('client_encoding');
      expect(parameter.value).assertEqual('UTF8');

      const key = await parseFrame([
        0x4b, 0, 0, 0, 12, 0, 0, 0, 42, 0xde, 0xad, 0xbe, 0xef
      ]) as PostgresBackendKeyData;
      expect(key.processId).assertEqual(42);
      assertBytes(key.secretKey, [0xde, 0xad, 0xbe, 0xef]);

      const idle = await parseFrame([0x5a, 0, 0, 0, 5, 0x49]) as PostgresReadyForQuery;
      const active = await parseFrame([0x5a, 0, 0, 0, 5, 0x54]) as PostgresReadyForQuery;
      const failed = await parseFrame([0x5a, 0, 0, 0, 5, 0x45]) as PostgresReadyForQuery;
      expect(idle.status).assertEqual(PostgresReadyStatus.Idle);
      expect(active.status).assertEqual(PostgresReadyStatus.InTransaction);
      expect(failed.status).assertEqual(PostgresReadyStatus.FailedTransaction);

      expect((await parseFrame([0x31, 0, 0, 0, 4])) instanceof
        PostgresParseComplete).assertTrue();
      expect((await parseFrame([0x32, 0, 0, 0, 4])) instanceof
        PostgresBindComplete).assertTrue();
      expect((await parseFrame([0x33, 0, 0, 0, 4])) instanceof
        PostgresCloseComplete).assertTrue();
      expect((await parseFrame([0x6e, 0, 0, 0, 4])) instanceof
        PostgresNoData).assertTrue();
      expect((await parseFrame([0x49, 0, 0, 0, 4])) instanceof
        PostgresEmptyQueryResponse).assertTrue();

      const notification = await parseFrame([
        65, 0, 0, 0, 21, 0, 0, 0, 42, 101, 118, 101, 110, 116, 115, 0,
        114, 101, 97, 100, 121, 0
      ]) as PostgresNotificationResponse;
      expect(notification.processId).assertEqual(42);
      expect(notification.channel).assertEqual('events');
      expect(notification.payload).assertEqual('ready');

      const negotiation = await parseFrame([
        118, 0, 0, 0, 30, 0, 0, 0, 2, 0, 0, 0, 2,
        95, 112, 113, 95, 46, 102, 111, 111, 0,
        95, 112, 113, 95, 46, 98, 97, 114, 0
      ]) as PostgresNegotiateProtocolVersion;
      expect(negotiation.newestMinorVersion).assertEqual(2);
      expect(negotiation.unsupportedOptions.length).assertEqual(2);
      expect(negotiation.unsupportedOptions[0]).assertEqual('_pq_.foo');
      expect(negotiation.unsupportedOptions[1]).assertEqual('_pq_.bar');
    });

    it('parsesRowDescriptionAndDataRowWithoutDecodingValues', 0, async () => {
      const description = await parseFrame([
        0x54, 0, 0, 0, 27, 0, 1, 105, 100, 0,
        0x89, 0xab, 0xcd, 0xef, 0xff, 0xfe,
        0xfe, 0xdc, 0xba, 0x98, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0, 1
      ]) as PostgresRowDescription;
      expect(description.columns.length).assertEqual(1);
      expect(description.columns[0].name).assertEqual('id');
      expect(description.columns[0].tableOid).assertEqual(2309737967);
      expect(description.columns[0].columnAttributeNumber).assertEqual(-2);
      expect(description.columns[0].typeOid).assertEqual(4275878552);
      expect(description.columns[0].typeSize).assertEqual(-1);
      expect(description.columns[0].typeModifier).assertEqual(-1);
      expect(description.columns[0].formatCode).assertEqual(1);

      const row = await parseFrame([
        0x44, 0, 0, 0, 21, 0, 3,
        0xff, 0xff, 0xff, 0xff,
        0, 0, 0, 0,
        0, 0, 0, 3, 0, 0xff, 1
      ]) as PostgresDataRow;
      expect(row.fields.length).assertEqual(3);
      expect(row.fields[0] === null).assertTrue();
      assertBytes(row.fields[1]!, []);
      assertBytes(row.fields[2]!, [0, 0xff, 1]);
    });

    it('parsesCommandParameterAndPortalMessagesWithoutInterpretation', 0, async () => {
      const command = await parseFrame([
        0x43, 0, 0, 0, 13, 85, 80, 68, 65, 84, 69, 32, 51, 0
      ]) as PostgresCommandComplete;
      expect(command.tag).assertEqual('UPDATE 3');

      const parameters = await parseFrame([
        0x74, 0, 0, 0, 18, 0, 3,
        0, 0, 0, 0, 0, 0, 0, 23, 0xff, 0xff, 0xff, 0xff
      ]) as PostgresParameterDescription;
      expect(parameters.typeOids.length).assertEqual(3);
      expect(parameters.typeOids[0]).assertEqual(0);
      expect(parameters.typeOids[1]).assertEqual(23);
      expect(parameters.typeOids[2]).assertEqual(4294967295);
      expect((await parseFrame([0x73, 0, 0, 0, 4])) instanceof
        PostgresPortalSuspended).assertTrue();
    });

    it('parsesEveryCopyDataMessageAndPreservesWireFormats', 0, async () => {
      const input = await parseFrame([
        0x47, 0, 0, 0, 11, 0, 0, 2, 0, 0, 0, 0
      ]) as PostgresCopyInResponse;
      expect(input.overallFormat).assertEqual(0);
      expect(input.columnFormats.length).assertEqual(2);
      expect(input.columnFormats[0]).assertEqual(0);
      expect(input.columnFormats[1]).assertEqual(0);

      const output = await parseFrame([
        0x48, 0, 0, 0, 7, 1, 0, 0
      ]) as PostgresCopyOutResponse;
      expect(output.overallFormat).assertEqual(1);
      expect(output.columnFormats.length).assertEqual(0);

      const both = await parseFrame([
        0x57, 0, 0, 0, 9, 1, 0, 1, 0, 1
      ]) as PostgresCopyBothResponse;
      expect(both.overallFormat).assertEqual(1);
      expect(both.columnFormats[0]).assertEqual(1);

      const data = await parseFrame([
        0x64, 0, 0, 0, 8, 0, 0xff, 1, 2
      ]) as PostgresCopyData;
      assertBytes(data.data, [0, 0xff, 1, 2]);
      expect((await parseFrame([0x63, 0, 0, 0, 4])) instanceof
        PostgresCopyDone).assertTrue();
    });

    it('rejectsMalformedDataQueryAndCopyMessages', 0, async () => {
      for (const frame of [
        [0x54, 0, 0, 0, 5, 0],
        [0x54, 0, 0, 0, 6, 0xff, 0xff],
        [0x54, 0, 0, 0, 7, 0, 1, 120],
        [0x54, 0, 0, 0, 27, 0, 1, 105, 100, 0,
          0x89, 0xab, 0xcd, 0xef, 0xff, 0xfe,
          0xfe, 0xdc, 0xba, 0x98, 0xff, 0xff,
          0xff, 0xff, 0xff, 0xff, 0, 2],
        [0x54, 0, 0, 0, 7, 0, 0, 1],
        [0x44, 0, 0, 0, 5, 0],
        [0x44, 0, 0, 0, 6, 0xff, 0xff],
        [0x44, 0, 0, 0, 10, 0, 1, 0xff, 0xff, 0xff, 0xfe],
        [0x44, 0, 0, 0, 11, 0, 1, 0, 0, 0, 2, 1],
        [0x44, 0, 0, 0, 7, 0, 0, 1],
        [0x43, 0, 0, 0, 4],
        [0x43, 0, 0, 0, 5, 120],
        [0x43, 0, 0, 0, 7, 0xc0, 0xaf, 0],
        [0x43, 0, 0, 0, 7, 120, 0, 1],
        [0x74, 0, 0, 0, 5, 0],
        [0x74, 0, 0, 0, 6, 0xff, 0xff],
        [0x74, 0, 0, 0, 9, 0, 1, 0, 0, 0],
        [0x74, 0, 0, 0, 7, 0, 0, 1],
        [0x73, 0, 0, 0, 5, 0],
        [0x63, 0, 0, 0, 5, 0],
        [0x47, 0, 0, 0, 7, 2, 0, 0],
        [0x48, 0, 0, 0, 6, 0, 0],
        [0x57, 0, 0, 0, 7, 0, 0xff, 0xff],
        [0x47, 0, 0, 0, 9, 0, 0, 1, 0, 2],
        [0x47, 0, 0, 0, 9, 0, 0, 1, 0, 1],
        [0x48, 0, 0, 0, 9, 0, 0, 0, 0, 0],
        [0x42, 0, 0, 0, 4]
      ]) {
        await assertProtocolFrame(frame);
      }
    });

    it('defensivelyCopiesRowColumnsAndRawDataBytes', 0, () => {
      const columns: PostgresRowDescriptionColumn[] = [
        new PostgresRowDescriptionColumn('id', 1, 2, 3, 4, 5, 0)
      ];
      const description = new PostgresRowDescription(columns);
      columns[0] = new PostgresRowDescriptionColumn('changed', 0, 0, 0, 0, 0, 0);
      expect(description.columns[0].name).assertEqual('id');

      const field = new Uint8Array([1, 2]);
      const fields: Array<Uint8Array | null> = [field];
      const row = new PostgresDataRow(fields);
      field[0] = 9;
      fields[0] = null;
      assertBytes(row.fields[0]!, [1, 2]);

      const copyBytes = new Uint8Array([3, 4]);
      const copy = new PostgresCopyData(copyBytes);
      copyBytes[0] = 9;
      assertBytes(copy.data, [3, 4]);
    });

    it('rejectsOversizedDataMessagePayloadsBeforeDecoding', 0, () => {
      const payload = new Uint8Array(33554429);
      payload[1] = 1;
      payload[2] = 1;
      payload[3] = 0xff;
      payload[4] = 0xff;
      payload[5] = 0xf7;
      for (const type of [0x54, 0x44, 0x43, 0x74, 0x47, 0x48, 0x57, 0x64]) {
        let failure: ArkDbError | null = null;
        try {
          PostgresBackendParser.parse({ type: type, payload: payload });
        } catch (error) {
          failure = error as ArkDbError;
        }
        expect(failure instanceof ArkDbError).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
      }
    });

    it('rejectsMalformedControlAsyncAndUnknownMessageFrames', 0, async () => {
      for (const frame of [
        [0x52, 0, 0, 0, 3],
        [0x52, 0, 0, 0, 8, 0, 0, 0],
        [83, 0, 0, 0, 14, 110, 97, 109, 101, 0, 118, 97, 108, 117, 101],
        [75, 0, 0, 0, 11, 0, 0, 0, 1, 1, 2, 3],
        [75, 0, 0, 0, 13, 0, 0, 0, 1, 1, 2, 3, 4, 5],
        [90, 0, 0, 0, 5, 88],
        [90, 0, 0, 0, 6, 73, 0],
        [49, 0, 0, 0, 5, 0],
        [65, 0, 0, 0, 20, 0, 0, 0, 1, 99, 104, 97, 110, 0,
          112, 97, 121, 108, 111, 97, 100],
        [118, 0, 0, 0, 12, 0, 0, 0, 1, 255, 255, 255, 255],
        [118, 0, 0, 0, 12, 0, 0, 0, 1, 0, 1, 0, 0],
        [118, 0, 0, 0, 13, 0, 0, 0, 1, 0, 0, 0, 1, 0],
        [118, 0, 0, 0, 15, 0, 0, 0, 1, 0, 0, 0, 1, 120, 0, 0],
        [118, 0, 0, 0, 15, 0, 0, 0, 1, 0, 0, 0, 1, 192, 175, 0],
        [89, 0, 0, 0, 4]
      ]) {
        await assertProtocolFrame(frame);
      }
    });
  });
}

async function parseFrame(frame: number[]): Promise<PostgresBackendMessage> {
  const channel = new PostgresMessageChannel(
    new LiteralFrameTransport(new Uint8Array(frame)));
  return PostgresBackendParser.parse(await channel.readMessage());
}

async function assertProtocolFrame(frame: number[]): Promise<void> {
  let failure: ArkDbError | null = null;
  try {
    await parseFrame(frame);
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

class LiteralFrameTransport implements PostgresByteTransport {
  private readonly frame: Uint8Array;
  private offset: number = 0;

  constructor(frame: Uint8Array) {
    this.frame = frame;
  }

  async read(maximumBytes: number): Promise<Uint8Array | null> {
    if (this.offset >= this.frame.length) return null;
    const end = Math.min(this.offset + maximumBytes, this.frame.length);
    const value = this.frame.subarray(this.offset, end);
    this.offset = end;
    return value;
  }

  async write(_data: Uint8Array): Promise<number> {
    return 0;
  }
}
