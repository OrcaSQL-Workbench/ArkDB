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

export default function statementCacheReuseTest(): void {
  describe('MySQL statement cache', () => {
    it('enabledCacheReusesStatementWithoutHiddenSql', 0, async () => {
      const config = new StatementCacheTestConfig();
      config.preparedCacheSize = 1;
      const fixture = new StatementCacheFixture(config);
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        await prepared.execute('DO 1', []);

        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
        const executions = commandFrames(fixture.peer, 0x17);
        expect(executions.length).assertEqual(2);
        expect(commandStatementId(executions[0])).assertEqual(7);
        expect(commandStatementId(executions[1])).assertEqual(7);
        const probes = commandFrames(fixture.peer, 0x03);
        expect(probes.length).assertEqual(0);
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23');
        expect(fixture.connection.operationScopes.length).assertEqual(2);
        expect(fixture.connection.fingerprintScopes.length).assertEqual(0);
        expect(fixture.connection.operationScopes[0] === fixture.connection.operationScopes[1]).assertFalse();
      } finally {
        await fixture.close();
      }
    });

    it('cacheZeroDoesNotRetainHandles', 0, async () => {
      const configs: ConnectionConfig[] = [new ConnectionConfig(), new StatementCacheTestConfig()];
      for (const config of configs) {
        const fixture = new StatementCacheFixture(config);
        try {
          const prepared = await fixture.open();
          await prepared.execute('DO 1', []);
          await prepared.execute('DO 1', []);

          expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,22,23,25');
          expect(commandFrames(fixture.peer, 0x03).length).assertEqual(0);
          const executions = commandFrames(fixture.peer, 0x17);
          expect(executions.length).assertEqual(2);
          expect(commandStatementId(executions[0])).assertEqual(7);
          expect(commandStatementId(executions[1])).assertEqual(8);
          const closes = commandFrames(fixture.peer, 0x19);
          expect(closes.length).assertEqual(2);
          expect(commandStatementId(closes[0])).assertEqual(7);
          expect(commandStatementId(closes[1])).assertEqual(8);
          expect(fixture.connection.fingerprintScopes.length).assertEqual(0);
        } finally {
          await fixture.close();
        }
      }
    });

    it('connectionSnapshotsCacheCapacityBeforeCallerMutation', 0, async () => {
      const enabled = cacheCoverageConfig(1);
      const retained = new CacheCoverageFixture(enabled);
      enabled.preparedCacheSize = 0;
      try {
        const prepared = await retained.open();
        await prepared.execute('DO 1', []);
        enabled.preparedCacheSize = 256;
        await prepared.execute('DO 1', []);
        expect(retained.peer.commands().join(',')).assertEqual('22,23,23');
        expect(cacheStatementIds(retained.peer.writes, 0x17)).assertEqual('7,7');
      } finally { await retained.close(); }
      const disabled = cacheCoverageConfig(0);
      const uncached = new CacheCoverageFixture(disabled);
      disabled.preparedCacheSize = 1;
      try {
        const prepared = await uncached.open();
        await prepared.execute('DO 1', []);
        await prepared.execute('DO 1', []);
        expect(uncached.peer.commands().join(',')).assertEqual('22,23,25,22,23,25');
        expect(cacheStatementIds(uncached.peer.writes, 0x17)).assertEqual('7,8');
      } finally { await uncached.close(); }
    });

    it('invalidCacheCapacityCannotCreateAConnectionSnapshot', 0, () => {
      const capacities: number[] = [-1, 257, 0.5, Number.NaN, Number.POSITIVE_INFINITY];
      for (const capacity of capacities) {
        const config = cacheCoverageConfig(capacity);
        let failure: ArkDbError | null = null;
        try {
          new MySqlConnection(config, '', new TcpTransport());
        } catch (error) {
          if (!(error instanceof ArkDbError)) throw error as Error;
          failure = error;
        }
        expect(failure !== null).assertTrue();
        if (failure === null) throw new Error('Invalid capacity must fail the actual connection clone.');
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      }
    });

    it('exactSqlSpellingUsesSeparateCachedStatements', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(3));
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        await prepared.execute('do 1', []);
        await prepared.execute('DO 1 ', []);
        await prepared.execute('DO 1', []);
        expect(commandFrames(fixture.peer, 0x16).map(commandSql).join('|')).assertEqual('DO 1|do 1|DO 1 ');
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,9,7');
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
        expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
      } finally { await fixture.close(); }
    });

    it('rawCommandsRetireContextEvenWhenSessionValuesAreUnchanged', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(2));
      const commands: string[] = ['DO 2', 'SELECT 1', 'CALL preserves_context()', 'DO 2'];
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        for (const sql of commands) {
          fixture.peer.textReplies.push(new CacheTextReply(sql));
          await fixture.connection.query(sql);
          await prepared.execute('DO 1', []);
        }
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,9,10,11,11');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,8,9,10');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(5);
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
        expect(fixture.connection.fingerprintScopes.length).assertEqual(0);
        expect(commandFrames(fixture.peer, 0x03).map(commandSql).join('|')).assertEqual(commands.join('|'));
        expect(fixture.connection.operationScopes.length).assertEqual(6);
      } finally { await fixture.close(); }
    });

    it('rawAndPortableStreamsEndTheSameCacheReuseContext', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('DO 2'));
        const nativeSink = new PreparedRecordingSink();
        await fixture.connection.queryStream('DO 2', new QueryOptions(), nativeSink);
        await prepared.execute('DO 1', []);
        const streaming = fixture.connection.features.streaming;
        if (streaming === undefined) throw new Error('Expected the portable streaming feature.');
        fixture.peer.textReplies.push(new CacheTextReply('DO 3'));
        const portableSink = new PreparedRecordingSink();
        await streaming.queryStream('DO 3', new QueryOptions(), new MySqlResultSinkAdapter(portableSink));
        await prepared.execute('DO 1', []);
        await prepared.executeStream('DO 1', [], new QueryOptions(), new PreparedRecordingSink());
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,9,9');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,8');
        expect(nativeSink.ends.length).assertEqual(1);
        expect(portableSink.ends.length).assertEqual(1);
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
      } finally { await fixture.close(); }
    });

    it('rawUseAndSetRetireWithoutRecognizingSqlOrProbingValues', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('USE cache_schema'));
        await fixture.connection.query('USE cache_schema');
        await prepared.execute('DO 1', []);
        const modeSql = "SET SESSION sql_mode = CONCAT('ANSI', '_QUOTES')";
        fixture.peer.textReplies.push(new CacheTextReply(modeSql, [okPayload()],
          new MySqlSessionFingerprint('cache_schema', 'ANSI_QUOTES', 'utf8mb4', '+00:00')));
        await fixture.connection.query(modeSql);
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('USE other_schema', [okPayload()],
          new MySqlSessionFingerprint('other_schema', 'ANSI_QUOTES', 'utf8mb4', '+00:00')));
        await fixture.connection.query('USE other_schema');
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,9,10');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,8,9');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(4);
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
        expect(commandFrames(fixture.peer, 0x03).map(commandSql).join('|'))
          .assertEqual('USE cache_schema|' + modeSql + '|USE other_schema');
      } finally { await fixture.close(); }
    });

    it('evictionClosesExactlyOnce', 0, async () => {
      const fixture = new CacheCoverageFixture(cacheCoverageConfig(2));
      try {
        const prepared = await fixture.open();
        for (const sql of ['DO 1', 'DO 2', 'DO 1', 'DO 3', 'DO 1', 'DO 2', 'DO 2']) {
          await prepared.execute(sql, []);
        }
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,7,9,7,10,10');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('8,9');
        expect(commandFrames(fixture.peer, 0x16).map(commandSql).join('|')).assertEqual('DO 1|DO 2|DO 3|DO 2');
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,22,23,23,25,22,23,23,25,22,23,23');
        await fixture.close();
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('8,9');
        expect(commandFrames(fixture.peer, 0x01).length).assertEqual(1);
      } finally { await fixture.close(); }
    });

    it('explicitHandlesStayIndependentAndEndConvenienceContext', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        const explicit = await prepared.prepare('DO 1');
        await explicit.execute([]);
        await explicit.execute([]);
        await prepared.execute('DO 1', []);
        expect(explicit.closed).assertFalse();
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,8,9');
        expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7');
        const sink = new PreparedRecordingSink();
        await explicit.executeStream([], new QueryOptions(), sink);
        await prepared.execute('DO 1', []);
        expect(sink.ends.length).assertEqual(1);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,8,9,8,10');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,9');
        await explicit.close();
        await explicit.close();
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,9,8');
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,8,8,9,8,10,11');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,9,8,10');
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(5);
      } finally { await fixture.close(); }
    });

    it('explicitServerRejectionRetiresConvenienceContextWithoutPoisoningSession', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        const explicit = await prepared.prepare('DO 1');
        await prepared.execute('DO 1', []);
        fixture.peer.executeReplies.push([errorPayload(1064, '42000')]);
        const failure = await cacheOperationFailure(explicit.execute([]));
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(explicit.closed).assertFalse();
        await prepared.execute('DO 1', []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,9,8,10');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,9');
        await explicit.close();
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7,9,8');
      } finally { await fixture.close(); }
    });

    it('newPhysicalConnectionCannotReuseOldCacheOrHandlesWithRecycledServerIds', 0, async () => {
      const fixture = new CacheCoverageFixture();
      const replacement = new CacheCoverageFixture();
      try {
        const first = await fixture.open();
        await first.execute('DO 1', []);
        const stale: MySqlPreparedStatement = await first.prepare('DO 1');
        const oldPeer = fixture.peer;
        await fixture.close();
        const current = await replacement.open();
        expect(stale.closed).assertTrue();
        const failure = await preparedFailureOf(stale.execute([]));
        expect(failure !== null && failure.kind === ArkDbErrorKind.Protocol).assertTrue();
        await stale.close();
        expect(replacement.peer.writes.length).assertEqual(0);
        await current.execute('DO 1', []);
        await current.execute('DO 1', []);
        expect(cacheStatementIds(oldPeer.writes, 0x17)).assertEqual('7');
        expect(commandFrames(oldPeer, 0x01).length).assertEqual(1);
        expect(replacement.peer.commands().join(',')).assertEqual('22,23,23');
        expect(cacheStatementIds(replacement.peer.writes, 0x17)).assertEqual('7,7');
        expect(commandFrames(replacement.peer, 0x19).length).assertEqual(0);
        expect(fixture.connection.operationScopes[0] === replacement.connection.operationScopes[0]).assertFalse();
      } finally {
        await fixture.close();
        await replacement.close();
      }
    });

    it('physicalCloseDuringExecutionCannotReturnAnOldBorrowToAReplacementChannel', 0, async () => {
      const fixture = new CacheCoverageFixture();
      const replacement = new CacheCoverageFixture();
      const prepared = await fixture.open();
      fixture.peer.holdCommand = 0x17;
      const entered = cacheCommandGate(fixture.peer, 0x17);
      const executing = preparedFailureOf(prepared.execute('DO 1', []));
      try {
        await entered.promise;
        const oldPeer = fixture.peer;
        await fixture.close();
        const failure = await executing;
        expect(failure !== null).assertTrue();
        expect(commandFrames(oldPeer, 0x19).length).assertEqual(0);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        const current = await replacement.open();
        await current.execute('DO 1', []);
        expect(replacement.peer.commands().join(',')).assertEqual('22,23');
        expect(cacheStatementIds(replacement.peer.writes, 0x17)).assertEqual('7');
        expect(commandFrames(replacement.peer, 0x19).length).assertEqual(0);
      } finally {
        await fixture.close();
        await executing;
        await replacement.close();
      }
    });

    it('serverRejectedCachedExecuteClosesItsBorrowWithoutReplay', 0, async () => {
      const fixture = new CacheCoverageFixture();
      const ddl = 'CREATE TABLE cache_boundary (id INT)';
      try {
        const prepared = await fixture.open();
        await prepared.execute(ddl, []);
        fixture.peer.executeReplies.push([errorPayload(1064, '42000')]);
        const failure = await cacheOperationFailure(prepared.execute(ddl, []));
        expect(failure.nativeCode).assertEqual(1064);
        expect(failure.sqlState).assertEqual('42000');
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,7');
        expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual('7');
        await prepared.execute(ddl, []);
        expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual('7,7,8');
        expect(commandFrames(fixture.peer, 0x16).map(commandSql).join('|')).assertEqual(ddl + '|' + ddl);
      } finally { await fixture.close(); }
    });

    it('unknownCachedExecuteWriteRetiresWithoutClosingOrReplayingTheHandle', 0, async () => {
      const fixture = new CacheCoverageFixture();
      try {
        const prepared = await fixture.open();
        await prepared.execute('DO 1', []);
        fixture.peer.failCommand = 0x17;
        const failure = await cacheOperationFailure(prepared.execute('DO 1', []));
        expect(failure.primary === fixture.peer.failure).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23');
        const blocked = await preparedFailureOf(prepared.execute('DO 1', []));
        expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23');
      } finally { await fixture.close(); }
    });
  });
}
