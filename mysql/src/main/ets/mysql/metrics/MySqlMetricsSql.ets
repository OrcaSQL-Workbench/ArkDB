import { ServerInfo } from '@arkdb/core';
import { ServerFamily, MySqlServerInfo } from '../model/MySqlServerInfo';

export const MYSQL_METRICS_PERFORMANCE_SCHEMA_SQL: string =
  "SHOW VARIABLES LIKE 'performance_schema'";

export const MYSQL_METRICS_OVERVIEW_SQL: string =
  'SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME IN (' +
  "'Aborted_connects', 'Connections', 'Max_used_connections', 'Threads_connected', 'Threads_running')";

export const MYSQL_METRICS_PROCESS_SQL: string =
  'SELECT COMMAND, STATE, TIME FROM INFORMATION_SCHEMA.PROCESSLIST ' +
  'ORDER BY TIME DESC, COMMAND ASC, STATE ASC LIMIT 101';

export const MYSQL_METRICS_INNODB_SQL: string =
  'SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME IN (' +
  "'Innodb_buffer_pool_pages_data', 'Innodb_buffer_pool_pages_dirty', " +
  "'Innodb_buffer_pool_pages_flushed', 'Innodb_buffer_pool_pages_free', " +
  "'Innodb_buffer_pool_pages_total', 'Innodb_buffer_pool_read_requests', " +
  "'Innodb_buffer_pool_reads', 'Innodb_buffer_pool_write_requests', " +
  "'Innodb_rows_deleted', 'Innodb_rows_inserted', 'Innodb_rows_read', 'Innodb_rows_updated')";

export const MYSQL_METRICS_QUERY_ACTIVITY_SQL: string =
  'SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status ' +
  "WHERE VARIABLE_NAME IN ('Queries', 'Questions', 'Slow_queries')";

export const MYSQL_METRICS_REPLICATION_SLAVE_SQL: string = 'SHOW SLAVE STATUS';
export const MYSQL_METRICS_REPLICATION_REPLICA_SQL: string = 'SHOW REPLICA STATUS';

export function mysqlMetricsProductSupported(serverInfo: ServerInfo): boolean {
  return parseAcceptedMySqlVersion(serverInfo) !== null;
}

export function mysqlReplicationSqlForServer(serverInfo: ServerInfo): string | null {
  const version = parseAcceptedMySqlVersion(serverInfo);
  if (version === null) return null;
  if (version.major === 5) return MYSQL_METRICS_REPLICATION_SLAVE_SQL;
  if (version.major === 8 && version.minor === 0 && version.patch <= 21) {
    return MYSQL_METRICS_REPLICATION_SLAVE_SQL;
  }
  return MYSQL_METRICS_REPLICATION_REPLICA_SQL;
}

class MySqlVersion {
  major: number = 0;
  minor: number = 0;
  patch: number = 0;
}

function parseAcceptedMySqlVersion(serverInfo: ServerInfo): MySqlVersion | null {
  if (!(serverInfo instanceof MySqlServerInfo) || serverInfo.family !== ServerFamily.MySQL) return null;
  const version = serverInfo.version;
  if (!/^(?:5\.7|[89]\.(?:0|[1-9][0-9]*))\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[._+~-][0-9A-Za-z]+)*)?$/.test(version)) {
    return null;
  }
  const dash = version.indexOf('-');
  const core = dash >= 0 ? version.substring(0, dash) : version;
  const parts = core.split('.');
  const parsed = new MySqlVersion();
  parsed.major = Number(parts[0]);
  parsed.minor = Number(parts[1]);
  parsed.patch = Number(parts[2]);
  return parsed;
}
