import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ColumnDef, ColumnInfo, ConnectionConfig, DatabaseContext, DatabaseSessionStatus,
  DbConnection, DbDriverFactory, DbExecutionController, DbObjectInfo, DbObjectKind, DbValueKind,
  DriverCapabilities, ForeignKeyInfo, IndexInfo, CatalogInfo, SchemaInfo, MetadataProvider,
  MySqlDriverFactory, QueryExecutionSummary, QueryOptions, QueryResult, QueryResultMeta,
  QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation, ServerFamily,
  ServerMetricsProvider, SqlValue
} from '@arkdb/mysql';

export default function legacyPublicInterfaceTest(): void {
  describe('Published MySQL 1.0.1 consumer interface', () => {
    it('keepsTheNonGenericFactoryAndNativeConnectionContract', 0, async () => {
      const factory: DbDriverFactory = new MySqlDriverFactory();
      const connection: DbConnection = factory.createConnection(new ConnectionConfig(), '');
      const metadata: MetadataProvider = factory.createMetadataProvider(connection);
      const cancellation: DbExecutionController = factory.createExecutionController(connection);
      const metrics: ServerMetricsProvider = factory.createServerMetricsProvider(connection);
      const concrete = new MySqlDriverFactory();
      const concreteMetadata: MetadataProvider = concrete.createMetadataProvider(connection);
      const concreteCancellation: DbExecutionController = concrete.createExecutionController(connection);
      const concreteMetrics: ServerMetricsProvider = concrete.createServerMetricsProvider(connection);
      expect(factory.driverId).assertEqual('mysql');
      expect(connection.sessionStatus.autocommit).assertTrue();
      expect(metadata !== null && cancellation !== null && metrics !== null).assertTrue();
      expect(concreteMetadata !== null && concreteCancellation !== null && concreteMetrics !== null).assertTrue();
      await connection.close();
    });

    it('preservesPublishedDefaultsAndNumericErrorCodes', 0, () => {
      const error: ArkDbError = ArkDbError.server('Synthetic server error.', 1064, '42000');
      const code: number | undefined = error.code;
      expect(code).assertEqual(1064);
      expect(new QueryResult().autocommit).assertTrue();
      expect(new DatabaseSessionStatus().autocommit).assertTrue();
      expect(new DriverCapabilities().supportsSchemas).assertTrue();
      expect(new DriverCapabilities().supportsTransactions).assertTrue();
      expect(new QueryResultSummary().lastInsertId).assertEqual(0n);
      expect(new QueryResultSummary().warningCount).assertEqual(0);
      expect(new QueryResultSummary().statusKnown).assertTrue();
      expect(new QueryExecutionSummary().statusKnown).assertTrue();
      expect(ServerFamily.PostgreSQL).assertEqual('PostgreSQL');
    });

    it('keepsNativeStreamMetadataAndLegacyProviderImplementations', 0, async () => {
      const sink: QueryResultSink = new LegacySink();
      const meta = new QueryResultMeta();
      meta.columns = [new ColumnDef()];
      await sink.onResultStart(meta);
      const chunk = new QueryRowChunk();
      chunk.rows = [['value', 1, 2n, new Uint8Array(3), null]];
      await sink.onRows(chunk);
      await sink.onResultEnd(new QueryResultSummary());
      const metadata: MetadataProvider = new LegacyMetadataProvider();
      const cancellation: DbExecutionController = new LegacyCancellation();
      await metadata.listCatalogs();
      await cancellation.cancel('123');
    });

    it('acceptsPublishedDataShapesWithoutRequiringNewCoreFields', 0, () => {
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
      const status: DatabaseSessionStatus = {
        autocommit: true, inTransaction: false,
        clone: (): DatabaseSessionStatus => new DatabaseSessionStatus()
      };
      const foreignKey: ForeignKeyInfo = {
        context: new DatabaseContext(), objectName: '', name: '', referencedSchema: '',
        referencedTable: '', columns: []
      };
      expect(capabilities.supportsTransactions).assertTrue();
      expect(result.columns[0].name).assertEqual('value');
      expect(status.clone().autocommit).assertTrue();
      expect(foreignKey.columns.length).assertEqual(0);
    });
  });
}

// Source-compatible examples of the published signatures; no network operations are invoked.
async function publishedConnectionUsage(connection: DbConnection, options: QueryOptions,
  sink: QueryResultSink): Promise<QueryResult> {
  await connection.ping();
  await connection.queryStream('SELECT 1', options, sink);
  await connection.changeContext(new DatabaseContext());
  const status: DatabaseSessionStatus = await connection.setAutocommit(true);
  await connection.commit();
  await connection.rollback();
  const numericCode: number | undefined = ArkDbError.server('Synthetic.', 1, 'HY000').code;
  const result: QueryResult = await connection.query('SELECT 1');
  const values: SqlValue[][] = result.rows;
  return result;
}

function publishedValueBytes(value: SqlValue): number {
  if (value === null) return 1;
  if (typeof value === 'string') return value.length * 2;
  if (typeof value === 'number') return 8;
  if (typeof value === 'bigint') return value.toString().length * 2;
  return value.length;
}

class LegacySink implements QueryResultSink {
  async onResultStart(meta: QueryResultMeta): Promise<void> {
    const columns: ColumnDef[] = meta.columns;
    expect(columns[0].flags).assertEqual(0);
    expect(columns[0].charset).assertEqual(0);
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    const rows: SqlValue[][] = chunk.rows;
    expect(rows[0].map((value: SqlValue): number => publishedValueBytes(value)).join(','))
      .assertEqual('10,8,2,3,1');
  }

  async onTruncation(_truncation: QueryTruncation): Promise<boolean> {
    return false;
  }

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    const insertId: bigint = summary.lastInsertId;
    const warningCount: number = summary.warningCount;
    expect(insertId).assertEqual(0n);
    expect(warningCount).assertEqual(0);
  }
}

class LegacyCancellation implements DbExecutionController {
  async cancel(_connectionHandle: string): Promise<void> {}
  isInterruptionError(_error: ArkDbError): boolean { return false; }
}

class LegacyMetadataProvider implements MetadataProvider {
  async listCatalogs(): Promise<CatalogInfo[]> { return []; }
  async listSchemas(_catalog: string): Promise<SchemaInfo[]> { return []; }
  async listObjects(_context: DatabaseContext, _kind: DbObjectKind): Promise<DbObjectInfo[]> { return []; }
  async listColumns(_context: DatabaseContext, _objectName: string): Promise<ColumnInfo[]> { return []; }
  async listIndexes(_context: DatabaseContext, _objectName: string): Promise<IndexInfo[]> { return []; }
  async listForeignKeys(_context: DatabaseContext, _objectName: string): Promise<ForeignKeyInfo[]> { return []; }
}
