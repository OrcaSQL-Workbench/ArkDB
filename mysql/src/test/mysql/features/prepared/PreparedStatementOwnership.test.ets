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

export default function preparedStatementOwnershipTest(): void {
  describe('MySQL internal prepared lifecycle', () => {
    it('rejectsUnknownResultMetadataAndRetiresThePhysicalSession', 0, async () => {
      await expectUnknownMetadataRejected(false);
    });

    it('rejectsOwnedPrepareOverlapBeforeResetWriteOrRead', 0, async () => {
      await expectOwnedPrepareOverlapRejected(false, false);
    });

    it('rejectsOwnedCloseDuringPrepareWithoutInvalidatingTheOtherHandle', 0, async () => {
      await expectOwnedPrepareOverlapRejected(false, true);
    });

    it('rejectsOwnedPrepareOverlapAcrossLifecycleObjectsSharingThePhysicalChannel', 0, async () => {
      await expectOwnedPrepareOverlapRejected(true, false);
    });

    it('rejectsOwnedCloseDuringAnotherLifecycleObjectsPrepare', 0, async () => {
      await expectOwnedPrepareOverlapRejected(true, true);
    });

    it('rejectsOwnedPrepareDuringAnotherLifecycleObjectsPendingClose', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)]]);
      const owner = new MySqlPreparedSession(host);
      const other = new MySqlPreparedSession(host);
      const existing = await prepareSuccessfully(owner, 'DO 7');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      host.transport.holdWriteAt = 2;
      const pending = captureCommandFailure(owner.closeOwned(scope, existing));
      await nextTask();
      const writes = host.transport.writes.length;
      const reads = host.transport.readAttempts;
      const resets = host.initialChannel.resets;
      const phase = scope.phase;
      const overlap = await capturePrepared(other.prepareOwned(scope, 'DO 8'));
      const writesAfter = host.transport.writes.length;
      const readsAfter = host.transport.readAttempts;
      const resetsAfter = host.initialChannel.resets;
      const phaseAfter = scope.phase;
      host.transport.releaseWrite();
      const firstError = await pending;
      let sequential: PreparedObservation | null = null;
      try {
        if (firstError === null && overlap.error !== null && host.state === ConnectionState.Ready) {
          sequential = await capturePrepared(other.prepareOwned(scope, 'DO 8'));
          if (sequential.statement !== null) await other.closeOwned(scope, sequential.statement);
        }
      } finally {
        host.commandGate.release(scope);
      }
      expectProtocolError(overlap.error);
      expect(writesAfter).assertEqual(writes);
      expect(readsAfter).assertEqual(reads);
      expect(resetsAfter).assertEqual(resets);
      expect(phaseAfter).assertEqual(phase);
      expect(firstError === null).assertTrue();
      expect(existing.closed).assertTrue();
      expect(sequential !== null && sequential.error === null).assertTrue();
      expect(host.retirements.length).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('rejectsOwnedCloseOverlapAcrossLifecycleObjectsBeforeInvalidatingAnotherHandle', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)]]);
      const owner = new MySqlPreparedSession(host);
      const other = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(owner, 'DO 7');
      const second = await prepareSuccessfully(other, 'DO 8');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      host.transport.holdWriteAt = 3;
      const pending = captureCommandFailure(owner.closeOwned(scope, first));
      await nextTask();
      const writes = host.transport.writes.length;
      const reads = host.transport.readAttempts;
      const resets = host.initialChannel.resets;
      const phase = scope.phase;
      const overlapError = await captureCommandFailure(other.closeOwned(scope, second));
      const writesAfter = host.transport.writes.length;
      const readsAfter = host.transport.readAttempts;
      const resetsAfter = host.initialChannel.resets;
      const phaseAfter = scope.phase;
      const secondStillOpen = !second.closed;
      host.transport.releaseWrite();
      const firstError = await pending;
      try {
        if (secondStillOpen && firstError === null) await other.closeOwned(scope, second);
      } finally {
        host.commandGate.release(scope);
      }
      expectProtocolError(overlapError);
      expect(writesAfter).assertEqual(writes);
      expect(readsAfter).assertEqual(reads);
      expect(resetsAfter).assertEqual(resets);
      expect(phaseAfter).assertEqual(phase);
      expect(firstError === null).assertTrue();
      expect(secondStillOpen).assertTrue();
      expect(first.closed).assertTrue();
      expect(second.closed).assertTrue();
      expect(host.retirements.length).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('acceptsEveryCurrentlySupportedMetadataTypeInBothPrepareBlocks', 0, async () => {
      const types = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff];
      for (let mode = 0; mode < 2; mode += 1) {
        const response = [prepareOk(1, types.length, types.length)];
        for (const type of types) response.push(column('parameter', type));
        if (mode === 0) response.push(eof());
        for (const type of types) response.push(column('result', type));
        if (mode === 0) response.push(eof());
        const host = new PreparedHost([response],
          Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
        const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'SELECT ?');
        expect(statement.parameterCount).assertEqual(28);
        expect(statement.columns.length).assertEqual(28);
        for (let index = 0; index < types.length; index += 1) {
          expect(statement.columns[index].type).assertEqual(types[index]);
        }
        expect(host.transport.readAttempts).assertEqual(mode === 0 ? 118 : 114);
        await statement.close();
        expect(host.retirements.length).assertEqual(0);
      }
    });

    it('joinsPendingOwnedCloseAcrossAllValidEntryPoints', 0, async () => {
      await expectPendingCloseJoined(CloseEntry.Owned);
    });

    it('joinsPendingSessionCloseAcrossHandleAndOwnedEntryPoints', 0, async () => {
      await expectPendingCloseJoined(CloseEntry.Session);
    });

    it('joinsPendingHandleCloseAcrossSessionAndOwnedEntryPoints', 0, async () => {
      await expectPendingCloseJoined(CloseEntry.Handle);
    });

    it('sharesOwnedCloseWriteAndRetirementFailureDuringAndAfterCleanup', 0, async () => {
      await expectOwnedCloseFailureJoined(false);
    });

    it('preservesOrdinaryOwnedCloseCausesForEveryRepeatedEntryPoint', 0, async () => {
      await expectOwnedCloseFailureJoined(true);
    });

    it('rejectsForeignAndStaleScopesBeforeJoiningTheOwnedClose', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 7');
      const stale = host.commandGate.reserve(MySqlCommandKind.Transaction);
      host.commandGate.release(stale);
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      const foreignHost = new PreparedHost([]);
      const foreignSession = new MySqlPreparedSession(foreignHost);
      const foreignScope = foreignHost.commandGate.reserve(MySqlCommandKind.Transaction);
      host.transport.holdWriteAt = 2;
      const first = new CloseObservation(session.closeOwned(scope, statement));
      await nextTask();
      const rejected = [
        new CloseObservation(session.closeOwned(stale, statement)),
        new CloseObservation(session.closeOwned(foreignScope, statement)),
        new CloseObservation(foreignSession.close(statement))
      ];
      await nextTask();
      const allRejectedBeforeFirstSettled = rejected.every((entry: CloseObservation): boolean =>
        entry.settled && entry.error instanceof ArkDbError &&
        entry.error.kind === ArkDbErrorKind.Protocol);
      const firstStillPending = !first.settled;
      const sameScope = host.commandGate.current === scope;
      const writes = host.transport.writes.length;
      const reads = host.transport.readAttempts;
      const resets = host.initialChannel.resets;
      host.transport.releaseWrite();
      await first.done;
      for (const entry of rejected) await entry.done;
      const staleAfter = await captureCommandFailure(session.closeOwned(stale, statement));
      foreignHost.commandGate.release(foreignScope);
      host.commandGate.release(scope);
      expect(allRejectedBeforeFirstSettled).assertTrue();
      expect(firstStillPending).assertTrue();
      expect(sameScope).assertTrue();
      expect(first.error === null).assertTrue();
      expectProtocolError(staleAfter);
      expect(writes).assertEqual(2);
      expect(reads).assertEqual(2);
      expect(resets).assertEqual(2);
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.retirements.length).assertEqual(0);
    });

    it('retriesUndispatchedOwnedAndSessionCloseAfterOtherHandleOverlap', 0, async () => {
      const host = new PreparedHost([
        [prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)],
        [prepareOk(9, 0, 1), column('result'), eof()]
      ]);
      const session = new MySqlPreparedSession(host);
      const owned = await prepareSuccessfully(session, 'DO 7');
      const external = await prepareSuccessfully(session, 'DO 8');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      host.transport.holdReadAt = 7;
      const preparing = capturePrepared(session.prepareOwned(scope, 'SELECT 9'));
      await nextTask();
      const ownedError = await captureCommandFailure(session.closeOwned(scope, owned));
      const sessionError = await captureCommandFailure(session.close(external));
      const handleError = await captureCommandFailure(external.close());
      const bothStillOpen = !owned.closed && !external.closed;
      const unchangedWrites = host.transport.writes.length;
      const unchangedReads = host.transport.readAttempts;
      const unchangedResets = host.initialChannel.resets;
      host.transport.releaseRead();
      const prepared = await preparing;
      let retryOwned: Object | null = null;
      try {
        retryOwned = await captureCommandFailure(session.closeOwned(scope, owned));
        if (prepared.statement !== null) await session.closeOwned(scope, prepared.statement);
      } finally {
        host.commandGate.release(scope);
      }
      const retrySession = await captureCommandFailure(session.close(external));
      await external.close();
      expectProtocolError(ownedError);
      expectProtocolError(sessionError);
      expectProtocolError(handleError);
      expect(bothStillOpen).assertTrue();
      expect(unchangedWrites).assertEqual(3);
      expect(unchangedReads).assertEqual(7);
      expect(unchangedResets).assertEqual(3);
      expect(prepared.error === null).assertTrue();
      expect(retryOwned === null).assertTrue();
      expect(retrySession === null).assertTrue();
      expect(owned.closed).assertTrue();
      expect(external.closed).assertTrue();
      expect(host.transport.writes.length).assertEqual(6);
      expect(host.retirements.length).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('reusesConnectionImmediatelyAfterRepeatedHandleCloseWithoutAwaitingSessionOriginal', 0, async () => {
      await expectReuseAtRepeatedSessionClose(CloseEntry.Handle);
    });

    it('repeatsHandleCloseRetainSessionOwnedReleaseFailure', 0, async () => {
      const gate = new ReleaseFailureGate();
      const host = new PreparedHost([[prepareOk(7, 0, 0)]], Capabilities.PROTOCOL_41, [], gate);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 7');
      const finalizer = new ArkDbError(ArkDbErrorKind.Protocol,
        'Synthetic reserved-scope release failure.', 'E_CLOSE_RELEASE', 'HY000');
      gate.closeReleaseFailure = finalizer;
      host.transport.holdWriteAt = 2;
      const original = new CloseObservation(session.close(statement));
      const repeated = statement.close();
      await nextTask();
      host.transport.releaseWrite();
      let repeatedFailure: Object | null = null;
      try { await repeated; } catch (error) { repeatedFailure = error as Object; }
      const gateSettledAtRepeatedContinuation = gate.current === null;
      await original.done;
      const laterHandle = await captureCommandFailure(statement.close());
      const laterSession = await captureCommandFailure(session.close(statement));
      expect(repeatedFailure instanceof MySqlOperationError).assertTrue();
      expect(repeatedFailure === original.error).assertTrue();
      expect(laterHandle === original.error).assertTrue();
      expect(laterSession === original.error).assertTrue();
      expect(gateSettledAtRepeatedContinuation).assertTrue();
      if (!(repeatedFailure instanceof MySqlOperationError)) throw new Error('Missing full close finalizer error.');
      expect(repeatedFailure.primary === finalizer).assertTrue();
      expect(repeatedFailure.nativeCode).assertEqual('E_CLOSE_RELEASE');
      expect(repeatedFailure.code === undefined).assertTrue();
      expect(repeatedFailure.sqlState).assertEqual('HY000');
      expect(repeatedFailure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
      expect(repeatedFailure.cleanupErrors.length).assertEqual(0);
      expect(gate.closeReleaseCalls).assertEqual(1);
      expect(gate.current === null).assertTrue();
      expect(statement.closed).assertTrue();
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.readAttempts).assertEqual(2);
      expect(host.initialChannel.resets).assertEqual(2);
      expect(host.retirements.length).assertEqual(0);
    });

    it('reusesConnectionImmediatelyAfterRepeatedSessionCloseWithoutAwaitingOriginal', 0, async () => {
      await expectReuseAtRepeatedSessionClose(CloseEntry.Session);
    });

    it('reusesConnectionImmediatelyAfterRepeatedOwnedCloseWithoutAwaitingSessionOriginal', 0, async () => {
      await expectReuseAtRepeatedSessionClose(CloseEntry.Owned);
    });

    it('retainsCallerScopeAtRepeatedCloseContinuationBeforeAwaitingOwnedOriginal', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 7');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      host.transport.holdWriteAt = 2;
      const original = new CloseObservation(session.closeOwned(scope, statement));
      const repeated = statement.close();
      await nextTask();
      host.transport.releaseWrite();
      let repeatedFailure: Object | null = null;
      try { await repeated; } catch (error) { repeatedFailure = error as Object; }
      const retainedAtContinuation = host.commandGate.current === scope;
      const immediatelyReused = await capturePrepared(session.prepareOwned(scope, 'DO 8'));
      await original.done;
      try {
        if (immediatelyReused.statement !== null) await session.closeOwned(scope, immediatelyReused.statement);
      } finally {
        host.commandGate.release(scope);
      }
      expect(repeatedFailure === null).assertTrue();
      expect(retainedAtContinuation).assertTrue();
      expect(immediatelyReused.error === null).assertTrue();
      expect(original.error === null).assertTrue();
      expect(scope.serial).assertEqual(2);
      expect(host.commandGate.current === null).assertTrue();
      expect(host.transport.writes.length).assertEqual(4);
      expect(host.transport.readAttempts).assertEqual(4);
      expect(host.initialChannel.resets).assertEqual(4);
      expect(host.retirements.length).assertEqual(0);
    });
  });
}
