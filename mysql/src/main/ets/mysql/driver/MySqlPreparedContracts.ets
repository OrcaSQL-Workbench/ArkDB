import { QueryOptions } from '@arkdb/core';
import { MySqlParameter } from '../model/MySqlParameter';
import { MySqlColumnDef, MySqlQueryResult } from '../model/MySqlQueryResult';
import { MySqlQueryExecutionSummary, MySqlQueryResultSink } from '../model/MySqlQueryStream';

export interface MySqlPreparedExecutor {
  prepare(sql: string): Promise<MySqlPreparedStatement>;
  execute(sql: string, parameters: MySqlParameter[], options?: QueryOptions): Promise<MySqlQueryResult>;
  executeStream(sql: string, parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
}

export interface MySqlPreparedStatement {
  readonly closed: boolean;
  readonly parameterCount: number;
  readonly columns: MySqlColumnDef[];
  execute(parameters: MySqlParameter[], options?: QueryOptions): Promise<MySqlQueryResult>;
  executeStream(parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
  close(): Promise<void>;
}
