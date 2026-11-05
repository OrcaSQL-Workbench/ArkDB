import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, QueryOptions } from '@arkdb/core';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../../main/ets/mysql/features/prepared/PreparedStatement';
import {
  MySqlPreparedStatement
} from '../../../../main/ets/mysql/api/MySqlPreparedContracts';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandLifecycleObserver, MySqlCommandScope
} from '../../../../main/ets/mysql/execution/MySqlCommandGate';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlQueryResultMeta, MySqlQueryResultSink, MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../../main/ets/mysql/model/MySqlQueryStream';
import { Capabilities } from '../../../../main/ets/mysql/protocol/Constants';
import { PacketChannel } from '../../../../main/ets/mysql/protocol/PacketChannel';
import { PacketWriter } from '../../../../main/ets/mysql/protocol/PacketWriter';
import { PacketTransportFixture } from '../../protocol/fixtures/PacketTransportFixture';
import {
  PreparedTransport, PreparedChannel, ReleaseFailureGate, PreparedHost,
  PreparedObservation, CloseEntry, CloseObservation, RecordingSink,
  StatementCloseStartObserver, SessionCloseStartObserver, expectReuseAtRepeatedSessionClose, expectPendingCloseJoined,
  expectOwnedCloseFailureJoined, expectUnknownMetadataRejected, expectOwnedPrepareOverlapRejected, capturePrepared,
  captureCommandFailure, expectProtocolError, prepareSuccessfully, expectProtocol,
  observeFailure, asOperation, throwFixtureFailure, nextTask,
  prepareOk, serverErr, column, eof,
  frame, assertBytes
} from './fixtures/PreparedStatementFixture';

export default function preparedStatementValidationTest(): void {
  describe('MySQL internal prepared lifecycle', () => {
    it('rejectsDisconnectedOpeningClosedAndExternallyQueryingSessionsBeforeDispatch', 0, async () => {
      const states = [ConnectionState.Idle, ConnectionState.Connecting, ConnectionState.Authenticating,
        ConnectionState.Closed, ConnectionState.Error, ConnectionState.Querying];
      for (const state of states) {
        const host = new PreparedHost([]);
        host.state = state;
        const error = await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1'));
        expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(host.transport.writes.length).assertEqual(0);
        expect(host.transport.readAttempts).assertEqual(0);
        expect(host.retirements.length).assertEqual(0);
        expect(host.commandGate.current === null).assertTrue();
      }
    });

    it('rejectsPrepareClosedDuringWriteBeforeReadingAnyResponse', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      host.transport.holdWriteAt = 1;
      const session = new MySqlPreparedSession(host);
      const pending = session.prepare('DO 1');
      await nextTask();
      host.state = ConnectionState.Closed;
      host.channel = null;
      host.transport.releaseWrite();
      const error = asOperation(await observeFailure(() => pending));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(host.transport.readAttempts).assertEqual(0);
      expect(host.retirements.length).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('rejectsPhysicalSessionReplacementDuringMetadataWithoutClosingTheReplacement', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 1), column('old'), eof()]]);
      host.transport.holdReadAt = 3;
      const session = new MySqlPreparedSession(host);
      const pending = session.prepare('SELECT 1');
      await nextTask();
      const replacement = new PreparedTransport([frame(prepareOk(1, 0, 0), 1)]);
      host.channel = new PacketChannel(replacement);
      host.transport.releaseRead();
      const error = asOperation(await observeFailure(() => pending));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(host.retirements.length).assertEqual(0);
      expect(host.state).assertEqual(ConnectionState.Ready);
      expect(replacement.writes.length).assertEqual(0);
      const next = await prepareSuccessfully(new MySqlPreparedSession(host), 'DO 2');
      expect(next.closed).assertFalse();
      expect(replacement.writes.length).assertEqual(1);
    });

    it('preservesConsumedFirstPacketErrWithoutRetiringOtherHandles', 0, async () => {
      const host = new PreparedHost([
        [prepareOk(1, 0, 0)], [serverErr(1064, '42000')], [prepareOk(3, 0, 0)]
      ]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const error = asOperation(await observeFailure(() => session.prepare('invalid sql')));
      expect(error.kind).assertEqual(ArkDbErrorKind.Server);
      expect(error.nativeCode).assertEqual(1064);
      expect(error.code).assertEqual(1064);
      expect(error.sqlState).assertEqual('42000');
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
      expect(error.cleanupErrors.length).assertEqual(0);
      expect(error.originalCause === undefined).assertTrue();
      expect(first.closed).assertFalse();
      expect(host.retirements.length).assertEqual(0);
      expect(host.state).assertEqual(ConnectionState.Ready);
      const next = await prepareSuccessfully(session, 'DO 3');
      expect(next.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(3);
    });

    it('rejectsTruncatedWrongHeaderFillerAndTrailingPrepareOkBytes', 0, async () => {
      const valid = prepareOk(1, 0, 0);
      const malformed: Uint8Array[] = [];
      for (let length = 0; length < 10; length += 1) malformed.push(valid.subarray(0, length));
      malformed.push(valid.subarray(0, 11));
      const filler = new Uint8Array(valid);
      filler[9] = 1;
      malformed.push(filler);
      const header = new Uint8Array(valid);
      header[0] = 1;
      malformed.push(header);
      const trailing = new Uint8Array(valid.length + 1);
      trailing.set(valid);
      malformed.push(trailing);
      malformed.push(new Uint8Array([0xff, 0x28, 0x04]));
      malformed.push(new Uint8Array([0xff, 0x28, 0x04, 0x23, 0x34, 0x32]));
      for (const payload of malformed) {
        const host = new PreparedHost([[payload]]);
        const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1')));
        expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(host.retirements.length).assertEqual(1);
        expect(host.state).assertEqual(ConnectionState.Closed);
        expect(host.commandGate.current === null).assertTrue();
      }
    });

    it('checksParameterAndColumnMetadataLengthsNullsAndFillersBeforeReturningAHandle', 0, async () => {
      const valid = column('field');
      const malformed = [new Uint8Array([0xfb]), new Uint8Array([0xfe, 1]),
        new Uint8Array([3, 0x64]), valid.subarray(0, valid.length - 1)];
      const fixedLength = new Uint8Array(valid);
      fixedLength[fixedLength.length - 13] = 11;
      malformed.push(fixedLength);
      const nullSchema = new Uint8Array(valid);
      nullSchema[4] = 0xfb;
      malformed.push(nullSchema);
      const filler = new Uint8Array(valid);
      filler[filler.length - 1] = 1;
      malformed.push(filler);
      const trailing = new Uint8Array(valid.length + 1);
      trailing.set(valid);
      malformed.push(trailing);
      for (const payload of malformed) {
        for (let parameters = 0; parameters < 2; parameters += 1) {
          const host = new PreparedHost([[prepareOk(1, parameters, 1 - parameters), payload, eof()]]);
          const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('SELECT ?')));
          expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(host.retirements.length).assertEqual(1);
          expect(host.state).assertEqual(ConnectionState.Closed);
          expect(host.commandGate.current === null).assertTrue();
        }
      }
    });

    it('requiresExactClassicMetadataEofRatherThanAnOkReplacementOrMissingTerminator', 0, async () => {
      const malformed = [new Uint8Array(0), new Uint8Array([0xfe]), new Uint8Array([0xfe, 0, 0]),
        new Uint8Array([0, 0, 0, 2, 0, 0, 0]), new Uint8Array([0xfe, 0, 0, 2, 0, 0])];
      for (const payload of malformed) {
        const host = new PreparedHost([[prepareOk(1, 1, 0), column('parameter'), payload]]);
        const error = await observeFailure(() => new MySqlPreparedSession(host).prepare('DO ?'));
        expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(host.retirements.length).assertEqual(1);
      }
      const missing = new PreparedHost([[prepareOk(1, 0, 1), column('result')]]);
      expect((await observeFailure(() => new MySqlPreparedSession(missing).prepare('SELECT 1'))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(missing.retirements.length).assertEqual(1);
    });

    it('retiresOnErrInsideEitherMetadataBlockOrTerminator', 0, async () => {
      const errorPacket = serverErr(1615, 'HY000');
      const responses = [
        [prepareOk(2, 1, 0), errorPacket],
        [prepareOk(2, 1, 0), column('p'), errorPacket],
        [prepareOk(2, 0, 1), errorPacket],
        [prepareOk(2, 0, 1), column('c'), errorPacket]
      ];
      for (const response of responses) {
        const host = new PreparedHost([[prepareOk(1, 0, 0)], response]);
        const session = new MySqlPreparedSession(host);
        const first = await prepareSuccessfully(session, 'DO 1');
        const error = asOperation(await observeFailure(() => session.prepare('SELECT ?')));
        expect(error.kind).assertEqual(ArkDbErrorKind.Server);
        expect(error.code).assertEqual(1615);
        expect(error.sqlState).assertEqual('HY000');
        expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(first.closed).assertTrue();
        expect(host.retirements.length).assertEqual(1);
        expect(host.state).assertEqual(ConnectionState.Closed);
        await first.close();
        expect(host.transport.writes.length).assertEqual(2);
      }
    });

    it('doesNotTrustServerShapedReadErrorsAsConsumedWireRejections', 0, async () => {
      const host = new PreparedHost([]);
      const primary = ArkDbError.server('Synthetic read failure.', 1317, '70100');
      host.transport.failReadAt = 1;
      host.transport.readFailure = new MySqlOperationError(primary, [], MySqlExecutionOutcome.ServerRejected);
      const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1')));
      expect(error.primary === primary).assertTrue();
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(host.retirements.length).assertEqual(1);
      expect(host.state).assertEqual(ConnectionState.Closed);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('retiresAllHandlesWhenTheServerDuplicatesAnActiveStatementIdentifier', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(7, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const error = await observeFailure(() => session.prepare('DO 2'));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(first.closed).assertTrue();
      expect(host.retirements.length).assertEqual(1);
      await first.close();
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('rejectsUnsupportedMetadataNegotiationBeforeAnyWireDispatch', 0, async () => {
      const modes = [0, Capabilities.PROTOCOL_41 | 0x02000000];
      for (const capabilities of modes) {
        const host = new PreparedHost([], capabilities);
        const error = await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1'));
        expect(error.kind).assertEqual(ArkDbErrorKind.Unsupported);
        expect(host.transport.writes.length).assertEqual(0);
        expect(host.transport.readAttempts).assertEqual(0);
        expect(host.retirements.length).assertEqual(0);
        expect(host.commandGate.current === null).assertTrue();
      }
    });

    it('enforcesTheUtf8PrepareBudgetAndUsesExistingLogicalPacketFragmentation', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]], Capabilities.PROTOCOL_41, [2]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'x'.repeat(16777215));
      expect(statement.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.writes[0].length).assertEqual(16777219);
      expect(host.transport.writes[0][0]).assertEqual(0xff);
      expect(host.transport.writes[0][1]).assertEqual(0xff);
      expect(host.transport.writes[0][2]).assertEqual(0xff);
      expect(host.transport.writes[0][3]).assertEqual(0);
      expect(host.transport.writes[0][4]).assertEqual(0x16);
      assertBytes(host.transport.writes[1], [1, 0, 0, 1, 0x78]);
      const rejected = new PreparedHost([]);
      const rejectedSession = new MySqlPreparedSession(rejected);
      expect((await observeFailure(() => rejectedSession.prepare('x'.repeat(16777216)))).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      expect((await observeFailure(() => rejectedSession.prepare('\u4e2d'.repeat(5592406)))).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      expect(rejected.transport.writes.length).assertEqual(0);
      expect(rejected.transport.readAttempts).assertEqual(0);
      expect(rejected.retirements.length).assertEqual(0);
    });

    it('rejectsUnknownParameterMetadataAndRetiresThePhysicalSession', 0, async () => {
      await expectUnknownMetadataRejected(true);
    });
  });
}
