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

export default function preparedStatementMetadataTest(): void {
  describe('MySQL internal prepared lifecycle', () => {
    it('consumesPrepareParametersAndColumns', 0, async () => {
      const host = new PreparedHost([[
        prepareOk(0x12345678, 2, 1), column('first'), column('second'), eof(),
        column('answer'), eof()
      ]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'SELECT ?, ?');
      expect(statement.parameterCount).assertEqual(2);
      expect(statement.columns.length).assertEqual(1);
      expect(statement.columns[0].name).assertEqual('answer');
      expect(host.transport.requestedLengths.length).assertEqual(12);
      expect(statement.closed).assertFalse();
      assertBytes(host.transport.writes[0],
        [12, 0, 0, 0, 0x16, 83, 69, 76, 69, 67, 84, 32, 63, 44, 32, 63]);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('closeDoesNotReadAck', 0, async () => {
      const host = new PreparedHost([[prepareOk(0x12345678, 0, 0)]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'DO 1');
      const readsBeforeClose = host.transport.requestedLengths.length;
      await statement.close();
      expect(statement.closed).assertTrue();
      expect(host.transport.requestedLengths.length).assertEqual(readsBeforeClose);
      expect(host.transport.writes.length).assertEqual(2);
      assertBytes(host.transport.writes[1], [5, 0, 0, 0, 0x19, 0x78, 0x56, 0x34, 0x12]);
      await statement.close();
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('rejectsForeignOrStaleHandle', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)]]);
      const foreignHost = new PreparedHost([]);
      const session = new MySqlPreparedSession(host);
      const foreignSession = new MySqlPreparedSession(foreignHost);
      const statement = await prepareSuccessfully(session, 'DO 1');
      const foreignScope = foreignHost.commandGate.reserve(MySqlCommandKind.Prepare);
      expectProtocol((): void => { foreignSession.assertUsable(foreignScope, statement); });
      foreignHost.commandGate.release(foreignScope);

      host.commandGate.advanceGeneration();
      const scope = host.commandGate.reserve(MySqlCommandKind.Prepare);
      expectProtocol((): void => { session.assertUsable(scope, statement); });
      host.commandGate.release(scope);
      expect(statement.closed).assertTrue();
      expect(host.transport.writes.length).assertEqual(1);
      expect(foreignHost.transport.writes.length).assertEqual(0);
    });

    it('omitsBothMetadataEofsWhenNegotiatedWithoutReadingTheNextResponse', 0, async () => {
      const host = new PreparedHost([
        [prepareOk(1, 2, 1), column('p1'), column('p2'), column('answer')],
        [prepareOk(2, 0, 0)]
      ], Capabilities.PROTOCOL_41 | Capabilities.DEPRECATE_EOF);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'SELECT ?, ?');
      expect(first.parameterCount).assertEqual(2);
      expect(first.columns[0].name).assertEqual('answer');
      expect(host.transport.requestedLengths.length).assertEqual(8);
      const second = await prepareSuccessfully(session, 'DO 1');
      expect(second.parameterCount).assertEqual(0);
      expect(second.columns.length).assertEqual(0);
      expect(host.transport.requestedLengths.length).assertEqual(10);
      await first.close();
      await second.close();
      expect(host.transport.requestedLengths.length).assertEqual(10);
    });

    it('consumesParameterOnlyAndColumnOnlyMetadataInBothEofModes', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const parameters = [prepareOk(1, 1, 0), column('parameter')];
        const columns = [prepareOk(2, 0, 1), column('result')];
        if (mode === 0) {
          parameters.push(eof());
          columns.push(eof());
        }
        const host = new PreparedHost([parameters, columns],
          Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
        const session = new MySqlPreparedSession(host);
        const parameterOnly = await prepareSuccessfully(session, 'DO ?');
        expect(parameterOnly.parameterCount).assertEqual(1);
        expect(parameterOnly.columns.length).assertEqual(0);
        const columnOnly = await prepareSuccessfully(session, 'SELECT 1');
        expect(columnOnly.parameterCount).assertEqual(0);
        expect(columnOnly.columns[0].name).assertEqual('result');
        expect(host.transport.requestedLengths.length).assertEqual(mode === 0 ? 12 : 8);
      }
    });

    it('readsNoMetadataOrEofForZeroCountsIncludingWarninglessOk', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const host = new PreparedHost([
          [prepareOk(0xffffffff, 0, 0).subarray(0, 10)],
          [prepareOk(2, 0, 0)]
        ], Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
        const session = new MySqlPreparedSession(host);
        const first = await prepareSuccessfully(session, 'DO 1');
        expect(first.parameterCount).assertEqual(0);
        expect(first.columns.length).assertEqual(0);
        expect(host.transport.requestedLengths.length).assertEqual(2);
        await first.close();
        assertBytes(host.transport.writes[1], [5, 0, 0, 0, 0x19, 0xff, 0xff, 0xff, 0xff]);
        await prepareSuccessfully(session, 'DO 2');
        expect(host.transport.requestedLengths.length).assertEqual(4);
      }
    });

    it('returnsDefensivePrepareTimeColumnSnapshots', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 1), column('answer'), eof()]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'SELECT 1');
      const first = statement.columns;
      expect(first[0].sourceSchema).assertEqual('schema');
      expect(first[0].sourceCatalog).assertEqual('schema');
      expect(first[0].sourceTable).assertEqual('table');
      expect(first[0].table).assertEqual('table');
      expect(first[0].nativeTypeId).assertEqual('253');
      expect(first[0].nativeTypeName).assertEqual('TEXT');
      expect(first[0].valueKind).assertEqual('text');
      expect(first[0].nullable).assertTrue();
      expect(first[0].type).assertEqual(0xfd);
      expect(first[0].charset).assertEqual(45);
      expect(first[0].columnLength).assertEqual(255);
      expect(first[0].flags).assertEqual(0);
      expect(first[0].decimals).assertEqual(0);
      first[0].name = 'changed';
      first[0].sourceSchema = 'changed';
      first.length = 0;
      expect(statement.columns.length).assertEqual(1);
      expect(statement.columns[0].name).assertEqual('answer');
      expect(statement.columns[0].sourceSchema).assertEqual('schema');
    });

    it('closesMultipleHandlesIndependentlyAndAllowsServerIdReuseAfterClose', 0, async () => {
      const host = new PreparedHost([
        [prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)], [prepareOk(1, 0, 0)]
      ]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const second = await prepareSuccessfully(session, 'DO 2');
      await first.close();
      expect(first.closed).assertTrue();
      expect(second.closed).assertFalse();
      const scope = host.commandGate.reserve(MySqlCommandKind.Prepare);
      session.assertUsable(scope, second);
      expectProtocol((): void => { session.assertUsable(scope, first); });
      host.commandGate.release(scope);
      const reused = await prepareSuccessfully(session, 'DO 3');
      expect(reused.closed).assertFalse();
      await first.close();
      expect(host.transport.writes.length).assertEqual(4);
      await second.close();
      await reused.close();
      expect(host.transport.writes.length).assertEqual(6);
    });

    it('rejectsChangedPhysicalChannelEvenWithMatchingServerIdsAndGeneration', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)]]);
      const oldSession = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(oldSession, 'DO 1');
      const replacement = new PreparedTransport([frame(prepareOk(7, 0, 0), 1)]);
      host.channel = new PacketChannel(replacement);
      const newSession = new MySqlPreparedSession(host);
      const replacementStatement = await prepareSuccessfully(newSession, 'DO 2');
      const scope = host.commandGate.reserve(MySqlCommandKind.Prepare);
      expectProtocol((): void => { oldSession.assertUsable(scope, statement); });
      expectProtocol((): void => { newSession.assertUsable(scope, statement); });
      newSession.assertUsable(scope, replacementStatement);
      host.commandGate.release(scope);
      await statement.close();
      expect(statement.closed).assertTrue();
      expect(replacementStatement.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(1);
      expect(replacement.writes.length).assertEqual(1);
    });

    it('keepsExecutionAndStreamingExplicitlyUnsupportedWithoutWireOrCallbacks', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'DO 1');
      const sink = new RecordingSink();
      const executeError = await observeFailure(() => statement.execute([]));
      const streamError = await observeFailure(() => statement.executeStream([], new QueryOptions(), sink));
      expect(executeError.kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(streamError.kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(sink.calls).assertEqual(0);
      expect(statement.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(1);
      expect(host.transport.requestedLengths.length).assertEqual(2);
      await statement.close();
      const closedError = await observeFailure(() => statement.execute([]));
      expect(closedError.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('preservesCloseWritePrimaryAndPhysicalRetirementCleanup', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const second = await prepareSuccessfully(session, 'DO 2');
      const primary = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic write failure.', 2006, 'HY000');
      const cleanup = ArkDbError.timeout('Synthetic socket retirement failure.');
      host.transport.failWriteAt = 3;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      const reads = host.transport.readAttempts;
      const error = asOperation(await observeFailure(() => first.close()));
      expect(error.primary === primary).assertTrue();
      expect(error.nativeCode).assertEqual(2006);
      expect(error.code).assertEqual(2006);
      expect(error.sqlState).assertEqual('HY000');
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(error.cleanupErrors.length).assertEqual(1);
      expect(error.cleanupErrors[0] === cleanup).assertTrue();
      expect(first.closed).assertTrue();
      expect(second.closed).assertTrue();
      expect(host.state).assertEqual(ConnectionState.Closed);
      expect(host.retirements.length).assertEqual(1);
      expect(host.transport.readAttempts).assertEqual(reads);
      expect(host.commandGate.current === null).assertTrue();
      expect((await observeFailure(() => first.close())) === error).assertTrue();
      await second.close();
      expect(host.transport.writes.length).assertEqual(3);
    });

    it('doesNotTrustServerShapedWriteErrorsAsConsumedPrepareRejections', 0, async () => {
      const host = new PreparedHost([]);
      const primary = ArkDbError.server('Synthetic transport rejection.', 1317, '70100');
      const cleanup = ArkDbError.network('Synthetic retirement failure.');
      host.transport.failWriteAt = 1;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      const session = new MySqlPreparedSession(host);
      const error = asOperation(await observeFailure(() => session.prepare('DO 1')));
      expect(error.primary === primary).assertTrue();
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(error.code).assertEqual(1317);
      expect(error.sqlState).assertEqual('70100');
      expect(error.cleanupErrors.length).assertEqual(1);
      expect(error.cleanupErrors[0] === cleanup).assertTrue();
      expect(host.retirements.length).assertEqual(1);
      expect(host.transport.readAttempts).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
      const stale = await observeFailure(() => session.prepare('DO 2'));
      expect(stale.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(host.transport.writes.length).assertEqual(1);
    });

    it('retainsOrdinaryWriteAndRetirementCausesWithoutMaskingEither', 0, async () => {
      const host = new PreparedHost([]);
      const primary = new Error('Synthetic non-driver write failure.');
      const cleanup = new Error('Synthetic non-driver retirement failure.');
      host.transport.failWriteAt = 1;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1')));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(error.originalCause === primary).assertTrue();
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(error.cleanupErrors.length).assertEqual(1);
      expect(asOperation(error.cleanupErrors[0]).originalCause === cleanup).assertTrue();
      expect(host.state).assertEqual(ConnectionState.Closed);
      expect(host.commandGate.current === null).assertTrue();
    });
  });
}
