import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState, DbConnection, QueryOptions, QueryTruncation
} from '@arkdb/core';
import { MySqlConnection } from '../../../main/ets/mysql/MySqlConnection';
import { MySqlPreparedExecutor, MySqlPreparedStatement } from '../../../main/ets/mysql/driver/MySqlPreparedContracts';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../main/ets/mysql/command/PreparedStatement';
import { parseBufferedResultStream } from '../../../main/ets/mysql/command/ResultStream';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../../../main/ets/mysql/execution/MySqlCommandGate';
import { MySqlSessionFingerprint } from '../../../main/ets/mysql/execution/MySqlSessionInitialization';
import {
  MySqlStatementCache, MySqlStatementCacheBorrow
} from '../../../main/ets/mysql/execution/MySqlStatementCache';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import { MySqlExecutionOutcome, MySqlOperationError } from '../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlQueryResult } from '../../../main/ets/mysql/model/MySqlQueryResult';
import { MySqlQueryResultSummary, MySqlResultSinkAdapter } from '../../../main/ets/mysql/model/MySqlQueryStream';
import { Capabilities, Collation, ColumnType } from '../../../main/ets/mysql/protocol/Constants';
import { PacketChannel } from '../../../main/ets/mysql/protocol/PacketChannel';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { encodeBinaryParameters } from '../../../main/ets/mysql/value/BinaryParameterEncoder';
import { BinaryRowDecoder } from '../../../main/ets/mysql/value/BinaryRowDecoder';
import { socket } from '../../../mock/NetworkKit.mock';
import { PacketTransportFixture } from '../protocol/PacketTransportFixture';
import {
  PreparedGate, PreparedRecordingSink, PreparedSocket, binaryIntResult, columnPayload, eofPayload,
  errorPayload, flushPrepared, framePacket, framedResponse, handshake, okPayload, preparedFailureOf, prepareResponse
} from '../command/PreparedExecutionFixture';

interface CacheSentPacket {
  data: ArrayBuffer;
}

class StatementCacheTestConfig extends ConnectionConfig {
  preparedCacheSize: number = 0;
}

class StatementCacheConnection extends MySqlConnection {
  readonly operationScopes: MySqlCommandScope[] = [];
  readonly fingerprintScopes: MySqlCommandScope[] = [];

  protected runPreparedCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>, cachedConvenience: boolean = false): Promise<T> {
    return super.runPreparedCommand<T>(kind, (scope: MySqlCommandScope): Promise<T> => {
      this.operationScopes.push(scope);
      return operation(scope);
    }, cachedConvenience);
  }

  protected readMySqlSessionFingerprint(scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> {
    this.fingerprintScopes.push(scope);
    return super.readMySqlSessionFingerprint(scope);
  }
}

class StatementCacheSocket extends PreparedSocket {
  responding: boolean = false;
  private nextStatementId: number = 7;

  async send(options: Object): Promise<void> {
    if (this.responding) {
      const frame = new Uint8Array((options as CacheSentPacket).data);
      const command = frame[4];
      if (command === 0x16) {
        if (commandSql(frame) !== 'DO 1') throw new Error('Unexpected cache fixture prepared SQL.');
        this.responses.push(prepareResponse(this.nextStatementId));
        this.nextStatementId += 1;
      } else if (command === 0x17) {
        this.responses.push([okPayload()]);
      } else if (command === 0x03) {
        if (commandSql(frame) !== 'SELECT DATABASE(), @@SESSION.sql_mode, ' +
          '@@SESSION.character_set_client, @@SESSION.time_zone') {
          throw new Error('Unexpected cache fixture text query.');
        }
        this.responses.push(cacheFingerprintResponse());
      } else if (command !== 0x19 && command !== 0x01) {
        throw new Error('Unexpected cache fixture command.');
      }
    }
    await super.send(options);
  }
}

class StatementCacheFixture {
  readonly peer: StatementCacheSocket = new StatementCacheSocket();
  readonly connection: StatementCacheConnection;

  constructor(config: ConnectionConfig) {
    config.host = 'synthetic.invalid';
    config.user = 'cache-user';
    config.ssl.mode = SslMode.DISABLED;
    this.connection = new StatementCacheConnection(config, '', new TcpTransport());
  }

  async open(): Promise<MySqlPreparedExecutor> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(0))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
    const prepared = this.connection.mysqlFeatures.prepared;
    if (prepared === undefined) throw new Error('Expected the public prepared executor.');
    return prepared;
  }

  close(): Promise<void> {
    return this.connection.close();
  }
}

export default function mySqlStatementCacheTest(): void {
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
        fixture.peer.textReplies.push(new CacheTextReply('COMMIT'));
        await fixture.connection.commit();
        await prepared.execute('DO 1', []);
        fixture.peer.textReplies.push(new CacheTextReply('ROLLBACK'));
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
          .assertEqual("START TRANSACTION|SET autocommit = 1|COMMIT|ROLLBACK|SHOW DATABASES|" +
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
        expect(reused.statement === borrowed.statement).assertTrue();
        await fixture.cache.release(fixture.scope, reused, false);
        const duplicate = await preparedFailureOf(fixture.cache.release(fixture.scope, borrowed, false));
        expect(duplicate !== null && duplicate.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(cacheStatementIds(fixture.host.transport.writes, 0x19)).assertEqual('7');
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

function commandFrames(peer: PreparedSocket, command: number): Uint8Array[] {
  return peer.writes.filter((frame: Uint8Array): boolean => frame[4] === command);
}

function commandStatementId(frame: Uint8Array): number {
  return new PacketReader(frame.subarray(5)).readUInt32();
}

function commandSql(frame: Uint8Array): string {
  return new PacketReader(frame.subarray(5)).readEofString();
}

function cacheFingerprintResponse(): Uint8Array[] {
  const row = new PacketWriter().writeLenEncString('cache_schema').writeLenEncString('')
    .writeLenEncString('utf8mb4').writeLenEncString('+00:00').toUint8Array();
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row, eofPayload()
  ];
}

const CACHE_FINGERPRINT_SQL = 'SELECT DATABASE(), @@SESSION.sql_mode, ' +
  '@@SESSION.character_set_client, @@SESSION.time_zone';

class CacheTextReply {
  readonly sql: string;
  readonly packets: Uint8Array[];
  readonly context: MySqlSessionFingerprint | null;

  constructor(sql: string, packets: Uint8Array[] = [okPayload()],
    context: MySqlSessionFingerprint | null = null) {
    this.sql = sql;
    this.packets = packets;
    this.context = context;
  }
}

class CacheCoverageSocket extends PreparedSocket {
  responding: boolean = false;
  fingerprint: MySqlSessionFingerprint = new MySqlSessionFingerprint('cache_schema', '', 'utf8mb4', '+00:00');
  readonly prepareReplies: Uint8Array[][] = [];
  readonly executeReplies: Uint8Array[][] = [];
  readonly probeReplies: Uint8Array[][] = [];
  readonly textReplies: CacheTextReply[] = [];
  readonly closing: PreparedGate = new PreparedGate();
  private nextStatementId: number = 7;
  private heldTail: Uint8Array[] = [];
  private tailSequence: number = 1;

  async send(options: Object): Promise<void> {
    if (this.responding) {
      const frame = new Uint8Array((options as CacheSentPacket).data);
      const command = frame[4];
      if (command === 0x16) {
        const reply = this.prepareReplies.shift();
        if (reply === undefined) {
          this.responses.push(prepareResponse(this.nextStatementId));
          this.nextStatementId += 1;
        } else {
          this.responses.push(reply);
        }
      } else if (command === 0x17) {
        const reply = this.executeReplies.shift();
        this.responses.push(reply === undefined ? [okPayload()] : reply);
      } else if (command === 0x03) {
        const sql = commandSql(frame);
        if (sql === CACHE_FINGERPRINT_SQL) {
          const reply = this.probeReplies.shift();
          this.responses.push(reply === undefined ? cacheContextPackets(this.fingerprint) : reply);
        } else {
          const reply = this.textReplies.shift();
          if (reply === undefined || reply.sql !== sql) throw new Error('Unexpected cache coverage text SQL.');
          this.responses.push(reply.packets);
          if (reply.context !== null) this.fingerprint = reply.context;
        }
      } else if (command === 0x0e) {
        this.responses.push([okPayload()]);
      } else if (command === 0x02) {
        await super.send(options);
        if (this.holdCommand !== command) this.emitResponse([okPayload()]);
        return;
      } else if (command !== 0x19 && command !== 0x01) {
        throw new Error('Unexpected cache coverage wire command.');
      }
    }
    await super.send(options);
  }

  close(): Promise<void> {
    this.closing.release();
    return super.close();
  }

  releaseHeldResponse(): void {
    const reply = this.responses.shift();
    if (reply === undefined) throw new Error('Expected one held cache coverage response.');
    this.holdCommand = -1;
    this.emitResponse(reply);
  }

  releaseHeldPrefix(packets: number): void {
    const reply = this.responses.shift();
    if (reply === undefined || packets <= 0 || packets >= reply.length) {
      throw new Error('Expected a complete response with a strictly partial network prefix.');
    }
    this.holdCommand = -1;
    this.heldTail = reply.slice(packets);
    this.tailSequence = packets + 1;
    this.emitMessage(cacheFrames(reply.slice(0, packets), 1));
  }

  releaseHeldTail(): void {
    if (this.heldTail.length === 0) throw new Error('Expected a held cache response tail.');
    const tail = this.heldTail;
    this.heldTail = [];
    this.emitMessage(cacheFrames(tail, this.tailSequence));
  }
}

class CacheCoverageFixture {
  readonly peer: CacheCoverageSocket = new CacheCoverageSocket();
  readonly connection: StatementCacheConnection;
  private capabilities: number;

  constructor(config: ConnectionConfig = cacheCoverageConfig(1), control?: () => DbConnection,
    capabilities: number = Capabilities.PROTOCOL_41) {
    config.host = 'synthetic.invalid';
    config.user = 'cache-user';
    config.ssl.mode = SslMode.DISABLED;
    this.capabilities = capabilities;
    this.connection = new StatementCacheConnection(config, '', new TcpTransport(), undefined, control);
  }

  async open(): Promise<MySqlPreparedExecutor> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(this.capabilities))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
    const prepared = this.connection.mysqlFeatures.prepared;
    if (prepared === undefined) throw new Error('Expected the public prepared feature.');
    return prepared;
  }

  close(): Promise<void> { return this.connection.close(); }
}

class CacheControlConnection extends MySqlConnection {
  readonly peer: CacheCoverageSocket = new CacheCoverageSocket();

  constructor() {
    super(cacheCoverageConfig(0), '', new TcpTransport());
  }

  async connect(): Promise<void> {
    socket.nextTcp = this.peer;
    const opening = super.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(0, 43))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
  }
}

class CacheEndAcknowledgementSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly acknowledgement: PreparedGate = new PreparedGate();

  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> {
    this.ends.push(summary);
    this.entered.release();
    await this.acknowledgement.promise;
  }
}

class CacheTruncationSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly truncations: QueryTruncation[] = [];
  readonly failure: Error | null;

  constructor(failure: Error | null = null) {
    super();
    this.failure = failure;
  }

  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncations.push(truncation);
    this.entered.release();
    if (this.failure !== null) throw this.failure;
    return false;
  }
}

class CacheOwnedTransport extends PacketTransportFixture {
  failCommand: number = -1;
  readonly failure: ArkDbError = ArkDbError.network('Synthetic owned cache write failure.');

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    await super.write(data, timeoutMs);
    if (data[4] === this.failCommand) throw this.failure;
  }
}

class CacheOwnedHost implements MySqlPreparedSessionHost {
  readonly commandGate: MySqlCommandGate;
  readonly capabilities: number = Capabilities.PROTOCOL_41;
  readonly transport: CacheOwnedTransport;
  channel: PacketChannel | null;
  state: ConnectionState = ConnectionState.Ready;

  constructor(responses: Uint8Array[][], gate: MySqlCommandGate = new MySqlCommandGate()) {
    this.commandGate = gate;
    this.transport = new CacheOwnedTransport(responses.map((reply: Uint8Array[]): Uint8Array =>
      framedResponse(reply)));
    this.channel = new PacketChannel(this.transport);
  }

  async retire(error: ArkDbError): Promise<void> {
    this.state = ConnectionState.Closed;
    this.channel = null;
  }
}

class CacheOwnedFixture {
  readonly host: CacheOwnedHost;
  readonly session: MySqlPreparedSession;
  readonly cache: MySqlStatementCache;
  readonly scope: MySqlCommandScope;

  constructor(capacity: number, responses: Uint8Array[][]) {
    this.host = new CacheOwnedHost(responses);
    this.session = new MySqlPreparedSession(this.host);
    this.cache = new MySqlStatementCache(capacity, this.host.commandGate, this.session);
    this.scope = this.host.commandGate.reserve(MySqlCommandKind.Query);
  }

  async execute(borrow: MySqlStatementCacheBorrow): Promise<MySqlQueryResult> {
    return this.session.executeOwned(this.scope, borrow.statement, encodeBinaryParameters([]),
      (command: Uint8Array): Promise<MySqlQueryResult> => cacheOwnedResult(this.host, this.scope, command));
  }

  async close(): Promise<void> {
    try { await this.cache.clearOwned(this.scope); } finally { this.host.commandGate.release(this.scope); }
  }
}

function cacheCoverageConfig(capacity: number | undefined): ConnectionConfig {
  const config = new ConnectionConfig();
  config.host = 'synthetic.invalid';
  config.user = 'cache-user';
  config.ssl.mode = SslMode.DISABLED;
  config.preparedCacheSize = capacity;
  return config;
}

function cacheContextPackets(context: MySqlSessionFingerprint): Uint8Array[] {
  const row = new PacketWriter();
  if (context.database === null) row.writeUInt8(0xfb);
  else row.writeLenEncString(context.database);
  row.writeLenEncString(context.sqlMode).writeLenEncString(context.characterSetClient)
    .writeLenEncString(context.timeZone);
  return cacheFingerprintRows([row.toUint8Array()]);
}

function cacheFingerprintRows(rows: Uint8Array[]): Uint8Array[] {
  return [new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload()]
    .concat(rows).concat([eofPayload()]);
}

function cacheFrames(packets: Uint8Array[], sequence: number): Uint8Array {
  const writer = new PacketWriter();
  for (let index = 0; index < packets.length; index += 1) {
    writer.writeBytes(framePacket(packets[index], sequence + index));
  }
  return writer.toUint8Array();
}

function cacheStatementIds(writes: Uint8Array[], command: number): string {
  return writes.filter((frame: Uint8Array): boolean => frame[4] === command)
    .map((frame: Uint8Array): number => commandStatementId(frame)).join(',');
}

function cacheProbeFrames(peer: PreparedSocket): Uint8Array[] {
  return commandFrames(peer, 0x03).filter((frame: Uint8Array): boolean =>
    commandSql(frame) === CACHE_FINGERPRINT_SQL);
}

function cacheCommandGate(peer: PreparedSocket, command: number): PreparedGate {
  const entered = new PreparedGate();
  peer.onCommand = (actual: number): void => { if (actual === command) entered.release(); };
  return entered;
}

async function cacheOperationFailure<T>(task: Promise<T>): Promise<MySqlOperationError> {
  const failure = await preparedFailureOf(task);
  expect(failure instanceof MySqlOperationError).assertTrue();
  if (!(failure instanceof MySqlOperationError)) throw new Error('Expected an owned cache operation failure.');
  return failure;
}

async function cacheOwnedResult(host: CacheOwnedHost, scope: MySqlCommandScope,
  command: Uint8Array): Promise<MySqlQueryResult> {
  const channel = host.channel;
  if (channel === null) throw ArkDbError.protocol('Expected the owned cache physical channel.');
  host.commandGate.setPhase(scope, MySqlCommandPhase.Executing);
  channel.resetSequence();
  await channel.writePacket(command);
  return parseBufferedResultStream(channel, host.capabilities, new BinaryRowDecoder());
}

async function assertCacheCancellationBarrier(heldCommand: number): Promise<void> {
  const control = new CacheControlConnection();
  const controlClose = new PreparedGate();
  control.peer.closeResult = controlClose.promise;
  const fixture = new CacheCoverageFixture(cacheCoverageConfig(1), (): DbConnection => control);
  const prepared = await fixture.open();
  await prepared.execute('DO 1', []);
  fixture.peer.holdCommand = heldCommand;
  const entered = cacheCommandGate(fixture.peer, heldCommand);
  if (heldCommand === 0x03) fixture.peer.textReplies.push(new CacheTextReply('DO 2'));
  let settled = false;
  const running = preparedFailureOf(heldCommand === 0x03 ?
    fixture.connection.query('DO 2') : prepared.execute('DO 1', []))
    .then((failure: ArkDbError | null): ArkDbError | null => { settled = true; return failure; });
  await entered.promise;
  control.peer.holdCommand = 0x03;
  control.peer.textReplies.push(new CacheTextReply('KILL QUERY 42'));
  const killEntered = cacheCommandGate(control.peer, 0x03);
  const cancellation = fixture.connection.cancel();
  const cancellationObservation = preparedFailureOf(cancellation);
  try {
    await killEntered.promise;
    fixture.peer.releaseHeldResponse();
    await flushPrepared();
    if (heldCommand === 0x17) expect(settled).assertFalse();
    expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
    expect(commandFrames(fixture.peer, 0x17).length).assertEqual(heldCommand === 0x03 ? 1 : 2);
    expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
    const blocked = await preparedFailureOf(prepared.execute('DO 1', []));
    expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
    expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
    control.peer.releaseHeldResponse();
    await control.peer.closing.promise;
    await flushPrepared();
    if (heldCommand === 0x17) expect(settled).assertFalse();
    expect(commandFrames(fixture.peer, 0x17).length).assertEqual(heldCommand === 0x03 ? 1 : 2);
    expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
    controlClose.release();
    expect((await cancellation).outcome).assertEqual(CancellationOutcome.Requested);
    expect((await running) === null).assertTrue();
    expect(commandFrames(control.peer, 0x03).map(commandSql).join('|')).assertEqual('KILL QUERY 42');
    expect(commandFrames(control.peer, 0x01).length).assertEqual(1);
    expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual(heldCommand === 0x03 ? '7' : '7,7');
    await prepared.execute('DO 1', []);
    expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual(heldCommand === 0x03 ? '7,8' : '7,7,7');
    expect(commandFrames(fixture.peer, 0x16).length).assertEqual(heldCommand === 0x03 ? 2 : 1);
    expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual(heldCommand === 0x03 ? '7' : '');
    expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
  } finally {
    controlClose.release();
    if (control.peer.responses.length > 0) control.peer.releaseHeldResponse();
    if (fixture.peer.responses.length > 0) fixture.peer.releaseHeldResponse();
    await fixture.close();
    await cancellationObservation;
    await running;
  }
}

const CACHE_STATE_PRODUCER_SQL = 'SELECT SQL_CALC_FOUND_ROWS n FROM ' +
  '(SELECT 10 AS n UNION ALL SELECT 20 UNION ALL SELECT 30) AS r LIMIT 1';
const CACHE_STATE_OBSERVER_SQL = 'SELECT FOUND_ROWS()';
const CACHE_STATE_LITERAL_SQL = "SELECT 'a' = 'A'";
const CACHE_STATE_GENERAL_SQL = "SET SESSION collation_connection = 'utf8mb4_general_ci'";
const CACHE_STATE_BINARY_SQL = "SET SESSION collation_connection = 'utf8mb4_bin'";

class CacheStatementStateHandle {
  readonly id: number;
  readonly sql: string;
  readonly collation: string;

  constructor(id: number, sql: string, collation: string) {
    this.id = id;
    this.sql = sql;
    this.collation = collation;
  }
}

class CacheStatementStateCompletion {
  readonly packets: Uint8Array[];
  readonly foundRows: bigint | null;
  readonly collation: string | null;

  constructor(packets: Uint8Array[], foundRows: bigint | null = null, collation: string | null = null) {
    this.packets = packets;
    this.foundRows = foundRows;
    this.collation = collation;
  }
}

// Finite counter/collation wire model, not a SQL engine or a diagnostics model.
class CacheStatementStateSocket extends PreparedSocket {
  responding: boolean = false;
  private readonly producerRows: bigint[] = [10n, 20n, 30n];
  private readonly context: MySqlSessionFingerprint =
    new MySqlSessionFingerprint('cache_schema', '', 'utf8mb4', '+00:00');
  private handles: CacheStatementStateHandle[] = [];
  private nextId: number = 7;
  private foundRows: bigint = 0n;
  private collation: string = 'utf8mb4_general_ci';
  private completing: CacheStatementStateCompletion | null = null;

  async send(options: Object): Promise<void> {
    if (this.responding) {
      if (this.completing !== null) throw new Error('A modeled command has not completed its response.');
      const frame = new Uint8Array((options as CacheSentPacket).data);
      const command = frame[4];
      if (command === 0x03) {
        this.queueCompletion(this.textCompletion(commandSql(frame)));
      } else if (command === 0x16) {
        const sql = commandSql(frame);
        if (sql !== CACHE_STATE_OBSERVER_SQL && sql !== CACHE_STATE_LITERAL_SQL &&
          sql !== CACHE_STATE_PRODUCER_SQL && sql !== CACHE_STATE_BINARY_SQL && sql !== CACHE_STATE_GENERAL_SQL) {
          throw new Error('Unexpected SQL in the finite prepared-state model.');
        }
        const handle = new CacheStatementStateHandle(this.nextId, sql, this.collation);
        this.nextId += 1;
        this.handles.push(handle);
        this.responses.push(sql === CACHE_STATE_BINARY_SQL || sql === CACHE_STATE_GENERAL_SQL ?
          prepareResponse(handle.id) : prepareResponse(handle.id, 0, [cacheStatementStateColumn()]));
      } else if (command === 0x17) {
        const handle = this.handle(commandStatementId(frame));
        if (handle.sql === CACHE_STATE_BINARY_SQL || handle.sql === CACHE_STATE_GENERAL_SQL) {
          this.queueCompletion(this.textCompletion(handle.sql));
        } else if (handle.sql === CACHE_STATE_PRODUCER_SQL) {
          this.queueCompletion(new CacheStatementStateCompletion(
            cacheStatementStateBinary(this.producerRows[0]), BigInt(this.producerRows.length)));
        } else {
          const value = handle.sql === CACHE_STATE_OBSERVER_SQL ? this.foundRows :
            cacheStatementStateEqual('a', 'A', handle.collation);
          this.queueCompletion(new CacheStatementStateCompletion(cacheStatementStateBinary(value), 1n));
        }
      } else if (command === 0x19) {
        const handle = this.handle(commandStatementId(frame));
        this.handles.splice(this.handles.indexOf(handle), 1);
      } else if (command === 0x01) {
        this.handles = [];
      } else {
        throw new Error('Unexpected command in the finite prepared-state model.');
      }
    }
    await super.send(options);
  }

  emitResponse(packets: Uint8Array[]): void {
    const completion = this.completing;
    if (completion !== null) {
      if (packets !== completion.packets) throw new Error('Modeled response ownership is inconsistent.');
      if (completion.foundRows !== null) this.foundRows = completion.foundRows;
      if (completion.collation !== null) this.collation = completion.collation;
      this.completing = null;
    }
    super.emitResponse(packets);
  }

  private handle(id: number): CacheStatementStateHandle {
    const handle = this.handles.find((entry: CacheStatementStateHandle): boolean => entry.id === id);
    if (handle === undefined) throw new Error('The finite server model does not own this statement id.');
    return handle;
  }

  private queueCompletion(completion: CacheStatementStateCompletion): void {
    this.completing = completion;
    this.responses.push(completion.packets);
  }

  private textCompletion(sql: string): CacheStatementStateCompletion {
    if (sql === CACHE_FINGERPRINT_SQL) {
      return new CacheStatementStateCompletion(cacheContextPackets(this.context), 1n);
    }
    if (sql === CACHE_STATE_PRODUCER_SQL) {
      const packets = [new Uint8Array([1]), cacheStatementStateColumn(), eofPayload()];
      packets.push(new PacketWriter().writeLenEncString(String(this.producerRows[0])).toUint8Array());
      packets.push(eofPayload());
      return new CacheStatementStateCompletion(packets, BigInt(this.producerRows.length));
    }
    if (sql === CACHE_STATE_GENERAL_SQL) {
      return new CacheStatementStateCompletion([okPayload()], null, 'utf8mb4_general_ci');
    }
    if (sql === CACHE_STATE_BINARY_SQL) {
      return new CacheStatementStateCompletion([okPayload()], null, 'utf8mb4_bin');
    }
    throw new Error('Unexpected text SQL in the finite prepared-state model.');
  }
}

class CacheStatementStateFixture {
  readonly peer: CacheStatementStateSocket = new CacheStatementStateSocket();
  readonly connection: MySqlConnection;

  constructor(capacity: number) {
    this.connection = new MySqlConnection(cacheCoverageConfig(capacity), '', new TcpTransport());
  }

  async open(): Promise<MySqlPreparedExecutor> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
    const prepared = this.connection.mysqlFeatures.prepared;
    if (prepared === undefined) throw new Error('Expected the public prepared feature.');
    return prepared;
  }

  close(): Promise<void> { return this.connection.close(); }
}

function cacheStatementStateColumn(): Uint8Array {
  return columnPayload('value', ColumnType.LONGLONG, 0, 0, Collation.BINARY);
}

function cacheStatementStateBinary(value: bigint): Uint8Array[] {
  return [
    new Uint8Array([1]), cacheStatementStateColumn(), eofPayload(),
    new PacketWriter().writeUInt8(0).writeUInt8(0).writeInt64(value).toUint8Array(),
    eofPayload()
  ];
}

function cacheStatementStateEqual(left: string, right: string, collation: string): bigint {
  if (collation === 'utf8mb4_general_ci') return left.toLowerCase() === right.toLowerCase() ? 1n : 0n;
  if (collation === 'utf8mb4_bin') return left === right ? 1n : 0n;
  throw new Error('Unsupported collation in the finite literal comparison model.');
}

function cacheStatementStateScalar(result: MySqlQueryResult): string {
  if (result.columns.length !== 1 || result.rows.length !== 1 || result.rows[0].length !== 1 ||
    typeof result.rows[0][0] !== 'bigint') {
    throw new Error('Expected one complete signed BIGINT result from the modeled server.');
  }
  return String(result.rows[0][0]);
}
