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

export default function statementCacheStateTest(): void {
  describe('MySQL statement cache', () => {
    it('foreignPhysicalHandlesCannotExecuteOrCloseOnACacheChannelWithTheSameServerId', 0, async () => {
      const first = new CacheOwnedFixture(1, [prepareResponse(7)]);
      const second = new CacheOwnedFixture(1, [prepareResponse(7), [okPayload()]]);
      try {
        const foreign = await first.cache.borrow(first.scope, 'DO 1');
        const current = await second.cache.borrow(second.scope, 'DO 1');
        const execution = await preparedFailureOf(second.session.executeOwned(
          second.scope, foreign.statement, encodeBinaryParameters([]),
          (command: Uint8Array): Promise<MySqlQueryResult> => cacheOwnedResult(second.host, second.scope, command)));
        const close = await preparedFailureOf(second.session.closeOwned(second.scope, foreign.statement));
        expect(execution !== null && execution.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(close !== null && close.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(foreign.statement.closed).assertFalse();
        expect(current.statement.closed).assertFalse();
        expect(second.host.transport.writes.length).assertEqual(1);
        await second.execute(current);
        await first.cache.release(first.scope, foreign, true);
        await second.cache.release(second.scope, current, true);
        await first.cache.clearOwned(first.scope);
        await second.cache.clearOwned(second.scope);
        expect(cacheStatementIds(first.host.transport.writes, 0x19)).assertEqual('7');
        expect(cacheStatementIds(second.host.transport.writes, 0x17)).assertEqual('7');
        expect(cacheStatementIds(second.host.transport.writes, 0x19)).assertEqual('7');
      } finally {
        await first.close();
        await second.close();
      }
    });

    it('prevalidationFailureCannotRetireARetainedEntry', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        const options = new QueryOptions();
        options.maxChunkRows = 0;
        const badOptions = await cacheOperationFailure(prepared.execute('DO 2', [], options));
        expect(badOptions.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(badOptions.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect(fixture.connection.operationScopes.length).assertEqual(1);
        await prepared.execute('DO 1', []);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23');
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,7');
      } finally { await fixture.close(); }
    });

    it('generationAdvanceExpiresTheBorrowBeforeAnyPhysicalChannelReplacement', 0, async () => {
      const gate = new MySqlCommandGate();
      const oldHost = new CacheOwnedHost([prepareResponse(7)], gate);
      const oldSession = new MySqlPreparedSession(oldHost);
      const oldCache = new MySqlStatementCache(1, gate, oldSession);
      const oldScope = gate.reserve(MySqlCommandKind.Query);
      const borrowed = await oldCache.borrow(oldScope, 'DO 1');
      gate.release(oldScope);
      gate.advanceGeneration();
      const currentScope = gate.reserve(MySqlCommandKind.Query);
      const newHost = new CacheOwnedHost([prepareResponse(7), [okPayload()]], gate);
      const currentSession = new MySqlPreparedSession(newHost);
      const currentCache = new MySqlStatementCache(1, gate, currentSession);
      try {
        expect(currentScope.generation > oldScope.generation).assertTrue();
        expect(oldHost.state).assertEqual(ConnectionState.Ready);
        expect(oldHost.channel !== null).assertTrue();
        expect(oldSession.isAlive()).assertFalse();
        expect(borrowed.statement.closed).assertTrue();
        const stale = await preparedFailureOf(oldCache.borrow(currentScope, 'DO 1'));
        expect(stale !== null && stale.kind === ArkDbErrorKind.Protocol).assertTrue();
        await oldCache.release(currentScope, borrowed, false);
        expect(oldHost.transport.writes.length).assertEqual(1);
        await oldHost.retire(ArkDbError.cancelled('Synthetic old physical channel replacement.'));
        const current = await currentCache.borrow(currentScope, 'DO 1');
        await oldSession.closeOwned(currentScope, borrowed.statement);
        expect(newHost.transport.writes.length).assertEqual(1);
        await currentSession.executeOwned(currentScope, current.statement, encodeBinaryParameters([]),
          (command: Uint8Array): Promise<MySqlQueryResult> => cacheOwnedResult(newHost, currentScope, command));
        await currentCache.release(currentScope, current, true);
        await currentCache.clearOwned(currentScope);
        expect(cacheStatementIds(oldHost.transport.writes, 0x19)).assertEqual('');
        expect(cacheStatementIds(newHost.transport.writes, 0x17)).assertEqual('7');
        expect(cacheStatementIds(newHost.transport.writes, 0x19)).assertEqual('7');
      } finally {
        try { await currentCache.clearOwned(currentScope); } finally { gate.release(currentScope); }
      }
    });

    it('preservesPriorStatementStateOnCacheMissAndHit', 0, async () => {
      const uncached = new CacheStatementStateFixture(0);
      const cached = new CacheStatementStateFixture(2);
      try {
        const uncachedPrepared = await uncached.open();
        const cachedPrepared = await cached.open();
        const explicit = await cachedPrepared.prepare(CACHE_STATE_OBSERVER_SQL);
        try {
          await uncached.connection.query(CACHE_STATE_PRODUCER_SQL);
          const baseline = await uncachedPrepared.execute(CACHE_STATE_OBSERVER_SQL, []);
          await cached.connection.query(CACHE_STATE_PRODUCER_SQL);
          const explicitControl = await explicit.execute([]);
          await cached.connection.query(CACHE_STATE_PRODUCER_SQL);
          const miss = await cachedPrepared.execute(CACHE_STATE_OBSERVER_SQL, []);
          const cachedProducer = await cachedPrepared.execute(CACHE_STATE_PRODUCER_SQL, []);
          const hit = await cachedPrepared.execute(CACHE_STATE_OBSERVER_SQL, []);

          expect([
            cacheStatementStateScalar(baseline), cacheStatementStateScalar(explicitControl),
            cacheStatementStateScalar(miss), cacheStatementStateScalar(hit)
          ].join(',')).assertEqual('3,3,3,3');
          expect(cacheStatementStateScalar(cachedProducer)).assertEqual('10');
          expect(commandFrames(cached.peer, 0x16).map(commandSql).join('|'))
            .assertEqual(CACHE_STATE_OBSERVER_SQL + '|' + CACHE_STATE_OBSERVER_SQL + '|' + CACHE_STATE_PRODUCER_SQL);
          expect(cacheStatementIds(cached.peer.writes, 0x17)).assertEqual('7,8,9,8');
          expect(commandFrames(cached.peer, 0x03).map(commandSql).join('|'))
            .assertEqual(CACHE_STATE_PRODUCER_SQL + '|' + CACHE_STATE_PRODUCER_SQL);
        } finally { await explicit.close(); }
      } finally {
        try { await uncached.close(); } finally { await cached.close(); }
      }
    });

    it('repreparesWhenOnlyConnectionCollationChanges', 0, async () => {
      const fixture = new CacheStatementStateFixture(2);
      try {
        const prepared = await fixture.open();
        await fixture.connection.query(CACHE_STATE_GENERAL_SQL);
        const continuousWarm = await prepared.execute(CACHE_STATE_LITERAL_SQL, []);
        await prepared.execute(CACHE_STATE_BINARY_SQL, []);
        const continuousReuse = await prepared.execute(CACHE_STATE_LITERAL_SQL, []);
        const continuousIds = cacheStatementIds(fixture.peer.writes, 0x17);
        const freshReference = await prepared.prepare(CACHE_STATE_LITERAL_SQL);
        let continuousFresh: MySqlQueryResult | null = null;
        try {
          continuousFresh = await freshReference.execute([]);
        } finally { await freshReference.close(); }
        if (continuousFresh === null) throw new Error('Expected the fresh explicit collation reference.');
        await fixture.connection.query(CACHE_STATE_GENERAL_SQL);
        const warm = await prepared.execute(CACHE_STATE_LITERAL_SQL, []);
        const before = await fixture.connection.query(CACHE_FINGERPRINT_SQL);
        await fixture.connection.query(CACHE_STATE_BINARY_SQL);
        const after = await fixture.connection.query(CACHE_FINGERPRINT_SQL);
        const reused = await prepared.execute(CACHE_STATE_LITERAL_SQL, []);
        const explicit = await prepared.prepare(CACHE_STATE_LITERAL_SQL);
        try {
          const fresh = await explicit.execute([]);

          expect(before.columns.length).assertEqual(4);
          expect(after.columns.length).assertEqual(4);
          expect(before.rows[0].join('|')).assertEqual(after.rows[0].join('|'));
          expect([
            cacheStatementStateScalar(continuousWarm), cacheStatementStateScalar(continuousReuse),
            cacheStatementStateScalar(continuousFresh)
          ].join(',')).assertEqual('1,1,0');
          expect(continuousIds).assertEqual('7,8,7');
          expect([
            cacheStatementStateScalar(warm), cacheStatementStateScalar(reused),
            cacheStatementStateScalar(fresh)
          ].join(',')).assertEqual('1,0,0');
        } finally { await explicit.close(); }
      } finally { await fixture.close(); }
    });
  });
}
