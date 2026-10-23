import { DbConnection } from '../../core/connection/DbConnection';
import { ConnectionConfig } from '../../core/model/ConnectionConfig';
import { DbDriverFactory } from '../../core/driver/DbDriverFactory';
import { DriverCapabilities } from '../../core/driver/DriverCapabilities';
import { MetadataProvider } from '../../core/metadata/MetadataProvider';
import { DbExecutionController } from '../../core/execution/DbExecutionController';
import { ServerMetricsProvider } from '../../core/metrics/ServerMetricsProvider';
import { MySqlConnection } from '../MySqlConnection';
import { MySqlExecutionController } from '../execution/MySqlExecutionController';
import { MySqlMetadataProvider } from '../metadata/MySqlMetadataProvider';
import { MySqlServerMetricsProvider } from '../metrics/MySqlServerMetricsProvider';

export class MySqlDriverFactory implements DbDriverFactory {
  readonly driverId: string = 'mysql';
  readonly capabilities: DriverCapabilities = mysqlCapabilities();

  createConnection(config: ConnectionConfig, password: string): DbConnection {
    return new MySqlConnection(config, password);
  }

  createMetadataProvider(connection: DbConnection): MetadataProvider {
    return new MySqlMetadataProvider(connection);
  }

  createExecutionController(controlConnection: DbConnection): DbExecutionController {
    return new MySqlExecutionController(controlConnection);
  }

  createServerMetricsProvider(connection: DbConnection): ServerMetricsProvider {
    return new MySqlServerMetricsProvider(connection);
  }
}

function mysqlCapabilities(): DriverCapabilities {
  const capabilities = new DriverCapabilities();
  capabilities.supportsSsl = true;
  capabilities.supportsCatalogs = true;
  capabilities.supportsSchemas = true;
  capabilities.supportsTransactions = true;
  capabilities.supportsMultipleResults = true;
  capabilities.supportsStreamingResults = true;
  capabilities.supportsGracefulCancel = true;
  capabilities.supportsExplain = true;
  capabilities.supportsPreparedStatements = false;
  capabilities.supportsServerMetrics = true;
  return capabilities;
}
