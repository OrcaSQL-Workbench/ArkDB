import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState } from '@arkdb/core';
import {
  MySqlCursorExecutor, MySqlCursorOptions, MySqlExecutionOutcome, MySqlOperationError,
  MySqlCommandKind, MySqlExecutionEvent, MySqlExecutionEventType,
  MySqlExecutionObserver, MySqlParameter, MySqlParameterType, requireMySqlFeatures
} from '../../../../../Index';
import {
  initializeMySqlExecutionObserverInternal
} from '../../../../main/ets/mysql/MySqlConnection';
import {
  Capabilities, ColumnType, StatusFlags
} from '../../../../main/ets/mysql/protocol/Constants';
import {
  PreparedExecutionFixture, columnPayload, cursorFetchEmptyStrings, cursorFetchResult,
  cursorOpenResult, prepareResponse,
  cursorBufferedFallback, errorPayload, flushPrepared, hex, okPayload, preparedFailureOf
} from '../prepared/fixtures/PreparedExecutionFixture';
import {
  CursorExecutionObserver, FinalFetchTerminalTrace, expectFetchContinuationRetires, expectCursorServerFailure,
  expectInFlightCloseFailure, retainsInFlightCloseFailure, requireFailureTask, finalFetchSettlesBeforeRootClose,
  finalFetchClosesAtCursorTerminal, flushCursorTurns
} from './fixtures/MySqlCursorFixture';

export default function mySqlCursorLifecycleTest(): void {
  describe('MySQL read-only server cursor', () => {
    it('rejectsReentry', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'));
      try {
        const cursor = await cursors.open('SELECT value FROM values', []);
        fixture.peer.holdCommand = 0x1c;
        const fetching = cursor.fetch();
        await flushPrepared();
        const repeated = await preparedFailureOf(cursor.fetch());
        const ping = await preparedFailureOf(fixture.connection.ping());
        expect(repeated!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(ping!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,28');
        fixture.peer.emitResponse(
          cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT));
        expect((await fetching)[0][0]).assertEqual(7);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,28,25');
      } finally {
        fixture.peer.holdCommand = -1;
        await fixture.close();
      }
    });

    it('inFlightPrepareRetainsPhysicalCloseFailure', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const partialPrepare = prepareResponse(
        7, 0, [columnPayload('value')]);
      fixture.peer.responses.push([partialPrepare[0]]);
      const opening = preparedFailureOf(cursors.open('SELECT value', []));
      try {
        await flushPrepared();
        const closeCause = new Error('Synthetic close failure during cursor PREPARE.');
        fixture.peer.closeFailure = closeCause;
        const closing = await preparedFailureOf(fixture.connection.close());
        const failure = await opening;
        expectInFlightCloseFailure(failure, closing);
      } finally {
        await preparedFailureOf(fixture.close());
        await opening;
      }
    });

    it('inFlightExecuteRetainsPhysicalCloseFailure', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const opening = preparedFailureOf(cursors.open('SELECT value', []));
      try {
        await flushPrepared();
        const closeCause = new Error('Synthetic close failure during cursor EXECUTE.');
        fixture.peer.closeFailure = closeCause;
        const closing = await preparedFailureOf(fixture.connection.close());
        const failure = await opening;
        expectInFlightCloseFailure(failure, closing);
      } finally {
        fixture.peer.holdCommand = -1;
        await preparedFailureOf(fixture.close());
        await opening;
      }
    });

    it('inFlightFetchRetainsPhysicalCloseFailure', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'));
      const cursor = await cursors.open('SELECT value', []);
      fixture.peer.holdCommand = 0x1c;
      const fetching = preparedFailureOf(cursor.fetch());
      try {
        await flushPrepared();
        const closeCause = new Error('Synthetic close failure during cursor FETCH.');
        fixture.peer.closeFailure = closeCause;
        const closing = await preparedFailureOf(fixture.connection.close());
        const failure = await fetching;
        expectInFlightCloseFailure(failure, closing);
      } finally {
        fixture.peer.holdCommand = -1;
        await preparedFailureOf(fixture.close());
        await fetching;
      }
    });

    it('inFlightResetRetainsPhysicalCloseFailure', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'));
      const cursor = await cursors.open('SELECT value', []);
      fixture.peer.holdCommand = 0x1a;
      const resetting = preparedFailureOf(cursor.close());
      try {
        await flushPrepared();
        const closeCause = new Error('Synthetic close failure during cursor RESET.');
        fixture.peer.closeFailure = closeCause;
        const closing = await preparedFailureOf(fixture.connection.close());
        const failure = await resetting;
        expectInFlightCloseFailure(failure, closing);
      } finally {
        fixture.peer.holdCommand = -1;
        await preparedFailureOf(fixture.close());
        await resetting;
      }
    });

    it('finalFetchPreservesSoleRootCloseFailureIdentity', 0, async () => {
      let earlyObserved = false;
      let targetObserved = false;
      let lateObserved = false;
      let delayedObserverObserved = false;
      for (let turns = 0; turns < 64; turns += 1) {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'),
          cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT));
        fixture.peer.closeFailure =
          new Error('Synthetic sole root close failure after final FETCH.');
        fixture.peer.afterSendTurns = turns;
        let active = true;
        let closing: Promise<ArkDbError | null> | null = null;
        let sequence = 0;
        let closeSequence = 0;
        let fetchSequence = 0;
        fixture.peer.afterSendSettled = (command: number): void => {
          if (!active || command !== 0x19 || closing !== null) return;
          closeSequence = ++sequence;
          closing = preparedFailureOf(fixture.connection.close());
        };
        const cursor = await cursors.open('SELECT value', []);
        const fetching = preparedFailureOf(cursor.fetch())
          .then((failure: ArkDbError | null): ArkDbError | null => {
            fetchSequence = ++sequence;
            return failure;
          });
        try {
          const failure = await fetching;
          active = false;
          if (closing === null || fetchSequence < closeSequence) {
            lateObserved = true;
            break;
          }
          if (failure === null) {
            delayedObserverObserved = closeSequence < fetchSequence;
            lateObserved = true;
            break;
          }
          const closeFailure = await requireFailureTask(closing,
            'Expected root close during response-free statement close.');
          expect(failure instanceof MySqlOperationError).assertTrue();
          expect(closeFailure instanceof MySqlOperationError).assertTrue();
          if (failure === closeFailure) {
            targetObserved = true;
          } else {
            earlyObserved = true;
          }
          if (failure instanceof MySqlOperationError) {
            expect(failure.outcome === MySqlExecutionOutcome.NotDispatched)
              .assertFalse();
          }
        } finally {
          active = false;
          fixture.peer.afterSendSettled = null;
          await preparedFailureOf(fixture.close());
          await fetching;
          if (closing !== null) await closing;
        }
      }
      if (!lateObserved) {
        lateObserved = await finalFetchSettlesBeforeRootClose();
      }
      const terminalTrace = await finalFetchClosesAtCursorTerminal();
      expect(earlyObserved).assertTrue();
      expect(targetObserved).assertTrue();
      expect(lateObserved).assertTrue();
      expect(delayedObserverObserved).assertTrue();
      expect(terminalTrace.closeStarted).assertTrue();
      expect(terminalTrace.cursorDoneAtClose).assertFalse();
      expect(terminalTrace.fetchSucceeded).assertFalse();
      expect(terminalTrace.closeSettledBeforeFetch).assertTrue();
      expect(terminalTrace.exactIdentity).assertTrue();
    });

    it('completedExecuteContinuationIsNeverNotDispatched', 0, async () => {
      let exercised = false;
      let notDispatched = false;
      for (let turns = 0; turns < 32; turns += 1) {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(prepareResponse(7));
        fixture.peer.holdCommand = 0x17;
        let operationSettled = false;
        const opening = preparedFailureOf(cursors.open('SELECT value', []))
          .then((failure: ArkDbError | null): ArkDbError | null => {
            operationSettled = true;
            return failure;
          });
        try {
          await flushPrepared();
          fixture.peer.emitResponse(cursorOpenResult('value'));
          await flushCursorTurns(turns);
          if (operationSettled) break;
          const closing = preparedFailureOf(fixture.connection.close());
          const failure = await opening;
          await closing;
          if (failure instanceof MySqlOperationError) {
            exercised = true;
            if (failure.outcome === MySqlExecutionOutcome.NotDispatched) {
              notDispatched = true;
              break;
            }
          }
        } finally {
          fixture.peer.holdCommand = -1;
          await preparedFailureOf(fixture.close());
          await opening;
        }
      }
      expect(exercised).assertTrue();
      expect(notDispatched).assertFalse();
    });

    it('disconnectInvalidatesCursorWithoutLeakingOwner', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'));
      const cursor = await cursors.open('SELECT value FROM values', []);
      await fixture.connection.close();
      expect(cursor.done).assertTrue();
      const stale = await preparedFailureOf(cursor.fetch());
      expect(stale!.kind).assertEqual(ArkDbErrorKind.Protocol);
      await cursor.close();
      expect(fixture.peer.commands().join(',')).assertEqual('22,23');
    });

    it('supportsCursorStatusTerminatorsInBothEofModes', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const deprecated = mode === 1;
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41 |
          (deprecated ? Capabilities.DEPRECATE_EOF : 0));
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7, 0, [], deprecated),
          cursorOpenResult('value', 2 | StatusFlags.CURSOR_EXISTS, deprecated),
          cursorFetchResult([9], 2 | StatusFlags.LAST_ROW_SENT, deprecated));
        try {
          const cursor = await cursors.open('SELECT 9', []);
          expect((await cursor.fetch())[0][0]).assertEqual(9);
          expect(cursor.done).assertTrue();
          expect(fixture.connection.sessionStatus.known).assertTrue();
          expect(fixture.connection.sessionStatus.autocommit).assertTrue();
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,28,25');
        } finally {
          await fixture.close();
        }
      }
    });

    it('observesOneCommandAcrossTheCursorLifetime', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const observer = new CursorExecutionObserver();
      initializeMySqlExecutionObserverInternal(
        fixture.connection, observer, (): number => 100);
      await fixture.open();
      observer.events.length = 0;
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        cursorFetchResult([1], 2 | StatusFlags.LAST_ROW_SENT));
      try {
        const cursor = await cursors.open('SELECT 1', []);
        expect(observer.events.length).assertEqual(1);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
        expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Cursor);
        await cursor.fetch();
        expect(observer.events.length).assertEqual(2);
        expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
        expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
      } finally {
        await fixture.close();
      }
    });
  });
}
