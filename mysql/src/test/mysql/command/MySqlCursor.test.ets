import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState } from '@arkdb/core';
import {
  MySqlCursorExecutor, MySqlCursorOptions, MySqlExecutionOutcome, MySqlOperationError,
  MySqlCommandKind, MySqlExecutionEvent, MySqlExecutionEventType,
  MySqlExecutionObserver, MySqlParameter, MySqlParameterType, requireMySqlFeatures
} from '../../../../Index';
import {
  initializeMySqlExecutionObserverInternal
} from '../../../main/ets/mysql/MySqlConnection';
import {
  Capabilities, ColumnType, StatusFlags
} from '../../../main/ets/mysql/protocol/Constants';
import {
  PreparedExecutionFixture, columnPayload, cursorFetchEmptyStrings, cursorFetchResult,
  cursorOpenResult, prepareResponse,
  cursorBufferedFallback, errorPayload, flushPrepared, hex, okPayload, preparedFailureOf
} from './PreparedExecutionFixture';

class CursorExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];
  cursorTerminal: (() => void) | null = null;

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
    const cursorTerminal = this.cursorTerminal;
    if (cursorTerminal !== null &&
      event.type === MySqlExecutionEventType.Terminal &&
      event.commandKind === MySqlCommandKind.Cursor) {
      cursorTerminal();
    }
  }
}

class FinalFetchTerminalTrace {
  readonly closeStarted: boolean;
  readonly cursorDoneAtClose: boolean;
  readonly fetchSucceeded: boolean;
  readonly exactIdentity: boolean;
  readonly closeSettledBeforeFetch: boolean;

  constructor(closeStarted: boolean, cursorDoneAtClose: boolean,
    fetchSucceeded: boolean, exactIdentity: boolean,
    closeSettledBeforeFetch: boolean) {
    this.closeStarted = closeStarted;
    this.cursorDoneAtClose = cursorDoneAtClose;
    this.fetchSucceeded = fetchSucceeded;
    this.exactIdentity = exactIdentity;
    this.closeSettledBeforeFetch = closeSettledBeforeFetch;
  }
}

export default function mySqlCursorTest(): void {
  describe('MySQL read-only server cursor', () => {
    it('fetchOnlyWhenRequested', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors: MySqlCursorExecutor | undefined =
        requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7, 1),
        cursorOpenResult('value'),
        cursorFetchResult([42], 2 | StatusFlags.LAST_ROW_SENT));
      try {
        const cursor = await cursors.open('SELECT ?', [
          new MySqlParameter(MySqlParameterType.Int32, 42)
        ]);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect(cursor.done).assertFalse();
        expect(cursor.columns.length).assertEqual(1);
        expect(cursor.columns[0].name).assertEqual('value');
        const columns = cursor.columns;
        columns[0].name = 'caller change';
        expect(cursor.columns[0].name).assertEqual('value');
        const blocked = await preparedFailureOf(fixture.connection.ping());
        expect(blocked instanceof ArkDbError).assertTrue();
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');

        const rows = await cursor.fetch();
        expect(rows.length).assertEqual(1);
        expect(rows[0][0]).assertEqual(42);
        expect(cursor.done).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,28,25');
      } finally {
        await fixture.close();
      }
    });

    it('rejectsInvalidOptionsWithoutPreparing', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      try {
        const invalidFetch = new MySqlCursorOptions();
        invalidFetch.fetchRows = 0;
        const fetchFailure = await preparedFailureOf(
          cursors.open('SELECT 1', [], invalidFetch));
        expect(fetchFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(fetchFailure!.message)
          .assertEqual('fetchRows must be between 1 and 10000.');

        const excessiveFetch = new MySqlCursorOptions();
        excessiveFetch.fetchRows = 10001;
        const excessiveFailure = await preparedFailureOf(
          cursors.open('SELECT 1', [], excessiveFetch));
        expect(excessiveFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(excessiveFailure!.message)
          .assertEqual('fetchRows must be between 1 and 10000.');

        const invalidBudget = new MySqlCursorOptions();
        invalidBudget.maxBufferedBytes = 0;
        const budgetFailure = await preparedFailureOf(
          cursors.open('SELECT 1', [], invalidBudget));
        expect(budgetFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('encodesBoundaryFetchRows', 0, async () => {
      const fetchRows = [1, 10000];
      const encoded = ['01000000', '10270000'];
      for (let index = 0; index < fetchRows.length; index += 1) {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        const options = new MySqlCursorOptions();
        options.fetchRows = fetchRows[index];
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'),
          cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT));
        try {
          const cursor = await cursors.open('SELECT 7', [], options);
          await cursor.fetch();
          expect(hex(fixture.peer.writes[2].subarray(4)))
            .assertEqual('1c07000000' + encoded[index]);
        } finally {
          await fixture.close();
        }
      }
    });

    it('rejectsRowsBeyondTheRequestedFetchCountWhenRowsUseZeroBytes', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const options = new MySqlCursorOptions();
      options.fetchRows = 1;
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value', 2 | StatusFlags.CURSOR_EXISTS,
          false, ColumnType.VAR_STRING),
        cursorFetchEmptyStrings(2, 2 | StatusFlags.CURSOR_EXISTS),
        [okPayload()],
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT value FROM values', [], options);
        const failure = await preparedFailureOf(cursor.fetch());
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.message).assertEqual('Cursor result exceeded maxRows.');
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

    it('lastRowSentReleasesOwner', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(0x12345678),
        cursorOpenResult('value'),
        cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT),
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT 7', []);
        expect(hex(fixture.peer.writes[1].subarray(4)))
          .assertEqual('17785634120101000000');
        expect((await cursor.fetch())[0][0]).assertEqual(7);
        expect(hex(fixture.peer.writes[2].subarray(4)))
          .assertEqual('1c78563412c8000000');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('earlyCloseDoesNotReadPhantomAck', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'),
        [okPayload()],
        [okPayload()]);
      try {
        const cursor = await cursors.open('SELECT 1', []);
        const closing = cursor.close();
        expect(cursor.close() === closing).assertTrue();
        await closing;
        expect(cursor.done).assertTrue();
        expect(hex(fixture.peer.writes[2].subarray(4)))
          .assertEqual('1a07000000');
        expect(hex(fixture.peer.writes[3].subarray(4)))
          .assertEqual('1907000000');
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,26,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('missingServerCursorDoesNotBufferFallback', 0, async () => {
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
          cursorBufferedFallback([42], 2, deprecated));
        try {
          const failure = await preparedFailureOf(
            cursors.open('SELECT 42', []));
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          }
          expect(fixture.connection.state).assertEqual(ConnectionState.Error);
          expect(fixture.peer.closeCalls).assertEqual(1);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        } finally {
          await fixture.close();
        }
      }
    });

    it('executeOkContinuationRetiresBeforePingConsumesStaleResponse', 0,
      async () => {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          [
            okPayload(2 | StatusFlags.MORE_RESULTS_EXISTS),
            okPayload()
          ],
          [okPayload()]);
        try {
          const failure = await preparedFailureOf(
            cursors.open('CALL continuation()', []));
          const stateAfterOpen = fixture.connection.state;
          const closeCallsAfterOpen = fixture.peer.closeCalls;
          const commandsAfterOpen = fixture.peer.commands().join(',');
          const queuedResponsesAfterOpen = fixture.peer.responses.length;
          const ping = await preparedFailureOf(fixture.connection.ping());

          expect(ping !== null).assertTrue();
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          }
          expect(stateAfterOpen).assertEqual(ConnectionState.Error);
          expect(closeCallsAfterOpen).assertEqual(1);
          expect(commandsAfterOpen).assertEqual('22,23');
          expect(queuedResponsesAfterOpen).assertEqual(1);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23');
          expect(fixture.peer.responses.length).assertEqual(1);
        } finally {
          await fixture.close();
        }
      });

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

function expectCursorServerFailure(failure: ArkDbError | null,
  code: number, sqlState: string): void {
  expect(failure instanceof MySqlOperationError).assertTrue();
  if (failure instanceof MySqlOperationError) {
    expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
    expect(failure.nativeCode).assertEqual(code);
    expect(failure.sqlState).assertEqual(sqlState);
    expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
    expect(failure.cleanupErrors.length).assertEqual(0);
  }
}

function expectInFlightCloseFailure(failure: ArkDbError | null,
  closing: ArkDbError | null): void {
  expect(retainsInFlightCloseFailure(failure, closing)).assertTrue();
}

function retainsInFlightCloseFailure(failure: ArkDbError | null,
  closing: ArkDbError | null): boolean {
  if (!(closing instanceof MySqlOperationError) ||
    !(failure instanceof MySqlOperationError) ||
    failure.outcome !== MySqlExecutionOutcome.Unknown) return false;
  for (const cleanup of failure.cleanupErrors) {
    if (cleanup === closing) return true;
  }
  return false;
}

function requireFailureTask(task: Promise<ArkDbError | null> | null,
  message: string): Promise<ArkDbError | null> {
  if (task === null) throw new Error(message);
  return task;
}

async function finalFetchSettlesBeforeRootClose(): Promise<boolean> {
  const fixture = new PreparedExecutionFixture();
  await fixture.open();
  const cursors = requireMySqlFeatures(fixture.connection).cursors;
  if (cursors === undefined) throw new Error('Expected cursor support.');
  fixture.peer.responses.push(
    prepareResponse(7),
    cursorOpenResult('value'),
    cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT));
  let sequence = 0;
  let closeSequence = 0;
  let fetchSequence = 0;
  const cursor = await cursors.open('SELECT value', []);
  const fetching = preparedFailureOf(cursor.fetch())
    .then((failure: ArkDbError | null): ArkDbError | null => {
      fetchSequence = ++sequence;
      return failure;
    });
  try {
    const failure = await fetching;
    fixture.peer.closeFailure =
      new Error('Synthetic root close after final FETCH settlement.');
    closeSequence = ++sequence;
    await preparedFailureOf(fixture.connection.close());
    return failure === null && fetchSequence < closeSequence;
  } finally {
    await preparedFailureOf(fixture.close());
    await fetching;
  }
}

async function finalFetchClosesAtCursorTerminal(): Promise<FinalFetchTerminalTrace> {
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
    cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT));
  fixture.peer.closeFailure =
    new Error('Synthetic sole root close failure at cursor terminal.');
  const cursor = await cursors.open('SELECT value', []);
  let sequence = 0;
  let closeSequence = 0;
  let closeSettledSequence = 0;
  let fetchSequence = 0;
  let closeStarted = false;
  let cursorDoneAtClose = false;
  let closing: Promise<ArkDbError | null> | null = null;
  observer.cursorTerminal = (): void => {
    if (closing !== null) return;
    closeStarted = true;
    cursorDoneAtClose = cursor.done;
    closeSequence = ++sequence;
    closing = preparedFailureOf(fixture.connection.close())
      .then((failure: ArkDbError | null): ArkDbError | null => {
        closeSettledSequence = ++sequence;
        return failure;
      });
  };
  const fetching = preparedFailureOf(cursor.fetch())
    .then((failure: ArkDbError | null): ArkDbError | null => {
      fetchSequence = ++sequence;
      return failure;
    });
  try {
    const failure = await fetching;
    const closeFailure = await requireFailureTask(closing,
      'Expected root close from cursor terminal observation.');
    return new FinalFetchTerminalTrace(
      closeStarted && closeSequence > 0,
      cursorDoneAtClose,
      failure === null,
      failure === closeFailure,
      closeSettledSequence > 0 && closeSettledSequence < fetchSequence);
  } finally {
    observer.cursorTerminal = null;
    await preparedFailureOf(fixture.close());
    await fetching;
    if (closing !== null) await closing;
  }
}

async function flushCursorTurns(turns: number): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}
