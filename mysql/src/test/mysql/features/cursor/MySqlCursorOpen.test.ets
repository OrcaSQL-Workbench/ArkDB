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

export default function mySqlCursorOpenTest(): void {
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

    it('metadataContinuationRetiresBeforeFetchConsumesStaleResponse', 0,
      async () => {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        const openResponse = cursorOpenResult(
          'value',
          StatusFlags.AUTOCOMMIT |
            StatusFlags.CURSOR_EXISTS |
            StatusFlags.MORE_RESULTS_EXISTS);
        openResponse.push(okPayload());
        fixture.peer.responses.push(
          prepareResponse(7),
          openResponse,
          cursorFetchResult([7], StatusFlags.AUTOCOMMIT | StatusFlags.LAST_ROW_SENT));
        let opened = false;
        let failure: ArkDbError | null = null;
        let fetchFailure: ArkDbError | null = null;
        try {
          try {
            const cursor = await cursors.open('SELECT continuation', []);
            opened = true;
            fetchFailure = await preparedFailureOf(cursor.fetch());
          } catch (error) {
            if (!(error instanceof ArkDbError)) throw error as Error;
            failure = error;
          }
          expect(opened).assertFalse();
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          }
          expect(fetchFailure === null).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Error);
          expect(fixture.peer.closeCalls).assertEqual(1);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23');
          expect(fixture.peer.responses.length).assertEqual(1);
        } finally {
          await fixture.close();
        }
      });

    it('fetchContinuationWithOpenCursorRetiresBeforeCleanup', 0,
      async () => {
        await expectFetchContinuationRetires(
          StatusFlags.AUTOCOMMIT |
            StatusFlags.CURSOR_EXISTS |
            StatusFlags.MORE_RESULTS_EXISTS);
      });

    it('terminalFetchContinuationRetiresBeforeCleanup', 0,
      async () => {
        await expectFetchContinuationRetires(
          StatusFlags.AUTOCOMMIT |
            StatusFlags.LAST_ROW_SENT |
            StatusFlags.MORE_RESULTS_EXISTS);
      });

    it('resetContinuationRetiresBeforeStatementCloseConsumesStaleResponse', 0,
      async () => {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'),
          [
            okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS),
            okPayload()
          ],
          [okPayload()]);
        try {
          const cursor = await cursors.open('SELECT continuation', []);
          const failure = await preparedFailureOf(cursor.close());
          const ping = await preparedFailureOf(fixture.connection.ping());

          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          }
          expect(ping !== null).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Error);
          expect(fixture.peer.closeCalls).assertEqual(1);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,26');
          expect(fixture.peer.responses.length).assertEqual(1);
        } finally {
          await fixture.close();
        }
      });
  });
}
