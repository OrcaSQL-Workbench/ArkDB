/**
 * Stable MySQL public interface, with explicitly named portable core contracts.
 * Runtime errors, deadlines and diagnostics retain their single shared owner.
 */
export { ArkDbError, ArkDbErrorKind, DatabaseContext, ContextChangeMode, DatabaseContextPolicy,
  ConnectionState, DbValueKind, MAX_QUERY_DRAIN_TIME_MS,
  MAX_STATEMENT_TIMEOUT_MS, QueryOptions, QueryTruncation, estimateSqlValueBytes,
  estimateSqlRowBytes, estimateSqlRowsBytes, DbDriverRegistry,
  DbConnectionFeatures, ConnectionDeadline, SystemConnectionTimerPort, connectionCleanupError,
  CancellationOutcome, ConnectionReuse, QueryCancellationResult, MetricKind, MetricMeasurement,
  ServerMetricsSnapshot, DbObjectKind, CatalogInfo, SchemaInfo, DbObjectInfo, ColumnInfo,
  IndexColumnInfo, IndexInfo, ForeignKeyColumnInfo, ForeignKeyInfo,
  LogLevel, LOG_DOMAIN, LogTag, Logger } from '@arkdb/core';
export type { DbStreamingConnection, DbConnectionHealth,
  DbContextController, DbTransactionController, ConnectionTimerPort, DbDriverDescriptor,
  LogSink, DbConnection as CoreDbConnection, DbDriverFactory as CoreDbDriverFactory,
  DbExecutionController as CoreDbExecutionController, MetadataProvider as CoreMetadataProvider,
  SqlValue as CoreSqlValue, QueryResultSink as CoreQueryResultSink } from '@arkdb/core';
export { DatabaseSessionStatus as CoreDatabaseSessionStatus, QueryResultMeta as CoreQueryResultMeta,
  QueryRowChunk as CoreQueryRowChunk, QueryResultSummary as CoreQueryResultSummary,
  QueryExecutionSummary as CoreQueryExecutionSummary, DriverCapabilities as CoreDriverCapabilities } from '@arkdb/core';

export { MySqlDriverCapabilities as DriverCapabilities } from './src/main/ets/mysql/driver/MySqlContracts';
export type { MySqlDbConnection as DbConnection, MySqlDbDriverFactory as DbDriverFactory,
  MySqlDbExecutionController as DbExecutionController, MySqlMetadataProviderContract as MetadataProvider } from
  './src/main/ets/mysql/driver/MySqlContracts';
export { MySqlDatabaseSessionStatus as DatabaseSessionStatus, MySqlQueryResultMeta as QueryResultMeta,
  MySqlQueryRowChunk as QueryRowChunk, MySqlQueryResultSummary as QueryResultSummary,
  MySqlQueryExecutionSummary as QueryExecutionSummary } from './src/main/ets/mysql/model/MySqlQueryStream';
export type { MySqlQueryResultSink as QueryResultSink } from './src/main/ets/mysql/model/MySqlQueryStream';
export type { MySqlValue as SqlValue } from './src/main/ets/mysql/model/MySqlQueryResult';

export { ConnectionConfigField, ConnectionValidationIssue, SslMode, SslConfig, ConnectionConfig } from
  './src/main/ets/mysql/model/ConnectionConfig';
export { MySqlSessionOptions } from './src/main/ets/mysql/model/MySqlSessionOptions';
export { ServerFamily, MySqlServerInfo, MySqlServerInfo as ServerInfo } from
  './src/main/ets/mysql/model/MySqlServerInfo';
export { MySqlColumnDef, MySqlColumnDef as ColumnDef, MySqlQueryResult, MySqlQueryResult as QueryResult } from
  './src/main/ets/mysql/model/MySqlQueryResult';
export { MySqlConnectionOptions } from './src/main/ets/mysql/driver/MySqlConnectionOptions';
export { MySqlConnectionFeatures, requireMySqlFeatures } from
  './src/main/ets/mysql/driver/MySqlConnectionFeatures';
export type { MySqlSession } from './src/main/ets/mysql/driver/MySqlSession';
export type { MySqlPreparedExecutor, MySqlPreparedStatement } from
  './src/main/ets/mysql/driver/MySqlPreparedContracts';
export { MySqlParameter, MySqlParameterType } from './src/main/ets/mysql/model/MySqlParameter';
export type { MySqlParameterValue } from './src/main/ets/mysql/model/MySqlParameter';
export { quoteMySqlIdentifier, mysqlPlaceholders } from './src/main/ets/mysql/value/MySqlSqlHelpers';
export { MySqlConnection, createMySqlConnection } from './src/main/ets/mysql/MySqlConnection';
export { MySqlDriverFactory } from './src/main/ets/mysql/driver/MySqlDriverFactory';
export { MySqlExecutionController } from './src/main/ets/mysql/execution/MySqlExecutionController';
export { MySqlMetadataProvider } from './src/main/ets/mysql/metadata/MySqlMetadataProvider';
export { MySqlServerMetricsProvider } from './src/main/ets/mysql/metrics/MySqlServerMetricsProvider';
export { MetricGauge, MetricCounter, ServerMetricsAvailability, ServerMetricsErrorKind,
  ReplicationIoRunning, ReplicationSqlRunning, ServerMetricsCategory,
  ServerOverviewSnapshot, ServerProcessInfo, ServerProcessSnapshot, InnoDbSnapshot,
  QueryActivitySnapshot, ReplicationChannelInfo, ReplicationSnapshot,
  MAX_METRICS_PROCESS_ROWS, MAX_METRICS_REPLICATION_CHANNELS, MAX_METRICS_UNSIGNED_64,
  MAX_PROCESS_COMMAND_UTF8_BYTES, MAX_PROCESS_STATE_UTF8_BYTES,
  MAX_REPLICATION_CHANNEL_NAME_UTF8_BYTES } from './src/main/ets/mysql/metrics/MySqlServerMetrics';
export type { ServerMetricsModel } from './src/main/ets/mysql/metrics/MySqlServerMetrics';
export type { MySqlMetricsProvider, MySqlMetricsProvider as ServerMetricsProvider } from
  './src/main/ets/mysql/metrics/MySqlMetricsProvider';
