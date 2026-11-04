import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionReuse, ConnectionState, ContextChangeMode,
  DatabaseContext, DatabaseSessionStatus, DbConnection, DbDriverRegistry, DriverCapabilities,
  estimateSqlRowBytes, MAX_QUERY_DRAIN_TIME_MS, MAX_STATEMENT_TIMEOUT_MS, MetricKind,
  MetricMeasurement, QueryOptions, ServerMetricsAvailability, ServerMetricsSnapshot,
  validateQueryOptions
} from '../../Index';
import { ProbeFactory, ProbeOptions } from './ReferenceAdapter';

export default function sharedContractsTest(): void {
  describe('Independent shared contracts', () => {
    it('registersAnIndependentTypedAdapterWithoutAnEngineEnum', 0, async () => {
      const registry = new DbDriverRegistry();
      const factory = registry.register(new ProbeFactory());
      const connection: DbConnection = factory.create(new ProbeOptions());
      expect(registry.describe('contract_probe').driverId).assertEqual('contract_probe');
      const ids = registry.driverIds();
      ids.push('not_registered');
      expect(registry.driverIds().length).assertEqual(1);
      expect(new DriverCapabilities().supportsTransactions).assertFalse();
      expect(connection.features!.transactions === undefined).assertTrue();
      expect(connection.features!.metadata === undefined).assertTrue();
      expect(connection.features!.metrics === undefined).assertTrue();
      await connection.connect();
      const result = await connection.query('values');
      expect(result.rows[0][0]).assertEqual(true);
      expect(result.rows[0][1]).assertEqual(9007199254740993n);
      expect(result.rows[0][2]).assertEqual('12.3400');
      expect(result.columns[0].sourceCatalog).assertEqual('fixture');
      expect(result.statusKnown).assertFalse();
      expect(result.lastInsertId === undefined).assertTrue();
      expect(result.warningCount === undefined).assertTrue();
      await connection.close();
    });

    it('keepsCatalogSelectionSeparateFromSchemaChanges', 0, async () => {
      const connection = new ProbeFactory().create(new ProbeOptions());
      await connection.connect();
      expect(connection.contextPolicy.catalogChange).assertEqual(ContextChangeMode.Reconnect);
      expect(connection.contextPolicy.schemaChange).assertEqual(ContextChangeMode.InPlace);
      expect(connection.contextPolicy.catalogsAreSchemas).assertFalse();
      const context = new DatabaseContext();
      context.catalog = 'fixture';
      context.schema = 'audit';
      await connection.changeContext(context);
      expect((await connection.query('values')).columns[0].sourceSchema).assertEqual('audit');
      context.catalog = 'different_database';
      let failure: ArkDbError | null = null;
      try { await connection.changeContext(context); } catch (error) { failure = error as ArkDbError; }
      expect(failure!.kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect((await connection.query('values')).columns[0].sourceCatalog).assertEqual('fixture');
      await connection.close();
    });

    it('cancelsOnlyTheCurrentExecutionWithoutAControlSqlConnection', 0, async () => {
      const connection = new ProbeFactory().create(new ProbeOptions());
      await connection.connect();
      const running = connection.query('wait').then(
        (): ArkDbError | null => null,
        (error: ArkDbError): ArkDbError | null => error
      );
      const cancellation = await connection.features.cancellation!.cancel();
      expect(cancellation.outcome).assertEqual(CancellationOutcome.Requested);
      expect(cancellation.connectionReuse).assertEqual(ConnectionReuse.AwaitingCompletion);
      const interrupted = await running;
      expect(interrupted !== null).assertTrue();
      expect(connection.isInterruptionError(interrupted!)).assertTrue();
      expect(interrupted!.nativeCode).assertEqual('57014');
      expect(connection.state).assertEqual(ConnectionState.Ready);
      expect((await connection.query('values')).rows.length).assertEqual(1);
      expect((await connection.cancel()).outcome).assertEqual(CancellationOutcome.NotRunning);
      await connection.close();
    });

    it('preservesTextualNativeErrorsAndUnknownSessionStatus', 0, async () => {
      const connection = new ProbeFactory().create(new ProbeOptions());
      await connection.connect();
      let failure: ArkDbError | null = null;
      try { await connection.query('error'); } catch (error) { failure = error as ArkDbError; }
      expect(failure instanceof ArkDbError).assertTrue();
      expect(failure!.nativeCode).assertEqual('42703');
      expect(failure!.code === undefined).assertTrue();
      expect(failure!.sqlState).assertEqual('42703');
      const status = new DatabaseSessionStatus();
      expect(status.known).assertFalse();
      status.known = true;
      const copy = status.clone();
      copy.inTransaction = true;
      expect(status.inTransaction).assertFalse();
      expect(copy.known).assertTrue();
      expect(estimateSqlRowBytes([true, false, null])).assertEqual(3);
      await connection.close();
    });

    it('modelsMetricsWithoutEngineSpecificStorageOrReplicationFields', 0, () => {
      const metric = new MetricMeasurement();
      metric.name = 'sessions.current';
      metric.unit = 'count';
      metric.kind = MetricKind.Gauge;
      metric.value = 9007199254740993n;
      const snapshot = new ServerMetricsSnapshot();
      snapshot.availability = ServerMetricsAvailability.Available;
      snapshot.sampledAtUptimeMs = 1;
      snapshot.measurements = [metric];
      expect(snapshot.validate().length).assertEqual(0);
      snapshot.measurements.push(metric);
      expect(snapshot.validate().length > 0).assertTrue();
    });

    it('validatesStatementTimeoutAtThePortableBoundary', 0, () => {
      const negative = new QueryOptions();
      negative.statementTimeoutMs = -1;
      expectQueryValidationFailure(negative,
        'statementTimeoutMs must be between 0 and ' + MAX_STATEMENT_TIMEOUT_MS);

      const fractional = new QueryOptions();
      fractional.statementTimeoutMs = 0.5;
      expectQueryValidationFailure(fractional,
        'statementTimeoutMs must be between 0 and ' + MAX_STATEMENT_TIMEOUT_MS);

      const excessive = new QueryOptions();
      excessive.statementTimeoutMs = MAX_STATEMENT_TIMEOUT_MS + 1;
      expectQueryValidationFailure(excessive,
        'statementTimeoutMs must be between 0 and ' + MAX_STATEMENT_TIMEOUT_MS);

      const boundary = new QueryOptions();
      boundary.statementTimeoutMs = MAX_STATEMENT_TIMEOUT_MS;
      validateQueryOptions(boundary);
    });

    it('validatesMaxRowsAtThePortableBoundary', 0, () => {
      const negative = new QueryOptions();
      negative.maxRows = -1;
      expectQueryValidationFailure(negative, 'maxRows must be a non-negative integer');

      const fractional = new QueryOptions();
      fractional.maxRows = 0.5;
      expectQueryValidationFailure(fractional, 'maxRows must be a non-negative integer');

      const unsafe = new QueryOptions();
      unsafe.maxRows = Number.MAX_SAFE_INTEGER + 1;
      expectQueryValidationFailure(unsafe, 'maxRows must be a non-negative integer');

      const boundary = new QueryOptions();
      boundary.maxRows = 0;
      validateQueryOptions(boundary);
    });

    it('validatesMaxChunkRowsAtThePortableBoundary', 0, () => {
      const zero = new QueryOptions();
      zero.maxChunkRows = 0;
      expectQueryValidationFailure(zero, 'maxChunkRows must be a positive integer');

      const fractional = new QueryOptions();
      fractional.maxChunkRows = 0.5;
      expectQueryValidationFailure(fractional, 'maxChunkRows must be a positive integer');

      const unsafe = new QueryOptions();
      unsafe.maxChunkRows = Number.MAX_SAFE_INTEGER + 1;
      expectQueryValidationFailure(unsafe, 'maxChunkRows must be a positive integer');

      const boundary = new QueryOptions();
      boundary.maxChunkRows = 1;
      validateQueryOptions(boundary);
    });

    it('validatesMaxChunkBytesAtThePortableBoundary', 0, () => {
      const zero = new QueryOptions();
      zero.maxChunkBytes = 0;
      expectQueryValidationFailure(zero, 'maxChunkBytes must be a positive integer');

      const fractional = new QueryOptions();
      fractional.maxChunkBytes = 0.5;
      expectQueryValidationFailure(fractional, 'maxChunkBytes must be a positive integer');

      const unsafe = new QueryOptions();
      unsafe.maxChunkBytes = Number.MAX_SAFE_INTEGER + 1;
      expectQueryValidationFailure(unsafe, 'maxChunkBytes must be a positive integer');

      const boundary = new QueryOptions();
      boundary.maxChunkBytes = 1;
      validateQueryOptions(boundary);
    });

    it('validatesMaxResultBytesAtThePortableBoundary', 0, () => {
      const zero = new QueryOptions();
      zero.maxResultBytes = 0;
      expectQueryValidationFailure(zero, 'maxResultBytes must be a positive integer');

      const fractional = new QueryOptions();
      fractional.maxResultBytes = 0.5;
      expectQueryValidationFailure(fractional, 'maxResultBytes must be a positive integer');

      const unsafe = new QueryOptions();
      unsafe.maxResultBytes = Number.MAX_SAFE_INTEGER + 1;
      expectQueryValidationFailure(unsafe, 'maxResultBytes must be a positive integer');

      const boundary = new QueryOptions();
      boundary.maxResultBytes = 1;
      validateQueryOptions(boundary);
    });

    it('validatesMaxResultSetsAtThePortableBoundary', 0, () => {
      const zero = new QueryOptions();
      zero.maxResultSets = 0;
      expectQueryValidationFailure(zero, 'maxResultSets must be a positive integer');

      const fractional = new QueryOptions();
      fractional.maxResultSets = 0.5;
      expectQueryValidationFailure(fractional, 'maxResultSets must be a positive integer');

      const unsafe = new QueryOptions();
      unsafe.maxResultSets = Number.MAX_SAFE_INTEGER + 1;
      expectQueryValidationFailure(unsafe, 'maxResultSets must be a positive integer');

      const boundary = new QueryOptions();
      boundary.maxResultSets = 1;
      validateQueryOptions(boundary);
    });

    it('validatesMaxDrainBytesAtThePortableBoundary', 0, () => {
      const zero = new QueryOptions();
      zero.maxDrainBytes = 0;
      expectQueryValidationFailure(zero, 'maxDrainBytes must be a positive integer');

      const fractional = new QueryOptions();
      fractional.maxDrainBytes = 0.5;
      expectQueryValidationFailure(fractional, 'maxDrainBytes must be a positive integer');

      const unsafe = new QueryOptions();
      unsafe.maxDrainBytes = Number.MAX_SAFE_INTEGER + 1;
      expectQueryValidationFailure(unsafe, 'maxDrainBytes must be a positive integer');

      const boundary = new QueryOptions();
      boundary.maxDrainBytes = 1;
      validateQueryOptions(boundary);
    });

    it('validatesMaxDrainTimeAtThePortableBoundary', 0, () => {
      const zero = new QueryOptions();
      zero.maxDrainTimeMs = 0;
      expectQueryValidationFailure(zero,
        'maxDrainTimeMs must be between 1 and ' + MAX_QUERY_DRAIN_TIME_MS);

      const fractional = new QueryOptions();
      fractional.maxDrainTimeMs = 0.5;
      expectQueryValidationFailure(fractional,
        'maxDrainTimeMs must be between 1 and ' + MAX_QUERY_DRAIN_TIME_MS);

      const excessive = new QueryOptions();
      excessive.maxDrainTimeMs = MAX_QUERY_DRAIN_TIME_MS + 1;
      expectQueryValidationFailure(excessive,
        'maxDrainTimeMs must be between 1 and ' + MAX_QUERY_DRAIN_TIME_MS);

      const boundary = new QueryOptions();
      boundary.maxDrainTimeMs = MAX_QUERY_DRAIN_TIME_MS;
      validateQueryOptions(boundary);
    });
  });
}

function expectQueryValidationFailure(options: QueryOptions, message: string): void {
  let failure: ArkDbError | null = null;
  try {
    validateQueryOptions(options);
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
  expect(failure!.message).assertEqual(message);
}
