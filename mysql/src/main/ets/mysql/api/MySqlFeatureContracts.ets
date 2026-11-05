import { QueryOptions } from '@arkdb/core';
import { MySqlPreparedStatement } from './MySqlPreparedContracts';
import { MySqlBatchOptions, MySqlBatchResult } from '../model/MySqlBatch';
import { MySqlDeadlineOptions } from '../model/MySqlDeadlineOptions';
import { MySqlInsertRowsOptions } from '../model/MySqlInsertRows';
import {
  MySqlLongDataOptions, MySqlLongParameter
} from '../features/longdata/MySqlLongDataOptions';
import {
  MySqlNamedParameter
} from '../features/named/MySqlNamedParameter';
import { MySqlParameter } from '../features/prepared/MySqlParameter';
import {
  MySqlProcedureArgument, MySqlProcedureResult
} from '../model/MySqlProcedure';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';

export interface MySqlBatchExecutor {
  execute(sql: string, rows: MySqlParameter[][],
    options?: MySqlBatchOptions): Promise<MySqlBatchResult>;
}

export interface MySqlDeadlineExecutor {
  query(sql: string, options?: MySqlDeadlineOptions): Promise<MySqlQueryResult>;
  execute(sql: string, parameters: MySqlParameter[],
    options?: MySqlDeadlineOptions): Promise<MySqlQueryResult>;
}

export interface MySqlInsertRowsExecutor {
  execute(tableParts: string[], columns: string[], rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions): Promise<MySqlBatchResult>;
}

export interface MySqlInsertRowsGroupSnapshot {
  readonly startIndex: number;
  readonly rows: MySqlParameter[][];
}

export interface MySqlInsertRowsSnapshot {
  readonly tableParts: string[];
  readonly columns: string[];
  readonly groups: MySqlInsertRowsGroupSnapshot[];
  readonly options: MySqlInsertRowsOptions;
}

export interface MySqlLongDataExecutor {
  execute(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    sources: MySqlLongParameter[], options?: MySqlLongDataOptions): Promise<MySqlQueryResult>;
}

export interface MySqlNamedExecutor {
  execute(sql: string, parameters: MySqlNamedParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult>;
  executeStream(sql: string, parameters: MySqlNamedParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
}

export interface MySqlProcedureCaller {
  call(procedure: string[], procedureArguments: MySqlProcedureArgument[],
    options?: QueryOptions): Promise<MySqlProcedureResult>;
}

export interface MySqlSessionController {
  reset(): Promise<void>;
}
