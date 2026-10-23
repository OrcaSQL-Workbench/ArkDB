import { DbConnection } from '../../core/connection/DbConnection';
import { ArkDbError, ArkDbErrorKind } from '../../core/model/ArkDbError';
import { ColumnDef, SqlValue } from '../../core/model/QueryResult';
import { QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary,
  QueryRowChunk, QueryTruncation } from '../../core/model/QueryStream';
import { monotonicNowMs } from '../../core/time/MonotonicClock';
import {
  InnoDbSnapshot,
  MAX_METRICS_PROCESS_ROWS,
  MAX_METRICS_REPLICATION_CHANNELS,
  MAX_METRICS_UNSIGNED_64,
  QueryActivitySnapshot,
  ReplicationChannelInfo,
  ReplicationIoRunning,
  ReplicationSnapshot,
  ReplicationSqlRunning,
  ServerMetricsAvailability,
  ServerMetricsCategory,
  ServerMetricsErrorKind,
  ServerMetricsModel,
  ServerOverviewSnapshot,
  ServerProcessInfo,
  ServerProcessSnapshot
} from '../../core/metrics/ServerMetrics';
import { ServerMetricsProvider } from '../../core/metrics/ServerMetricsProvider';
import { utf8Decode, utf8Encode } from '../protocol/Charsets';
import {
  MYSQL_METRICS_INNODB_SQL,
  MYSQL_METRICS_OVERVIEW_SQL,
  MYSQL_METRICS_PERFORMANCE_SCHEMA_SQL,
  MYSQL_METRICS_PROCESS_SQL,
  MYSQL_METRICS_QUERY_ACTIVITY_SQL,
  MYSQL_METRICS_REPLICATION_REPLICA_SQL,
  mysqlMetricsProductSupported,
  mysqlReplicationSqlForServer
} from './MySqlMetricsSql';

const GLOBAL_STATUS_MAX_ROWS: number = 13;
const GLOBAL_STATUS_MAX_BYTES: number = 16 * 1024;
const PROCESS_SOURCE_MAX_ROWS: number = 101;
const PROCESS_SOURCE_MAX_BYTES: number = 128 * 1024;
const REPLICATION_SOURCE_MAX_ROWS: number = 17;
const REPLICATION_SOURCE_MAX_BYTES: number = 128 * 1024;

export class MySqlServerMetricsProvider implements ServerMetricsProvider {
  private connection: DbConnection;

  constructor(connection: DbConnection) {
    this.connection = connection;
  }

  async readOverview(): Promise<ServerMetricsCategory<ServerOverviewSnapshot>> {
    if (!mysqlMetricsProductSupported(this.connection.serverInfo)) {
      return unsupportedProduct<ServerOverviewSnapshot>();
    }
    const probe = await this.ensurePerformanceSchema<ServerOverviewSnapshot>();
    if (probe !== null) return probe;
    try {
      const rows = await this.readRows(MYSQL_METRICS_OVERVIEW_SQL, GLOBAL_STATUS_MAX_ROWS,
        GLOBAL_STATUS_MAX_BYTES);
      const values = statusValues(rows, [
        'Threads_connected',
        'Threads_running',
        'Connections',
        'Aborted_connects',
        'Max_used_connections'
      ]);
      if (values === null) return unsupportedSource<ServerOverviewSnapshot>();
      const data = new ServerOverviewSnapshot();
      data.threadsConnected.value = values.valueAt(0);
      data.threadsRunning.value = values.valueAt(1);
      data.connectionAttempts.value = values.valueAt(2);
      data.abortedConnectionAttempts.value = values.valueAt(3);
      data.maxUsedConnections.value = values.valueAt(4);
      return available(data);
    } catch (error) {
      return mappedOrThrow<ServerOverviewSnapshot>(error as Error);
    }
  }

  async listProcesses(limit: number): Promise<ServerMetricsCategory<ServerProcessSnapshot>> {
    validateProcessLimit(limit);
    if (!mysqlMetricsProductSupported(this.connection.serverInfo)) {
      return unsupportedProduct<ServerProcessSnapshot>();
    }
    try {
      const rows = await this.readRows(MYSQL_METRICS_PROCESS_SQL, PROCESS_SOURCE_MAX_ROWS,
        PROCESS_SOURCE_MAX_BYTES);
      const data = new ServerProcessSnapshot();
      const mappedRows = Math.min(limit, rows.length);
      for (let index = 0; index < mappedRows; index++) {
        const row = rows[index];
        if (row.length < 3) throw ArkDbError.protocol('Process metrics row is incomplete.');
        const process = new ServerProcessInfo();
        process.command = requiredText(row[0], 'process command');
        process.state = optionalText(row[1], 'process state');
        process.durationSeconds = requiredSafeInteger(row[2], 'process duration');
        data.rows.push(process);
      }
      data.truncated = rows.length > limit;
      if (rows.length === 0) return empty(data);
      return available(data);
    } catch (error) {
      return mappedOrThrow<ServerProcessSnapshot>(error as Error);
    }
  }

  async readInnoDb(): Promise<ServerMetricsCategory<InnoDbSnapshot>> {
    if (!mysqlMetricsProductSupported(this.connection.serverInfo)) {
      return unsupportedProduct<InnoDbSnapshot>();
    }
    const probe = await this.ensurePerformanceSchema<InnoDbSnapshot>();
    if (probe !== null) return probe;
    try {
      const rows = await this.readRows(MYSQL_METRICS_INNODB_SQL, GLOBAL_STATUS_MAX_ROWS,
        GLOBAL_STATUS_MAX_BYTES);
      const values = statusValues(rows, [
        'Innodb_buffer_pool_pages_total',
        'Innodb_buffer_pool_pages_free',
        'Innodb_buffer_pool_pages_data',
        'Innodb_buffer_pool_pages_dirty',
        'Innodb_buffer_pool_read_requests',
        'Innodb_buffer_pool_reads',
        'Innodb_buffer_pool_write_requests',
        'Innodb_buffer_pool_pages_flushed',
        'Innodb_rows_read',
        'Innodb_rows_inserted',
        'Innodb_rows_updated',
        'Innodb_rows_deleted'
      ]);
      if (values === null) return unsupportedSource<InnoDbSnapshot>();
      const data = new InnoDbSnapshot();
      data.bufferPoolPagesTotal.value = values.valueAt(0);
      data.bufferPoolPagesFree.value = values.valueAt(1);
      data.bufferPoolPagesData.value = values.valueAt(2);
      data.bufferPoolPagesDirty.value = values.valueAt(3);
      data.bufferPoolReadRequests.value = values.valueAt(4);
      data.bufferPoolReads.value = values.valueAt(5);
      data.bufferPoolWriteRequests.value = values.valueAt(6);
      data.bufferPoolPagesFlushed.value = values.valueAt(7);
      data.rowsRead.value = values.valueAt(8);
      data.rowsInserted.value = values.valueAt(9);
      data.rowsUpdated.value = values.valueAt(10);
      data.rowsDeleted.value = values.valueAt(11);
      return available(data);
    } catch (error) {
      return mappedOrThrow<InnoDbSnapshot>(error as Error);
    }
  }

  async readQueryActivity(): Promise<ServerMetricsCategory<QueryActivitySnapshot>> {
    if (!mysqlMetricsProductSupported(this.connection.serverInfo)) {
      return unsupportedProduct<QueryActivitySnapshot>();
    }
    const probe = await this.ensurePerformanceSchema<QueryActivitySnapshot>();
    if (probe !== null) return probe;
    try {
      const rows = await this.readRows(MYSQL_METRICS_QUERY_ACTIVITY_SQL, GLOBAL_STATUS_MAX_ROWS,
        GLOBAL_STATUS_MAX_BYTES);
      const values = statusValues(rows, ['Questions', 'Queries', 'Slow_queries']);
      if (values === null) return unsupportedSource<QueryActivitySnapshot>();
      const data = new QueryActivitySnapshot();
      data.questions.value = values.valueAt(0);
      data.queries.value = values.valueAt(1);
      data.slowQueries.value = values.valueAt(2);
      return available(data);
    } catch (error) {
      return mappedOrThrow<QueryActivitySnapshot>(error as Error);
    }
  }

  async readReplication(): Promise<ServerMetricsCategory<ReplicationSnapshot>> {
    const sql = mysqlReplicationSqlForServer(this.connection.serverInfo);
    if (sql === null) return unsupportedProduct<ReplicationSnapshot>();
    try {
      const result = await this.readRowsAndColumns(sql, REPLICATION_SOURCE_MAX_ROWS,
        REPLICATION_SOURCE_MAX_BYTES, true);
      const data = mapReplication(result, sql === MYSQL_METRICS_REPLICATION_REPLICA_SQL);
      if (data.channels.length === 0) return empty(data);
      return available(data);
    } catch (error) {
      return mappedOrThrow<ReplicationSnapshot>(error as Error);
    }
  }

  private async ensurePerformanceSchema<T extends ServerMetricsModel>(): Promise<ServerMetricsCategory<T> | null> {
    try {
      const rows = await this.readRows(MYSQL_METRICS_PERFORMANCE_SCHEMA_SQL, 1, GLOBAL_STATUS_MAX_BYTES);
      if (rows.length === 0) return unsupportedSource<T>();
      if (rows.length !== 1 || rows[0].length < 2) {
        throw ArkDbError.protocol('Performance Schema probe row is malformed.');
      }
      const name = requiredText(rows[0][0], 'performance_schema variable name');
      const value = requiredText(rows[0][1], 'performance_schema value');
      if (lowerAscii(name) !== 'performance_schema') {
        throw ArkDbError.protocol('Performance Schema probe row is malformed.');
      }
      if (lowerAscii(value) === 'on') return null;
      if (lowerAscii(value) === 'off') return disabled<T>();
      throw ArkDbError.protocol('Performance Schema probe value is malformed.');
    } catch (error) {
      return mappedOrThrow<T>(error as Error);
    }
  }

  private async readRows(sql: string, maxRows: number, maxBytes: number): Promise<SqlValue[][]> {
    return (await this.readRowsAndColumns(sql, maxRows, maxBytes)).rows;
  }

  private async readRowsAndColumns(sql: string, maxRows: number,
    maxBytes: number, allowRowLimitTruncation: boolean = false): Promise<MetricsQueryResult> {
    const sink = new MetricsQuerySink();
    const options = new QueryOptions();
    options.maxRows = maxRows;
    options.maxChunkRows = maxRows;
    options.maxChunkBytes = maxBytes;
    options.maxResultBytes = maxBytes;
    options.maxDrainBytes = maxBytes;
    options.maxResultSets = 1;
    const summary = await this.connection.queryStream(sql, options, sink);
    if (summary.truncationInterrupted) {
      throw ArkDbError.protocol('Metrics source result exceeded configured bounds.');
    }
    if (summary.resultSetCount > 1) {
      throw ArkDbError.protocol('Metrics source result exceeded configured bounds.');
    }
    if (sink.truncated && (!allowRowLimitTruncation || sink.truncationReason !== 'rowLimit')) {
      throw ArkDbError.protocol('Metrics source result exceeded configured bounds.');
    }
    if (sink.rows.length > maxRows) {
      throw ArkDbError.protocol('Metrics source result exceeded configured bounds.');
    }
    return sink.result();
  }
}

class MetricsQueryResult {
  columns: ColumnDef[] = [];
  rows: SqlValue[][] = [];
}

class MetricsQuerySink implements QueryResultSink {
  columns: ColumnDef[] = [];
  rows: SqlValue[][] = [];
  truncated: boolean = false;
  truncationReason: string = '';

  async onResultStart(meta: QueryResultMeta): Promise<void> {
    this.columns = meta.columns;
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    for (const row of chunk.rows) {
      this.rows.push(row);
    }
  }

  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncated = true;
    this.truncationReason = truncation.reason;
    return false;
  }

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    this.truncated = this.truncated || summary.truncated;
    if (this.truncationReason.length === 0) this.truncationReason = summary.truncationReason;
  }

  result(): MetricsQueryResult {
    const result = new MetricsQueryResult();
    result.columns = this.columns;
    result.rows = this.rows;
    return result;
  }
}

class StatusValues {
  values: bigint[] = [];

  valueAt(index: number): bigint {
    return this.values[index];
  }
}

function statusValues(rows: SqlValue[][], names: string[]): StatusValues | null {
  const result = new StatusValues();
  for (const name of names) {
    let found = false;
    let value = 0n;
    for (const row of rows) {
      if (row.length < 2) throw ArkDbError.protocol('Metrics status row is incomplete.');
      if (requiredText(row[0], 'status variable name') === name) {
        if (row[1] === null) return null;
        value = requiredUnsigned64(row[1], name);
        found = true;
        break;
      }
    }
    if (!found) return null;
    result.values.push(value);
  }
  return result;
}

function mapReplication(result: MetricsQueryResult, useReplicaColumns: boolean): ReplicationSnapshot {
  const data = new ReplicationSnapshot();
  const channelIndex = columnIndex(result.columns, 'channel_name');
  const selectedIoIndex = columnIndex(result.columns,
    useReplicaColumns ? 'replica_io_running' : 'slave_io_running');
  const selectedSqlIndex = columnIndex(result.columns,
    useReplicaColumns ? 'replica_sql_running' : 'slave_sql_running');
  const selectedLagIndex = columnIndex(result.columns,
    useReplicaColumns ? 'seconds_behind_source' : 'seconds_behind_master');
  if (channelIndex < 0 || selectedIoIndex < 0 || selectedSqlIndex < 0 || selectedLagIndex < 0) {
    throw new UnsupportedSourceError();
  }
  if (result.rows.length === 0) return data;

  const count = Math.min(MAX_METRICS_REPLICATION_CHANNELS, result.rows.length);
  for (let index = 0; index < count; index++) {
    const row = result.rows[index];
    const channel = new ReplicationChannelInfo();
    channel.channelName = nonNullText(row[channelIndex], 'replication channel name');
    channel.ioRunning = mapIoRunning(optionalText(row[selectedIoIndex], 'replication I/O running'));
    channel.sqlRunning = mapSqlRunning(optionalText(row[selectedSqlIndex], 'replication SQL running'));
    channel.secondsBehindSource = optionalUnsigned64(row[selectedLagIndex], 'replication lag');
    data.channels.push(channel);
  }
  data.truncated = result.rows.length > MAX_METRICS_REPLICATION_CHANNELS;
  return data;
}

function columnIndex(columns: ColumnDef[], name: string): number {
  for (let index = 0; index < columns.length; index++) {
    if (lowerAscii(columns[index].name) === name) return index;
  }
  return -1;
}

function mapIoRunning(value: string | null): ReplicationIoRunning {
  const normalized = value === null ? '' : lowerAscii(value);
  if (normalized === 'yes') return ReplicationIoRunning.Yes;
  if (normalized === 'no') return ReplicationIoRunning.No;
  if (normalized === 'connecting') return ReplicationIoRunning.Connecting;
  return ReplicationIoRunning.Unknown;
}

function mapSqlRunning(value: string | null): ReplicationSqlRunning {
  const normalized = value === null ? '' : lowerAscii(value);
  if (normalized === 'yes') return ReplicationSqlRunning.Yes;
  if (normalized === 'no') return ReplicationSqlRunning.No;
  return ReplicationSqlRunning.Unknown;
}

function validateProcessLimit(limit: number): void {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_METRICS_PROCESS_ROWS) {
    throw ArkDbError.validation('Process metrics limit must be between 1 and 100.');
  }
}

function available<T extends ServerMetricsModel>(data: T): ServerMetricsCategory<T> {
  return mapped(ServerMetricsAvailability.Available, data);
}

function empty<T extends ServerMetricsModel>(data: T): ServerMetricsCategory<T> {
  return mapped(ServerMetricsAvailability.Empty, data);
}

function mapped<T extends ServerMetricsModel>(availability: ServerMetricsAvailability,
  data: T): ServerMetricsCategory<T> {
  const result = new ServerMetricsCategory<T>();
  result.availability = availability;
  result.data = data;
  result.sampledAtUptimeMs = monotonicNowMs();
  ensureCategoryValid(result);
  return result;
}

function unsupportedProduct<T extends ServerMetricsModel>(): ServerMetricsCategory<T> {
  const result = new ServerMetricsCategory<T>();
  result.availability = ServerMetricsAvailability.Unsupported;
  result.errorKind = ServerMetricsErrorKind.UnsupportedProduct;
  ensureCategoryValid(result);
  return result;
}

function unsupportedSource<T extends ServerMetricsModel>(): ServerMetricsCategory<T> {
  const result = new ServerMetricsCategory<T>();
  result.availability = ServerMetricsAvailability.Unsupported;
  result.errorKind = ServerMetricsErrorKind.UnsupportedSource;
  ensureCategoryValid(result);
  return result;
}

function disabled<T extends ServerMetricsModel>(): ServerMetricsCategory<T> {
  const result = new ServerMetricsCategory<T>();
  result.availability = ServerMetricsAvailability.Disabled;
  result.errorKind = ServerMetricsErrorKind.PerformanceSchemaDisabled;
  ensureCategoryValid(result);
  return result;
}

function serverCategory<T extends ServerMetricsModel>(availability: ServerMetricsAvailability,
  error: ArkDbError): ServerMetricsCategory<T> {
  const result = new ServerMetricsCategory<T>();
  result.availability = availability;
  result.errorKind = ServerMetricsErrorKind.Server;
  result.errorCode = error.code === undefined ? null : error.code;
  result.errorSqlState = error.sqlState === undefined ? null : error.sqlState;
  ensureCategoryValid(result);
  return result;
}

function mappedOrThrow<T extends ServerMetricsModel>(error: Error): ServerMetricsCategory<T> {
  if (error instanceof UnsupportedSourceError) return unsupportedSource<T>();
  if (!(error instanceof ArkDbError)) throw error;
  if (error.kind !== ArkDbErrorKind.Server) throw error;
  if (isPermissionDenied(error)) return serverCategory<T>(ServerMetricsAvailability.PermissionDenied, error);
  if (isUnsupportedSource(error)) return serverCategory<T>(ServerMetricsAvailability.Unsupported, error);
  throw error;
}

function isPermissionDenied(error: ArkDbError): boolean {
  if (error.sqlState !== '42000') return false;
  return error.code === 1142 || error.code === 1143 || error.code === 1227;
}

function isUnsupportedSource(error: ArkDbError): boolean {
  return (error.code === 1146 && error.sqlState === '42S02') ||
    (error.code === 1054 && error.sqlState === '42S22');
}

function ensureCategoryValid<T extends ServerMetricsModel>(category: ServerMetricsCategory<T>): void {
  const errors = category.validate();
  if (errors.length > 0) {
    throw ArkDbError.protocol(errors[0].message);
  }
}

function requiredText(value: SqlValue, field: string): string {
  const text = optionalText(value, field);
  if (text === null || text.length === 0) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
  }
  return text;
}

function nonNullText(value: SqlValue, field: string): string {
  const text = optionalText(value, field);
  if (text === null) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
  }
  return text;
}

function optionalText(value: SqlValue, field: string): string | null {
  if (value === null) return null;
  if (typeof value === 'string') return value;
  if (value instanceof Uint8Array) {
    const decoded = utf8Decode(value);
    if (!sameBytes(value, utf8Encode(decoded))) {
      throw ArkDbError.protocol('Invalid UTF-8 ' + field + ' in metrics response.');
    }
    return decoded;
  }
  throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
}

function requiredUnsigned64(value: SqlValue, field: string): bigint {
  if (value === null) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
  }
  const parsed = optionalUnsigned64(value, field);
  if (parsed === null) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
  }
  return parsed;
}

function optionalUnsigned64(value: SqlValue, field: string): bigint | null {
  if (value === null) return null;
  let parsed: bigint;
  if (typeof value === 'bigint') {
    parsed = value;
  } else if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) {
      throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
    }
    parsed = BigInt(value);
  } else {
    const text = requiredText(value, field);
    if (!/^(?:0|[1-9][0-9]*)$/.test(text)) {
      throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
    }
    parsed = BigInt(text);
  }
  if (parsed < 0n || parsed > MAX_METRICS_UNSIGNED_64) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
  }
  return parsed;
}

function requiredSafeInteger(value: SqlValue, field: string): number {
  const parsed = requiredUnsigned64(value, field);
  const result = Number(parsed);
  if (!Number.isSafeInteger(result)) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metrics response.');
  }
  return result;
}

function lowerAscii(value: string): string {
  let result = '';
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code >= 65 && code <= 90) {
      result += String.fromCharCode(code + 32);
    } else {
      result += value.charAt(index);
    }
  }
  return result;
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

class UnsupportedSourceError extends Error {
  constructor() {
    super('Unsupported metrics source.');
    this.name = 'UnsupportedSourceError';
  }
}
