import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionReuse, ConnectionState, ConnectionTimerPort,
  DbConnection, QueryResult, ServerInfo, SystemConnectionTimerPort, QueryOptions, QueryResultMeta,
  QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation, QueryCancellationResult
} from '@arkdb/core';
import {
  MySqlQueryExecutionSummary, MySqlQueryResultMeta, MySqlQueryResultSink,
  MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../../main/ets/mysql/model/MySqlQueryStream';
import { requireMySqlFeatures } from '../../../../../Index';
import { ConnectionConfig, SslMode } from '../../../../main/ets/mysql/model/ConnectionConfig';
import { MySqlConnection } from '../../../../main/ets/mysql/MySqlConnection';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlValue } from '../../../../main/ets/mysql/model/MySqlQueryResult';
import { MySqlExecutionController } from '../../../../main/ets/mysql/execution/MySqlExecutionController';
import { TcpTransport } from '../../../../main/ets/mysql/transport/TcpTransport';
import {
  Capabilities, ColumnType, StatusFlags
} from '../../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../../main/ets/mysql/protocol/PacketWriter';
import { MockSocket, socket } from '../../../../mock/NetworkKit.mock';
import {
  PreparedExecutionFixture, PreparedGate, PreparedRecordingSink, binaryIntResult, errorPayload,
  cursorFetchResult, cursorOpenResult, flushPrepared, okPayload, preparedFailureOf,
  prepareResponse
} from '../../features/prepared/fixtures/PreparedExecutionFixture';
import {
  Gate, CancellationTimers, ControlConnection, CancellationSocket,
  CancellationFixture, StreamRecordingSink, NativeStreamRecordingSink, InterruptedStreamSink,
  InterruptedEndGateSink, FailingTruncationSink, CancellingTruncationSink, FailingStreamSink,
  PreparedCancellationSink, PreparedHeldRowsSink, PreparedCancellationObservation, OpeningFailureControl,
  PreparedCompletedAcknowledgementSink, releasePreparedControl, handshake, ok,
  selectResult, interrupted, truncatingSelectPrefix, interruptedSelectResult,
  flushCancellation, frame
} from './fixtures/MySqlCancellationFixture';

export default function mySqlCancellationCursorTest(): void {
  describe('MySQL connection-owned cancellation lifetime', () => {
    it('cancelsActiveCursorExecuteBeforeStatementClose', 0, async () => {
      const control = new ControlConnection();
      control.executing = new Gate();
      control.closing = new Gate();
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const opening = preparedFailureOf(
        cursors.open('SELECT interrupted', []));
      await flushPrepared();
      const cancelling = fixture.connection.cancel();
      await flushPrepared();
      const dispatched = control.commands.length > 0;
      fixture.peer.emitResponse([errorPayload(1317, '70100')]);
      await flushPrepared();
      const commandsBeforeControlCleanup = fixture.peer.commands().join(',');
      let commandsDuringControlCleanup = commandsBeforeControlCleanup;
      try {
        if (dispatched) {
          control.executing.release();
          await control.cleaning.promise;
          await flushPrepared();
          commandsDuringControlCleanup = fixture.peer.commands().join(',');
          control.closing.release();
        }
        const cancellation = await cancelling;
        const failure = await opening;
        expect(dispatched).assertTrue();
        expect(commandsBeforeControlCleanup).assertEqual('22,23');
        expect(commandsDuringControlCleanup).assertEqual('22,23');
        expect(cancellation.outcome).assertEqual(CancellationOutcome.Requested);
        expect(failure !== null).assertTrue();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        fixture.peer.holdCommand = -1;
        releasePreparedControl(control);
        await fixture.close();
        await preparedFailureOf(cancelling);
        await opening;
      }
    });

    it('cancelsActiveCursorFetchBeforeReset', 0, async () => {
      const control = new ControlConnection();
      control.executing = new Gate();
      control.closing = new Gate();
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'));
      const cursor = await cursors.open('SELECT interrupted', []);
      fixture.peer.responses.push([okPayload()]);
      fixture.peer.holdCommand = 0x1c;
      const fetching = preparedFailureOf(cursor.fetch());
      await flushPrepared();
      const cancelling = fixture.connection.cancel();
      await flushPrepared();
      const dispatched = control.commands.length > 0;
      fixture.peer.emitResponse([errorPayload(1317, '70100')]);
      await flushPrepared();
      const commandsBeforeControlCleanup = fixture.peer.commands().join(',');
      let commandsDuringControlCleanup = commandsBeforeControlCleanup;
      try {
        if (dispatched) {
          control.executing.release();
          await control.cleaning.promise;
          await flushPrepared();
          commandsDuringControlCleanup = fixture.peer.commands().join(',');
          control.closing.release();
        }
        const cancellation = await cancelling;
        const failure = await fetching;
        expect(dispatched).assertTrue();
        expect(commandsBeforeControlCleanup).assertEqual('22,23,28');
        expect(commandsDuringControlCleanup).assertEqual('22,23,28');
        expect(cancellation.outcome).assertEqual(CancellationOutcome.Requested);
        expect(failure !== null).assertTrue();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,26,25');
      } finally {
        fixture.peer.holdCommand = -1;
        releasePreparedControl(control);
        await fixture.close();
        await preparedFailureOf(cancelling);
        await fetching;
      }
    });

    it('preservesCursorExecuteServerRejectionWithDefiniteCancellationCleanup', 0,
      async () => {
        const control = new ControlConnection();
        control.executing = new Gate();
        control.cleanupFailure =
          ArkDbError.network('Synthetic cursor execute control cleanup failure.');
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41, (): DbConnection => control);
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(prepareResponse(7));
        fixture.peer.holdCommand = 0x17;
        const opening = preparedFailureOf(
          cursors.open('SELECT rejected', []));
        await flushPrepared();
        const cancelling = preparedFailureOf(fixture.connection.cancel());
        try {
          await control.dispatched.promise;
          fixture.peer.emitResponse([errorPayload(1213, '40001')]);
          control.executing.release();
          expect((await cancelling) instanceof MySqlOperationError).assertTrue();
          const failure = await opening;
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
            expect(failure.nativeCode).assertEqual(1213);
            expect(failure.sqlState).assertEqual('40001');
            expect(failure.outcome)
              .assertEqual(MySqlExecutionOutcome.ServerRejected);
            expect(failure.cleanupErrors.length).assertEqual(1);
            const cleanup = failure.cleanupErrors[0];
            expect(cleanup instanceof MySqlOperationError).assertTrue();
            if (cleanup instanceof MySqlOperationError) {
              expect(cleanup.primary === control.cleanupFailure).assertTrue();
            }
          }
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        } finally {
          fixture.peer.holdCommand = -1;
          releasePreparedControl(control);
          await fixture.close();
          await cancelling;
          await opening;
        }
      });

    it('preservesCursorFetchServerRejectionWithDefiniteCancellationCleanup', 0,
      async () => {
        const control = new ControlConnection();
        control.executing = new Gate();
        control.cleanupFailure =
          ArkDbError.network('Synthetic cursor fetch control cleanup failure.');
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41, (): DbConnection => control);
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'));
        const cursor = await cursors.open('SELECT rejected', []);
        fixture.peer.responses.push([okPayload()]);
        fixture.peer.holdCommand = 0x1c;
        const fetching = preparedFailureOf(cursor.fetch());
        await flushPrepared();
        const cancelling = preparedFailureOf(fixture.connection.cancel());
        try {
          await control.dispatched.promise;
          fixture.peer.emitResponse([errorPayload(1213, '40001')]);
          control.executing.release();
          expect((await cancelling) instanceof MySqlOperationError).assertTrue();
          const failure = await fetching;
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
            expect(failure.nativeCode).assertEqual(1213);
            expect(failure.sqlState).assertEqual('40001');
            expect(failure.outcome)
              .assertEqual(MySqlExecutionOutcome.ServerRejected);
            expect(failure.cleanupErrors.length).assertEqual(1);
            const cleanup = failure.cleanupErrors[0];
            expect(cleanup instanceof MySqlOperationError).assertTrue();
            if (cleanup instanceof MySqlOperationError) {
              expect(cleanup.primary === control.cleanupFailure).assertTrue();
            }
          }
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
          expect(fixture.peer.commands().join(','))
            .assertEqual('22,23,28,26,25');
        } finally {
          fixture.peer.holdCommand = -1;
          releasePreparedControl(control);
          await fixture.close();
          await cancelling;
          await fetching;
        }
      });

    it('keepsCursorFetchOutcomeUnknownForUncertainDispatchedCancellation', 0,
      async () => {
        const control = new ControlConnection();
        control.executing = new Gate();
        control.failure = new ArkDbError(
          ArkDbErrorKind.Network, 'Synthetic uncertain cursor KILL.',
          'CURSOR_KILL_UNKNOWN', '08S01');
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41, (): DbConnection => control);
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'));
        const cursor = await cursors.open('SELECT rejected', []);
        fixture.peer.holdCommand = 0x1c;
        const fetching = preparedFailureOf(cursor.fetch());
        await flushPrepared();
        const cancelling = preparedFailureOf(fixture.connection.cancel());
        try {
          await control.dispatched.promise;
          fixture.peer.emitResponse([errorPayload(1213, '40001')]);
          control.executing.release();
          expect((await cancelling) instanceof MySqlOperationError).assertTrue();
          const failure = await fetching;
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
            expect(failure.nativeCode).assertEqual(1213);
            expect(failure.sqlState).assertEqual('40001');
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
            expect(failure.cleanupErrors.length > 0).assertTrue();
          }
          expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,28');
        } finally {
          fixture.peer.holdCommand = -1;
          releasePreparedControl(control);
          await fixture.close();
          await cancelling;
          await fetching;
        }
      });

    it('suppressesLateCursorKillBeforeTheNextFetch', 0, async () => {
      const control = new ControlConnection();
      control.opening = new Gate();
      control.closing = new Gate();
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      const cursors = requireMySqlFeatures(fixture.connection).cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      fixture.peer.responses.push(
        prepareResponse(7),
        cursorOpenResult('value'));
      const cursor = await cursors.open('SELECT values', []);
      fixture.peer.holdCommand = 0x1c;
      let firstSettled = false;
      const first = cursor.fetch().then((rows: MySqlValue[][]): MySqlValue[][] => {
        firstSettled = true;
        return rows;
      });
      await flushPrepared();
      let cancellationSettled = false;
      const cancelling = fixture.connection.cancel().then(
        (result: QueryCancellationResult): QueryCancellationResult => {
          cancellationSettled = true;
          return result;
        });
      await flushPrepared();
      fixture.peer.emitResponse(
        cursorFetchResult([1], StatusFlags.AUTOCOMMIT | StatusFlags.CURSOR_EXISTS));
      await flushPrepared();
      let second: Promise<ArkDbError | null> | null = null;
      if (firstSettled) {
        second = preparedFailureOf(cursor.fetch());
        await flushPrepared();
      }
      const commandsBeforeControlOpening = fixture.peer.commands().join(',');
      const cancellationSettledBeforeOpening = cancellationSettled;
      control.opening.release();
      await flushPrepared();
      if (control.closed) {
        await control.cleaning.promise;
      }
      control.closing.release();
      try {
        const cancellation = await cancelling;
        const firstRows = await first;
        if (second === null) {
          second = preparedFailureOf(cursor.fetch());
          await flushPrepared();
        }
        const secondTask = second;
        if (secondTask === null) {
          throw new Error('Expected the second cursor fetch task.');
        }
        const commandsAfterCancellation = fixture.peer.commands().join(',');
        fixture.peer.emitResponse(
          cursorFetchResult([2], StatusFlags.AUTOCOMMIT | StatusFlags.LAST_ROW_SENT));
        const secondFailure = await secondTask;

        expect(cancellationSettledBeforeOpening).assertFalse();
        expect(commandsBeforeControlOpening).assertEqual('22,23,28');
        expect(control.commands.length).assertEqual(0);
        expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(firstRows[0][0]).assertEqual(1);
        expect(commandsAfterCancellation).assertEqual('22,23,28,28');
        expect(secondFailure === null).assertTrue();
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,28,28,25');
      } finally {
        fixture.peer.holdCommand = -1;
        releasePreparedControl(control);
        await fixture.close();
        await preparedFailureOf(cancelling);
        await first;
        if (second !== null) await second;
      }
    });

    it('doesNotCancelInactiveCursorPhases', 0, async () => {
      {
        const control = new ControlConnection();
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41, (): DbConnection => control);
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.holdCommand = 0x16;
        fixture.peer.responses.push(
          cursorOpenResult('value'),
          [okPayload()]);
        const opening = cursors.open('SELECT preparing', []);
        try {
          await flushPrepared();
          const cancellation = await fixture.connection.cancel();
          expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
          expect(control.commands.length).assertEqual(0);
          fixture.peer.emitResponse(prepareResponse(7));
          const cursor = await opening;
          fixture.peer.holdCommand = -1;
          await cursor.close();
        } finally {
          fixture.peer.holdCommand = -1;
          await fixture.close();
          await preparedFailureOf(opening);
        }
      }

      {
        const control = new ControlConnection();
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41, (): DbConnection => control);
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'),
          [okPayload()]);
        const cursor = await cursors.open('SELECT idle', []);
        try {
          const cancellation = await fixture.connection.cancel();
          expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
          expect(control.commands.length).assertEqual(0);
          await cursor.close();
        } finally {
          await fixture.close();
        }
      }

      {
        const control = new ControlConnection();
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41, (): DbConnection => control);
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'));
        const cursor = await cursors.open('SELECT resetting', []);
        fixture.peer.holdCommand = 0x1a;
        const closing = preparedFailureOf(cursor.close());
        try {
          await flushPrepared();
          const cancellation = await fixture.connection.cancel();
          expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
          expect(control.commands.length).assertEqual(0);
          fixture.peer.emitResponse([okPayload()]);
          fixture.peer.holdCommand = -1;
          expect((await closing) === null).assertTrue();
        } finally {
          fixture.peer.holdCommand = -1;
          await fixture.close();
          await closing;
        }
      }

      {
        const control = new ControlConnection();
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41, (): DbConnection => control);
        await fixture.open();
        const cursors = requireMySqlFeatures(fixture.connection).cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        fixture.peer.responses.push(
          prepareResponse(7),
          cursorOpenResult('value'),
          [okPayload()]);
        const cursor = await cursors.open('SELECT closing', []);
        const closeGate = new PreparedGate();
        fixture.peer.onCommand = (command: number): void => {
          if (command === 0x19) fixture.peer.sendResult = closeGate.promise;
        };
        const closing = preparedFailureOf(cursor.close());
        try {
          await flushPrepared();
          expect(fixture.peer.commands().join(','))
            .assertEqual('22,23,26,25');
          const cancellation = await fixture.connection.cancel();
          expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
          expect(control.commands.length).assertEqual(0);
          closeGate.release();
          expect((await closing) === null).assertTrue();
        } finally {
          closeGate.release();
          fixture.peer.sendResult = null;
          fixture.peer.onCommand = null;
          await fixture.close();
          await closing;
        }
      }
    });
  });
}
