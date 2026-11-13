import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, CoreDatabaseSessionStatus,
  CoreDbConnection, CoreDbDriverFactory, CoreDbExecutionController,
  CoreDriverCapabilities, CoreMetadataProvider, CoreQueryExecutionSummary,
  CoreQueryResultMeta, CoreQueryResultSink, CoreQueryResultSummary,
  CoreQueryRowChunk, CoreSqlValue, DatabaseContext, DriverCapabilities,
  PostgresColumnDef, PostgresConnection, PostgresConnectionConfig,
  PostgresConnectionFeatures, PostgresConnectionOptions,
  PostgresDatabaseSessionStatus, PostgresDriverCapabilities,
  PostgresDriverFactory, PostgresError, PostgresFeatureConnection,
  PostgresParameter, PostgresParameterType, PostgresParameterValue,
  PostgresPreparedExecutor, PostgresQueryResult, PostgresServerInfo,
  PostgresSslMode, PostgresTransactionState, QueryOptions, QueryResultMeta,
  QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation,
  requirePostgresFeatures
} from '../../../Index';

export default function publicInterfaceTest(): void {
  describe('PostgresPublicInterface', () => {
    it('exportsPortableCoreContractsAndPostgresNames', 0, () => {
      const factory: CoreDbDriverFactory<PostgresConnectionOptions, PostgresConnection> =
        new PostgresDriverFactory();
      const connection: CoreDbConnection = factory.create(
        new PostgresConnectionOptions(validConfig(), 'secret'));
      const capabilities: DriverCapabilities = new CoreDriverCapabilities();
      const value: CoreSqlValue = 1;
      const sink: CoreQueryResultSink = new NoopSink();
      const metadata: CoreMetadataProvider | undefined = connection.features!.metadata;
      const cancellation: CoreDbExecutionController | undefined =
        connection.features!.cancellation;
      expect(factory.driverId).assertEqual('pgsql');
      expect(capabilities.supportsSsl).assertFalse();
      expect(value).assertEqual(1);
      expect(sink !== null).assertTrue();
      expect(metadata === undefined).assertTrue();
      expect(cancellation === undefined).assertTrue();
      expect(new CoreDatabaseSessionStatus().known).assertFalse();
      expect(new CoreQueryResultMeta().resultIndex).assertEqual(0);
      expect(new CoreQueryRowChunk().rows.length).assertEqual(0);
      expect(new CoreQueryResultSummary().rowCount).assertEqual(0);
      expect(new CoreQueryExecutionSummary().resultSetCount).assertEqual(0);
    });

    it('validatesAndClonesPostgresConfiguration', 0, () => {
      const config = validConfig();
      config.ssl.tlsVersions = ['TLSv1.2'];
      expect(config.validate().length).assertEqual(0);
      const copy = config.clone();
      copy.ssl.tlsVersions!.push('TLSv1.3');
      expect(config.ssl.tlsVersions!.length).assertEqual(1);
      expect(copy.ssl.mode).assertEqual(PostgresSslMode.VERIFY_FULL);
      expect(JSON.stringify(config).indexOf('password')).assertEqual(-1);

      config.port = 0;
      expectValidation(config);
      config.port = 5432;
      config.connectTimeoutMs = 0;
      expectValidation(config);
      config.connectTimeoutMs = 10000;
      config.user = 'bad\u0000user';
      expectValidation(config);
      config.user = String.fromCharCode(0xD800);
      expectValidation(config);
      config.user = 'postgres';
      config.ssl.clientCertPath = 'client.crt';
      expectValidation(config);
      config.ssl.clientKeyPath = 'client.key';
      config.ssl.tlsVersions = ['TLSv1.1'];
      expectValidation(config);
    });

    it('preservesApprovedNativeDataShapes', 0, () => {
      const result = new PostgresQueryResult();
      const column = new PostgresColumnDef();
      column.typeOid = 23;
      result.columns.push(column);
      result.commandTag = 'SELECT 1';
      result.rowCountExact = 1n;
      expect(result.columns[0].typeOid).assertEqual(23);
      expect(result.lastInsertId === undefined).assertTrue();
      expect(result.warningCount === undefined).assertTrue();
      expect(result.additionalResults.length).assertEqual(0);

      const info = new PostgresServerInfo();
      expect(info.protocolMajor).assertEqual(3);
      expect(info.integerDatetimes).assertTrue();
      const status = new PostgresDatabaseSessionStatus();
      status.known = true;
      status.inTransaction = true;
      status.transactionState = PostgresTransactionState.FailedTransaction;
      const statusCopy = status.clone();
      expect(statusCopy instanceof PostgresDatabaseSessionStatus).assertTrue();
      expect(statusCopy.transactionState).assertEqual(PostgresTransactionState.FailedTransaction);

      const error = new PostgresError(ArkDbErrorKind.Server, 'duplicate', '23505', '23505');
      error.severity = 'ERROR';
      error.constraintName = 'users_email_key';
      expect(error.nativeCode).assertEqual('23505');
      expect(error.code === undefined).assertTrue();
      expect(error.constraintName).assertEqual('users_email_key');
    });

    it('keepsCapabilitiesAndFeaturesDisabled', 0, () => {
      const capabilities = new PostgresDriverCapabilities();
      expectAllCapabilitiesFalse(capabilities);
      const connection = new PostgresDriverFactory().create(
        new PostgresConnectionOptions(validConfig(), 'secret'));
      const prepared: PostgresPreparedExecutor | undefined =
        connection.postgresFeatures.prepared;
      const paramValue: PostgresParameterValue = new Uint8Array([0x01, 0x02]);
      const param = new PostgresParameter(PostgresParameterType.Bytea, paramValue);
      expect(prepared === undefined).assertTrue();
      expect(param.type).assertEqual('bytea');
      expect((param.value as Uint8Array).length).assertEqual(2);
      expectAllCapabilitiesFalse(new PostgresDriverFactory().capabilities);
      expect(JSON.stringify(connection.features)).assertEqual('{}');
      expect(JSON.stringify(connection.postgresFeatures)).assertEqual('{}');
      expect(requirePostgresFeatures(connection) === connection.postgresFeatures).assertTrue();
      expect(connection.state).assertEqual(ConnectionState.Idle);
    });

    it('doesNotSerializeTransientPasswords', 0, async () => {
      const password = 'do-not-serialize';
      const options = new PostgresConnectionOptions(validConfig(), password);
      expect(options.password).assertEqual(password);
      expect(JSON.stringify(options).indexOf(password)).assertEqual(-1);
      const connection = new PostgresDriverFactory().create(options);
      expect(JSON.stringify(connection).indexOf(password)).assertEqual(-1);
      await connection.close();
      expect(JSON.stringify(connection).indexOf(password)).assertEqual(-1);
    });

    it('rejectsEveryUnimplementedRuntimeOperation', 0, async () => {
      const connection = new PostgresDriverFactory().create(
        new PostgresConnectionOptions(validConfig(), 'secret'));
      await expectUnsupported(async (): Promise<void> => { await connection.query('SELECT 1'); });
      await expectUnsupported(async (): Promise<void> => {
        await connection.queryStream('SELECT 1', new QueryOptions(), new NoopSink());
      });
      await expectUnsupported((): Promise<void> => connection.ping());
      await expectUnsupported((): Promise<void> =>
        connection.changeContext(new DatabaseContext()));
      await expectUnsupported(async (): Promise<void> => { await connection.begin(); });
      await expectUnsupported(async (): Promise<void> => { await connection.commit(); });
      await expectUnsupported(async (): Promise<void> => { await connection.rollback(); });
      await expectUnsupported(async (): Promise<void> => { await connection.cancel(); });
      expectSyncUnsupported((): void => {
        connection.isInterruptionError(ArkDbError.cancelled('cancelled'));
      });
      expect(connection.state).assertEqual(ConnectionState.Idle);
      await connection.close();
      await connection.close();
      expect(connection.state).assertEqual(ConnectionState.Closed);
    });

    it('rejectsAbsentPostgresFeatures', 0, () => {
      expectSyncUnsupported((): void => {
        requirePostgresFeatures(new MissingPostgresFeatures());
      });
      expect(new PostgresConnectionFeatures() !== null).assertTrue();
    });
  });
}

function validConfig(): PostgresConnectionConfig {
  const config = new PostgresConnectionConfig();
  config.host = 'localhost';
  config.user = 'postgres';
  return config;
}

function expectValidation(config: PostgresConnectionConfig): void {
  const errors = config.validate();
  expect(errors.length > 0).assertTrue();
  expect(errors[0].kind).assertEqual(ArkDbErrorKind.Validation);
}

function expectAllCapabilitiesFalse(capabilities: PostgresDriverCapabilities): void {
  expect(capabilities.supportsSsl).assertTrue();
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

async function expectUnsupported(operation: () => Promise<void>): Promise<void> {
  let failure: ArkDbError | null = null;
  try {
    await operation();
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Unsupported);
}

function expectSyncUnsupported(operation: () => void): void {
  let failure: ArkDbError | null = null;
  try {
    operation();
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Unsupported);
}

class NoopSink implements QueryResultSink {
  async onResultStart(_meta: QueryResultMeta): Promise<void> {}
  async onRows(_chunk: QueryRowChunk): Promise<void> {}
  async onTruncation(_truncation: QueryTruncation): Promise<boolean> {
    return true;
  }
  async onResultEnd(_summary: QueryResultSummary): Promise<void> {}
}

class MissingPostgresFeatures implements PostgresFeatureConnection {}
