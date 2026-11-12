import { QueryExecutionSummary, QueryOptions, QueryResultSink } from '@arkdb/core';
import { PostgresParameter } from '../features/prepared/PostgresParameter';
import { PostgresQueryResult } from '../model/PostgresModels';

export interface PostgresPreparedExecutor {
  execute(sql: string, parameters: PostgresParameter[],
    options: QueryOptions): Promise<PostgresQueryResult>;
  queryStream(sql: string, parameters: PostgresParameter[],
    options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary>;
}
