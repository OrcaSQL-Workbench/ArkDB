import { ArkDbError } from '@arkdb/core';
import { MySqlDbConnection } from './MySqlContracts';
import { MySqlPreparedExecutor } from './MySqlPreparedContracts';
import { MySqlCursorExecutor } from './MySqlCursorContracts';
import { MySqlBatchExecutor } from '../execution/MySqlBatchExecutor';
import { MySqlDeadlineExecutor } from '../execution/MySqlDeadlineExecutor';
import { MySqlInsertRowsExecutor } from '../execution/MySqlInsertRowsExecutor';
import { MySqlNamedExecutor } from '../execution/MySqlNamedExecutor';
import { MySqlProcedureCaller } from '../execution/MySqlProcedureCaller';
import { MySqlSessionController } from '../execution/MySqlSessionController';
import { MySqlTransactionRunner } from '../execution/MySqlTransactionRunner';
import { MySqlLongDataExecutor } from '../command/LongData';

export class MySqlConnectionFeatures {
  batch?: MySqlBatchExecutor;
  cursors?: MySqlCursorExecutor;
  deadlines?: MySqlDeadlineExecutor;
  insertRows?: MySqlInsertRowsExecutor;
  longData?: MySqlLongDataExecutor;
  named?: MySqlNamedExecutor;
  prepared?: MySqlPreparedExecutor;
  procedures?: MySqlProcedureCaller;
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
