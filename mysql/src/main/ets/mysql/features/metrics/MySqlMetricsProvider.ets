import {
  InnoDbSnapshot, QueryActivitySnapshot, ReplicationSnapshot, ServerMetricsCategory,
  ServerOverviewSnapshot, ServerProcessSnapshot
} from './MySqlServerMetrics';

export interface MySqlMetricsProvider {
  readOverview(): Promise<ServerMetricsCategory<ServerOverviewSnapshot>>;
  listProcesses(limit: number): Promise<ServerMetricsCategory<ServerProcessSnapshot>>;
  readInnoDb(): Promise<ServerMetricsCategory<InnoDbSnapshot>>;
  readQueryActivity(): Promise<ServerMetricsCategory<QueryActivitySnapshot>>;
  readReplication(): Promise<ServerMetricsCategory<ReplicationSnapshot>>;
}
