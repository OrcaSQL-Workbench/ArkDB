/**
 * Public @arkdb/mysql interface. No UI, saved-profile, or application runtime dependencies.
 */

export { ArkDbError, ArkDbErrorKind } from './src/main/ets/core/model/ArkDbError';
export {
  ConnectionConfigField,
  ConnectionValidationIssue,
  SslMode,
  SslConfig,
  ConnectionConfig
} from './src/main/ets/core/model/ConnectionConfig';
export { DatabaseContext } from './src/main/ets/core/model/DatabaseContext';
export { ConnectionState, ServerFamily, ServerInfo } from './src/main/ets/core/model/ServerInfo';
export { DbValueKind, ColumnDef, QueryResult } from './src/main/ets/core/model/QueryResult';
export type { SqlValue } from './src/main/ets/core/model/QueryResult';
export { DatabaseSessionStatus, MAX_QUERY_DRAIN_TIME_MS, MAX_STATEMENT_TIMEOUT_MS,
	QueryOptions, QueryResultMeta, QueryRowChunk,
	QueryTruncation, QueryResultSummary, QueryExecutionSummary, estimateSqlValueBytes, estimateSqlRowBytes,
	estimateSqlRowsBytes } from './src/main/ets/core/model/QueryStream';
export type { QueryResultSink } from './src/main/ets/core/model/QueryStream';
export { DriverCapabilities } from './src/main/ets/core/driver/DriverCapabilities';
export { MetricGauge, MetricCounter, ServerMetricsAvailability, ServerMetricsErrorKind,
  ReplicationIoRunning, ReplicationSqlRunning, ServerMetricsCategory,
  ServerOverviewSnapshot, ServerProcessInfo, ServerProcessSnapshot, InnoDbSnapshot,
  QueryActivitySnapshot, ReplicationChannelInfo, ReplicationSnapshot,
  MAX_METRICS_PROCESS_ROWS, MAX_METRICS_REPLICATION_CHANNELS, MAX_METRICS_UNSIGNED_64,
  MAX_PROCESS_COMMAND_UTF8_BYTES, MAX_PROCESS_STATE_UTF8_BYTES,
  MAX_REPLICATION_CHANNEL_NAME_UTF8_BYTES } from './src/main/ets/core/metrics/ServerMetrics';
export type { ServerMetricsModel } from './src/main/ets/core/metrics/ServerMetrics';
export { DbObjectKind, CatalogInfo, SchemaInfo, DbObjectInfo, ColumnInfo, IndexColumnInfo, IndexInfo,
  ForeignKeyColumnInfo, ForeignKeyInfo } from './src/main/ets/core/metadata/Metadata';
export type { DbConnection } from './src/main/ets/core/connection/DbConnection';
export { ConnectionDeadline, SystemConnectionTimerPort, connectionCleanupError } from
  './src/main/ets/core/connection/ConnectionDeadline';
export type { ConnectionTimerPort } from './src/main/ets/core/connection/ConnectionDeadline';
export type { DbDriverFactory } from './src/main/ets/core/driver/DbDriverFactory';
export type { DbExecutionController } from './src/main/ets/core/execution/DbExecutionController';
export type { ServerMetricsProvider } from './src/main/ets/core/metrics/ServerMetricsProvider';
export type { MetadataProvider } from './src/main/ets/core/metadata/MetadataProvider';

// Connection API
export { MySqlConnection, createMySqlConnection } from './src/main/ets/mysql/MySqlConnection';
export { MySqlDriverFactory } from './src/main/ets/mysql/driver/MySqlDriverFactory';

// Logging & diagnostics
export { LogLevel, LOG_DOMAIN, LogTag } from './src/main/ets/core/diagnostics/LogSink';
export type { LogSink } from './src/main/ets/core/diagnostics/LogSink';
export { Logger } from './src/main/ets/core/diagnostics/Logger';
