import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState,
  ConnectionTimerPort, DbConnection, QueryCancellationResult, QueryResult, ServerInfo
} from '@arkdb/core';
import {
  MySqlCommandKind, MySqlCursorExecutor, MySqlExecutionEvent,
  MySqlExecutionEventType, MySqlExecutionObserver, requireMySqlFeatures
} from '../../../../../Index';
import {
  initializeMySqlExecutionObserverInternal
} from '../../../../main/ets/mysql/MySqlConnection';
import { MySqlLongDataExecutor } from '../../../../main/ets/mysql/api/MySqlFeatureContracts';
import { MySqlByteSource } from '../../../../main/ets/mysql/features/longdata/MySqlByteSource';
import {
  MySqlLongDataOptions, MySqlLongParameter, MySqlLongParameterKind
} from '../../../../main/ets/mysql/features/longdata/MySqlLongDataOptions';
import {
  MySqlParameter, MySqlParameterType
} from '../../../../main/ets/mysql/features/prepared/MySqlParameter';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../main/ets/mysql/model/MySqlOperationError';
import { Capabilities, StatusFlags } from '../../../../main/ets/mysql/protocol/Constants';
import { PacketReader } from '../../../../main/ets/mysql/protocol/PacketReader';
import {
  PreparedExecutionFixture, PreparedGate, PreparedSocket, cursorOpenResult,
  errorPayload, flushPrepared, okPayload, hex, preparedFailureOf, prepareResponse
} from '../prepared/fixtures/PreparedExecutionFixture';
import {
  LongDataExecutionObserver, ChunkByteSource, PendingByteSource, FailingByteSource,
  OrdinaryReadFailureSource, OrdinaryCloseFailureSource, EventByteSource, ClosingFailureSource,
  ZeroByteClosingFailureSource, LongDataTimerTask, LongDataTimers, ChunkThenPendingSource,
  LongDataControlConnection, ParsedExecutePacket, parseLastExecute, expectOneObservedLongDataCommand
} from './fixtures/LongDataFixture';

export default function longDataCancellationTest(): void {
  describe('MySQL prepared long data', () => {
    it('uploadTimeoutDuringReadResetsWithoutSendingKill', 0, async () => {
      const timers = new LongDataTimers();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, undefined, timers);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()], [okPayload()]);
      const source = new ChunkThenPendingSource();
      const options = new MySqlLongDataOptions();
      options.uploadTimeoutMs = 10;
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)],
          options));
        await source.pendingEntered.promise;
        timers.advance(10);
        const failure = await running;

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(source.closeCount).assertEqual(1);
        expect(statement.closed).assertFalse();
        await statement.execute([
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))
        ]);
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('lateReadCompletionAfterAbsoluteExpiryResetsWithoutExecute', 0, async () => {
      const timers = new LongDataTimers();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, undefined, timers);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const source = new PendingByteSource();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const options = new MySqlLongDataOptions();
        options.uploadTimeoutMs = 10;
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)],
          options));
        await source.readEntered.promise;
        timers.elapseWithoutFiring(10);
        source.release(null);
        const failure = await running;

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(timers.fireNextDue()).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('manualCancelDuringUploadReturnsNotRunning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const source = new PendingByteSource();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));
        await source.readEntered.promise;
        const cancellation = await fixture.connection.cancel();
        expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
        source.release(null);
        expect((await running) === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('manualCancelDuringFinalExecuteUsesPreparedConvergence', 0, async () => {
      const control = new LongDataControlConnection();
      control.executing = new PreparedGate();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      fixture.peer.holdCommand = 0x17;
      let running: Promise<ArkDbError | null> | null = null;
      let cancelling: Promise<QueryCancellationResult> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])]))]));
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,23');
        cancelling = fixture.connection.cancel();
        await control.dispatched.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushPrepared();
        control.executing.release();

        expect((await cancelling).outcome).assertEqual(CancellationOutcome.Requested);
        expect((await running) === null).assertTrue();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(control.closed).assertTrue();
        await statement.close();
      } finally {
        if (control.executing !== null) control.executing.release();
        fixture.peer.holdCommand = -1;
        await fixture.close();
        if (cancelling !== null) await preparedFailureOf(cancelling);
        if (running !== null) await running;
      }
    });
  });
}
