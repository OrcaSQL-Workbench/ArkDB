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

export default function preparedStatementCloseTest(): void {
  describe('MySQL internal prepared lifecycle', () => {
    it('rejectsConcurrentPrepareAndCloseWithoutQueuingOrInvalidatingAUsableHandle', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      host.transport.holdWriteAt = 2;
      const pending = session.prepare('DO 2');
      await nextTask();
      expect(host.commandGate.current!.kind).assertEqual(MySqlCommandKind.Prepare);
      expect(host.commandGate.current!.phase).assertEqual('preparing');
      expect((await observeFailure(() => session.prepare('DO 3'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await observeFailure(() => first.close())).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(first.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(2);
      host.transport.releaseWrite();
      const second = await pending;
      await session.close(first);
      expect(second.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(3);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('sharesOnePendingIdempotentCloseAndNeverWaitsForAnAck', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 1');
      host.transport.holdWriteAt = 2;
      const first = statement.close();
      const second = statement.close();
      expect(first === second).assertTrue();
      await nextTask();
      expect(statement.closed).assertTrue();
      expect(host.commandGate.current!.kind).assertEqual(MySqlCommandKind.StatementClose);
      expect(host.commandGate.current!.phase).assertEqual('cleaning');
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.readAttempts).assertEqual(2);
      expect((await observeFailure(() => session.prepare('DO 2'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      host.transport.releaseWrite();
      await first;
      await second;
      await statement.close();
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.readAttempts).assertEqual(2);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('memoizesExpiredHandleClosePromiseExactly', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 1');
      session.invalidate();

      const first = statement.close();
      const second = statement.close();
      expect(first === second).assertTrue();
      await first;
      await second;
      const third = statement.close();
      expect(third === first).assertTrue();
      await third;
      expect(host.transport.writes.length).assertEqual(1);
    });

    it('memoizesBusyHandleCloseRejectionAndErrorIdentity', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 1');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);

      const first = statement.close();
      const second = statement.close();
      expect(first === second).assertTrue();
      const firstError = await captureCommandFailure(first);
      const secondError = await captureCommandFailure(second);
      expect(firstError instanceof ArkDbError).assertTrue();
      expect(firstError === secondError).assertTrue();
      const third = statement.close();
      expect(third === first).assertTrue();
      expect((await captureCommandFailure(third)) === firstError).assertTrue();

      host.commandGate.release(scope);
      const retried = await captureCommandFailure(session.close(statement));
      expect(retried === null).assertTrue();
      expect(statement.closed).assertTrue();
    });

    it('memoizesExplicitSessionRetryPreflightRejectionExactly', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 1');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);

      const original = statement.close();
      const originalError = await captureCommandFailure(original);
      const retry = session.close(statement);
      const retryError = await captureCommandFailure(retry);
      const repeated = statement.close();
      const repeatedError = await captureCommandFailure(repeated);
      const repeatedRetryPromise = repeated === retry;
      const repeatedRetryError = repeatedError === retryError;

      host.commandGate.release(scope);
      const completed = await captureCommandFailure(session.close(statement));

      expectProtocolError(originalError);
      expectProtocolError(retryError);
      expect(repeatedRetryPromise).assertTrue();
      expect(repeatedRetryError).assertTrue();
      expect(completed === null).assertTrue();
      expect(statement.closed).assertTrue();
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('publishesStatementCloseBeforeStartObserverReentry', 0, async () => {
      const observer = new StatementCloseStartObserver();
      const gate = new MySqlCommandGate(observer);
      const host = new PreparedHost([[prepareOk(1, 0, 0)]],
        Capabilities.PROTOCOL_41, [], gate);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 1');
      observer.statement = statement;
      const primary = ArkDbError.network('Synthetic reentrant CLOSE write failure.');
      const cleanup = ArkDbError.timeout('Synthetic reentrant CLOSE retirement failure.');
      host.transport.failWriteAt = 2;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      host.holdRetirement = true;

      const first = statement.close();
      const repeated = observer.repeated;
      if (repeated === null) throw new Error('Expected statement close start reentry.');
      const firstObservation = new CloseObservation(first);
      const repeatedObservation = new CloseObservation(repeated);
      await nextTask();
      try {
        expect(first === repeated).assertTrue();
        expect(firstObservation.settled).assertFalse();
        expect(repeatedObservation.settled).assertFalse();
        expect(host.transport.writes.length).assertEqual(2);
        expect(observer.closeStarts).assertEqual(1);
        expect(observer.closeTerminals).assertEqual(0);

        host.releaseRetirement();
        await firstObservation.done;
        await repeatedObservation.done;
        expect(firstObservation.error instanceof MySqlOperationError).assertTrue();
        if (!(firstObservation.error instanceof MySqlOperationError)) {
          throw new Error('Expected reentrant statement close operation failure.');
        }
        expect(firstObservation.error.primary === primary).assertTrue();
        expect(firstObservation.error.cleanupErrors.length).assertEqual(1);
        expect(firstObservation.error.cleanupErrors[0] === cleanup).assertTrue();
        expect(repeatedObservation.error === firstObservation.error).assertTrue();
        expect(observer.closeTerminals).assertEqual(1);
      } finally {
        host.releaseRetirement();
        await firstObservation.done;
        await repeatedObservation.done;
      }
    });

    it('sessionCloseReentryJoinsPendingHandleBridge', 0, async () => {
      const observer = new SessionCloseStartObserver();
      const gate = new MySqlCommandGate(observer);
      const host = new PreparedHost([[prepareOk(2, 0, 0)]],
        Capabilities.PROTOCOL_41, [], gate);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 2');
      observer.session = session;
      observer.statement = statement;
      const primary = ArkDbError.network('Synthetic session reentry CLOSE write failure.');
      const cleanup = ArkDbError.timeout('Synthetic session reentry CLOSE retirement failure.');
      host.transport.failWriteAt = 2;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      host.holdRetirement = true;

      const first = statement.close();
      const repeated = observer.repeated;
      if (repeated === null) throw new Error('Expected session close start reentry.');
      const firstObservation = new CloseObservation(first);
      const repeatedObservation = new CloseObservation(repeated);
      await nextTask();
      try {
        expect(first === repeated).assertTrue();
        expect(firstObservation.settled).assertFalse();
        expect(repeatedObservation.settled).assertFalse();
        expect(host.transport.writes.length).assertEqual(2);

        host.releaseRetirement();
        await firstObservation.done;
        await repeatedObservation.done;
        expect(firstObservation.error instanceof MySqlOperationError).assertTrue();
        if (!(firstObservation.error instanceof MySqlOperationError)) {
          throw new Error('Expected session reentry statement close failure.');
        }
        expect(firstObservation.error.primary === primary).assertTrue();
        expect(firstObservation.error.cleanupErrors.length).assertEqual(1);
        expect(firstObservation.error.cleanupErrors[0] === cleanup).assertTrue();
        expect(repeatedObservation.error === firstObservation.error).assertTrue();
        expect(host.transport.writes.length).assertEqual(2);
        expect(statement.close() === first).assertTrue();
        expect(session.close(statement) === first).assertTrue();
      } finally {
        host.releaseRetirement();
        await firstObservation.done;
        await repeatedObservation.done;
      }
    });

    it('usesTheCallerOwnedScopeForComposedPrepareAndCloseWithoutReentry', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      const first = await session.prepareOwned(scope, 'DO 1');
      session.assertUsable(scope, first);
      expect(host.commandGate.current === scope).assertTrue();
      await session.closeOwned(scope, first);
      expect(first.closed).assertTrue();
      expect(host.commandGate.current === scope).assertTrue();
      const second = await session.prepareOwned(scope, 'DO 2');
      session.assertUsable(scope, second);
      expect(scope.serial).assertEqual(1);
      expect(host.commandGate.current === scope).assertTrue();
      const foreignGate = new MySqlCommandGate();
      const foreign = foreignGate.reserve(MySqlCommandKind.Prepare);
      expect((await observeFailure(() => session.prepareOwned(foreign, 'DO 3'))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect((await observeFailure(() => session.closeOwned(foreign, second))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(second.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(3);
      foreignGate.release(foreign);
      await session.closeOwned(scope, second);
      host.commandGate.release(scope);
      expect(host.transport.readAttempts).assertEqual(4);
    });
  });
}
