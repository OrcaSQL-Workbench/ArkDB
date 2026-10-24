import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionReuse, ConnectionState, ContextChangeMode,
  DatabaseContext, DatabaseSessionStatus, DbConnection, DbDriverRegistry, DriverCapabilities,
  estimateSqlRowBytes, MetricKind, MetricMeasurement, ServerMetricsAvailability, ServerMetricsSnapshot
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
  });
}
