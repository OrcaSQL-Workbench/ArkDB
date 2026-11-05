import { QueryOptions } from '@arkdb/core';
import {
  MySqlPreparedExecutor
} from './MySqlPreparedContracts';
import { MySqlCursorExecutor } from './MySqlCursorContracts';
import {
  MySqlBatchExecutor, MySqlDeadlineExecutor, MySqlInsertRowsExecutor,
  MySqlLongDataExecutor, MySqlNamedExecutor, MySqlProcedureCaller,
  MySqlSessionController
} from './MySqlFeatureContracts';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import { MySqlServerInfo } from '../model/MySqlServerInfo';
import {
  MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';
import {
  MySqlTransactionOptions
} from '../features/transaction/MySqlTransactionOptions';

export interface MySqlFeatureConnection {
  readonly mysqlFeatures?: MySqlConnectionFeatures;
}

export interface MySqlSession extends MySqlFeatureConnection {
  readonly mysqlFeatures: MySqlConnectionFeatures;
  readonly serverInfo: MySqlServerInfo;
  readonly sessionStatus: MySqlDatabaseSessionStatus;
  query(sql: string): Promise<MySqlQueryResult>;
  queryStream(sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
  savepoint(name: string): Promise<void>;
  rollbackTo(name: string): Promise<void>;
  releaseSavepoint(name: string): Promise<void>;
}

export interface MySqlTransactionRunner {
  run<T>(options: MySqlTransactionOptions,
    body: (session: MySqlSession) => Promise<T>): Promise<T>;
}

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
