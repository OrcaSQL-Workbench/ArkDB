import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ColumnDef, ColumnInfo, ConnectionConfig, ConnectionConfigField,
  ConnectionState, DatabaseContext, DatabaseSessionStatus,
  DbConnection, DbDriverFactory, DbExecutionController, DbObjectInfo, DbObjectKind, DbValueKind,
  DriverCapabilities, ForeignKeyInfo, IndexInfo, CatalogInfo, SchemaInfo, MetadataProvider,
  MySqlDriverFactory, MySqlSessionOptions, QueryExecutionSummary, QueryOptions, QueryResult, QueryResultMeta,
  QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation, ServerFamily, ServerInfo,
  ServerMetricsProvider, SqlValue, mapMySqlRows
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
      const summary: QueryResultSummary = {
        resultIndex: 0, rowCount: 0, rowCountKnown: true, loadedRowCount: 0, loadedBytes: 0,
        affectedRows: 0, lastInsertId: 0n, warningCount: 0, truncated: false, truncationReason: '',
        statusKnown: true, status: status
      };
      const foreignKey: ForeignKeyInfo = {
        context: new DatabaseContext(), objectName: '', name: '', referencedSchema: '',
        referencedTable: '', columns: []
      };
      result.rows.push(['12.3400']);
      const mapped = mapMySqlRows<string>(result,
        (row: SqlValue[], columns: ColumnDef[], rowIndex: number): string => {
          expect(columns[0] === column).assertTrue();
          expect(rowIndex).assertEqual(0);
          return row[0] as string;
        });
      expect(capabilities.supportsTransactions).assertTrue();
      expect(result.columns[0].name).assertEqual('value');
      expect(mapped[0]).assertEqual('12.3400');
      expect(result.affectedRowsExact === undefined).assertTrue();
      expect(summary.affectedRowsExact === undefined).assertTrue();
      expect(status.clone().autocommit).assertTrue();
      expect(foreignKey.columns.length).assertEqual(0);
    });

    it('oldCustomConnectionNeedsNoNewMethods', 0, async () => {
      const connection: DbConnection = new LegacyCustomConnection();
      expect((await connection.query('SELECT 1')).rows.length).assertEqual(0);
      expect(connection.sessionStatus.autocommit).assertTrue();
      await connection.close();
    });
  });

  describe('Optional MySQL session options through the HAR', () => {
    it('clonesOptionalSessionOptionsThroughThePublicPackageEntry', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'offline.invalid';
      config.user = 'consumer-user';
      const session = new MySqlSessionOptions();
      session.timeZone = 'Unknown/Session_Zone';
      session.sqlMode = '';
      config.session = session;
      expect(config.validateIssues().length).assertEqual(0);
      const copied = config.clone().session;
      expect(copied !== undefined && copied !== session).assertTrue();
      if (copied === undefined) throw new Error('Expected the public session options snapshot.');
      const timeZone: string | undefined = copied.timeZone;
      const sqlMode: string | undefined = copied.sqlMode;
      expect(timeZone).assertEqual('Unknown/Session_Zone');
      expect(sqlMode).assertEqual('');
      session.timeZone = '+08:00';
      session.sqlMode = 'ANSI_QUOTES';
      expect(copied.timeZone).assertEqual('Unknown/Session_Zone');
      expect(copied.sqlMode).assertEqual('');
      copied.timeZone = 'copy-only';
      expect(session.timeZone).assertEqual('+08:00');
      expect(ConnectionConfigField.Session).assertEqual('session');
      expect(ConnectionConfigField.SessionTimeZone).assertEqual('session.timeZone');
      expect(ConnectionConfigField.SessionSqlMode).assertEqual('session.sqlMode');
    });

    it('retainsCanonicalValidationAndCloneErrorsForSessionInputs', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'offline.invalid';
      config.user = 'consumer-user';
      config.session = new MySqlSessionOptions();
      config.session.timeZone = '\uD800';
      config.session.sqlMode = '\uDC00';
      const issues = config.validateIssues();
      expect(issues.length).assertEqual(2);
      expect(issues[0].field).assertEqual(ConnectionConfigField.SessionTimeZone);
      expect(issues[1].field).assertEqual(ConnectionConfigField.SessionSqlMode);
      for (const issue of issues) {
        expect(issue.error instanceof ArkDbError).assertTrue();
        expect(issue.error.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(issue.invalidValue === undefined).assertTrue();
      }
      const errors = config.validate();
      expect(errors.length).assertEqual(2);
      expect(errors[0] instanceof ArkDbError).assertTrue();
      expect(errors[0].kind).assertEqual(ArkDbErrorKind.Validation);
      let failure: ArkDbError | null = null;
      try {
        config.clone();
      } catch (error) {
        if (!(error instanceof ArkDbError)) throw error as Error;
        failure = error;
      }
      expect(failure !== null).assertTrue();
      if (failure !== null) {
        expect(failure instanceof ArkDbError).assertTrue();
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.message.indexOf('\uD800')).assertEqual(-1);
        expect(failure.message.indexOf('\uDC00')).assertEqual(-1);
      }
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

export class LegacyCustomConnection implements DbConnection {
  readonly state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();
  async connect(): Promise<void> {}
  async ping(): Promise<void> {}
  async query(_sql: string): Promise<QueryResult> { return new QueryResult(); }
  async queryStream(_sql: string, _options: QueryOptions,
    _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return new QueryExecutionSummary();
  }
  async changeContext(_context: DatabaseContext): Promise<void> {}
  async setAutocommit(_enabled: boolean): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async commit(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async rollback(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async close(): Promise<void> {}
}
