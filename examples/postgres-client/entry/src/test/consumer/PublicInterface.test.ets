import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, PostgresConnectionConfig,
  PostgresConnectionOptions, PostgresDriverCapabilities, PostgresDriverFactory
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

      let failure: ArkDbError | null = null;
      try {
        await connection.connect();
      } catch (error) {
        if (!(error instanceof ArkDbError)) throw error as Error;
        failure = error;
      }

      expect(failure !== null).assertTrue();
      if (failure === null) throw new Error('Expected the PostgreSQL skeleton to be unsupported.');
      expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(failure.message).assertEqual('PostgreSQL connection is not implemented.');
      expect(connection.state).assertEqual(ConnectionState.Idle);
      await connection.close();
      expect(connection.state).assertEqual(ConnectionState.Closed);
    });
  });
}

function expectAllCapabilitiesFalse(capabilities: PostgresDriverCapabilities): void {
  expect(capabilities.supportsSsl).assertFalse();
  expect(capabilities.supportsCatalogs).assertFalse();
  expect(capabilities.supportsSchemas).assertFalse();
  expect(capabilities.supportsTransactions).assertFalse();
  expect(capabilities.supportsMetadata).assertFalse();
  expect(capabilities.supportsMultipleResults).assertFalse();
  expect(capabilities.supportsStreamingResults).assertFalse();
  expect(capabilities.supportsGracefulCancel).assertFalse();
  expect(capabilities.supportsExplain).assertFalse();
  expect(capabilities.supportsPreparedStatements).assertFalse();
  expect(capabilities.supportsServerMetrics).assertFalse();
}
