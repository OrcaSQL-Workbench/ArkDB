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
      expect(JSON.stringify(connection.features)).assertEqual('{"health":{}}');
      expect(JSON.stringify(connection).indexOf('secret')).assertEqual(-1);

      for (const op of [async (): Promise<void> => { await connection.query('SELECT 1'); },
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
  expect(capabilities.supportsCatalogs).assertFalse();
  expect(capabilities.supportsSchemas).assertFalse();
  expect(capabilities.supportsTransactions).assertFalse();
  expect(capabilities.supportsMetadata).assertFalse();
  expect(capabilities.supportsMultipleResults).assertTrue();
  expect(capabilities.supportsStreamingResults).assertFalse();
  expect(capabilities.supportsGracefulCancel).assertFalse();
  expect(capabilities.supportsExplain).assertFalse();
  expect(capabilities.supportsPreparedStatements).assertFalse();
  expect(capabilities.supportsServerMetrics).assertFalse();
}
