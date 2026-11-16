import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, ContextChangeMode, DatabaseContext,
  PostgresConnectionConfig, PostgresConnectionOptions, PostgresDriverCapabilities,
  PostgresDriverFactory, PostgresQueryResultSummary, PostgresSession,
  PostgresTransactionIsolation, PostgresTransactionOptions, PostgresTransactionRunner,
  QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk,
  postgresPlaceholders, quotePostgresIdentifier, requirePostgresFeatures
} from '@arkdb/postgres';

export default function publicInterfaceTest(): void {
  describe('Published PostgreSQL skeleton consumer interface', () => {
    it('usesCanonicalUnsupportedIdentityWithoutNetworking', 0, async () => {
      const config = new PostgresConnectionConfig();
      config.host = 'offline.invalid';
      config.user = 'consumer';
      const factory = new PostgresDriverFactory();
      const connection = factory.create(new PostgresConnectionOptions(config, 'secret'));
      expect(factory.driverId).assertEqual('pgsql');
      expectAllCapabilitiesFalse(factory.capabilities);
      expect(connection.features.streaming !== undefined).assertTrue();
      expect(connection.features.context !== undefined).assertTrue();
      const policy = connection.contextPolicy;
      expect(policy.catalogChange === ContextChangeMode.Reconnect &&
        policy.schemaChange === ContextChangeMode.InPlace && !policy.catalogsAreSchemas).assertTrue();
      policy.schemaChange = ContextChangeMode.Unsupported;
      expect(connection.contextPolicy.schemaChange).assertEqual(ContextChangeMode.InPlace);
      expect(connection.features.context!.contextPolicy.catalogChange)
        .assertEqual(ContextChangeMode.Reconnect);
      const txRunner: PostgresTransactionRunner | undefined = connection.postgresFeatures.transactions;
      const txSession: PostgresSession | null = null;
      expect(connection.postgresFeatures.prepared !== undefined && txRunner !== undefined &&
        txSession === null && connection.features.transactions !== undefined &&
        new PostgresTransactionOptions().isolation === PostgresTransactionIsolation.ReadCommitted)
        .assertTrue();
      expect(requirePostgresFeatures(connection).prepared === connection.postgresFeatures.prepared &&
        requirePostgresFeatures(connection).transactions === txRunner).assertTrue();
      expect(JSON.stringify(connection.features)).assertEqual('{"streaming":{},"health":{},"context":{},"transactions":{}}');
      expect(JSON.stringify(connection.postgresFeatures)).assertEqual('{"prepared":{},"transactions":{}}');
      expect(quotePostgresIdentifier(['public', 'my"tbl'])).assertEqual('"public"."my""tbl"');
      expect(postgresPlaceholders(3)).assertEqual('$1,$2,$3');
      expect(postgresPlaceholders(2, 4)).assertEqual('$4,$5');
      expect(new PostgresQueryResultSummary() instanceof QueryResultSummary && !new PostgresQueryResultSummary().affectedRowsKnown).assertTrue();
      expect(JSON.stringify(connection).indexOf('secret')).assertEqual(-1);

      for (const op of [async (): Promise<void> => { await connection.query('SELECT 1'); },
        async (): Promise<void> => { await connection.queryStream('SELECT 1', new QueryOptions(), new ConsumerNoopSink()); },
        async (): Promise<void> => { await connection.features.streaming!.queryStream('SELECT 1', new QueryOptions(), new ConsumerNoopSink()); },
        async (): Promise<void> => { await connection.postgresFeatures.prepared!.execute('SELECT 1', [], new QueryOptions()); },
        async (): Promise<void> => { await connection.postgresFeatures.prepared!.queryStream('SELECT 1', [], new QueryOptions(), new ConsumerNoopSink()); },
        (): Promise<void> => connection.changeContext(new DatabaseContext()),
        (): Promise<void> => connection.features.context!.changeContext(new DatabaseContext()),
        async (): Promise<void> => { await connection.begin(); }, async (): Promise<void> => { await connection.commit(); },
        async (): Promise<void> => { await connection.rollback(); }, async (): Promise<void> => { await connection.features.transactions!.begin(); },
        async (): Promise<void> => { await connection.features.transactions!.commit(); }, async (): Promise<void> => { await connection.features.transactions!.rollback(); },
        async (): Promise<void> => { await connection.postgresFeatures.transactions!.run(new PostgresTransactionOptions(), async (_s: PostgresSession): Promise<void> => {}); },
        (): Promise<void> => connection.ping(), (): Promise<void> => connection.features.health!.ping()]) {
        await expectUnconnectedProtocol(op);
      }
      expect(connection.state).assertEqual(ConnectionState.Idle);
      await connection.close();
      expect(connection.state).assertEqual(ConnectionState.Closed);
    });
  });
}

async function expectUnconnectedProtocol(op: () => Promise<void>): Promise<void> {
  let failure: ArkDbError | null = null;
  try { await op(); } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    failure = error;
  }
  expect(failure !== null && failure.kind === ArkDbErrorKind.Protocol &&
    failure.message === 'PostgreSQL connection is not connected.').assertTrue();
}

function expectAllCapabilitiesFalse(capabilities: PostgresDriverCapabilities): void {
  expect(capabilities.supportsSsl).assertTrue();
  expect(capabilities.supportsCatalogs).assertTrue();
  expect(capabilities.supportsSchemas).assertTrue();
  expect(capabilities.supportsTransactions).assertTrue();
  expect(capabilities.supportsMetadata).assertFalse();
  expect(capabilities.supportsMultipleResults).assertTrue();
  expect(capabilities.supportsStreamingResults).assertTrue();
  expect(capabilities.supportsGracefulCancel).assertFalse();
  expect(capabilities.supportsExplain).assertFalse();
  expect(capabilities.supportsPreparedStatements).assertTrue();
  expect(capabilities.supportsServerMetrics).assertFalse();
}

class ConsumerNoopSink implements QueryResultSink {
  async onResultStart(_meta: QueryResultMeta): Promise<void> {}
  async onRows(_chunk: QueryRowChunk): Promise<void> {}
  async onResultEnd(_summary: QueryResultSummary): Promise<void> {}
}
