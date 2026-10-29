import { ArkDbError } from '@arkdb/core';
import { MySqlDbConnection } from './MySqlContracts';
import { MySqlPreparedExecutor } from './MySqlPreparedContracts';
import { MySqlBatchExecutor } from '../execution/MySqlBatchExecutor';

export class MySqlConnectionFeatures {
  batch?: MySqlBatchExecutor;
  prepared?: MySqlPreparedExecutor;
}

export function requireMySqlFeatures(connection: MySqlDbConnection): MySqlConnectionFeatures {
  const features = connection.mysqlFeatures;
  if (features === undefined) {
    throw ArkDbError.unsupported('This connection does not provide MySQL features.');
  }
  return features;
}
