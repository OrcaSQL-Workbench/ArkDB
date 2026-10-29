import { describe, expect, it } from '@ohos/hypium';
import {
  ConnectionConfig, DatabaseSessionStatus, CoreDbDriverFactory, estimateSqlRowBytes, LogTag,
  MySqlDriverFactory, ArkDbError, ArkDbErrorKind, QueryOptions, QueryResult, SqlValue, SslMode,
  MySqlConnection, MySqlConnectionOptions, ColumnDef, DbValueKind, DriverCapabilities,
  DatabaseContext, ForeignKeyInfo, DbConnection, DbDriverFactory, MetadataProvider, DbExecutionController,
  ServerMetricsProvider, CoreDbConnection, ConnectionState, ServerInfo, QueryExecutionSummary,
  QueryResultSink, MySqlConnectionFeatures, requireMySqlFeatures, MySqlParameter,
  MySqlParameterType, MySqlParameterValue, MySqlPreparedExecutor, MySqlPreparedStatement,
  MySqlSession, MySqlBatchOptions, MySqlOperationError, MySqlExecutionOutcome, quoteMySqlIdentifier,
  mysqlPlaceholders, createMySqlConnection,
  CoreQueryResultSink, CoreQueryResultMeta, CoreQueryRowChunk, CoreQueryResultSummary
} from '../../../Index';
import {
  PreparedSocket, PreparedRecordingSink, prepareResponse, binaryIntResult, columnPayload,
  eofPayload, okPayload, framePacket, handshake, flushPrepared
} from '../mysql/command/PreparedExecutionFixture';
import { Capabilities, ColumnType } from '../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../main/ets/mysql/protocol/PacketWriter';
import { socket } from '../../mock/NetworkKit.mock';

export default function publicInterfaceTest(): void {
  describe('PublicInterface', () => {
    it('createsTheDriverThroughItsNeutralFactoryContract', 0, () => {
      const factory: CoreDbDriverFactory<MySqlConnectionOptions, MySqlConnection> = new MySqlDriverFactory();
      expect(factory.driverId).assertEqual('mysql');
      expect(factory.capabilities.supportsStreamingResults).assertTrue();
      expect(factory.capabilities.supportsTransactions).assertTrue();
      expect(factory.capabilities.supportsPreparedStatements).assertTrue();
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

    it('oldCustomConnectionNeedsNoNewMethods', 0, async () => {
      const minimal: CoreDbConnection = new QueryOnlyConnection();
      const legacy: DbConnection = new LegacyCustomConnection();
      expect((await minimal.query('SELECT 1')).rows.length).assertEqual(0);
      expect((await legacy.query('SELECT 1')).rows.length).assertEqual(0);
      expect(legacy.mysqlFeatures === undefined).assertTrue();
      await minimal.close();
      await legacy.close();
    });

    it('absentMysqlFeaturesThrowsUnsupported', 0, () => {
      const legacy: DbConnection = new LegacyCustomConnection();
      let failure: Object | null = null;
      try { requireMySqlFeatures(legacy); } catch (error) { failure = error as Object; }
      expect(failure instanceof ArkDbError).assertTrue();
      if (!(failure instanceof ArkDbError)) throw new Error('Expected the public ArkDbError identity.');
      expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
    });

    it('batchFailureDependenciesCompileFromPublicIndex', 0, () => {
      const primary = ArkDbError.protocol('Synthetic public batch failure.');
      const failure: MySqlOperationError =
        new MySqlOperationError(primary, [], MySqlExecutionOutcome.NotDispatched);

      expect(failure.primary === primary).assertTrue();
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
    });

    it('batchOptionsValidateThroughPublicIndex', 0, () => {
      const options: MySqlBatchOptions = new MySqlBatchOptions();
      const errors: ArkDbError[] = options.validate();

      expect(options.maxItems).assertEqual(1000);
      expect(options.maxBufferedBytes).assertEqual(33554432);
      expect(errors.length).assertEqual(0);
    });

    it('preparedPublicImportsCompile', 0, () => {
      const features: MySqlConnectionFeatures = new MySqlConnectionFeatures();
      expect(features.prepared === undefined).assertTrue();
      const bytes = new Uint8Array([1, 2]);
      const parameter: MySqlParameter = new MySqlParameter(MySqlParameterType.Binary, bytes);
      bytes[0] = 9;
      const value: MySqlParameterValue = parameter.value;
      expect(value instanceof Uint8Array).assertTrue();
      if (!(value instanceof Uint8Array)) throw new Error('Expected a public binary parameter.');
      expect(value[0]).assertEqual(1);
      expect(quoteMySqlIdentifier(['schema', 'a`b'])).assertEqual('`schema`.`a``b`');
      expect(mysqlPlaceholders(2)).assertEqual('?,?');
    });

    it('createsPreparedFeatureWithoutOpeningTheConnection', 0, async () => {
      const factory: DbDriverFactory = new MySqlDriverFactory();
      const connection = factory.createConnection(new ConnectionConfig(), '');
      expect(connection.state).assertEqual(ConnectionState.Idle);
      expect(connection.mysqlFeatures !== undefined).assertTrue();
      const features: MySqlConnectionFeatures = requireMySqlFeatures(connection);
      expect(features.prepared !== undefined).assertTrue();
      await connection.close();
    });

    it('checksEveryPublicPreparedMethodForAllCreationPathsBeforeConnectAndAfterClose', 0, async () => {
      const factory = new MySqlDriverFactory();
      const nativeFactory: DbDriverFactory = factory;
      const config = publicConfig();
      const connections: DbConnection[] = [
        new MySqlConnection(config, ''), createMySqlConnection(config, ''),
        factory.create(new MySqlConnectionOptions(config, '')),
        nativeFactory.createConnection(config, '')
      ];
      for (const connection of connections) {
        const prepared = publicPrepared(connection);
        for (let phase = 0; phase < 2; phase += 1) {
          expect(connection.state).assertEqual(phase === 0 ? ConnectionState.Idle : ConnectionState.Closed);
          const preparing = await publicFailure((): Promise<MySqlPreparedStatement> => prepared.prepare('SELECT ?'));
          const executing = await publicFailure((): Promise<QueryResult> =>
            prepared.execute('SELECT ?', [new MySqlParameter(MySqlParameterType.Int32, 7)]));
          const streaming = await publicFailure((): Promise<QueryExecutionSummary> =>
            prepared.executeStream('SELECT ?', [new MySqlParameter(MySqlParameterType.Int32, 7)],
              new QueryOptions(), new PreparedRecordingSink()));
          expect(preparing.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(executing.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(streaming.kind).assertEqual(ArkDbErrorKind.Protocol);
          await connection.close();
        }
      }
    });

    it('executesPublicParametersAndKeepsTheBorrowedSessionTextQueryUnchanged', 0, async () => {
      const connection = new MySqlDriverFactory().create(new MySqlConnectionOptions(publicConfig(), ''));
      const session: MySqlSession = connection;
      const prepared = publicPrepared(connection);
      const peer = new PreparedSocket();
      await openPublicConnection(connection, peer);
      try {
        peer.responses.push(prepareResponse(7, 1), binaryIntResult([42]), textIntResult('7'));
        const result = await prepared.execute('SELECT ?', [new MySqlParameter(MySqlParameterType.Int32, 42)]);
        expect(result.rows[0][0]).assertEqual(42);
        expect(result.columns[0].type).assertEqual(ColumnType.LONG);
        expect(result.lastInsertId).assertEqual(0n);
        expect(result.warningCount).assertEqual(0);
        expect((await session.query('SELECT 7')).rows[0][0]).assertEqual(7);
        expect(session.mysqlFeatures === requireMySqlFeatures(connection)).assertTrue();
        expect(session.serverInfo === connection.serverInfo).assertTrue();
        expect(session.sessionStatus.known).assertTrue();
        expect(peer.commands().join(',')).assertEqual('22,23,25,3');
      } finally { await connection.close(); }
    });

    it('reusesAndClosesPublicStatementsThroughBufferedAndNativeStreamContracts', 0, async () => {
      const connection = new MySqlDriverFactory().createConnection(publicConfig(), '');
      const peer = new PreparedSocket();
      await openPublicConnection(connection, peer);
      try {
        peer.responses.push(prepareResponse(11, 1, [columnPayload('prepared', ColumnType.LONG)]),
          binaryIntResult([41]), binaryIntResult([42]));
        const statement: MySqlPreparedStatement = await publicPrepared(connection).prepare('SELECT ?');
        expect(statement.parameterCount).assertEqual(1);
        expect(statement.closed).assertFalse();
        const columns = statement.columns;
        columns[0].name = 'changed by caller';
        expect(statement.columns[0].name).assertEqual('prepared');
        const buffered = await statement.execute([new MySqlParameter(MySqlParameterType.Int32, 41)]);
        expect(buffered.rows[0][0]).assertEqual(41);
        expect(buffered.columns[0].name).assertEqual('value');
        const sink = new PreparedRecordingSink();
        const streamed = await statement.executeStream([new MySqlParameter(MySqlParameterType.Int32, 42)],
          new QueryOptions(), sink);
        expect(streamed.loadedRowCount).assertEqual(1);
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(sink.ends[0].lastInsertId).assertEqual(0n);
        expect(sink.ends[0].warningCount).assertEqual(0);
        await statement.close();
        await statement.close();
        expect(statement.closed).assertTrue();
        expect((await publicFailure((): Promise<QueryResult> => statement.execute([]))).kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect(peer.commands().join(',')).assertEqual('22,23,23,25');
      } finally { await connection.close(); }
    });

    it('keepsNativeAndPortableTextStreamDefaultsSeparateAfterPublicPreparedStreaming', 0, async () => {
      const connection = createMySqlConnection(publicConfig(), '');
      const session: MySqlSession = connection;
      const peer = new PreparedSocket();
      await openPublicConnection(connection, peer);
      try {
        peer.responses.push(prepareResponse(7), binaryIntResult([9]), textIntResult('7'), textIntResult('8'));
        const preparedSink = new PreparedRecordingSink();
        const prepared = await publicPrepared(connection).executeStream('SELECT 9', [],
          new QueryOptions(), preparedSink);
        expect(prepared.loadedRowCount).assertEqual(1);
        expect(preparedSink.chunks[0].rows[0][0]).assertEqual(9);
        expect(preparedSink.ends[0].lastInsertId).assertEqual(0n);
        const portable = new PublicPortableSink();
        const streaming = connection.features.streaming;
        if (streaming === undefined) throw ArkDbError.unsupported('Expected portable streaming.');
        await streaming.queryStream('SELECT 7', new QueryOptions(), portable);
        expect(portable.chunks[0].rows[0][0]).assertEqual(7);
        expect(portable.ends[0].lastInsertId === undefined).assertTrue();
        const native = new PreparedRecordingSink();
        await session.queryStream('SELECT 8', new QueryOptions(), native);
        expect(native.chunks[0].rows[0][0]).assertEqual(8);
        expect(native.ends[0].lastInsertId).assertEqual(0n);
        expect(native.ends[0].warningCount).assertEqual(0);
        expect(peer.commands().join(',')).assertEqual('22,23,25,3,3');
      } finally { await connection.close(); }
    });

    it('keepsCapturedFeaturesAndStatementsBoundToTheirOwnPhysicalConnection', 0, async () => {
      const first = new MySqlDriverFactory().createConnection(publicConfig(), '');
      const firstPrepared = publicPrepared(first);
      const firstPeer = new PreparedSocket();
      await openPublicConnection(first, firstPeer);
      firstPeer.responses.push(prepareResponse(7));
      const stale = await firstPrepared.prepare('DO 1');
      await first.close();
      const second = new MySqlDriverFactory().createConnection(publicConfig(), '');
      const secondPrepared = publicPrepared(second);
      const secondPeer = new PreparedSocket();
      await openPublicConnection(second, secondPeer);
      try {
        secondPeer.responses.push(prepareResponse(7), [okPayload()]);
        const current = await secondPrepared.prepare('DO 2');
        expect(stale.closed).assertTrue();
        expect((await publicFailure((): Promise<QueryResult> => stale.execute([]))).kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect((await publicFailure((): Promise<QueryResult> => firstPrepared.execute('DO 3', []))).kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        await stale.close();
        expect(secondPeer.commands().join(',')).assertEqual('22');
        expect(current.closed).assertFalse();
        await current.execute([]);
        await current.close();
        expect(secondPeer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await first.close();
        await second.close();
      }
    });

    it('rejectsOverlappingPublicPreparedAndTextCommandsWithoutQueueing', 0, async () => {
      const connection = createMySqlConnection(publicConfig(), '');
      const peer = new PreparedSocket();
      await openPublicConnection(connection, peer);
      peer.holdCommand = 0x16;
      peer.responses.push(binaryIntResult([42]));
      const prepared = publicPrepared(connection);
      const running = prepared.execute('SELECT ?', [new MySqlParameter(MySqlParameterType.Int32, 42)]);
      try {
        await flushPrepared();
        expect((await publicFailure((): Promise<MySqlPreparedStatement> => prepared.prepare('SELECT 2'))).kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect((await publicFailure((): Promise<QueryResult> => connection.query('SELECT 3'))).kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect(peer.commands().join(',')).assertEqual('22');
      } finally {
        peer.emitResponse(prepareResponse(7, 1));
        try {
          expect((await running).rows[0][0]).assertEqual(42);
          expect(peer.commands().join(',')).assertEqual('22,23,25');
        } finally { await connection.close(); }
      }
    });

    it('checksPreparedAvailabilitySeparatelyFromTheFeatureContainer', 0, () => {
      const connection = new FeatureOnlyConnection();
      const features = requireMySqlFeatures(connection);
      expect(features === connection.mysqlFeatures).assertTrue();
      expect(features.prepared === undefined).assertTrue();
    });
  });
}

class QueryOnlyConnection implements CoreDbConnection {
  readonly state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  async connect(): Promise<void> {}
  async query(_sql: string): Promise<QueryResult> { return new QueryResult(); }
  async close(): Promise<void> {}
}

class LegacyCustomConnection extends QueryOnlyConnection implements DbConnection {
  readonly sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();
  async ping(): Promise<void> {}
  async queryStream(_sql: string, _options: QueryOptions,
    _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return new QueryExecutionSummary();
  }
  async changeContext(_context: DatabaseContext): Promise<void> {}
  async setAutocommit(_enabled: boolean): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async commit(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async rollback(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
}

class FeatureOnlyConnection extends LegacyCustomConnection {
  readonly mysqlFeatures: MySqlConnectionFeatures = new MySqlConnectionFeatures();
}

class PublicPortableSink implements CoreQueryResultSink {
  starts: CoreQueryResultMeta[] = [];
  chunks: CoreQueryRowChunk[] = [];
  ends: CoreQueryResultSummary[] = [];
  async onResultStart(value: CoreQueryResultMeta): Promise<void> { this.starts.push(value); }
  async onRows(value: CoreQueryRowChunk): Promise<void> { this.chunks.push(value); }
  async onResultEnd(value: CoreQueryResultSummary): Promise<void> { this.ends.push(value); }
}

function publicConfig(): ConnectionConfig {
  const config = new ConnectionConfig();
  config.host = 'synthetic.invalid';
  config.ssl.mode = SslMode.DISABLED;
  return config;
}

function publicPrepared(connection: DbConnection): MySqlPreparedExecutor {
  const prepared = requireMySqlFeatures(connection).prepared;
  if (prepared === undefined) throw ArkDbError.unsupported('Expected public prepared support.');
  return prepared;
}

async function openPublicConnection(connection: DbConnection, peer: PreparedSocket): Promise<void> {
  socket.nextTcp = peer;
  const opening = connection.connect();
  peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
    .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
  await opening;
  peer.writes = [];
}

function textIntResult(value: string): Uint8Array[] {
  return [new Uint8Array([1]), columnPayload('value', ColumnType.LONG), eofPayload(),
    new PacketWriter().writeLenEncString(value).toUint8Array(), eofPayload()];
}

async function publicFailure<T>(operation: () => Promise<T>): Promise<ArkDbError> {
  let failure: Object | null = null;
  try { await operation(); } catch (error) { failure = error as Object; }
  if (!(failure instanceof ArkDbError)) throw new Error('Expected a failure with the public ArkDbError identity.');
  return failure;
}

async function preparedPublicUsage(executor: MySqlPreparedExecutor, session: MySqlSession,
  options: QueryOptions, sink: QueryResultSink): Promise<QueryResult> {
  const parameters: MySqlParameter[] = [new MySqlParameter(MySqlParameterType.Int32, 7)];
  const statement: MySqlPreparedStatement = await executor.prepare('SELECT ?');
  try {
    const count: number = statement.parameterCount;
    const columns: ColumnDef[] = statement.columns;
    const closed: boolean = statement.closed;
    await statement.execute(parameters, options);
    await statement.executeStream(parameters, options, sink);
    await executor.executeStream('SELECT ?', parameters, options, sink);
    await session.queryStream('SELECT 1', options, sink);
    const features: MySqlConnectionFeatures = session.mysqlFeatures;
    const status: DatabaseSessionStatus = session.sessionStatus;
    const info: ServerInfo = session.serverInfo;
    return await executor.execute('SELECT ?', parameters, options);
  } finally {
    await statement.close();
  }
}
