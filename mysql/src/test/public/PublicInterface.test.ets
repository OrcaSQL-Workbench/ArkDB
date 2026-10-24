import { describe, expect, it } from '@ohos/hypium';
import {
  ConnectionConfig, DatabaseSessionStatus, CoreDbDriverFactory, estimateSqlRowBytes, LogTag,
  MySqlDriverFactory, ArkDbError, ArkDbErrorKind, QueryOptions, QueryResult, SqlValue, SslMode,
  MySqlConnection, MySqlConnectionOptions, ColumnDef, DbValueKind, DriverCapabilities,
  DatabaseContext, ForeignKeyInfo, DbConnection, MetadataProvider, DbExecutionController,
  ServerMetricsProvider
} from '../../../Index';

export default function publicInterfaceTest(): void {
  describe('PublicInterface', () => {
    it('createsTheDriverThroughItsNeutralFactoryContract', 0, () => {
      const factory: CoreDbDriverFactory<MySqlConnectionOptions, MySqlConnection> = new MySqlDriverFactory();
      expect(factory.driverId).assertEqual('mysql');
      expect(factory.capabilities.supportsStreamingResults).assertTrue();
      expect(factory.capabilities.supportsTransactions).assertTrue();
      expect(factory.capabilities.supportsPreparedStatements).assertFalse();
    });

    it('retainsConcreteFactoryProviderHelperAssignments', 0, async () => {
      const factory = new MySqlDriverFactory();
      const connection: DbConnection = factory.createConnection(new ConnectionConfig(), '');
      const metadata: MetadataProvider = factory.createMetadataProvider(connection);
      const cancellation: DbExecutionController = factory.createExecutionController(connection);
      const metrics: ServerMetricsProvider = factory.createServerMetricsProvider(connection);
      expect(factory.driverId).assertEqual('mysql');
      expect(metadata !== null && cancellation !== null && metrics !== null).assertTrue();
      await connection.close();
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
      expect(status.known).assertFalse();
      expect(status.autocommit).assertTrue();
    });

    it('acceptsPublishedDataLiteralsWithoutNewRequiredCoreFields', 0, () => {
      const capabilities: DriverCapabilities = {
        supportsSsl: false, supportsCatalogs: false, supportsSchemas: true, supportsTransactions: true,
        supportsMultipleResults: false, supportsStreamingResults: false, supportsGracefulCancel: false,
        supportsExplain: false, supportsPreparedStatements: false, supportsServerMetrics: false
      };
      const column: ColumnDef = {
        name: 'value', sourceSchema: '', sourceTable: '', nativeTypeId: '', nativeTypeName: '',
        valueKind: DbValueKind.Unknown, nullable: true, table: '', type: 0, charset: 0,
        columnLength: 0, flags: 0, decimals: 0
      };
      const result: QueryResult = {
        columns: [column], rows: [], affectedRows: 0, lastInsertId: 0n, warningCount: 0,
        loadedBytes: 0, executionTimeMs: 0, autocommit: true, inTransaction: false,
        truncated: false, truncationReason: '', additionalResults: []
      };
      const foreignKey: ForeignKeyInfo = {
        context: new DatabaseContext(), objectName: '', name: '', referencedSchema: '',
        referencedTable: '', columns: []
      };
      expect(result.columns[0].name).assertEqual('value');
      expect(capabilities.supportsTransactions).assertTrue();
      expect(foreignKey.columns.length).assertEqual(0);
    });
  });
}
