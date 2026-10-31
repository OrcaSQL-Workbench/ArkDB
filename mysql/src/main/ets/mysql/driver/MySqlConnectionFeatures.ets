import { ArkDbError } from '@arkdb/core';
import { MySqlDbConnection } from './MySqlContracts';
import { MySqlPreparedExecutor } from './MySqlPreparedContracts';
import { MySqlBatchExecutor } from '../execution/MySqlBatchExecutor';
import { MySqlDeadlineExecutor } from '../execution/MySqlDeadlineExecutor';
import { MySqlNamedExecutor } from '../execution/MySqlNamedExecutor';
import { MySqlSessionController } from '../execution/MySqlSessionController';
import { MySqlTransactionRunner } from '../execution/MySqlTransactionRunner';

export class MySqlConnectionFeatures {
  batch?: MySqlBatchExecutor;
  deadlines?: MySqlDeadlineExecutor;
  named?: MySqlNamedExecutor;
  prepared?: MySqlPreparedExecutor;
  session?: MySqlSessionController;
  transactions?: MySqlTransactionRunner;
}

export function requireMySqlFeatures(connection: MySqlDbConnection): MySqlConnectionFeatures {
  const features = connection.mysqlFeatures;
  if (features === undefined) {
    throw ArkDbError.unsupported('This connection does not provide MySQL features.');
  }
  return features;
}
