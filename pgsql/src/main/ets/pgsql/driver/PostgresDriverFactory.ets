import { DbDriverFactory } from '@arkdb/core';
import { PostgresConnection } from '../PostgresConnection';
import { PostgresDriverCapabilities } from '../api/PostgresContracts';
import { PostgresConnectionOptions } from '../model/PostgresConnectionConfig';

export class PostgresDriverFactory implements
  DbDriverFactory<PostgresConnectionOptions, PostgresConnection> {
  readonly driverId: string = 'pgsql';
  readonly capabilities: PostgresDriverCapabilities =
    new PostgresDriverCapabilities();

  create(options: PostgresConnectionOptions): PostgresConnection {
    return new PostgresConnection(options.config, options.password);
  }
}
