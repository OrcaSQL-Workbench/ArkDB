import { describe, expect, it } from '@ohos/hypium';
import {
  DriverCapabilities,
  MAX_METRICS_PROCESS_ROWS,
  MAX_METRICS_REPLICATION_CHANNELS,
  MAX_METRICS_UNSIGNED_64,
  MAX_PROCESS_COMMAND_UTF8_BYTES,
  MAX_PROCESS_STATE_UTF8_BYTES,
  MAX_REPLICATION_CHANNEL_NAME_UTF8_BYTES,
  InnoDbSnapshot,
  MetricCounter,
  MetricGauge,
  QueryActivitySnapshot,
  ReplicationChannelInfo,
  ReplicationIoRunning,
  ReplicationSnapshot,
  ReplicationSqlRunning,
  ServerMetricsAvailability,
  ServerMetricsCategory,
  ServerMetricsErrorKind,
  ServerMetricsProvider,
  ServerOverviewSnapshot,
  ServerProcessInfo,
  ServerProcessSnapshot
} from '../../../../Index';

export default function serverMetricsTest() {
  describe('ServerMetrics', () => {
    it('preservesExactBigintMetricValues', 0, () => {
      const exact = 9007199254740993n;
      const counter = new MetricCounter();
      const gauge = new MetricGauge();

      counter.value = exact;
      gauge.value = exact;

      expect(counter.value.toString()).assertEqual('9007199254740993');
      expect(gauge.value.toString()).assertEqual('9007199254740993');
    });

    it('modelsExplicitAvailabilityAndErrorStates', 0, () => {
      const category = new ServerMetricsCategory<ServerOverviewSnapshot>();

      category.availability = ServerMetricsAvailability.PermissionDenied;
      category.sampledAtUptimeMs = null;
      category.data = null;
      category.errorKind = ServerMetricsErrorKind.Server;
      category.errorCode = 1142;
      category.errorSqlState = '42000';

      expect(category.availability).assertEqual('permission-denied');
      expect(category.errorKind).assertEqual('server');
      expect(category.validate().length).assertEqual(0);
      expect(ServerMetricsAvailability.Available).assertEqual('available');
      expect(ServerMetricsAvailability.Unsupported).assertEqual('unsupported');
      expect(ServerMetricsAvailability.Disabled).assertEqual('disabled');
      expect(ServerMetricsAvailability.Empty).assertEqual('empty');
      expect(ServerMetricsErrorKind.UnsupportedProduct).assertEqual('unsupported-product');
      expect(ServerMetricsErrorKind.UnsupportedSource).assertEqual('unsupported-source');
      expect(ServerMetricsErrorKind.PerformanceSchemaDisabled).assertEqual('performance-schema-disabled');
    });

    it('rejectsContradictoryCategoryAvailabilityState', 0, () => {
      const availableWithoutSample = new ServerMetricsCategory<ServerOverviewSnapshot>();
      availableWithoutSample.availability = ServerMetricsAvailability.Available;
      availableWithoutSample.data = new ServerOverviewSnapshot();

      const availableWithError = new ServerMetricsCategory<ServerOverviewSnapshot>();
      availableWithError.availability = ServerMetricsAvailability.Available;
      availableWithError.sampledAtUptimeMs = 1;
      availableWithError.data = new ServerOverviewSnapshot();
      availableWithError.errorKind = ServerMetricsErrorKind.Server;
      availableWithError.errorCode = 1142;
      availableWithError.errorSqlState = '42000';

      const emptyWithoutData = new ServerMetricsCategory<ServerProcessSnapshot>();
      emptyWithoutData.availability = ServerMetricsAvailability.Empty;
      emptyWithoutData.sampledAtUptimeMs = 2;

      const unsupportedWithData = new ServerMetricsCategory<ServerOverviewSnapshot>();
      unsupportedWithData.availability = ServerMetricsAvailability.Unsupported;
      unsupportedWithData.data = new ServerOverviewSnapshot();
      unsupportedWithData.errorKind = ServerMetricsErrorKind.UnsupportedSource;

      const disabledWithServerError = new ServerMetricsCategory<QueryActivitySnapshot>();
      disabledWithServerError.availability = ServerMetricsAvailability.Disabled;
      disabledWithServerError.errorKind = ServerMetricsErrorKind.Server;
      disabledWithServerError.errorCode = 1054;
      disabledWithServerError.errorSqlState = '42S22';

      const permissionDeniedWithLocalError = new ServerMetricsCategory<QueryActivitySnapshot>();
      permissionDeniedWithLocalError.availability = ServerMetricsAvailability.PermissionDenied;
      permissionDeniedWithLocalError.errorKind = ServerMetricsErrorKind.UnsupportedSource;

      expect(availableWithoutSample.validate().length > 0).assertTrue();
      expect(availableWithError.validate().length > 0).assertTrue();
      expect(emptyWithoutData.validate().length > 0).assertTrue();
      expect(unsupportedWithData.validate().length > 0).assertTrue();
      expect(disabledWithServerError.validate().length > 0).assertTrue();
      expect(permissionDeniedWithLocalError.validate().length > 0).assertTrue();
    });

    it('validatesNestedNeutralSnapshotValues', 0, () => {
      const overview = new ServerOverviewSnapshot();
      const innodb = new InnoDbSnapshot();
      const queryActivity = new QueryActivitySnapshot();

      overview.threadsConnected.value = -1n;
      innodb.bufferPoolReads.value = 18446744073709551616n;
      queryActivity.questions.value = 18446744073709551616n;

      expect(overview.validate().length > 0).assertTrue();
      expect(innodb.validate().length > 0).assertTrue();
      expect(queryActivity.validate().length > 0).assertTrue();
    });

    it('validatesSampleTimeAsNonNegativeSafeInteger', 0, () => {
      const valid = new ServerMetricsCategory<QueryActivitySnapshot>();
      valid.availability = ServerMetricsAvailability.Available;
      valid.sampledAtUptimeMs = 0;
      valid.data = new QueryActivitySnapshot();

      const negative = new ServerMetricsCategory<QueryActivitySnapshot>();
      negative.sampledAtUptimeMs = -1;

      const unsafe = new ServerMetricsCategory<QueryActivitySnapshot>();
      unsafe.sampledAtUptimeMs = 9007199254740992;

      expect(valid.validate().length).assertEqual(0);
      expect(negative.validate()[0].kind).assertEqual('validation');
      expect(unsafe.validate()[0].kind).assertEqual('validation');
    });

    it('rejectsProcessRowsOutsideNeutralBounds', 0, () => {
      const emptyCommand = new ServerProcessInfo();
      emptyCommand.command = '';

      const longCommand = new ServerProcessInfo();
      longCommand.command = repeatedAscii(MAX_PROCESS_COMMAND_UTF8_BYTES + 1);

      const longState = new ServerProcessInfo();
      longState.command = 'Query';
      longState.state = repeatedAscii(MAX_PROCESS_STATE_UTF8_BYTES + 1);

      const negativeDuration = new ServerProcessInfo();
      negativeDuration.command = 'Sleep';
      negativeDuration.durationSeconds = -1;

      const tooManyRows = new ServerProcessSnapshot();
      for (let i = 0; i < MAX_METRICS_PROCESS_ROWS + 1; i++) {
        const row = new ServerProcessInfo();
        row.command = 'Sleep';
        tooManyRows.rows.push(row);
      }

      expect(emptyCommand.validate().length > 0).assertTrue();
      expect(longCommand.validate().length > 0).assertTrue();
      expect(longState.validate().length > 0).assertTrue();
      expect(negativeDuration.validate().length > 0).assertTrue();
      expect(tooManyRows.validate().length > 0).assertTrue();
    });

    it('rejectsReplicationRowsOutsideNeutralBounds', 0, () => {
      const longChannel = new ReplicationChannelInfo();
      longChannel.channelName = repeatedAscii(MAX_REPLICATION_CHANNEL_NAME_UTF8_BYTES + 1);

      const negativeLag = new ReplicationChannelInfo();
      negativeLag.secondsBehindSource = -1n;

      const oversizedLag = new ReplicationChannelInfo();
      oversizedLag.secondsBehindSource = 18446744073709551616n;

      const tooManyChannels = new ReplicationSnapshot();
      for (let i = 0; i < MAX_METRICS_REPLICATION_CHANNELS + 1; i++) {
        tooManyChannels.channels.push(new ReplicationChannelInfo());
      }

      expect(longChannel.validate().length > 0).assertTrue();
      expect(negativeLag.validate().length > 0).assertTrue();
      expect(oversizedLag.validate().length > 0).assertTrue();
      expect(tooManyChannels.validate().length > 0).assertTrue();
    });

    it('usesUtf8BytesForNeutralStringBounds', 0, () => {
      const process = new ServerProcessInfo();
      process.command = repeatedText('查', 22);

      const state = new ServerProcessInfo();
      state.command = 'Query';
      state.state = repeatedText('查', 171);

      const channel = new ReplicationChannelInfo();
      channel.channelName = repeatedText('查', 43);

      expect(process.validate().length > 0).assertTrue();
      expect(state.validate().length > 0).assertTrue();
      expect(channel.validate().length > 0).assertTrue();
    });

    it('keepsApprovedCollectionBoundsExact', 0, () => {
      expect(MAX_METRICS_PROCESS_ROWS).assertEqual(100);
      expect(MAX_METRICS_REPLICATION_CHANNELS).assertEqual(16);
      expect(MAX_METRICS_UNSIGNED_64.toString()).assertEqual('18446744073709551615');
      expect(MAX_PROCESS_COMMAND_UTF8_BYTES).assertEqual(64);
      expect(MAX_PROCESS_STATE_UTF8_BYTES).assertEqual(512);
      expect(MAX_REPLICATION_CHANNEL_NAME_UTF8_BYTES).assertEqual(128);
    });

    it('exposesOnlyNeutralSnapshotFields', 0, () => {
      const overview = new ServerOverviewSnapshot();
      const process = new ServerProcessInfo();
      const processes = new ServerProcessSnapshot();
      const channel = new ReplicationChannelInfo();
      const replication = new ReplicationSnapshot();

      overview.connectionAttempts.value = 18446744073709551615n;
      process.command = 'Query';
      process.state = null;
      process.durationSeconds = 9;
      processes.rows = [process];
      channel.channelName = '';
      channel.ioRunning = ReplicationIoRunning.Connecting;
      channel.sqlRunning = ReplicationSqlRunning.Unknown;
      channel.secondsBehindSource = null;
      replication.channels = [channel];

      expect(overview.connectionAttempts.value.toString()).assertEqual('18446744073709551615');
      expect(processes.rows.length).assertEqual(1);
      expect(processes.truncated).assertFalse();
      expect(channel.ioRunning).assertEqual('connecting');
      expect(channel.sqlRunning).assertEqual('unknown');
      expect(replication.channels.length).assertEqual(1);
    });

    it('wiresDriverCapabilityAndProviderInterface', 0, async () => {
      const capabilities = new DriverCapabilities();
      const provider = new FixedServerMetricsProvider();

      const overview = await provider.readOverview();
      const processes = await provider.listProcesses(100);
      const innoDb = await provider.readInnoDb();
      const queryActivity = await provider.readQueryActivity();
      const replication = await provider.readReplication();

      expect(capabilities.supportsServerMetrics).assertFalse();
      expect(overview.data!.threadsRunning.value.toString()).assertEqual('2');
      expect(processes.data!.rows[0].command).assertEqual('Sleep');
      expect(innoDb.data!.bufferPoolReads.value.toString()).assertEqual('3');
      expect(queryActivity.data!.slowQueries.value.toString()).assertEqual('4');
      expect(replication.data!.channels[0].sqlRunning).assertEqual('yes');
    });
  });
}

function repeatedAscii(count: number): string {
  return repeatedText('x', count);
}

function repeatedText(text: string, count: number): string {
  let result = '';
  for (let i = 0; i < count; i++) {
    result += text;
  }
  return result;
}

class FixedServerMetricsProvider implements ServerMetricsProvider {
  async readOverview(): Promise<ServerMetricsCategory<ServerOverviewSnapshot>> {
    const data = new ServerOverviewSnapshot();
    data.threadsRunning.value = 2n;
    const result = new ServerMetricsCategory<ServerOverviewSnapshot>();
    result.availability = ServerMetricsAvailability.Available;
    result.sampledAtUptimeMs = 1;
    result.data = data;
    return result;
  }

  async listProcesses(limit: number): Promise<ServerMetricsCategory<ServerProcessSnapshot>> {
    expect(limit).assertEqual(100);
    const row = new ServerProcessInfo();
    row.command = 'Sleep';
    const data = new ServerProcessSnapshot();
    data.rows = [row];
    const result = new ServerMetricsCategory<ServerProcessSnapshot>();
    result.availability = ServerMetricsAvailability.Available;
    result.sampledAtUptimeMs = 2;
    result.data = data;
    return result;
  }

  async readInnoDb(): Promise<ServerMetricsCategory<InnoDbSnapshot>> {
    const data = new InnoDbSnapshot();
    data.bufferPoolReads.value = 3n;
    const result = new ServerMetricsCategory<InnoDbSnapshot>();
    result.availability = ServerMetricsAvailability.Available;
    result.sampledAtUptimeMs = 3;
    result.data = data;
    return result;
  }

  async readQueryActivity(): Promise<ServerMetricsCategory<QueryActivitySnapshot>> {
    const data = new QueryActivitySnapshot();
    data.slowQueries.value = 4n;
    const result = new ServerMetricsCategory<QueryActivitySnapshot>();
    result.availability = ServerMetricsAvailability.Available;
    result.sampledAtUptimeMs = 4;
    result.data = data;
    return result;
  }

  async readReplication(): Promise<ServerMetricsCategory<ReplicationSnapshot>> {
    const channel = new ReplicationChannelInfo();
    channel.sqlRunning = ReplicationSqlRunning.Yes;
    const data = new ReplicationSnapshot();
    data.channels = [channel];
    const result = new ServerMetricsCategory<ReplicationSnapshot>();
    result.availability = ServerMetricsAvailability.Available;
    result.sampledAtUptimeMs = 5;
    result.data = data;
    return result;
  }
}
