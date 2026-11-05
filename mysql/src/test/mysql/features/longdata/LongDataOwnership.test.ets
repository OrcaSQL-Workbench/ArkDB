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

export default function longDataOwnershipTest(): void {
  describe('MySQL prepared long data', () => {
    it('longDataHasNoPerChunkAck', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const observer = new LongDataExecutionObserver();
      initializeMySqlExecutionObserverInternal(
        fixture.connection, observer, (): number => 100);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?');
        observer.events.length = 0;
        const longData: MySqlLongDataExecutor | undefined = fixture.connection.mysqlFeatures.longData;
        expect(longData !== undefined).assertTrue();
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const options = new MySqlLongDataOptions();
        options.chunkBytes = 2;
        await longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1, 2]), new Uint8Array([3])]))],
          options);

        expect(fixture.peer.commands().join(',')).assertEqual('22,24,24,23');
        expect(fixture.peer.writes[1][3]).assertEqual(0);
        expect(fixture.peer.writes[2][3]).assertEqual(0);
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual('180700000000000102');
        expect(hex(fixture.peer.writes[2].subarray(4))).assertEqual('1807000000000003');
        expectOneObservedLongDataCommand(observer);
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('connectionCloseDuringUploadConvergesWithoutLateExecute', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const observer = new LongDataExecutionObserver();
      initializeMySqlExecutionObserverInternal(
        fixture.connection, observer, (): number => 100);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      const source = new PendingByteSource();
      let settled = false;
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        observer.events.length = 0;
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]))
          .then((failure: ArkDbError | null): ArkDbError | null => {
            settled = true;
            return failure;
          });
        await source.readEntered.promise;
        expect(observer.events.length).assertEqual(1);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
        await fixture.connection.close();
        await flushPrepared();

        expect(settled).assertTrue();
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        expectOneObservedLongDataCommand(observer);
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('uploadFailureNeverExecutesStatementAndResetKeepsItUsable', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const observer = new LongDataExecutionObserver();
      initializeMySqlExecutionObserverInternal(
        fixture.connection, observer, (): number => 100);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()], [okPayload()]);
      const sourceFailure = ArkDbError.network('Synthetic long-data source failure.');
      const source = new FailingByteSource([new Uint8Array([1, 2])], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        observer.events.length = 0;
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
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(statement.closed).assertFalse();
        expect(source.closeCount).assertEqual(1);
        expectOneObservedLongDataCommand(observer);
        observer.events.length = 0;
        await statement.execute([
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))
        ]);
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26,23');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('cursorOwnershipRejectsLongDataBeforeSourceRead', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 1), prepareResponse(8), cursorOpenResult('value'), [okPayload()]);
      const events: string[] = [];
      const source = new EventByteSource(
        'long', events, [new Uint8Array([1])]);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = requireMySqlFeatures(fixture.connection).longData;
        const cursors: MySqlCursorExecutor | undefined =
          requireMySqlFeatures(fixture.connection).cursors;
        if (longData === undefined || cursors === undefined) {
          throw new Error('Expected long-data and cursor support.');
        }
        const cursor = await cursors.open('SELECT 1', []);
        const before = fixture.peer.commands().join(',');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure !== null).assertTrue();
        if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(source.readCount).assertEqual(0);
        expect(source.closeCount).assertEqual(0);
        expect(events.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual(before);
        await cursor.close();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('longDataOwnershipRejectsCursorBeforeWireWork', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 1), prepareResponse(8), cursorOpenResult('warm'),
        [okPayload()], [okPayload()]);
      const source = new PendingByteSource();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = requireMySqlFeatures(fixture.connection).longData;
        const cursors: MySqlCursorExecutor | undefined =
          requireMySqlFeatures(fixture.connection).cursors;
        if (longData === undefined || cursors === undefined) {
          throw new Error('Expected long-data and cursor support.');
        }
        const warm = await cursors.open('SELECT 1', []);
        await warm.close();
        fixture.peer.writes = [];
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));
        await source.readEntered.promise;
        const failure = await preparedFailureOf(cursors.open('SELECT 1', []));

        expect(failure !== null).assertTrue();
        if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.commands().join(',')).assertEqual('');
        source.release(null);
        expect((await running) === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('23');
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('resetFailureRetiresConnectionAndInvalidatesStatement', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [errorPayload(1243, 'HY000')]);
      const source = new FailingByteSource([new Uint8Array([1])],
        ArkDbError.network('Synthetic source failure before reset failure.'));
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length > 0).assertTrue();
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('truncatedResetOkDoesNotClaimSynchronization', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [new Uint8Array([0])]);
      const source = new FailingByteSource([new Uint8Array([1])],
        ArkDbError.network('Synthetic source failure before truncated reset.'));
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length > 0).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
      } finally {
        await fixture.close();
      }
    });
  });
}
