import { QueryOptions } from '@arkdb/core';
import { MySqlConnectionFeatures } from './MySqlConnectionFeatures';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import { MySqlServerInfo } from '../model/MySqlServerInfo';
import {
  MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';

export interface MySqlSession {
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
