import { DbConnection } from '../connection/DbConnection';
import { ConnectionConfig } from '../model/ConnectionConfig';
import { MetadataProvider } from '../metadata/MetadataProvider';
import { DriverCapabilities } from './DriverCapabilities';
import { DbExecutionController } from '../execution/DbExecutionController';
import { ServerMetricsProvider } from '../metrics/ServerMetricsProvider';

export interface DbDriverFactory {
  readonly driverId: string;
  readonly capabilities: DriverCapabilities;
  createConnection(config: ConnectionConfig, password: string): DbConnection;
  createMetadataProvider(connection: DbConnection): MetadataProvider;
  createExecutionController(controlConnection: DbConnection): DbExecutionController;
  createServerMetricsProvider(connection: DbConnection): ServerMetricsProvider;
}
