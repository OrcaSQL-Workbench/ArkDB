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

export default function mySqlCancellationControlTest(): void {
  describe('MySQL connection-owned cancellation lifetime', () => {
    it('preservesAnOrdinaryConsumerCauseAndItsSocketCleanupFailure', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const original = new Error('Synthetic ordinary consumer failure.');
      fixture.peer.closeFailure = new Error('Synthetic socket cleanup failure.');
      try {
        const query = fixture.connection.features.streaming!.queryStream(
          'SELECT value', new QueryOptions(), new FailingStreamSink(original)).then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        fixture.peer.emitMessage(selectResult());
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === original).assertTrue();
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
      } finally {
        let cleanup: ArkDbError | null = null;
        try { await fixture.close(); } catch (error) { cleanup = error as ArkDbError; }
        expect(cleanup instanceof ArkDbError).assertTrue();
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
      }
    });

    it('retainsBothCleanupFailuresAfterAnUnacknowledgedKill', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.executing = new Gate();
      const controlCleanup = ArkDbError.network('Synthetic control cleanup failure.');
      fixture.control.cleanupFailure = controlCleanup;
      await fixture.open();
      fixture.peer.closeFailure = new Error('Synthetic target cleanup failure.');
      const query = fixture.connection.query('SELECT 1').then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        const cancellation = fixture.connection.cancel().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        await fixture.control.dispatched.promise;
        timers.expire();
        const failure = await cancellation;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.cleanupErrors[1] === controlCleanup).assertTrue();
        }
        expect((await query) instanceof ArkDbError).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        let cleanup: ArkDbError | null = null;
        try { await fixture.close(); } catch (error) { cleanup = error as ArkDbError; }
        expect(cleanup instanceof ArkDbError).assertTrue();
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
        await query;
      }
    });

    it('holdsTheOperationUntilControlSocketCleanupSettles', 0, async () => {
      const fixture = new CancellationFixture();
      const cleanup = new Gate();
      fixture.control.closing = cleanup;
      await fixture.open();
      const query = fixture.connection.query('SELECT 1');
      let settled = false;
      const cancellation = fixture.connection.cancel().then((): void => { settled = true; });
      try {
        await fixture.control.cleaning.promise;
        fixture.peer.emitMessage(ok());
        await query;
        expect(settled).assertFalse();
        let blocked: ArkDbError | null = null;
        try { await fixture.connection.ping(); } catch (error) { blocked = error as ArkDbError; }
        expect(blocked instanceof ArkDbError).assertTrue();
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        cleanup.release();
        await cancellation;
        const next = fixture.connection.query('SELECT 2');
        fixture.peer.emitMessage(ok());
        await next;
        expect(fixture.control.commands.length).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        cleanup.release();
        await cancellation;
        await fixture.close();
      }
    });

    it('doesNotKillTheOwnedStatusRefreshSubcommand', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      let streamFailure: Object | null = null;
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream(
        'SELECT value', options, new InterruptedStreamSink()).then(
        (): void => {}, (error: Object): void => { streamFailure = error; });
      try {
        fixture.peer.emitMessage(interruptedSelectResult());
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        expect(fixture.connection.state).assertEqual(ConnectionState.Querying);
        const cancellation = await fixture.connection.cancel();
        expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(cancellation.connectionReuse).assertEqual(ConnectionReuse.AwaitingCompletion);
        expect(fixture.control.commands.length).assertEqual(0);
        fixture.peer.emitMessage(ok());
        await query;
        expect(streamFailure === null).assertTrue();
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        await fixture.close();
        await query;
      }
    });

    it('preservesStatusRefreshErrorsAndTheirSocketCleanupFailures', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream(
        'SELECT value', options, new InterruptedStreamSink()).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      fixture.peer.closeFailure = new Error('Synthetic refresh cleanup failure.');
      try {
        fixture.peer.emitMessage(interruptedSelectResult());
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        fixture.peer.emitMessage(frame(1, new PacketWriter().writeUInt8(0xff).writeUInt16(1047)
          .writeUInt8(0x23).writeString('08S01').writeString('Synthetic status refresh rejection.')
          .toUint8Array()));
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure!.nativeCode).assertEqual(1047);
        expect(failure!.sqlState).assertEqual('08S01');
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.connection.sessionStatus.known).assertFalse();
      } finally {
        let cleanup: ArkDbError | null = null;
        try { await fixture.close(); } catch (error) { cleanup = error as ArkDbError; }
        expect(cleanup instanceof ArkDbError).assertTrue();
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
        await query;
      }
    });

    it('closeNeverWritesQuitOverAnOwnedPingAndWaitsForSocketCleanup', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const cleanup = new Gate();
      fixture.peer.closeResult = cleanup.promise;
      const ping = fixture.connection.ping().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      await flushCancellation();
      const sends = fixture.peer.sends;
      let closed = false;
      const closing = fixture.connection.close().then((): void => { closed = true; });
      try {
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(sends);
        expect(closed).assertFalse();
        let reopeningFailure: ArkDbError | null = null;
        try { await fixture.connection.connect(); } catch (error) {
          reopeningFailure = error as ArkDbError;
        }
        expect(reopeningFailure instanceof ArkDbError).assertTrue();
        expect(reopeningFailure!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.sends).assertEqual(sends);
        cleanup.release();
        await closing;
        expect((await ping) instanceof ArkDbError).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        cleanup.release();
        await closing;
        await fixture.close();
        await ping;
      }
    });

    it('boundsControlOpeningAndCleansUpWithoutPretendingTheQueryWasCancelled', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.opening = new Gate();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        const cancellation = fixture.connection.cancel().then(
          (): ArkDbError | null => null,
          (error: ArkDbError): ArkDbError | null => error
        );
        timers.expire();
        const failure = await cancellation;
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(fixture.control.closed).assertTrue();
        expect(fixture.control.commands.length).assertEqual(0);
        fixture.peer.emitMessage(ok());
        await query;
      } finally { await fixture.close(); }
    });

    it('retiresTheTargetWhenADispatchedKillTimesOutWithoutAcknowledgement', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.executing = new Gate();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        const cancellation = fixture.connection.cancel().then(
          (): ArkDbError | null => null,
          (error: ArkDbError): ArkDbError | null => error
        );
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(ok());
        await query;
        timers.expire();

        const failure = await cancellation;
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(fixture.control.commands[0]).assertEqual('KILL QUERY 42');
        expect(fixture.control.closed).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.closeCalls > 0).assertTrue();
        let blocked: ArkDbError | null = null;
        try { await fixture.connection.query('SELECT 2'); } catch (error) { blocked = error as ArkDbError; }
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        const reopening = fixture.connection.connect().then(
          (): ArkDbError | null => null,
          (error: ArkDbError): ArkDbError | null => error
        );
        timers.expire();
        expect((await reopening)!.kind).assertEqual(ArkDbErrorKind.Protocol);
      } finally { await fixture.close(); }
    });

    it('keepsTheTargetUsableAfterAnAcknowledgedServerRejectionOfKill', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.failure = ArkDbError.server('Synthetic control access denial.', 1227, '42000');
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        let failure: ArkDbError | null = null;
        try { await fixture.connection.cancel(); } catch (error) { failure = error as ArkDbError; }
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure!.code).assertEqual(1227);
        fixture.peer.emitMessage(ok());
        await query;
        const next = fixture.connection.query('SELECT 2');
        fixture.peer.emitMessage(ok());
        await next;
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally { await fixture.close(); }
    });

    it('closeWaitsForTheOwnedControlConnectionAndPreventsALateKill', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.opening = new Gate();
      await fixture.open();
      const query = fixture.connection.query('SELECT 1').catch((_error: Object): void => {});
      const cancellation = fixture.connection.cancel();
      const closing = fixture.connection.close();
      fixture.control.opening.release();
      await closing;
      await query;
      expect((await cancellation).connectionReuse).assertEqual(ConnectionReuse.Closed);
      expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      expect(fixture.control.closed).assertTrue();
      expect(fixture.control.commands.length).assertEqual(0);
    });

    it('doesNotKillPreparedMetadataOrStatementClose', 0, async () => {
      const control = new ControlConnection();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      const closing = new PreparedGate();
      fixture.peer.holdCommand = 0x16;
      fixture.peer.responses.push([okPayload()]);
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x19) fixture.peer.sendResult = closing.promise;
      };
      const executing = preparedFailureOf(executor.execute('DO 1', []));
      try {
        await flushPrepared();
        expect((await fixture.connection.cancel()).outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(control.commands.length).assertEqual(0);
        fixture.peer.emitResponse(prepareResponse(7));
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect((await fixture.connection.cancel()).outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(control.commands.length).assertEqual(0);
        expect((await preparedFailureOf(fixture.connection.ping()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
        closing.release();
        expect((await executing) === null).assertTrue();
      } finally {
        closing.release();
        fixture.peer.sendResult = null;
        await fixture.close();
        await executing;
      }
    });
  });
}
