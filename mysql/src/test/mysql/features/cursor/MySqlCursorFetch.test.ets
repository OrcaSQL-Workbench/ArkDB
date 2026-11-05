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

export default function mySqlCursorFetchTest(): void {
  describe('MySQL read-only server cursor', () => {
    it('executeServerErrorPreservesIdentityAndConnectionReuse', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        [errorPayload(1064, '42000')],
        [okPayload()]);
      try {
        const failure = await preparedFailureOf(
          cursors.open('SELECT broken', []));
        expectCursorServerFailure(failure, 1064, '42000');
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('fetchServerErrorPreservesIdentityAndConnectionReuse', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        [errorPayload(1213, '40001')],
        [okPayload()],
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT broken', []);
        const failure = await preparedFailureOf(cursor.fetch());
        expectCursorServerFailure(failure, 1213, '40001');
        expect(cursor.done).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,26,25');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,26,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('resetServerErrorPreservesIdentityAndConnectionReuse', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        [errorPayload(1047, '08S01')],
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT value', []);
        const failure = await preparedFailureOf(cursor.close());
        expectCursorServerFailure(failure, 1047, '08S01');
        expect(cursor.done).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,26,25');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,26,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('emptyResult', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        cursorFetchResult([], 2 | StatusFlags.LAST_ROW_SENT));
      try {
        const cursor = await cursors.open('SELECT 1 WHERE FALSE', []);
        expect((await cursor.fetch()).length).assertEqual(0);
        expect(cursor.done).assertTrue();
        expect((await cursor.fetch()).length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,28,25');
      } finally {
        await fixture.close();
      }
    });

    it('partialFinalBatch', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const options = new MySqlCursorOptions();
      options.fetchRows = 3;
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        cursorFetchResult([1, 2, 3], 2 | StatusFlags.CURSOR_EXISTS),
        cursorFetchResult([4], 2 | StatusFlags.LAST_ROW_SENT));
      try {
        const cursor = await cursors.open('SELECT value FROM values', [], options);
        const first = await cursor.fetch();
        expect(first.length).assertEqual(3);
        expect(cursor.done).assertFalse();
        expect(hex(fixture.peer.writes[2].subarray(4)))
          .assertEqual('1c0700000003000000');
        const final = await cursor.fetch();
        expect(final.length).assertEqual(1);
        expect(final[0][0]).assertEqual(4);
        expect(cursor.done).assertTrue();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,28,25');
      } finally {
        await fixture.close();
      }
    });

    it('budgetOverflowDrainsThenCloses', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const options = new MySqlCursorOptions();
      options.maxBufferedBytes = 8;
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        cursorFetchResult([1, 2], 2 | StatusFlags.CURSOR_EXISTS),
        [okPayload()],
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT value FROM values', [], options);
        const failure = await preparedFailureOf(cursor.fetch());
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(cursor.done).assertTrue();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,26,25');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,26,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('drainByteBudgetExhaustionRetiresConnection', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const options = new MySqlCursorOptions();
      options.maxBufferedBytes = 8;
      options.maxDrainBytes = 6;
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        cursorFetchResult([1, 2], 2 | StatusFlags.CURSOR_EXISTS),
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT value FROM values', [], options);
        const failure = await preparedFailureOf(cursor.fetch());
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.message)
            .assertEqual('Truncated result exceeded synchronization drain budget');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(cursor.done).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,28');
      } finally {
        await fixture.close();
      }
    });

    it('drainTimeBudgetExhaustionRetiresConnection', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const options = new MySqlCursorOptions();
      options.maxBufferedBytes = 8;
      options.maxDrainTimeMs = 5;
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        [okPayload()],
        [okPayload()]);
      fixture.peer.holdCommand = 0x1c;
      try {
        const cursor = await cursors.open('SELECT value FROM values', [], options);
        const fetching = cursor.fetch();
        await flushPrepared();
        const response = cursorFetchResult(
          [1, 2], 2 | StatusFlags.CURSOR_EXISTS);
        fixture.peer.emitResponse([response[0], response[1]], 1);
        await flushPrepared();
        const delayedTerminator = new Promise<void>(
          (resolve: () => void): void => {
            setTimeout((): void => {
              fixture.peer.emitResponse([response[2]], 3);
              resolve();
            }, 30);
          });
        const failure = await preparedFailureOf(fetching);
        await delayedTerminator;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.message)
            .assertEqual('Truncated result exceeded synchronization drain time budget');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(cursor.done).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,28');
      } finally {
        fixture.peer.holdCommand = -1;
        await fixture.close();
      }
    });

    it('cumulativeMaxRowsLimitsFetchAndClosesCursor', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const options = new MySqlCursorOptions();
      options.fetchRows = 2;
      options.maxRows = 3;
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        cursorFetchResult([1, 2], 2 | StatusFlags.CURSOR_EXISTS),
        cursorFetchResult([3], 2 | StatusFlags.CURSOR_EXISTS),
        [okPayload()],
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT value FROM values', [], options);
        options.maxRows = 100;
        expect((await cursor.fetch()).length).assertEqual(2);
        const final = await cursor.fetch();
        expect(final.length).assertEqual(1);
        expect(final[0][0]).assertEqual(3);
        expect(cursor.done).assertTrue();
        expect(hex(fixture.peer.writes[3].subarray(4)))
          .assertEqual('1c0700000001000000');
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,28,26,25');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,28,26,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('cumulativeResultBytesOverflowDrainsAndCloses', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const options = new MySqlCursorOptions();
      options.fetchRows = 1;
      options.maxResultBytes = 12;
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        cursorFetchResult([1], 2 | StatusFlags.CURSOR_EXISTS),
        cursorFetchResult([2], 2 | StatusFlags.CURSOR_EXISTS),
        [okPayload()],
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT value FROM values', [], options);
        expect((await cursor.fetch())[0][0]).assertEqual(1);
        const failure = await preparedFailureOf(cursor.fetch());
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.message)
            .assertEqual('Cursor result exceeded maxResultBytes.');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(cursor.done).assertTrue();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,28,26,25');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,28,26,25,14');
      } finally {
        await fixture.close();
      }
    });
  });
}
