import { ServerMetricsSnapshot } from './ServerMetrics';

export interface ServerMetricsProvider {
  readMetrics(): Promise<ServerMetricsSnapshot>;
}
