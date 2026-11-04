import { ArkDbError, DbConnection } from '@arkdb/core';
import { ConnectionConfig } from '../model/ConnectionConfig';

export type MySqlControlConnectionBuilder<T extends DbConnection> =
  (config: ConnectionConfig, password: string,
    createControlConnection: () => DbConnection) => T;

export function createMySqlControlConnection<T extends DbConnection>(
  config: ConnectionConfig, password: string,
  builder: MySqlControlConnectionBuilder<T>): T {
  const controlConfig = config.clone();
  controlConfig.defaultSchema = undefined;
  controlConfig.autocommit = true;
  controlConfig.session = undefined;
  controlConfig.multipleStatements = false;
  return builder(controlConfig, password, (): DbConnection => {
    throw ArkDbError.unsupported(
      'A MySQL control connection cannot create another control connection.');
  });
}
