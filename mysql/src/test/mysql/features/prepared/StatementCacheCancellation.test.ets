import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState, DbConnection, QueryOptions, QueryTruncation
} from '@arkdb/core';
import { MySqlConnection } from '../../../../main/ets/mysql/MySqlConnection';
import {
  MySqlPreparedExecutor, MySqlPreparedStatement
} from '../../../../main/ets/mysql/api/MySqlPreparedContracts';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../../main/ets/mysql/features/prepared/PreparedStatement';
import {
  parseBufferedResultStream
} from '../../../../main/ets/mysql/command/ResultStream';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../../../../main/ets/mysql/execution/MySqlCommandGate';
import {
  MySqlSessionFingerprint
} from '../../../../main/ets/mysql/features/session/MySqlSessionInitialization';
import {
  MySqlStatementCache, MySqlStatementCacheBorrow
} from '../../../../main/ets/mysql/features/prepared/MySqlStatementCache';
import {
  ConnectionConfig, SslMode
} from '../../../../main/ets/mysql/model/ConnectionConfig';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlQueryResult } from '../../../../main/ets/mysql/model/MySqlQueryResult';
import {
  MySqlQueryResultSummary, MySqlResultSinkAdapter
} from '../../../../main/ets/mysql/model/MySqlQueryStream';
import {
  Capabilities, Collation, ColumnType
} from '../../../../main/ets/mysql/protocol/Constants';
import { PacketChannel } from '../../../../main/ets/mysql/protocol/PacketChannel';
import { PacketReader } from '../../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../../main/ets/mysql/protocol/PacketWriter';
import { TcpTransport } from '../../../../main/ets/mysql/transport/TcpTransport';
import {
  encodeBinaryParameters
} from '../../../../main/ets/mysql/features/prepared/BinaryParameterEncoder';
import {
  BinaryRowDecoder
} from '../../../../main/ets/mysql/features/prepared/BinaryRowDecoder';
import { socket } from '../../../../mock/NetworkKit.mock';
import { PacketTransportFixture } from '../../protocol/fixtures/PacketTransportFixture';
import {
  PreparedGate, PreparedRecordingSink, PreparedSocket, binaryIntResult, columnPayload, eofPayload,
  errorPayload, flushPrepared, framePacket, framedResponse, handshake, okPayload, preparedFailureOf, prepareResponse
} from './fixtures/PreparedExecutionFixture';
import {
  CacheSentPacket, StatementCacheTestConfig, StatementCacheConnection, StatementCacheSocket,
  StatementCacheFixture, commandFrames, commandStatementId, commandSql,
  cacheFingerprintResponse, CACHE_FINGERPRINT_SQL, CacheTextReply, CacheCoverageSocket,
  CacheCoverageFixture, CacheControlConnection, CacheEndAcknowledgementSink, CacheTruncationSink,
  CacheOwnedTransport, CacheOwnedHost, CacheOwnedFixture, cacheCoverageConfig,
  cacheContextPackets, cacheFingerprintRows, cacheFrames, cacheStatementIds,
  cacheProbeFrames, cacheCommandGate, cacheOperationFailure, cacheOwnedResult,
  assertCacheCancellationBarrier, CACHE_STATE_PRODUCER_SQL, CACHE_STATE_OBSERVER_SQL, CACHE_STATE_LITERAL_SQL,
  CACHE_STATE_GENERAL_SQL, CACHE_STATE_BINARY_SQL, CacheStatementStateHandle, CacheStatementStateCompletion,
  CacheStatementStateSocket, CacheStatementStateFixture, cacheStatementStateColumn, cacheStatementStateBinary,
  cacheStatementStateEqual, cacheStatementStateScalar
} from './fixtures/StatementCacheFixture';

export default function statementCacheCancellationTest(): void {
  describe('MySQL statement cache', () => {
    it('disabledCacheCloseFailureKeepsTheCompletedExecutionOutcome', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(0));
      try {
        const prepared = await fixture.open();
        fixture.peer.failCommand = 0x19;
        const failure = await cacheOperationFailure(prepared.execute('DO 1', []));
        expect(failure.primary === fixture.peer.failure).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally { await fixture.close(); }
    });

    it('uncertainPrepareWriteCannotRetainOrRetryAnAcquisition', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(2));
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.failCommand = 0x16;
        const failure = await cacheOperationFailure(prepared.execute('DO 2', []));
        expect(failure.primary === fixture.peer.failure).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,22');
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        const blocked = await preparedFailureOf(prepared.execute('DO 2', []));
        expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,22');
      } finally { await fixture.close(); }
    });

    it('rawWriteUncertaintyCannotReplayOrReuseThePreviousContext', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.failCommand = 0x03;
        fixture.peer.textReplies.push(new CacheTextReply('DO 2'));
        const failure = await cacheOperationFailure(fixture.connection.query('DO 2'));
        expect(failure.primary === fixture.peer.failure).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,3');
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7');
      } finally { await fixture.close(); }
    });

    it('rawCancellationHoldsAdmissionAndRetiresTheOldCacheContext', 0, async () => {
      await assertCacheCancellationBarrier(0x03);
    });

    it('cachedExecuteKeepsItsBorrowUntilKillAndControlCleanupSettle', 0, async () => {
      await assertCacheCancellationBarrier(0x17);
    });

    it('unknownCachedExecuteCancellationRetiresAndForbidsReconnect', 0, async () => {
      const control = new CacheControlConnection();
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(1), (): DbConnection => control);
      const prepared = await fixture.open();
      await prepared.execute('DO 1', []);
      fixture.peer.holdCommand = 0x17;
      const executeEntered = cacheCommandGate(fixture.peer, 0x17);
      const running = preparedFailureOf(prepared.execute('DO 1', []));
      await executeEntered.promise;
      control.peer.holdCommand = 0x03;
      control.peer.textReplies.push(new CacheTextReply('KILL QUERY 42'));
      const killEntered = cacheCommandGate(control.peer, 0x03);
      const cancellation = preparedFailureOf(fixture.connection.cancel());
      let interrupted = false;
      try {
        await killEntered.promise;
        fixture.peer.releaseHeldResponse();
        await flushPrepared();
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,7');
        control.peer.emitError();
        interrupted = true;
        const cancelled = await cancellation;
        const failure = await running;
        expect(cancelled instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(cancelled instanceof MySqlOperationError) || !(failure instanceof MySqlOperationError)) {
          throw new Error('Expected original unknown-KILL and prepared-operation failures.');
        }
        expect(cancelled.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(control.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23');
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        const blocked = await preparedFailureOf(prepared.execute('DO 1', []));
        expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
        const reconnect = await preparedFailureOf(fixture.connection.connect());
        expect(reconnect !== null && reconnect.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23');
      } finally {
        if (!interrupted) control.peer.emitError();
        await fixture.close();
        await cancellation;
        await running;
      }
    });

    it('streamConsumerAckRejectsBusyWithoutRetiringTheBorrow', 0, async () => {
      const fixture = new CacheCoverageFixture();
      const prepared = await fixture.open();
      fixture.peer.executeReplies.push(binaryIntResult([42]));
      const sink = new CacheEndAcknowledgementSink();
      let settled = false;
      const running = preparedFailureOf(prepared.executeStream('DO 1', [], new QueryOptions(), sink))
        .then((failure: ArkDbError | null): ArkDbError | null => { settled = true; return failure; });
      try {
        await sink.entered.promise;
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(settled).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        const execute = await preparedFailureOf(prepared.execute('DO 1', []));
        const prepare = await preparedFailureOf(prepared.prepare('DO 2'));
        const ping = await preparedFailureOf(fixture.connection.ping());
        const raw = await preparedFailureOf(fixture.connection.query('DO 2'));
        const stream = await preparedFailureOf(fixture.connection.queryStream(
          'DO 2', new QueryOptions(), new PreparedRecordingSink()));
        expect(execute !== null && execute.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(prepare !== null && prepare.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(ping !== null && ping.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(raw !== null && raw.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(stream !== null && stream.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        sink.acknowledgement.release();
        expect((await running) === null).assertTrue();
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,7');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        expect(fixture.connection.operationScopes.length).assertEqual(2);
        expect(fixture.connection.operationScopes[0].kind).assertEqual(MySqlCommandKind.QueryStream);
        expect(fixture.connection.operationScopes[1].kind).assertEqual(MySqlCommandKind.Query);
        expect(fixture.connection.fingerprintScopes.length).assertEqual(0);
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await running;
      }
    });

    it('truncatedStreamDrainsAllResultsBeforeReturningTheCachedBorrow', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(1), undefined,
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      const prepared = await fixture.open();
      fixture.peer.executeReplies.push(binaryIntResult([1, 2], 10).concat(binaryIntResult([3])));
      fixture.peer.holdCommand = 0x17;
      const entered = cacheCommandGate(fixture.peer, 0x17);
      const sink = new CacheTruncationSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const execution = prepared.executeStream('DO 1', [], options, sink);
      const failureObservation = preparedFailureOf(execution);
      try {
        await entered.promise;
        fixture.peer.releaseHeldPrefix(5);
        await sink.entered.promise;
        expect(sink.truncations.length).assertEqual(1);
        expect(sink.truncations[0].reason).assertEqual('rowLimit');
        expect(sink.ends.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        const blocked = await preparedFailureOf(prepared.execute('DO 1', []));
        expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
        fixture.peer.releaseHeldTail();
        const result = await execution;
        expect(result.resultSetCount).assertEqual(2);
        expect(result.rowCount).assertEqual(3);
        expect(result.loadedRowCount).assertEqual(1);
        expect(result.statusKnown).assertTrue();
        expect(sink.ends.length).assertEqual(2);
        expect(sink.ends[0].truncated).assertTrue();
        expect(sink.ends[1].truncated).assertTrue();
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,7');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
      } finally {
        await fixture.close();
        await failureObservation;
      }
    });

    it('unsynchronizedStreamDrainInvalidatesRatherThanReusesTheCache', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        fixture.peer.executeReplies.push(binaryIntResult([1, 2, 3]));
        const options = new QueryOptions();
        options.maxRows = 1;
        options.maxDrainBytes = 1;
        const failure = await cacheOperationFailure(prepared.executeStream(
          'DO 1', [], options, new PreparedRecordingSink()));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.connection.sessionStatus.known).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        const blocked = await preparedFailureOf(prepared.execute('DO 1', []));
        expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally { await fixture.close(); }
    });

    it('truncationConsumerFailureKeepsCompletedOutcomeAfterDrainAndOwnedClose', 0, async () => {
      const fixture = new CacheCoverageFixture();
      const original = new Error('Synthetic cache truncation consumer failure.');
      const sink = new CacheTruncationSink(original);
      try {
        const prepared = await fixture.open();
        fixture.peer.executeReplies.push(binaryIntResult([1, 2]));
        const options = new QueryOptions();
        options.maxRows = 1;
        const failure = await cacheOperationFailure(prepared.executeStream('DO 1', [], options, sink));
        expect(failure.originalCause === original).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(sink.ends.length).assertEqual(1);
        expect(sink.ends[0].truncated).assertTrue();
        expect(sink.ends[0].statusKnown).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7');
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(2);
      } finally { await fixture.close(); }
    });
  });
}
