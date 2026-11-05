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

export default function mySqlCancellationPreparedTest(): void {
  describe('MySQL connection-owned cancellation lifetime', () => {
    it('waitsForPreparedKillAndControlCleanupBeforeStatementClose', 0, async () => {
      const control = new ControlConnection();
      control.executing = new Gate();
      control.closing = new Gate();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      let settled = false;
      const executing = preparedFailureOf(executor.execute('DO 1', [])).then(
        (error: ArkDbError | null): ArkDbError | null => { settled = true; return error; });
      await flushPrepared();
      const cancelling = fixture.connection.cancel();
      try {
        await control.dispatched.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushPrepared();
        expect(settled).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        control.executing.release();
        await control.cleaning.promise;
        await flushPrepared();
        expect(settled).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect((await preparedFailureOf(fixture.connection.ping()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
        control.closing.release();
        expect((await cancelling).outcome).assertEqual(CancellationOutcome.Requested);
        expect((await executing) === null).assertTrue();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        releasePreparedControl(control);
        await fixture.close();
        await preparedFailureOf(cancelling);
        await executing;
      }
    });

    it('suppressesALatePreparedKillBeforeTheNextCommand', 0, async () => {
      const control = new ControlConnection();
      control.opening = new Gate();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO 1', []));
      await flushPrepared();
      const cancelling = fixture.connection.cancel();
      try {
        fixture.peer.emitResponse([okPayload()]);
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        control.opening.release();
        expect((await cancelling).outcome).assertEqual(CancellationOutcome.NotRunning);
        expect((await executing) === null).assertTrue();
        expect(control.commands.length).assertEqual(0);
        expect(control.closed).assertTrue();
        fixture.peer.responses.push([okPayload()]);
        await fixture.connection.query('DO next_command');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,3');
      } finally {
        releasePreparedControl(control);
        await fixture.close();
        await preparedFailureOf(cancelling);
        await executing;
      }
    });

    it('retiresUnknownPreparedKillWithoutClosingOrReplayingTheStatement', 0, async () => {
      const control = new ControlConnection();
      control.executing = new Gate();
      control.failure = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic uncertain prepared KILL.',
        'KILL_UNKNOWN', '08S01');
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      const statement = await executor.prepare('DO 1');
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(statement.execute([]));
      await flushPrepared();
      const cancelling = preparedFailureOf(fixture.connection.cancel());
      try {
        await control.dispatched.promise;
        control.executing.release();
        const cancellation = await cancelling;
        const failure = await executing;
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === control.failure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.nativeCode).assertEqual('KILL_UNKNOWN');
        }
        expect(statement.closed).assertTrue();
        await statement.close();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect((await preparedFailureOf(fixture.connection.connect()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        releasePreparedControl(control);
        await fixture.close();
        await cancelling;
        await executing;
      }
    });

    it('refreshesInterruptedPreparedTruncationBeforeClosingTheStatement', 0, async () => {
      const control = new ControlConnection();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      const interrupted = binaryIntResult([1, 2]);
      interrupted[interrupted.length - 1] = errorPayload(1317, '70100');
      fixture.peer.responses.push(prepareResponse(7), interrupted, [okPayload()]);
      const refreshCancellation = new PreparedCancellationObservation();
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x0e) refreshCancellation.task = fixture.connection.cancel();
      };
      const options = new QueryOptions();
      options.maxRows = 1;
      const sink = new PreparedCancellationSink(fixture.connection);
      try {
        const result = await executor.executeStream('SELECT truncated', [], options, sink);
        expect(result.loadedRowCount).assertEqual(1);
        expect(result.rowCountKnown).assertFalse();
        expect(result.truncationInterrupted).assertTrue();
        expect(result.statusKnown).assertTrue();
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(sink.ends[0].statusKnown).assertFalse();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,14,25');
        expect(refreshCancellation.task !== null).assertTrue();
        if (refreshCancellation.task !== null) {
          expect((await refreshCancellation.task).outcome).assertEqual(CancellationOutcome.NotRunning);
        }
      } finally {
        releasePreparedControl(control);
        await fixture.close();
      }
    });

    it('retiresPreparedTargetWhenADispatchedKillBecomesUnknownAfterResultCompletion', 0, async () => {
      const control = new ControlConnection();
      control.executing = new Gate();
      control.failure = ArkDbError.network('Synthetic unknown late dispatched KILL.');
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO 1', []));
      await flushPrepared();
      const cancelling = preparedFailureOf(fixture.connection.cancel());
      try {
        await control.dispatched.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        control.executing.release();
        expect((await cancelling) instanceof MySqlOperationError).assertTrue();
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === control.failure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect((await preparedFailureOf(fixture.connection.connect()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        releasePreparedControl(control);
        await fixture.close();
        await cancelling;
        await executing;
      }
    });

    it('retainsPreparedCancellationCleanupThatSettlesBeforeTheExecutionRows', 0, async () => {
      const control = new ControlConnection();
      control.cleanupFailure = ArkDbError.network('Synthetic prepared control cleanup failure.');
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO 1', []));
      await flushPrepared();
      try {
        const cancellation = await preparedFailureOf(fixture.connection.cancel());
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        fixture.peer.emitResponse([okPayload()]);
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === control.cleanupFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        releasePreparedControl(control);
        await fixture.close();
        await executing;
      }
    });

    it('keepsPreparedServerRejectionPrimaryWhenControlCleanupAlsoFails', 0, async () => {
      const control = new ControlConnection();
      control.executing = new Gate();
      control.cleanupFailure = ArkDbError.network('Synthetic prepared control cleanup failure.');
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO 1', []));
      await flushPrepared();
      const cancelling = preparedFailureOf(fixture.connection.cancel());
      try {
        await control.dispatched.promise;
        fixture.peer.emitResponse([errorPayload(1213, '40001')]);
        await flushPrepared();
        control.executing.release();
        expect((await cancelling) instanceof MySqlOperationError).assertTrue();
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.nativeCode).assertEqual(1213);
          expect(failure.sqlState).assertEqual('40001');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0] instanceof MySqlOperationError).assertTrue();
          const cleanup = failure.cleanupErrors[0];
          if (cleanup instanceof MySqlOperationError) expect(cleanup.primary === control.cleanupFailure).assertTrue();
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        releasePreparedControl(control);
        await fixture.close();
        await cancelling;
        await executing;
      }
    });

    it('holdsPreparedOwnershipThroughCloseDuringASinkAckAndSocketCleanup', 0, async () => {
      const control = new ControlConnection();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([42]));
      const sink = new PreparedHeldRowsSink();
      const socketCleanup = new PreparedGate();
      fixture.peer.closeResult = socketCleanup.promise;
      let executionSettled = false;
      const executing = preparedFailureOf(executor.executeStream('SELECT 42', [], new QueryOptions(), sink)).then(
        (error: ArkDbError | null): ArkDbError | null => { executionSettled = true; return error; });
      await sink.entered.promise;
      const closing = fixture.close();
      try {
        await flushPrepared();
        expect(executionSettled).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect((await preparedFailureOf(fixture.connection.ping()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
        socketCleanup.release();
        await closing;
        expect((await executing) instanceof MySqlOperationError).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        socketCleanup.release();
        sink.acknowledgement.release();
        releasePreparedControl(control);
        await closing;
        await executing;
      }
    });

    it('keepsCompletedPreparedSqlOutcomeWhenControlOpeningFails', 0, async () => {
      const opening = new ArkDbError(ArkDbErrorKind.Timeout, 'Synthetic control opening timeout.',
        'CONTROL_OPEN', '08001');
      const control = new OpeningFailureControl(opening);
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO completed_sql', []));
      try {
        await flushPrepared();
        const cancellation = await preparedFailureOf(fixture.connection.cancel());
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        if (cancellation instanceof MySqlOperationError) {
          expect(cancellation.primary === opening).assertTrue();
          expect(cancellation.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(control.commands.length).assertEqual(0);
        fixture.peer.emitResponse([okPayload()]);
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === opening).assertTrue();
          expect(failure.nativeCode).assertEqual('CONTROL_OPEN');
          expect(failure.sqlState).assertEqual('08001');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        fixture.peer.responses.push([okPayload()]);
        await fixture.connection.ping();
      } finally {
        await fixture.close();
        await executing;
      }
    });

    it('keepsCompletedPreparedStreamOutcomeWhenKillIsRejected', 0, async () => {
      const control = new ControlConnection();
      control.failure = ArkDbError.server('Synthetic KILL access denial.', 1227, '42000');
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const sink = new PreparedRecordingSink();
      const executing = preparedFailureOf(executor.executeStream(
        'SELECT completed_sql', [], new QueryOptions(), sink));
      try {
        await flushPrepared();
        const cancellation = await preparedFailureOf(fixture.connection.cancel());
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        if (cancellation instanceof MySqlOperationError) {
          expect(cancellation.primary === control.failure).assertTrue();
          expect(cancellation.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        }
        fixture.peer.emitResponse(binaryIntResult([42]));
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === control.failure).assertTrue();
          expect(failure.nativeCode).assertEqual(1227);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(sink.ends[0].statusKnown).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
        await executing;
      }
    });

    it('retainsFirstPreparedCancelCleanupFailureAfterLaterSuccess', 0, async () => {
      const cleanup = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic first control cleanup.',
        'FIRST_CLEANUP', '08S01');
      const first = new ControlConnection();
      first.cleanupFailure = cleanup;
      const second = new ControlConnection();
      second.closing = new Gate();
      const controls = [first, second];
      let nextControl = 0;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => controls[nextControl++]);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO completed_sql', []));
      try {
        await flushPrepared();
        const firstFailure = await preparedFailureOf(fixture.connection.cancel());
        expect(firstFailure instanceof MySqlOperationError).assertTrue();
        if (firstFailure instanceof MySqlOperationError) {
          expect(firstFailure.primary === cleanup).assertTrue();
          expect(firstFailure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        const retry = fixture.connection.cancel();
        const concurrent = fixture.connection.cancel();
        expect(concurrent === retry).assertTrue();
        const retried = preparedFailureOf(retry);
        await second.cleaning.promise;
        expect(nextControl).assertEqual(2);
        second.closing.release();
        expect((await retried) === null).assertTrue();
        fixture.peer.emitResponse([okPayload()]);
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === cleanup).assertTrue();
          expect(failure.nativeCode).assertEqual('FIRST_CLEANUP');
          expect(failure.sqlState).assertEqual('08S01');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
          expect(failure.cleanupErrors[0] === cleanup).assertTrue();
        }
        expect(first.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(second.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        releasePreparedControl(second);
        await fixture.close();
        await executing;
      }
    });

    it('aggregatesPreparedCancellationFailuresChronologicallyWithOriginalCause', 0, async () => {
      const original = new Error('Synthetic first control opening cause.');
      const first = new OpeningFailureControl(original);
      const second = new ControlConnection();
      second.failure = ArkDbError.server('Synthetic second KILL denial.', 1227, '42000');
      second.cleanupFailure = ArkDbError.network('Synthetic second control cleanup.');
      const third = new ControlConnection();
      const controls: ControlConnection[] = [first, second, third];
      let nextControl = 0;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => controls[nextControl++]);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO completed_sql', []));
      try {
        await flushPrepared();
        const firstFailure = await preparedFailureOf(fixture.connection.cancel());
        const secondFailure = await preparedFailureOf(fixture.connection.cancel());
        expect(firstFailure instanceof MySqlOperationError).assertTrue();
        expect(secondFailure instanceof MySqlOperationError).assertTrue();
        if (firstFailure instanceof MySqlOperationError) {
          expect(firstFailure.originalCause === original).assertTrue();
          expect(firstFailure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        if (secondFailure instanceof MySqlOperationError) {
          expect(secondFailure.primary === second.failure).assertTrue();
          expect(secondFailure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          expect(secondFailure.cleanupErrors[0] === second.cleanupFailure).assertTrue();
        }
        expect((await fixture.connection.cancel()).outcome).assertEqual(CancellationOutcome.Requested);
        fixture.peer.emitResponse([okPayload()]);
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError && firstFailure instanceof MySqlOperationError) {
          expect(failure.primary === firstFailure.primary).assertTrue();
          expect(failure.originalCause === original).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0] === secondFailure).assertTrue();
        }
        expect(nextControl).assertEqual(3);
        expect(first.commands.length).assertEqual(0);
        expect(second.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(third.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
        await executing;
      }
    });

    it('retainsPreparedSqlPrimaryAndEveryCancellationFailureInAttemptOrder', 0, async () => {
      const first = new ControlConnection();
      first.cleanupFailure = ArkDbError.network('Synthetic first acknowledged control cleanup.');
      const second = new ControlConnection();
      second.failure = ArkDbError.server('Synthetic second KILL denial.', 1227, '42000');
      second.cleanupFailure = ArkDbError.network('Synthetic second control cleanup.');
      const third = new ControlConnection();
      const controls = [first, second, third];
      let nextControl = 0;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => controls[nextControl++]);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const executing = preparedFailureOf(executor.execute('DO rejected_sql', []));
      try {
        await flushPrepared();
        const firstFailure = await preparedFailureOf(fixture.connection.cancel());
        const secondFailure = await preparedFailureOf(fixture.connection.cancel());
        expect(firstFailure instanceof MySqlOperationError).assertTrue();
        expect(secondFailure instanceof MySqlOperationError).assertTrue();
        expect((await fixture.connection.cancel()).outcome).assertEqual(CancellationOutcome.Requested);
        fixture.peer.emitResponse([errorPayload(1213, '40001')]);
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.nativeCode).assertEqual(1213);
          expect(failure.sqlState).assertEqual('40001');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0] === firstFailure).assertTrue();
          expect(failure.cleanupErrors[1] === secondFailure).assertTrue();
        }
        expect(nextControl).assertEqual(3);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
        await executing;
      }
    });

    it('retainsPromptPhysicalCloseFailureWhenPreparedStreamUnwindsAfterCloseSettles', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([42]));
      fixture.peer.closeFailure = new Error('Synthetic prompt physical cleanup failure.');
      const sink = new PreparedHeldRowsSink();
      const executing = preparedFailureOf(executor.executeStream(
        'SELECT 42', [], new QueryOptions(), sink));
      await sink.entered.promise;
      const closeTask = fixture.close();
      const closed = preparedFailureOf(closeTask);
      try {
        const closeFailure = await closed;
        expect(closeFailure instanceof MySqlOperationError).assertTrue();
        expect(fixture.connection.close() === closeTask).assertTrue();
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError && closeFailure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.primary === closeFailure.primary).assertFalse();
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0] === closeFailure).assertTrue();
          expect(closeFailure.kind).assertEqual(ArkDbErrorKind.Network);
          expect(closeFailure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(sink.ends.length).assertEqual(0);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.connection.sessionStatus.known).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect((await preparedFailureOf(fixture.connection.ping()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
      } finally {
        sink.acknowledgement.release();
        await closed;
        await executing;
      }
    });

    it('ordersSettledControlAndPromptCloseFailuresAfterPreparedStreamPrimary', 0, async () => {
      const control = new ControlConnection();
      control.cleanupFailure = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic settled control cleanup failure.', 'CONTROL_CLEANUP', '08S01');
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const sink = new PreparedHeldRowsSink();
      const executing = preparedFailureOf(executor.executeStream(
        'SELECT 42', [], new QueryOptions(), sink));
      try {
        await flushPrepared();
        const cancellation = await preparedFailureOf(fixture.connection.cancel());
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        if (cancellation instanceof MySqlOperationError) {
          expect(cancellation.primary === control.cleanupFailure).assertTrue();
          expect(cancellation.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        fixture.peer.emitResponse(binaryIntResult([42]));
        await sink.entered.promise;
        fixture.peer.closeFailure = new Error('Synthetic prompt physical cleanup after control failure.');
        const closeFailure = await preparedFailureOf(fixture.close());
        expect(closeFailure instanceof MySqlOperationError).assertTrue();
        const failure = await executing;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError && closeFailure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.primary === control.cleanupFailure).assertFalse();
          expect(failure.primary === closeFailure.primary).assertFalse();
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0] === cancellation).assertTrue();
          expect(failure.cleanupErrors[1] === closeFailure).assertTrue();
        }
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect(sink.ends.length).assertEqual(0);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        sink.acknowledgement.release();
        releasePreparedControl(control);
        await preparedFailureOf(fixture.close());
        await executing;
      }
    });

    it('preservesCompletedPreparedSqlOutcomeWhenOnlyConcurrentPhysicalCloseFails', 0, async () => {
      const control = new ControlConnection();
      control.closing = new Gate();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      let executionSettled = false;
      const executing = preparedFailureOf(executor.execute('DO completed_sql', [])).then(
        (failure: ArkDbError | null): ArkDbError | null => { executionSettled = true; return failure; });
      await flushPrepared();
      let cancellationSettled = false;
      const cancelling = fixture.connection.cancel().then((result: QueryCancellationResult): QueryCancellationResult => {
        cancellationSettled = true;
        return result;
      });
      try {
        await control.cleaning.promise;
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(control.closed).assertTrue();
        fixture.peer.emitResponse([okPayload()]);
        await flushPrepared();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(executionSettled).assertFalse();
        expect(cancellationSettled).assertFalse();
        fixture.peer.closeFailure = new Error('Synthetic close cleanup after completed SQL.');
        const closing = preparedFailureOf(fixture.close());
        await flushPrepared();
        expect(executionSettled).assertFalse();
        expect(cancellationSettled).assertFalse();
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        control.closing.release();
        expect((await cancelling).outcome).assertEqual(CancellationOutcome.Requested);
        const closeFailure = await closing;
        const failure = await executing;
        expect(closeFailure instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError && closeFailure instanceof MySqlOperationError) {
          expect(failure.primary === closeFailure.primary).assertTrue();
          expect(failure.kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
          expect(failure.cleanupErrors.length).assertEqual(closeFailure.cleanupErrors.length);
          expect(failure.originalCause === closeFailure.originalCause).assertTrue();
          expect(closeFailure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect((await preparedFailureOf(fixture.connection.ping()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
      } finally {
        releasePreparedControl(control);
        await preparedFailureOf(fixture.close());
        await preparedFailureOf(cancelling);
        await executing;
      }
    });

    it('preservesCompletedPreparedStreamOutcomeAfterAllAcksBeforeCloseFailure', 0, async () => {
      const control = new ControlConnection();
      control.closing = new Gate();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      const sink = new PreparedCompletedAcknowledgementSink();
      let executionSettled = false;
      const executing = preparedFailureOf(executor.executeStream(
        'SELECT completed_sql', [], new QueryOptions(), sink)).then(
        (failure: ArkDbError | null): ArkDbError | null => { executionSettled = true; return failure; });
      await flushPrepared();
      let cancellationSettled = false;
      const cancelling = fixture.connection.cancel().then((result: QueryCancellationResult): QueryCancellationResult => {
        cancellationSettled = true;
        return result;
      });
      try {
        await control.cleaning.promise;
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(control.closed).assertTrue();
        fixture.peer.emitResponse(binaryIntResult([42]));
        await sink.entered.promise;
        expect(sink.acknowledged).assertFalse();
        expect(executionSettled).assertFalse();
        sink.acknowledgement.release();
        await flushPrepared();
        expect(sink.acknowledged).assertTrue();
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(sink.ends.length).assertEqual(1);
        expect(sink.ends[0].statusKnown).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(executionSettled).assertFalse();
        expect(cancellationSettled).assertFalse();
        fixture.peer.closeFailure = new Error('Synthetic close cleanup after all result acknowledgements.');
        const closing = preparedFailureOf(fixture.close());
        await flushPrepared();
        expect(executionSettled).assertFalse();
        expect(cancellationSettled).assertFalse();
        expect(fixture.peer.closeCalls).assertEqual(1);
        control.closing.release();
        expect((await cancelling).outcome).assertEqual(CancellationOutcome.Requested);
        const closeFailure = await closing;
        const failure = await executing;
        expect(closeFailure instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError && closeFailure instanceof MySqlOperationError) {
          expect(failure.primary === closeFailure.primary).assertTrue();
          expect(failure.kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
          expect(failure.cleanupErrors.length).assertEqual(closeFailure.cleanupErrors.length);
          expect(failure.originalCause === closeFailure.originalCause).assertTrue();
          expect(closeFailure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(sink.ends.length).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        sink.acknowledgement.release();
        releasePreparedControl(control);
        await preparedFailureOf(fixture.close());
        await preparedFailureOf(cancelling);
        await executing;
      }
    });
  });
}
