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

export default function longDataFailureTest(): void {
  describe('MySQL prepared long data', () => {
    it('sourceCloseFailurePreventsExecuteAndIsPreserved', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const closeFailure = ArkDbError.network('Synthetic source close failure.');
      const source = new ClosingFailureSource(closeFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === closeFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('firstReadFailureResetsBeforeReturning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const sourceFailure = ArkDbError.network('Synthetic first source read failure.');
      const source = new FailingByteSource([], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === sourceFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('resetContinuationRetiresBeforeReturningTheUploadFailure', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1),
        [okPayload(StatusFlags.MORE_RESULTS_EXISTS)], [okPayload()]);
      const sourceFailure = ArkDbError.network('Synthetic source read failure.');
      const source = new FailingByteSource([], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === sourceFailure).assertTrue();
          expect(failure.cleanupErrors.length > 0).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
      } finally {
        await fixture.close();
      }
    });

    it('preservesSourceOperationErrorIdentityAndOutcome', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const sourcePrimary = ArkDbError.network('Synthetic nested source failure.');
      const sourceCleanup = ArkDbError.protocol('Synthetic nested source cleanup failure.');
      const sourceFailure = new MySqlOperationError(sourcePrimary,
        [sourceCleanup], MySqlExecutionOutcome.Completed);
      const source = new FailingByteSource([], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === sourceFailure).assertTrue();
          expect(failure.primary instanceof MySqlOperationError).assertTrue();
          if (failure.primary instanceof MySqlOperationError) {
            expect(failure.primary.outcome).assertEqual(MySqlExecutionOutcome.Completed);
          }
          expect(failure.cleanupErrors.length).assertEqual(0);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('preservesOrdinaryReadFailureIdentity', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const sourceFailure = new Error('Synthetic ordinary source read failure.');
      const source = new OrdinaryReadFailureSource(sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === sourceFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.readCount).assertEqual(1);
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('preservesOrdinaryCloseFailureIdentity', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const closeFailure = new Error('Synthetic ordinary source close failure.');
      const source = new OrdinaryCloseFailureSource(closeFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === closeFailure).assertTrue();
          expect(failure.cleanupErrors.length).assertEqual(0);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('invalidFirstChunkResetsBeforeReturning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array(0)]))]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('zeroByteCloseFailureResetsBeforeReturning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const closeFailure = ArkDbError.network('Synthetic zero-byte source close failure.');
      const source = new ZeroByteClosingFailureSource(closeFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === closeFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(source.closeCount).assertEqual(1);
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('timedOutLongDataWriteRetiresWithoutResetOrLateReturn', 0, async () => {
      const timers = new LongDataTimers();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, undefined, timers);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      const writeGate = new PreparedGate();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        fixture.peer.sendResult = writeGate.promise;
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const options = new MySqlLongDataOptions();
        options.uploadTimeoutMs = 10;
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])]))],
          options));
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24');
        timers.elapseWithoutFiring(10);
        expect(timers.fireNextDue()).assertTrue();
        const failure = await running;

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length > 0).assertTrue();
        }
        expect(timers.fireNextDue()).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
      } finally {
        writeGate.release();
        fixture.peer.sendResult = null;
        if (running !== null) await running;
        await fixture.close();
      }
    });
  });
}
