import {
  DbConnection, DbStreamingConnection, DbDriverFactory
} from '@arkdb/core';
import { ConnectionConfig } from '../model/ConnectionConfig';
import { MySqlConnectionOptions } from './MySqlConnectionOptions';
import { MySqlDbConnection, MySqlDbDriverFactory, MySqlDriverCapabilities } from './MySqlContracts';
import { MySqlConnection } from '../MySqlConnection';
import { MySqlExecutionController } from '../execution/MySqlExecutionController';
import { MySqlMetadataProvider } from '../metadata/MySqlMetadataProvider';
import { MySqlServerMetricsProvider } from '../metrics/MySqlServerMetricsProvider';

export class MySqlDriverFactory implements DbDriverFactory<MySqlConnectionOptions, MySqlConnection>,
  MySqlDbDriverFactory {
  readonly driverId: string = 'mysql';
  readonly capabilities: MySqlDriverCapabilities = mysqlCapabilities();

  create(options: MySqlConnectionOptions): MySqlConnection {
    return this.createConnection(options.config, options.password);
  }

  createConnection(config: ConnectionConfig, password: string): MySqlConnection {
    return new MySqlConnection(config, password);
  }

  createMetadataProvider(connection: DbConnection): MySqlMetadataProvider {
    return new MySqlMetadataProvider(connection);
  }

  createExecutionController(controlConnection: DbConnection): MySqlExecutionController {
    return new MySqlExecutionController(controlConnection);
  }

  createServerMetricsProvider(connection: MySqlDbConnection | DbStreamingConnection): MySqlServerMetricsProvider {
    return new MySqlServerMetricsProvider(connection);
  }
}

function mysqlCapabilities(): MySqlDriverCapabilities {
  const capabilities = new MySqlDriverCapabilities();
  capabilities.supportsSsl = true;
  capabilities.supportsCatalogs = true;
  capabilities.supportsSchemas = true;
  capabilities.supportsTransactions = true;
  capabilities.supportsMetadata = true;
  capabilities.supportsMultipleResults = true;
  capabilities.supportsStreamingResults = true;
  capabilities.supportsGracefulCancel = true;
  capabilities.supportsExplain = true;
  capabilities.supportsPreparedStatements = false;
  capabilities.supportsServerMetrics = true;
  return capabilities;
}
