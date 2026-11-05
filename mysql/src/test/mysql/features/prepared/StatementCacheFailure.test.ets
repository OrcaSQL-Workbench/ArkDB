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

export default function statementCacheFailureTest(): void {
  describe('MySQL statement cache', () => {
    it('cachedExecutionPrimarySurvivesStatementAndPhysicalCleanupFailures', 0, async () => {
      const fixture = new CacheCoverageFixture();
      const prepared = await fixture.open();
      fixture.peer.executeReplies.push([errorPayload(1213, '40001')]);
      fixture.peer.failCommand = 0x19;
      fixture.peer.closeFailure = new Error('Synthetic cache physical cleanup failure.');
      try {
        const failure = await cacheOperationFailure(prepared.execute('DO 1', []));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure.nativeCode).assertEqual(1213);
        expect(failure.sqlState).assertEqual('40001');
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.cleanupErrors.length).assertEqual(1);
        const cleanup = failure.cleanupErrors[0];
        expect(cleanup instanceof MySqlOperationError).assertTrue();
        if (!(cleanup instanceof MySqlOperationError)) throw new Error('Expected the owned CLOSE failure.');
        expect(cleanup.primary === fixture.peer.failure).assertTrue();
        expect(cleanup.cleanupErrors.length).assertEqual(1);
        expect(cleanup.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        const closing = await preparedFailureOf(fixture.close());
        expect(closing !== null && closing.kind === ArkDbErrorKind.Network).assertTrue();
      }
    });

    it('evictionCloseFailureDoesNotPrepareAReplacementOrReplaySql', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.failCommand = 0x19;
        const failure = await cacheOperationFailure(prepared.execute('DO 2', []));
        expect(failure.primary === fixture.peer.failure).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7');
        expect(commandFrames(fixture.peer, 0x16).map(commandSql).join('|')).assertEqual('DO 1');
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7');
      } finally { await fixture.close(); }
    });

    it('prepareServerRejectionClearsIdleEntriesWithoutRetainingAPhantom', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(2));
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.prepareReplies.push([errorPayload(1295, 'HY000')]);
        const failure = await cacheOperationFailure(prepared.execute('DO 2', []));
        expect(failure.nativeCode).assertEqual(1295);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,22,25');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7');
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8');
        expect(commandFrames(fixture.peer, 0x16).map(commandSql).join('|')).assertEqual('DO 1|DO 2|DO 1');
      } finally { await fixture.close(); }
    });

    it('prepareRejectionKeepsItsPrimaryWhenIdleCleanupAlsoFails', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(2));
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.prepareReplies.push([errorPayload(1295, 'HY000')]);
        fixture.peer.failCommand = 0x19;
        const failure = await cacheOperationFailure(prepared.execute('DO 2', []));
        expect(failure.nativeCode).assertEqual(1295);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.cleanupErrors.length).assertEqual(1);
        const cleanup = failure.cleanupErrors[0];
        expect(cleanup instanceof MySqlOperationError).assertTrue();
        if (!(cleanup instanceof MySqlOperationError)) throw new Error('Expected retained idle cleanup cause.');
        expect(cleanup.primary === fixture.peer.failure).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,22,25');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally { await fixture.close(); }
    });

    it('rawServerRejectionStillRetiresThePreviousReuseContext', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('DO 2', [errorPayload(1142, '42000')]));
        const failure = await cacheOperationFailure(fixture.connection.query('DO 2'));
        expect(failure.nativeCode).assertEqual(1142);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,3');
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(2);
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7');
        expect(commandFrames(fixture.peer, 0x03).map(commandSql).join('|')).assertEqual('DO 2');
      } finally { await fixture.close(); }
    });

    it('retiredIdleCloseFailurePreventsReplacementAndHiddenSql', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('DO 2'));
        await fixture.connection.query('DO 2');
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        fixture.peer.failCommand = 0x19;
        const failure = await cacheOperationFailure(prepared.execute('DO 1', []));
        expect(failure.primary === fixture.peer.failure).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,3,25');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally { await fixture.close(); }
    });

    it('controlTransactionMetadataAndMetricsShareNonCacheAdmission', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        await fixture.connection.ping();
        await prepared.execute('DO 1', []);
        await fixture.connection.useDatabase('cache_schema');
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('START TRANSACTION'));
        await fixture.connection.begin();
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('SET autocommit = 1'));
        await fixture.connection.setAutocommit(true);
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('COMMIT AND NO CHAIN NO RELEASE'));
        await fixture.connection.commit();
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('ROLLBACK AND NO CHAIN NO RELEASE'));
        await fixture.connection.rollback();
        await prepared.execute('DO 1', []);
        const metadata = fixture.connection.features.metadata;
        const metrics = fixture.connection.features.metrics;
        if (metadata === undefined || metrics === undefined) throw new Error('Expected metadata and metrics features.');
        fixture.peer.textReplies.push(new CacheTextReply('SHOW DATABASES',
          [new Uint8Array([1]), columnPayload('Database'), eofPayload(), eofPayload()]));
        const schemas = await metadata.listSchemas('');
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply("SHOW VARIABLES LIKE 'performance_schema'",
          [new Uint8Array([2]), columnPayload('Variable_name'), columnPayload('Value'), eofPayload(),
            new PacketWriter().writeLenEncString('performance_schema').writeLenEncString('OFF').toUint8Array(),
            eofPayload()]));
        const sample = await metrics.readMetrics();
        await prepared.execute('DO 1', []);
        expect(schemas.length).assertEqual(0);
        expect(sample.measurements.length).assertEqual(0);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,9,10,11,12,13,14,15');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,8,9,10,11,12,13,14');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(9);
        expect(commandFrames(fixture.peer, 0x03).map(commandSql).join('|'))
          .assertEqual("START TRANSACTION|SET autocommit = 1|COMMIT AND NO CHAIN NO RELEASE|" +
            "ROLLBACK AND NO CHAIN NO RELEASE|SHOW DATABASES|" +
            "SHOW VARIABLES LIKE 'performance_schema'");
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
      } finally { await fixture.close(); }
    });

    it('allBorrowedUsesTemporaryHandle', 0, async () => {
      const fixture = new CacheOwnedFixture(1,
        [prepareResponse(7), prepareResponse(8), prepareResponse(9), [okPayload()], prepareResponse(10)]);
      try {
        const retained = await fixture.cache.borrow(fixture.scope, 'DO 1');
        const firstTemporary = await fixture.cache.borrow(fixture.scope, 'DO 2');
        const secondTemporary = await fixture.cache.borrow(fixture.scope, 'DO 3');
        expect(retained.statement.closed).assertFalse();
        expect(firstTemporary.statement.closed).assertFalse();
        expect(secondTemporary.statement.closed).assertFalse();
        await fixture.cache.release(fixture.scope, firstTemporary, true);
        await fixture.cache.release(fixture.scope, secondTemporary, false);
        expect(firstTemporary.statement.closed).assertTrue();
        expect(secondTemporary.statement.closed).assertTrue();
        expect(retained.statement.closed).assertFalse();
        await fixture.cache.release(fixture.scope, retained, true);
        const hit = await fixture.cache.borrow(fixture.scope, 'DO 1');
        expect(hit.statement === retained.statement).assertTrue();
        await fixture.execute(hit);
        await fixture.cache.release(fixture.scope, hit, true);
        const replacement = await fixture.cache.borrow(fixture.scope, 'DO 4');
        expect(retained.statement.closed).assertTrue();
        await fixture.cache.release(fixture.scope, replacement, true);
        await fixture.cache.clearOwned(fixture.scope);
        expect(cacheStatementIds(fixture.host.transport.writes, 0x17)).assertEqual('7');
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('8,9,7,10');
        expect(fixture.host.transport.writes.filter((frame: Uint8Array): boolean => frame[4] === 0x16)
          .map(commandSql).join('|')).assertEqual('DO 1|DO 2|DO 3|DO 4');
      } finally { await fixture.close(); }
    });

    it('retiredBorrowKeepsItsCapacityUntilTheOwnerReturnsIt', 0, async () => {
      const fixture = new CacheOwnedFixture(1, [prepareResponse(7), prepareResponse(8), prepareResponse(9)]);
      try {
        const old = await fixture.cache.borrow(fixture.scope, 'DO 1');
        fixture.cache.retireOwned(fixture.scope);
        const temporary = await fixture.cache.borrow(fixture.scope, 'DO 1');
        await fixture.cache.release(fixture.scope, temporary, true);
        expect(temporary.statement.closed).assertTrue();
        expect(old.statement.closed).assertFalse();
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('8');
        await fixture.cache.release(fixture.scope, old, true);
        expect(old.statement.closed).assertTrue();
        const current = await fixture.cache.borrow(fixture.scope, 'DO 1');
        await fixture.cache.release(fixture.scope, current, true);
        const hit = await fixture.cache.borrow(fixture.scope, 'DO 1');
        expect(hit.statement === current.statement).assertTrue();
        await fixture.cache.release(fixture.scope, hit, true);
        await fixture.cache.clearOwned(fixture.scope);
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('8,7,9');
        expect(fixture.host.transport.writes.filter((frame: Uint8Array): boolean => frame[4] === 0x16).length)
          .assertEqual(3);
      } finally { await fixture.close(); }
    });

    it('temporaryCloseFailureRetiresTheRetainedPhysicalHandleToo', 0, async () => {
      const fixture = new CacheOwnedFixture(1, [prepareResponse(7), prepareResponse(8)]);
      try {
        const retained = await fixture.cache.borrow(fixture.scope, 'DO 1');
        const temporary = await fixture.cache.borrow(fixture.scope, 'DO 2');
        fixture.host.transport.failCommand = 0x19;
        const failure = await cacheOperationFailure(fixture.cache.release(fixture.scope, temporary, true));
        expect(failure.primary === fixture.host.transport.failure).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.session.isAlive()).assertFalse();
        expect(retained.statement.closed).assertTrue();
        expect(temporary.statement.closed).assertTrue();
        await fixture.cache.release(fixture.scope, retained, false);
        const blocked = await preparedFailureOf(fixture.cache.borrow(fixture.scope, 'DO 3'));
        expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('8');
        expect(fixture.host.transport.writes.filter((frame: Uint8Array): boolean => frame[4] === 0x16).length)
          .assertEqual(2);
      } finally { await fixture.close(); }
    });

    it('temporaryPrepareRejectionCannotStealTheBorrowedRetainedEntry', 0, async () => {
      const fixture = new CacheOwnedFixture(1, [prepareResponse(7), [errorPayload(1295, 'HY000')]]);
      try {
        const retained = await fixture.cache.borrow(fixture.scope, 'DO 1');
        const failure = await cacheOperationFailure(fixture.cache.borrow(fixture.scope, 'DO 2'));
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.nativeCode).assertEqual(1295);
        expect(retained.statement.closed).assertFalse();
        await fixture.cache.release(fixture.scope, retained, true);
        const hit = await fixture.cache.borrow(fixture.scope, 'DO 1');
        expect(hit.statement === retained.statement).assertTrue();
        await fixture.cache.release(fixture.scope, hit, true);
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('');
        await fixture.cache.clearOwned(fixture.scope);
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('7');
      } finally { await fixture.close(); }
    });

    it('foreignOrAlreadySettledBorrowsCannotCloseAnOwnedEntry', 0, async () => {
      const fixture = new CacheOwnedFixture(1, [prepareResponse(7)]);
      const other = new MySqlStatementCache(1, fixture.host.commandGate, fixture.session);
      try {
        const borrowed = await fixture.cache.borrow(fixture.scope, 'DO 1');
        const foreignGate = new MySqlCommandGate();
        const foreignScope = foreignGate.reserve(MySqlCommandKind.Query);
        let retirement: ArkDbError | null = null;
        try { fixture.cache.retireOwned(foreignScope); } catch (error) {
          if (!(error instanceof ArkDbError)) throw error as Error;
          retirement = error;
        } finally { foreignGate.release(foreignScope); }
        expect(retirement !== null && retirement.kind === ArkDbErrorKind.Protocol).assertTrue();
        const foreign = await preparedFailureOf(other.release(fixture.scope, borrowed, false));
        expect(foreign !== null && foreign.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(borrowed.statement.closed).assertFalse();
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('');
        await fixture.cache.release(fixture.scope, borrowed, true);
        const reused = await fixture.cache.borrow(fixture.scope, 'DO 1');
        const staleClose = await preparedFailureOf(fixture.cache.release(fixture.scope, borrowed, false));
        expect(staleClose !== null && staleClose.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(reused.statement.closed).assertFalse();
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('');
        const staleReturn = await preparedFailureOf(fixture.cache.release(fixture.scope, borrowed, true));
        expect(staleReturn !== null && staleReturn.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(reused.statement.closed).assertFalse();
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('');
        expect(reused === borrowed).assertFalse();
        expect(reused.statement === borrowed.statement).assertTrue();
        await fixture.cache.release(fixture.scope, reused, false);
        expect(reused.statement.closed).assertTrue();
        const duplicate = await preparedFailureOf(fixture.cache.release(fixture.scope, borrowed, false));
        expect(duplicate !== null && duplicate.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('7');
        expect(fixture.host.transport.writes.filter((frame: Uint8Array): boolean => frame[4] === 0x16).length)
          .assertEqual(1);
      } finally { await fixture.close(); }
    });

    it('anAlreadyClosedRetainedHandleIsNotReusedOrClosedTwice', 0, async () => {
      const fixture = new CacheOwnedFixture(1, [prepareResponse(7), prepareResponse(8)]);
      try {
        const old = await fixture.cache.borrow(fixture.scope, 'DO 1');
        await fixture.cache.release(fixture.scope, old, true);
        await fixture.session.closeOwned(fixture.scope, old.statement);
        const replacement = await fixture.cache.borrow(fixture.scope, 'DO 1');
        expect(replacement.statement === old.statement).assertFalse();
        expect(old.statement.closed).assertTrue();
        await fixture.cache.release(fixture.scope, replacement, true);
        await fixture.cache.clearOwned(fixture.scope);
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('7,8');
      } finally { await fixture.close(); }
    });

    it('borrowCannotBeReusedUntilOwnedExecutionAndItsConsumerAckSettle', 0, async () => {
      const fixture = new CacheOwnedFixture(1, [prepareResponse(7), binaryIntResult([42])]);
      const entered = new PreparedGate();
      const acknowledgement = new PreparedGate();
      const borrowed = await fixture.cache.borrow(fixture.scope, 'DO 1');
      const executing = fixture.session.executeOwned(fixture.scope, borrowed.statement, encodeBinaryParameters([]),
        async (command: Uint8Array): Promise<MySqlQueryResult> => {
          const result = await cacheOwnedResult(fixture.host, fixture.scope, command);
          entered.release();
          await acknowledgement.promise;
          return result;
        });
      const settlement = preparedFailureOf(executing);
      try {
        await entered.promise;
        const overlapping = await preparedFailureOf(fixture.cache.borrow(fixture.scope, 'DO 1'));
        expect(overlapping !== null && overlapping.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(fixture.host.transport.writes.length).assertEqual(2);
        expect(borrowed.statement.closed).assertFalse();
        acknowledgement.release();
        expect((await executing).rows[0][0]).assertEqual(42);
        await fixture.cache.release(fixture.scope, borrowed, true);
        const hit = await fixture.cache.borrow(fixture.scope, 'DO 1');
        expect(hit.statement === borrowed.statement).assertTrue();
        await fixture.cache.release(fixture.scope, hit, true);
        await fixture.cache.clearOwned(fixture.scope);
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('7');
      } finally {
        acknowledgement.release();
        await settlement;
        await fixture.close();
      }
    });

    it('temporaryExecuteRejectionClosesOnlyTheTemporaryHandle', 0, async () => {
      const fixture = new CacheOwnedFixture(1,
        [prepareResponse(7), prepareResponse(8), [errorPayload(1064, '42000')], [okPayload()]]);
      try {
        const retained = await fixture.cache.borrow(fixture.scope, 'DO 1');
        const temporary = await fixture.cache.borrow(fixture.scope, 'DO 2');
        const failure = await preparedFailureOf(fixture.execute(temporary));
        expect(failure !== null).assertTrue();
        if (failure === null) throw new Error('Expected the consumed temporary execution rejection.');
        expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure.nativeCode).assertEqual(1064);
        expect(failure.sqlState).assertEqual('42000');
        await fixture.cache.release(fixture.scope, temporary, false);
        expect(temporary.statement.closed).assertTrue();
        expect(retained.statement.closed).assertFalse();
        await fixture.cache.release(fixture.scope, retained, true);
        const hit = await fixture.cache.borrow(fixture.scope, 'DO 1');
        expect(hit.statement === retained.statement).assertTrue();
        await fixture.execute(hit);
        await fixture.cache.release(fixture.scope, hit, true);
        expect(cacheStatementIds(fixture.host.transport.writes, 0x17)).assertEqual('8,7');
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('8');
      } finally { await fixture.close(); }
    });
  });
}
