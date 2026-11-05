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

export default function mySqlCancellationTextTest(): void {
  describe('MySQL connection-owned cancellation lifetime', () => {
    it('propagatesReadyCloseQuitFailureAfterSocketShutdown', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const primary = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic QUIT write failure.',
        'QUIT_SEND', '08S01');
      fixture.peer.writeFailure = primary;
      const sends = fixture.peer.sends;
      const failure = await fixture.connection.close().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      expect(failure instanceof MySqlOperationError).assertTrue();
      if (failure instanceof MySqlOperationError) {
        expect(failure.primary === primary).assertTrue();
        expect(failure.kind).assertEqual(ArkDbErrorKind.Network);
        expect(failure.nativeCode).assertEqual('QUIT_SEND');
        expect(failure.sqlState).assertEqual('08S01');
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      }
      expect(fixture.peer.sends).assertEqual(sends + 1);
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.listenerCount).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
    });

    it('preservesQuitPrimaryAndSocketCleanupFailureTogether', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const primary = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic QUIT write failure.',
        'QUIT_SEND', '08S01');
      fixture.peer.writeFailure = primary;
      fixture.peer.closeFailure = new Error('Synthetic socket cleanup failure.');
      const failure = await fixture.connection.close().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      expect(failure instanceof MySqlOperationError).assertTrue();
      if (failure instanceof MySqlOperationError) {
        expect(failure.primary === primary).assertTrue();
        expect(failure.nativeCode).assertEqual('QUIT_SEND');
        expect(failure.sqlState).assertEqual('08S01');
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      }
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.listenerCount).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
    });

    it('keepsOrdinaryNoSuchThreadCancellationCompatible', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        const primary = ArkDbError.server('Synthetic no-such-thread rejection.', 1094, 'HY000');
        fixture.control.failure = mode === 0 ? primary :
          new MySqlOperationError(primary, [], MySqlExecutionOutcome.ServerRejected);
        await fixture.open();
        const query = fixture.connection.query('SELECT 1').then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        try {
          const result = await fixture.connection.cancel();
          expect(result.outcome).assertEqual(CancellationOutcome.NotRunning);
          expect(fixture.control.closed).assertTrue();
          expect(fixture.control.commands[0]).assertEqual('KILL QUERY 42');
          fixture.peer.emitMessage(ok());
          expect((await query) === null).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('retainsNoSuchThreadQueryCleanupInsteadOfReportingNotRunning', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        const primary = ArkDbError.server('Synthetic no-such-thread rejection.', 1094, 'HY000');
        const queryCleanup = ArkDbError.network('Synthetic control query cleanup failure.');
        const closeCleanup = ArkDbError.timeout('Synthetic control close cleanup failure.');
        fixture.control.failure = new MySqlOperationError(primary, [queryCleanup],
          MySqlExecutionOutcome.ServerRejected);
        if (mode === 1) fixture.control.cleanupFailure = closeCleanup;
        await fixture.open();
        const query = fixture.connection.query('SELECT 1').then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        try {
          const failure = await fixture.connection.cancel().then(
            (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.primary === primary).assertTrue();
            expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
            expect(failure.code).assertEqual(1094);
            expect(failure.nativeCode).assertEqual(1094);
            expect(failure.sqlState).assertEqual('HY000');
            expect(failure.cleanupErrors.length).assertEqual(mode === 0 ? 1 : 2);
            expect(failure.cleanupErrors[0] === queryCleanup).assertTrue();
            if (mode === 1) expect(failure.cleanupErrors[1] === closeCleanup).assertTrue();
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          }
          fixture.peer.emitMessage(ok());
          expect((await query) === null).assertTrue();
          expect(fixture.control.closed).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('rejectsCancellationDuringInterruptedResultEndCallback', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        const result = await fixture.connection.cancel();
        expect(result.outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(fixture.control.commands.length).assertEqual(0);
        expect(fixture.peer.sends).assertEqual(2);
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        fixture.peer.emitMessage(ok());
        expect((await query) === null).assertTrue();
        expect(fixture.connection.sessionStatus.known).assertTrue();
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await query;
      }
    });

    it('settlesPendingKillAndControlCleanupBeforeOwnedStatusRefresh', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.executing = new Gate();
      fixture.control.closing = new Gate();
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      const cancellation = fixture.connection.cancel().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        fixture.control.executing.release();
        await fixture.control.cleaning.promise;
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        fixture.control.closing.release();
        expect((await cancellation) === null).assertTrue();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        fixture.peer.emitMessage(ok());
        expect((await query) === null).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.connection.sessionStatus.known).assertTrue();
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await cancellation;
        await query;
      }
    });

    it('retiresUnknownPendingKillWithoutDispatchingStatusRefresh', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.executing = new Gate();
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      const cancellation = fixture.connection.cancel().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        timers.expire();
        const cancelled = await cancellation;
        const failure = await query;
        expect(cancelled instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (cancelled instanceof MySqlOperationError && failure instanceof MySqlOperationError) {
          expect(failure.primary === cancelled.primary).assertTrue();
          expect(failure.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.peer.sends).assertEqual(2);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        const reopening = await fixture.connection.connect().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(reopening!.kind).assertEqual(ArkDbErrorKind.Protocol);
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await cancellation;
        await query;
      }
    });

    it('preservesPendingCancellationFailureBeforeStatusRefresh', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.executing = new Gate();
      const primary = ArkDbError.server('Synthetic pending KILL rejection.', 1227, '42000');
      const cleanup = ArkDbError.network('Synthetic pending control cleanup failure.');
      fixture.control.failure = primary;
      fixture.control.cleanupFailure = cleanup;
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      const cancellation = fixture.connection.cancel().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        fixture.control.executing.release();
        const cancelled = await cancellation;
        const failure = await query;
        expect(cancelled instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === primary).assertTrue();
          expect(failure.code).assertEqual(1227);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0] === cleanup).assertTrue();
        }
        expect(fixture.peer.sends).assertEqual(2);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
      } finally {
        sink.acknowledgement.release();
        const closing = await fixture.close().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        if (closing !== null) {
          expect(closing instanceof MySqlOperationError).assertTrue();
          if (closing instanceof MySqlOperationError) {
            expect(closing.primary === primary).assertTrue();
            expect(closing.cleanupErrors[0] === cleanup).assertTrue();
          }
        }
        await cancellation;
        await query;
      }
    });

    it('retainsTruncationHookCauseAfterSuccessfulFallbackDrain', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        await fixture.open();
        const original: ArkDbError | Error = mode === 0 ? new Error('Synthetic truncation hook failure.') :
          ArkDbError.server('Synthetic truncation hook server-kind failure.', 1317, '45000');
        const sink = new FailingTruncationSink(original);
        const options = new QueryOptions();
        options.maxRows = 1;
        let settled = false;
        const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
          (): ArkDbError | null => { settled = true; return null; },
          (error: ArkDbError): ArkDbError | null => { settled = true; return error; });
        try {
          fixture.peer.emitMessage(truncatingSelectPrefix());
          await sink.failed.promise;
          await flushCancellation();
          expect(settled).assertFalse();
          expect(fixture.peer.closeCalls).assertEqual(0);
          fixture.peer.emitMessage(frame(6, new Uint8Array([0xfe, 0, 0, 2, 0])));
          const failure = await query;
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.originalCause === original).assertTrue();
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
            expect(failure.cleanupErrors.length).assertEqual(0);
            if (original instanceof ArkDbError) {
              expect(failure.primary === original).assertTrue();
              expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
              expect(failure.code).assertEqual(1317);
              expect(failure.sqlState).assertEqual('45000');
              expect(fixture.connection.isInterruptionError(failure)).assertFalse();
            }
          }
          expect(sink.ends.length).assertEqual(1);
          expect(sink.ends[0].truncated).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
          expect(fixture.connection.sessionStatus.known).assertTrue();
          const next = fixture.connection.query('SELECT 2');
          fixture.peer.emitMessage(ok());
          await next;
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('preservesTruncationCancellationPrimaryAndAllCleanupCauses', 0, async () => {
      const fixture = new CancellationFixture();
      const primary = ArkDbError.server('Synthetic truncation KILL rejection.', 1227, '42000');
      const innerCleanup = ArkDbError.network('Synthetic control query cleanup failure.');
      const closeCleanup = ArkDbError.timeout('Synthetic control close cleanup failure.');
      fixture.control.failure = new MySqlOperationError(primary, [innerCleanup],
        MySqlExecutionOutcome.ServerRejected);
      fixture.control.cleanupFailure = closeCleanup;
      await fixture.open();
      const sink = new CancellingTruncationSink(fixture.connection);
      const options = new QueryOptions();
      options.maxRows = 1;
      let settled = false;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => { settled = true; return null; },
        (error: ArkDbError): ArkDbError | null => { settled = true; return error; });
      try {
        fixture.peer.emitMessage(truncatingSelectPrefix());
        await sink.failed.promise;
        await flushCancellation();
        expect(settled).assertFalse();
        fixture.peer.emitMessage(frame(6, new Uint8Array([0xfe, 0, 0, 2, 0])));
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === primary).assertTrue();
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.nativeCode).assertEqual(1227);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.originalCause === sink.failure).assertTrue();
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0] === innerCleanup).assertTrue();
          expect(failure.cleanupErrors[1] === closeCleanup).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(fixture.control.closed).assertTrue();
        expect(sink.ends.length).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        await fixture.close();
        await query;
      }
    });

    it('retainsTruncationHookFailureWhenFallbackDrainAndCleanupFail', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const original = new Error('Synthetic truncation hook failure before drain loss.');
      const sink = new FailingTruncationSink(original);
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        fixture.peer.emitMessage(truncatingSelectPrefix());
        await sink.failed.promise;
        await flushCancellation();
        fixture.peer.closeFailure = new Error('Synthetic drain-loss cleanup failure.');
        fixture.peer.emitError();
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === original).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.cleanupErrors[1].kind).assertEqual(ArkDbErrorKind.Network);
        }
        expect(sink.ends.length).assertEqual(0);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
      } finally {
        const cleanup = await fixture.close().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
        await query;
      }
    });

    it('keepsLegacyStreamDefaultsOutOfPortableFeatureObservations', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      try {
        const native = new NativeStreamRecordingSink();
        const nativeQuery = fixture.connection.queryStream('SELECT value', new QueryOptions(), native);
        fixture.peer.emitMessage(selectResult());
        const summary = await nativeQuery;
        expect(summary instanceof MySqlQueryExecutionSummary).assertTrue();
        expect(native.starts[0] instanceof MySqlQueryResultMeta).assertTrue();
        expect(native.chunks[0] instanceof MySqlQueryRowChunk).assertTrue();
        expect(native.ends[0] instanceof MySqlQueryResultSummary).assertTrue();
        expect(native.chunks[0].rows[0][0]).assertEqual('one');
        expect(native.ends[0].lastInsertId).assertEqual(0n);
        expect(native.ends[0].warningCount).assertEqual(3);

        const portable = new StreamRecordingSink();
        const portableQuery = fixture.connection.features.streaming!.queryStream(
          'SELECT value', new QueryOptions(), portable);
        fixture.peer.emitMessage(selectResult());
        await portableQuery;
        expect(portable.chunks[0].rows[0][0]).assertEqual('one');
        expect(portable.ends[0].lastInsertId === undefined).assertTrue();
        expect(portable.ends[0].warningCount).assertEqual(3);
      } finally { await fixture.close(); }
    });

    it('reportsARequestWithoutClaimingTheOriginalExecutionHasSettled', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT SLEEP(1)')
          .then((): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        fixture.connection.serverInfo.connectionHandle = '999';
        const result = await fixture.connection.features.cancellation!.cancel();
        expect(result.outcome).assertEqual(CancellationOutcome.Requested);
        expect(result.connectionReuse).assertEqual(ConnectionReuse.AwaitingCompletion);
        expect(fixture.control.commands[0]).assertEqual('KILL QUERY 42');
        expect(fixture.control.closed).assertTrue();
        fixture.peer.emitMessage(interrupted());
        const failure = await query;
        expect(failure !== null).assertTrue();
        expect(fixture.connection.isInterruptionError(failure!)).assertTrue();
        expect(fixture.connection.sessionStatus.known).assertFalse();
        expect((await fixture.connection.cancel()).connectionReuse)
          .assertEqual(ConnectionReuse.RequiresSynchronization);
        const ping = fixture.connection.ping();
        fixture.peer.emitMessage(ok());
        await ping;
        expect(fixture.connection.sessionStatus.known).assertTrue();
      } finally { await fixture.close(); }
    });

    it('neverSendsALateKillForACompletedExecutionOrAllowsItToHitTheNextOne', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.opening = new Gate();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        const cancellation = fixture.connection.cancel();
        fixture.peer.emitMessage(ok());
        await query;
        let blocked: ArkDbError | null = null;
        try { await fixture.connection.query('SELECT 2'); } catch (error) { blocked = error as ArkDbError; }
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        fixture.control.opening.release();
        expect((await cancellation).outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(fixture.control.commands.length).assertEqual(0);
        const next = fixture.connection.query('SELECT 2');
        fixture.peer.emitMessage(ok());
        await next;
        expect(fixture.control.commands.length).assertEqual(0);
      } finally { await fixture.close(); }
    });

    it('surfacesControlCleanupFailureInsteadOfReportingCancellationSuccess', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      try {
        fixture.control.cleanupFailure = ArkDbError.network('Synthetic control cleanup failure.');
        const query = fixture.connection.query('SELECT 1');
        let failure: ArkDbError | null = null;
        try { await fixture.connection.cancel(); } catch (error) { failure = error as ArkDbError; }
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Network);
        fixture.peer.emitMessage(ok());
        await query;
        expect(fixture.control.closed).assertTrue();
      } finally { await fixture.close(); }
    });

    it('preservesPrimaryAndCleanupErrors', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        const primary = ArkDbError.server('Synthetic control rejection.',
          mode === 0 ? 1227 : 'ER_SPECIFIC_ACCESS_DENIED_ERROR', '42000');
        const cleanup = ArkDbError.network('Synthetic control cleanup failure.');
        fixture.control.failure = primary;
        fixture.control.cleanupFailure = cleanup;
        await fixture.open();
        let queryFailure: Object | null = null;
        const query = fixture.connection.query('SELECT 1').then((): void => {},
          (error: Object): void => { queryFailure = error; });
        try {
          let failure: ArkDbError | null = null;
          try { await fixture.connection.cancel(); } catch (error) { failure = error as ArkDbError; }
          expect(failure instanceof ArkDbError).assertTrue();
          expect(failure instanceof MySqlOperationError).assertTrue();
          expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure!.nativeCode).assertEqual(mode === 0 ? 1227 : 'ER_SPECIFIC_ACCESS_DENIED_ERROR');
          expect(failure!.code).assertEqual(mode === 0 ? 1227 : undefined);
          expect(failure!.sqlState).assertEqual('42000');
          expect(failure!.message.indexOf('cleanup failed') >= 0).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.primary === primary).assertTrue();
            expect(failure.cleanupErrors.length).assertEqual(1);
            expect(failure.cleanupErrors[0] === cleanup).assertTrue();
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          }
          fixture.peer.emitMessage(ok());
          await query;
          expect(queryFailure === null).assertTrue();
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('doesNotTreatConsumerServerErrorsAsConsumedWireRejections', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const primary = ArkDbError.server('Synthetic consumer failure.', 1317, '45000');
      try {
        const query = fixture.connection.features.streaming!.queryStream(
          'SELECT value', new QueryOptions(), new FailingStreamSink(primary)).then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        fixture.peer.emitMessage(selectResult());
        const failure = await query;
        expect(failure instanceof ArkDbError).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure!.code).assertEqual(1317);
        expect(failure!.sqlState).assertEqual('45000');
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === primary).assertTrue();
          expect(failure.originalCause === primary).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.connection.isInterruptionError(failure!)).assertFalse();
        expect(new MySqlExecutionController(fixture.control).isInterruptionError(failure!)).assertFalse();
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
      } finally { await fixture.close(); }
    });
  });
}
