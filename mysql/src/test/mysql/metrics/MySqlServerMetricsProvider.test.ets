import { describe, it, expect } from '@ohos/hypium';
import {
  DbStreamingConnection, DatabaseContext, ArkDbError, ArkDbErrorKind, SqlValue, DatabaseSessionStatus,
  QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk,
  QueryTruncation, ConnectionState
} from '@arkdb/core';
import {
  MySqlColumnDef as ColumnDef, MySqlQueryResult as QueryResult
} from '../../../main/ets/mysql/model/MySqlQueryResult';
import { ServerFamily, MySqlServerInfo as ServerInfo } from '../../../main/ets/mysql/model/MySqlServerInfo';
import {
  ServerMetricsAvailability, ServerMetricsErrorKind, ReplicationIoRunning, ReplicationSqlRunning
} from '../../../main/ets/mysql/metrics/MySqlServerMetrics';
import { MySqlServerMetricsProvider } from '../../../main/ets/mysql/metrics/MySqlServerMetricsProvider';
import {
  MYSQL_METRICS_INNODB_SQL, MYSQL_METRICS_OVERVIEW_SQL, MYSQL_METRICS_PERFORMANCE_SCHEMA_SQL,
  MYSQL_METRICS_PROCESS_SQL, MYSQL_METRICS_QUERY_ACTIVITY_SQL, MYSQL_METRICS_REPLICATION_REPLICA_SQL,
  MYSQL_METRICS_REPLICATION_SLAVE_SQL, mysqlMetricsProductSupported, mysqlReplicationSqlForServer
} from '../../../main/ets/mysql/metrics/MySqlMetricsSql';

export default function mySqlServerMetricsProviderTest() {
  describe('MySqlServerMetricsProvider', () => {
    it('adaptsNativeOverviewToPortableMetricsWithoutExposingStorageEngineFields', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([['performance_schema', 'ON']]);
      connection.pushResult([
        ['Threads_connected', '12'], ['Threads_running', '3'],
        ['Connections', '9007199254740993'], ['Aborted_connects', '2'], ['Max_used_connections', '19']
      ]);
      const snapshot = await new MySqlServerMetricsProvider(connection).readMetrics();
      expect(snapshot.validate().length).assertEqual(0);
      expect(snapshot.measurements.length).assertEqual(5);
      expect(snapshot.measurements[2].name).assertEqual('connections.total');
      expect(snapshot.measurements[2].value.toString()).assertEqual('9007199254740993');
      expect(snapshot.measurements[2].unit).assertEqual('count');
      const unsupported = await new MySqlServerMetricsProvider(new MetricsConnection('10.11.8',
        ServerFamily.MariaDB)).readMetrics();
      expect(unsupported.availability).assertEqual(ServerMetricsAvailability.Unsupported);
      expect(unsupported.measurements.length).assertEqual(0);
      expect(unsupported.reason.length > 0).assertTrue();
    });
    it('mapsOverviewRowsAndPreservesUnsignedCountersAboveSafeInteger', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([['performance_schema', 'ON']]);
      connection.pushResult([
        ['Threads_connected', '12'],
        ['Threads_running', '3'],
        ['Connections', '9007199254740993'],
        ['Aborted_connects', '2'],
        ['Max_used_connections', '19']
      ]);
      const provider = new MySqlServerMetricsProvider(connection);

      const result = await provider.readOverview();

      expect(connection.sql[0]).assertEqual(MYSQL_METRICS_PERFORMANCE_SCHEMA_SQL);
      expect(connection.sql[1]).assertEqual(MYSQL_METRICS_OVERVIEW_SQL);
      expect(result.availability).assertEqual(ServerMetricsAvailability.Available);
      expect(result.sampledAtUptimeMs !== null).assertTrue();
      expect(result.data!.threadsConnected.value.toString()).assertEqual('12');
      expect(result.data!.threadsRunning.value.toString()).assertEqual('3');
      expect(result.data!.connectionAttempts.value.toString()).assertEqual('9007199254740993');
      expect(result.data!.abortedConnectionAttempts.value.toString()).assertEqual('2');
      expect(result.data!.maxUsedConnections.value.toString()).assertEqual('19');
    });

    it('mapsMySqlNineOverviewUsingExistingGlobalStatusStatement', 0, async () => {
      const connection = new MetricsConnection('9.0.0');
      connection.pushResult([['performance_schema', 'ON']]);
      connection.pushResult([
        ['Threads_connected', '12'],
        ['Threads_running', '3'],
        ['Connections', '20'],
        ['Aborted_connects', '2'],
        ['Max_used_connections', '19']
      ]);
      const provider = new MySqlServerMetricsProvider(connection);

      const result = await provider.readOverview();

      expect(connection.sql[0]).assertEqual(MYSQL_METRICS_PERFORMANCE_SCHEMA_SQL);
      expect(connection.sql[1]).assertEqual(MYSQL_METRICS_OVERVIEW_SQL);
      expect(result.availability).assertEqual(ServerMetricsAvailability.Available);
    });

    it('returnsDisabledWhenPerformanceSchemaIsOffWithoutReadingGlobalStatus', 0, async () => {
      const connection = new MetricsConnection('5.7.44');
      connection.pushResult([['performance_schema', 'OFF']]);
      const provider = new MySqlServerMetricsProvider(connection);

      const result = await provider.readQueryActivity();

      expect(connection.sql.length).assertEqual(1);
      expect(result.availability).assertEqual(ServerMetricsAvailability.Disabled);
      expect(result.errorKind).assertEqual(ServerMetricsErrorKind.PerformanceSchemaDisabled);
    });

    it('returnsUnsupportedWithoutQueryForRejectedProductsAndVersions', 0, async () => {
      await expectUnsupportedProductWithoutQuery(ServerFamily.MariaDB, '10.11.8');
      await expectUnsupportedProductWithoutQuery(ServerFamily.Unknown, '8.0.36');
      await expectUnsupportedProductWithoutQuery(ServerFamily.MySQL, '8.0');
      await expectUnsupportedProductWithoutQuery(ServerFamily.MySQL, '8.0.36 commercial');
      await expectUnsupportedProductWithoutQuery(ServerFamily.MySQL, '5.6.51');
    });

    it('mapsOnlyDocumentedServerErrorsToAvailabilityResults', 0, async () => {
      const denied = new MetricsConnection('8.0.36');
      denied.pushResult([['performance_schema', 'ON']]);
      denied.pushError(ArkDbError.server('denied', 1142, '42000'));
      const deniedResult = await new MySqlServerMetricsProvider(denied).readOverview();

      const missing = new MetricsConnection('8.0.36');
      missing.pushResult([['performance_schema', 'ON']]);
      missing.pushError(ArkDbError.server('missing', 1054, '42S22'));
      const missingResult = await new MySqlServerMetricsProvider(missing).readInnoDb();

      const missingTable = new MetricsConnection('8.0.36');
      missingTable.pushError(ArkDbError.server('missing table', 1146, '42S02'));
      const missingTableResult = await new MySqlServerMetricsProvider(missingTable).listProcesses(100);

      const unexpected = new MetricsConnection('8.0.36');
      unexpected.pushResult([['performance_schema', 'ON']]);
      unexpected.pushError(ArkDbError.server('deadlock', 1213, '40001'));
      let caught: ArkDbError | null = null;

      try {
        await new MySqlServerMetricsProvider(unexpected).readQueryActivity();
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(deniedResult.availability).assertEqual(ServerMetricsAvailability.PermissionDenied);
      expect(deniedResult.errorCode).assertEqual(1142);
      expect(deniedResult.errorSqlState).assertEqual('42000');
      expect(missingResult.availability).assertEqual(ServerMetricsAvailability.Unsupported);
      expect(missingResult.errorKind).assertEqual(ServerMetricsErrorKind.Server);
      expect(missingResult.errorCode).assertEqual(1054);
      expect(missingTableResult.availability).assertEqual(ServerMetricsAvailability.Unsupported);
      expect(missingTableResult.errorCode).assertEqual(1146);
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Server);
      expect(caught!.code).assertEqual(1213);
    });

    it('mapsEveryApprovedServerErrorOnlyWhenCodeAndSqlStateMatch', 0, async () => {
      await expectMappedOverviewError(1142, '42000', ServerMetricsAvailability.PermissionDenied);
      await expectMappedOverviewError(1143, '42000', ServerMetricsAvailability.PermissionDenied);
      await expectMappedOverviewError(1227, '42000', ServerMetricsAvailability.PermissionDenied);
      await expectMappedOverviewError(1146, '42S02', ServerMetricsAvailability.Unsupported);
      await expectMappedOverviewError(1054, '42S22', ServerMetricsAvailability.Unsupported);

      await expectOverviewErrorRethrown(1142, 'HY000');
      await expectOverviewErrorRethrown(1143, 'HY000');
      await expectOverviewErrorRethrown(1227, 'HY000');
      await expectOverviewErrorRethrown(1213, '42000');
      await expectOverviewErrorRethrown(1146, 'HY000');
      await expectOverviewErrorRethrown(1146, '42S22');
      await expectOverviewErrorRethrown(9999, '42S02');
      await expectOverviewErrorRethrown(1054, 'HY000');
      await expectOverviewErrorRethrown(1054, '42S02');
      await expectOverviewErrorRethrown(9999, '42S22');
    });

    it('rejectsMalformedPerformanceSchemaAndStatusValues', 0, async () => {
      const malformedProbe = new MetricsConnection('8.0.36');
      malformedProbe.pushResult([['performance_schema', 'MAYBE']]);
      const negativeCounter = new MetricsConnection('8.0.36');
      negativeCounter.pushResult([['performance_schema', 'ON']]);
      negativeCounter.pushResult([
        ['Questions', '1'],
        ['Queries', '-1'],
        ['Slow_queries', '0']
      ]);

      let probeError: ArkDbError | null = null;
      let counterError: ArkDbError | null = null;

      try {
        await new MySqlServerMetricsProvider(malformedProbe).readOverview();
      } catch (error) {
        probeError = error as ArkDbError;
      }
      try {
        await new MySqlServerMetricsProvider(negativeCounter).readQueryActivity();
      } catch (error) {
        counterError = error as ArkDbError;
      }

      expect(probeError !== null).assertTrue();
      expect(probeError!.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(counterError !== null).assertTrue();
      expect(counterError!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('returnsUnsupportedForMissingOrNullRequiredGlobalStatusRows', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([['performance_schema', 'ON']]);
      connection.pushResult([
        ['Threads_connected', '12'],
        ['Threads_running', null],
        ['Connections', '30'],
        ['Aborted_connects', '2'],
        ['Max_used_connections', '19']
      ]);
      const provider = new MySqlServerMetricsProvider(connection);

      const result = await provider.readOverview();

      expect(result.availability).assertEqual(ServerMetricsAvailability.Unsupported);
      expect(result.errorKind).assertEqual(ServerMetricsErrorKind.UnsupportedSource);
    });

    it('mapsInnoDbAndQueryActivityStatusRows', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([['performance_schema', 'ON']]);
      connection.pushResult([
        ['Innodb_buffer_pool_pages_total', '100'],
        ['Innodb_buffer_pool_pages_free', '10'],
        ['Innodb_buffer_pool_pages_data', '80'],
        ['Innodb_buffer_pool_pages_dirty', '5'],
        ['Innodb_buffer_pool_read_requests', '9007199254740994'],
        ['Innodb_buffer_pool_reads', '7'],
        ['Innodb_buffer_pool_write_requests', '8'],
        ['Innodb_buffer_pool_pages_flushed', '9'],
        ['Innodb_rows_read', '10'],
        ['Innodb_rows_inserted', '11'],
        ['Innodb_rows_updated', '12'],
        ['Innodb_rows_deleted', '13']
      ]);
      connection.pushResult([['performance_schema', 'ON']]);
      connection.pushResult([
        ['Questions', '14'],
        ['Queries', '15'],
        ['Slow_queries', '16']
      ]);
      const provider = new MySqlServerMetricsProvider(connection);

      const innoDb = await provider.readInnoDb();
      const queryActivity = await provider.readQueryActivity();

      expect(connection.sql[1]).assertEqual(MYSQL_METRICS_INNODB_SQL);
      expect(connection.sql[3]).assertEqual(MYSQL_METRICS_QUERY_ACTIVITY_SQL);
      expect(innoDb.data!.bufferPoolReadRequests.value.toString()).assertEqual('9007199254740994');
      expect(innoDb.data!.rowsDeleted.value.toString()).assertEqual('13');
      expect(queryActivity.data!.questions.value.toString()).assertEqual('14');
      expect(queryActivity.data!.queries.value.toString()).assertEqual('15');
      expect(queryActivity.data!.slowQueries.value.toString()).assertEqual('16');
    });

    it('preservesEmptyProcessResults', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([]);
      const provider = new MySqlServerMetricsProvider(connection);

      const result = await provider.listProcesses(100);

      expect(connection.sql[0]).assertEqual(MYSQL_METRICS_PROCESS_SQL);
      expect(result.availability).assertEqual(ServerMetricsAvailability.Empty);
      expect(result.data!.rows.length).assertEqual(0);
      expect(result.data!.truncated).assertFalse();
    });

    it('usesTheValidatedProcessLimitOnlyForMappingAndTruncation', 0, async () => {
      const invalid = new MetricsConnection('8.0.36');
      let caught: ArkDbError | null = null;
      try {
        await new MySqlServerMetricsProvider(invalid).listProcesses(0);
      } catch (error) {
        caught = error as ArkDbError;
      }

      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([
        ['Query', 'Sending data', 9],
        ['Sleep', null, 4],
        ['Connect', '', 1]
      ]);
      const result = await new MySqlServerMetricsProvider(connection).listProcesses(2);

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(invalid.sql.length).assertEqual(0);
      expect(connection.sql[0]).assertEqual(MYSQL_METRICS_PROCESS_SQL);
      expect(connection.options[0].maxRows).assertEqual(101);
      expect(result.data!.rows.length).assertEqual(2);
      expect(result.data!.rows[0].command).assertEqual('Query');
      expect(result.data!.rows[0].state).assertEqual('Sending data');
      expect(result.data!.rows[0].durationSeconds).assertEqual(9);
      expect(result.data!.truncated).assertTrue();
    });

    it('emitsOneHundredProcessesFromFullSentinelResult', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      const rows: SqlValue[][] = [];
      for (let i = 0; i < 101; i++) {
        rows.push(['Query', 'Sending data', i]);
      }
      connection.pushResult(rows);

      const result = await new MySqlServerMetricsProvider(connection).listProcesses(100);

      expect(result.availability).assertEqual(ServerMetricsAvailability.Available);
      expect(result.data!.rows.length).assertEqual(100);
      expect(result.data!.truncated).assertTrue();
      expect(result.data!.rows[99].durationSeconds).assertEqual(99);
    });

    it('rejectsUnsigned64ValuesAboveTheMetricsBound', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([['performance_schema', 'ON']]);
      connection.pushResult([
        ['Threads_connected', '18446744073709551616'],
        ['Threads_running', '3'],
        ['Connections', '4'],
        ['Aborted_connects', '5'],
        ['Max_used_connections', '6']
      ]);
      let caught: ArkDbError | null = null;

      try {
        await new MySqlServerMetricsProvider(connection).readOverview();
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('rejectsProcessCommandValuesAboveUtf8Bound', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([['界'.repeat(22), 'Sending data', 9]]);
      let caught: ArkDbError | null = null;

      try {
        await new MySqlServerMetricsProvider(connection).listProcesses(100);
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('rejectsMalformedProcessRows', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      connection.pushResult([['', null, 0]]);
      let caught: ArkDbError | null = null;

      try {
        await new MySqlServerMetricsProvider(connection).listProcesses(100);
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('selectsReplicationSqlFromAcceptedMySqlVersionsOnly', 0, () => {
      expect(mysqlMetricsProductSupported(serverInfo(ServerFamily.MySQL, '9.0.0'))).assertTrue();
      expect(mysqlMetricsProductSupported(
        serverInfo(ServerFamily.MySQL, '9.1.2-enterprise')
      )).assertTrue();
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '5.7.44')))
        .assertEqual(MYSQL_METRICS_REPLICATION_SLAVE_SQL);
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '8.0.21')))
        .assertEqual(MYSQL_METRICS_REPLICATION_SLAVE_SQL);
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '8.0.22')))
        .assertEqual(MYSQL_METRICS_REPLICATION_REPLICA_SQL);
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '8.1.0-enterprise')))
        .assertEqual(MYSQL_METRICS_REPLICATION_REPLICA_SQL);
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '9.0.0')))
        .assertEqual(MYSQL_METRICS_REPLICATION_REPLICA_SQL);
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '9.1.2-enterprise')))
        .assertEqual(MYSQL_METRICS_REPLICATION_REPLICA_SQL);
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MariaDB, '10.11.8')) === null)
        .assertTrue();
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '8.0')) === null)
        .assertTrue();
      expect(mysqlReplicationSqlForServer(serverInfo(ServerFamily.MySQL, '8.0.22.1')) === null)
        .assertTrue();
      expect(mysqlMetricsProductSupported(serverInfo(ServerFamily.MySQL, '9.0'))).assertFalse();
      expect(mysqlMetricsProductSupported(serverInfo(ServerFamily.MySQL, '9.0.0.1'))).assertFalse();
      expect(mysqlMetricsProductSupported(
        serverInfo(ServerFamily.MySQL, '9.0.0 enterprise')
      )).assertFalse();
      expect(mysqlMetricsProductSupported(serverInfo(ServerFamily.MySQL, '10.0.0'))).assertFalse();
      expect(mysqlMetricsProductSupported(serverInfo(ServerFamily.MySQL, '09.0.0'))).assertFalse();
    });

    it('mapsReplicationByColumnNameAndCapsChannels', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      const rows: SqlValue[][] = [];
      for (let i = 0; i < 17; i++) {
        rows.push([i === 3 ? null : String(i), i === 2 ? 'No' : 'Yes',
          i === 1 ? 'Connecting' : 'Yes', i === 0 ? '' : 'channel-' + String(i)]);
      }
      connection.pushResult(rows, [
        'seconds_behind_source',
        'replica_sql_running',
        'replica_io_running',
        'channel_name'
      ]);
      const provider = new MySqlServerMetricsProvider(connection);

      const result = await provider.readReplication();

      expect(connection.sql[0]).assertEqual(MYSQL_METRICS_REPLICATION_REPLICA_SQL);
      expect(connection.options[0].maxRows).assertEqual(17);
      expect(result.availability).assertEqual(ServerMetricsAvailability.Available);
      expect(result.data!.channels.length).assertEqual(16);
      expect(result.data!.truncated).assertTrue();
      expect(result.data!.channels[1].ioRunning).assertEqual(ReplicationIoRunning.Connecting);
      expect(result.data!.channels[2].sqlRunning).assertEqual(ReplicationSqlRunning.No);
      expect(result.data!.channels[3].secondsBehindSource === null).assertTrue();
      expect(result.data!.channels[0].channelName).assertEqual('');
      expect(result.data!.channels[15].channelName).assertEqual('channel-15');
    });

    it('mapsLegacySlaveStatusRowsByNameAndPreservesNullableLag', 0, async () => {
      const connection = new MetricsConnection('5.7.44');
      connection.pushResult([
        ['default', 'Yes', 'No', null],
        ['delayed', 'No', 'Yes', '9007199254740995']
      ], [
        'Channel_Name',
        'Slave_IO_Running',
        'Slave_SQL_Running',
        'Seconds_Behind_Master'
      ]);

      const result = await new MySqlServerMetricsProvider(connection).readReplication();

      expect(connection.sql[0]).assertEqual(MYSQL_METRICS_REPLICATION_SLAVE_SQL);
      expect(result.availability).assertEqual(ServerMetricsAvailability.Available);
      expect(result.data!.channels.length).assertEqual(2);
      expect(result.data!.channels[0].channelName).assertEqual('default');
      expect(result.data!.channels[0].ioRunning).assertEqual(ReplicationIoRunning.Yes);
      expect(result.data!.channels[0].sqlRunning).assertEqual(ReplicationSqlRunning.No);
      expect(result.data!.channels[0].secondsBehindSource === null).assertTrue();
      expect(result.data!.channels[1].channelName).assertEqual('delayed');
      expect(result.data!.channels[1].ioRunning).assertEqual(ReplicationIoRunning.No);
      expect(result.data!.channels[1].sqlRunning).assertEqual(ReplicationSqlRunning.Yes);
      expect(result.data!.channels[1].secondsBehindSource!.toString()).assertEqual('9007199254740995');
    });

    it('usesAtMostSeventeenSourceRowsForReplicationTruncation', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      const rows: SqlValue[][] = [];
      for (let i = 0; i < 18; i++) {
        rows.push(['channel-' + String(i), 'Yes', 'Yes', String(i)]);
      }
      connection.pushResult(rows, [
        'Channel_Name',
        'Replica_IO_Running',
        'Replica_SQL_Running',
        'Seconds_Behind_Source'
      ]);
      const provider = new MySqlServerMetricsProvider(connection);

      const result = await provider.readReplication();

      expect(result.availability).assertEqual(ServerMetricsAvailability.Available);
      expect(result.data!.channels.length).assertEqual(16);
      expect(result.data!.truncated).assertTrue();
      expect(result.data!.channels[15].channelName).assertEqual('channel-15');
    });

    it('returnsEmptyReplicationAndUnsupportedForMissingReplicationColumns', 0, async () => {
      const empty = new MetricsConnection('8.0.21');
      empty.pushResult([], ['Channel_Name', 'Slave_IO_Running', 'Slave_SQL_Running',
        'Seconds_Behind_Master']);
      const emptyResult = await new MySqlServerMetricsProvider(empty).readReplication();

      const emptyMissingColumn = new MetricsConnection('8.0.36');
      emptyMissingColumn.pushResult([], [
        'Channel_Name',
        'Replica_IO_Running',
        'Replica_SQL_Running'
      ]);
      const emptyMissingResult = await new MySqlServerMetricsProvider(emptyMissingColumn).readReplication();

      const missingColumn = new MetricsConnection('8.0.36');
      missingColumn.pushResult([['default', 'Yes', 'Yes']], [
        'Channel_Name',
        'Replica_IO_Running',
        'Replica_SQL_Running'
      ]);
      const missingResult = await new MySqlServerMetricsProvider(missingColumn).readReplication();

      expect(empty.sql[0]).assertEqual(MYSQL_METRICS_REPLICATION_SLAVE_SQL);
      expect(emptyResult.availability).assertEqual(ServerMetricsAvailability.Empty);
      expect(emptyResult.data!.channels.length).assertEqual(0);
      expect(emptyMissingResult.availability).assertEqual(ServerMetricsAvailability.Unsupported);
      expect(emptyMissingResult.errorKind).assertEqual(ServerMetricsErrorKind.UnsupportedSource);
      expect(missingResult.availability).assertEqual(ServerMetricsAvailability.Unsupported);
      expect(missingResult.errorKind).assertEqual(ServerMetricsErrorKind.UnsupportedSource);
    });

    it('rejectsInterruptedReplicationRowLimitAfterTruncationCallback', 0, async () => {
      const connection = new MetricsConnection('8.0.36');
      const rows: SqlValue[][] = [];
      for (let i = 0; i < 18; i++) {
        rows.push(['channel-' + String(i), 'Yes', 'Yes', String(i)]);
      }
      connection.pushInterruptedResult(rows, [
        'Channel_Name',
        'Replica_IO_Running',
        'Replica_SQL_Running',
        'Seconds_Behind_Source'
      ]);
      let caught: ArkDbError | null = null;

      try {
        await new MySqlServerMetricsProvider(connection).readReplication();
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('mapsReplicationPermissionDeniedButRejectsMalformedLag', 0, async () => {
      const denied = new MetricsConnection('8.0.36');
      denied.pushError(ArkDbError.server('denied', 1227, '42000'));
      const deniedResult = await new MySqlServerMetricsProvider(denied).readReplication();

      const malformed = new MetricsConnection('8.0.36');
      malformed.pushResult([['default', 'Yes', 'Yes', '-1']], [
        'Channel_Name',
        'Replica_IO_Running',
        'Replica_SQL_Running',
        'Seconds_Behind_Source'
      ]);
      let caught: ArkDbError | null = null;

      try {
        await new MySqlServerMetricsProvider(malformed).readReplication();
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(deniedResult.availability).assertEqual(ServerMetricsAvailability.PermissionDenied);
      expect(deniedResult.errorKind).assertEqual(ServerMetricsErrorKind.Server);
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });
  });
}

async function expectUnsupportedProductWithoutQuery(family: ServerFamily, version: string): Promise<void> {
  const connection = new MetricsConnection(version, family);
  const result = await new MySqlServerMetricsProvider(connection).readOverview();
  expect(result.availability).assertEqual(ServerMetricsAvailability.Unsupported);
  expect(result.errorKind).assertEqual(ServerMetricsErrorKind.UnsupportedProduct);
  expect(connection.sql.length).assertEqual(0);
}

async function expectMappedOverviewError(code: number, sqlState: string,
  availability: ServerMetricsAvailability): Promise<void> {
  const connection = new MetricsConnection('8.0.36');
  connection.pushResult([['performance_schema', 'ON']]);
  connection.pushError(ArkDbError.server('mapped', code, sqlState));

  const result = await new MySqlServerMetricsProvider(connection).readOverview();

  expect(result.availability).assertEqual(availability);
  expect(result.errorKind).assertEqual(ServerMetricsErrorKind.Server);
  expect(result.errorCode).assertEqual(code);
  expect(result.errorSqlState).assertEqual(sqlState);
}

async function expectOverviewErrorRethrown(code: number, sqlState: string): Promise<void> {
  const connection = new MetricsConnection('8.0.36');
  connection.pushResult([['performance_schema', 'ON']]);
  connection.pushError(ArkDbError.server('unmapped', code, sqlState));
  let caught: ArkDbError | null = null;

  try {
    await new MySqlServerMetricsProvider(connection).readOverview();
  } catch (error) {
    caught = error as ArkDbError;
  }

  expect(caught !== null).assertTrue();
  expect(caught!.kind).assertEqual(ArkDbErrorKind.Server);
  expect(caught!.code).assertEqual(code);
  expect(caught!.sqlState).assertEqual(sqlState);
}

function serverInfo(family: ServerFamily, version: string): ServerInfo {
  const info = new ServerInfo();
  info.family = family;
  info.version = version;
  return info;
}

class StreamResponse {
  rows: SqlValue[][] = [];
  columns: string[] = [];
  error: ArkDbError | null = null;
  truncationInterrupted: boolean = false;
}

class MetricsConnection implements DbStreamingConnection {
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();
  readonly state: ConnectionState = ConnectionState.Ready;
  readonly sql: string[] = [];
  readonly options: QueryOptions[] = [];
  private responses: StreamResponse[] = [];

  constructor(version: string, family: ServerFamily = ServerFamily.MySQL) {
    this.serverInfo.family = family;
    this.serverInfo.version = version;
  }

  pushResult(rows: SqlValue[][], columns: string[] = ['c1', 'c2', 'c3', 'c4']): void {
    const response = new StreamResponse();
    response.rows = rows;
    response.columns = columns;
    this.responses.push(response);
  }

  pushInterruptedResult(rows: SqlValue[][], columns: string[] = ['c1', 'c2', 'c3', 'c4']): void {
    const response = new StreamResponse();
    response.rows = rows;
    response.columns = columns;
    response.truncationInterrupted = true;
    this.responses.push(response);
  }

  pushError(error: ArkDbError): void {
    const response = new StreamResponse();
    response.error = error;
    this.responses.push(response);
  }

  async connect(): Promise<void> {}

  async ping(): Promise<void> {}

  async query(sql: string): Promise<QueryResult> {
    throw ArkDbError.protocol('Metrics provider must stream queries.');
  }

  async queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    this.sql.push(sql);
    this.options.push(options.clone());
    const response = this.responses.shift();
    if (response === undefined) {
      throw ArkDbError.protocol('No fixture response.');
    }
    if (response.error !== null) {
      throw response.error;
    }

    const meta = new QueryResultMeta();
    meta.columns = columns(response.columns);
    meta.hasRows = true;
    await sink.onResultStart(meta);
    const loadedRowCount = options.maxRows > 0 && response.rows.length > options.maxRows ?
      options.maxRows : response.rows.length;
    if (loadedRowCount > 0) {
      const chunk = new QueryRowChunk();
      chunk.rows = response.rows.slice(0, loadedRowCount);
      await sink.onRows(chunk);
    }
    let truncationCancelled = false;
    if (loadedRowCount < response.rows.length && sink.onTruncation !== undefined) {
      const truncation = new QueryTruncation();
      truncation.loadedRowCount = loadedRowCount;
      truncation.reason = 'rowLimit';
      truncationCancelled = await sink.onTruncation(truncation);
    }
    const resultSummary = new QueryResultSummary();
    resultSummary.rowCount = response.rows.length;
    resultSummary.loadedRowCount = loadedRowCount;
    resultSummary.truncated = loadedRowCount < response.rows.length;
    resultSummary.truncationReason = resultSummary.truncated ? 'rowLimit' : '';
    await sink.onResultEnd(resultSummary);
    const summary = new QueryExecutionSummary();
    summary.resultSetCount = 1;
    summary.rowCount = response.rows.length;
    summary.loadedRowCount = loadedRowCount;
    summary.truncationInterrupted = response.truncationInterrupted || truncationCancelled;
    return summary;
  }

  async changeContext(context: DatabaseContext): Promise<void> {}

  async setAutocommit(enabled: boolean): Promise<DatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async commit(): Promise<DatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async rollback(): Promise<DatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async close(): Promise<void> {}
}

function columns(names: string[]): ColumnDef[] {
  const result: ColumnDef[] = [];
  for (const name of names) {
    const column = new ColumnDef();
    column.name = name;
    result.push(column);
  }
  return result;
}
