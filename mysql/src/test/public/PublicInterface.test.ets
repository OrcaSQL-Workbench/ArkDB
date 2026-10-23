import { describe, expect, it } from '@ohos/hypium';
import {
  ConnectionConfig, DatabaseSessionStatus, DbDriverFactory,
  estimateSqlRowBytes, LogTag, MySqlDriverFactory, ArkDbError, ArkDbErrorKind,
  QueryOptions, QueryResult, SqlValue, SslMode
} from '../../../Index';

export default function publicInterfaceTest(): void {
  describe('PublicInterface', () => {
    it('createsTheDriverThroughItsNeutralFactoryContract', 0, () => {
      const factory: DbDriverFactory = new MySqlDriverFactory();
      expect(factory.driverId).assertEqual('mysql');
      expect(factory.capabilities.supportsStreamingResults).assertTrue();
      expect(factory.capabilities.supportsTransactions).assertTrue();
      expect(factory.capabilities.supportsPreparedStatements).assertFalse();
    });

    it('validatesTheDocumentedConfigurationWithoutEmbeddingAPassword', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'localhost';
      config.user = 'example';
      config.ssl.mode = SslMode.VERIFY_IDENTITY;
      expect(config.validate().length).assertEqual(0);
      expect(config.clone().ssl.mode).assertEqual(SslMode.VERIFY_IDENTITY);
      expect(JSON.stringify(config).indexOf('password')).assertEqual(-1);
    });

    it('usesOnlyDriverOwnedLogTags', 0, () => {
      expect(LogTag.Conn).assertEqual('ArkDB.Conn');
      expect(LogTag.Auth).assertEqual('ArkDB.Auth');
      expect(LogTag.Proto).assertEqual('ArkDB.Proto');
      expect(LogTag.Net).assertEqual('ArkDB.Net');
      expect(LogTag.Query).assertEqual('ArkDB.Query');
    });

    it('preservesExactValuesAndBoundedStreamingDefaults', 0, () => {
      const row: SqlValue[] = [9007199254740993n, '12.34', new Uint8Array([1, 2]), null];
      const result = new QueryResult();
      result.rows.push(row);
      expect(result.rows[0][0]).assertEqual(9007199254740993n);
      expect(estimateSqlRowBytes(row)).assertEqual(45);
      const options = new QueryOptions();
      expect(options.maxResultBytes > 0).assertTrue();
      expect(options.maxResultSets > 0).assertTrue();
      expect(options.maxDrainBytes > 0).assertTrue();
      expect(options.maxDrainTimeMs > 0).assertTrue();
    });

    it('retainsTypedServerErrorsAndIndependentSessionSnapshots', 0, () => {
      const error = ArkDbError.server('Synthetic server error', 1064, '42000');
      expect(error.name).assertEqual('ArkDbError');
      expect(error.kind).assertEqual(ArkDbErrorKind.Server);
      expect(error.code).assertEqual(1064);
      expect(error.sqlState).assertEqual('42000');
      const status = new DatabaseSessionStatus();
      const copy = status.clone();
      copy.autocommit = false;
      expect(status.autocommit).assertTrue();
    });
  });
}
