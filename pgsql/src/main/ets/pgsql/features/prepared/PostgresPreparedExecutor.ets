import { ArkDbError, QueryExecutionSummary, QueryOptions, QueryResultSink, validateQueryOptions } from '@arkdb/core';
import { PostgresPreparedExecutor } from '../../api/PostgresPreparedContracts';
import { PostgresQueryResult } from '../../model/PostgresModels';
import { PostgresParameter } from './PostgresParameter';
import { encodePostgresPreparedFrames, POSTGRES_PARAMETER_FORMAT_TEXT, PostgresPreparedFrames, scrubPostgresPreparedFrames } from './PostgresParameterEncoder';

export type PostgresPreparedExecuteRunner = (frames: PostgresPreparedFrames, options: QueryOptions) => Promise<PostgresQueryResult>;
const preparedExecuteRunners: WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedExecuteRunner> =
  new WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedExecuteRunner>();

export class PostgresConnectionPreparedExecutor implements PostgresPreparedExecutor {
  constructor(runExecute: PostgresPreparedExecuteRunner) { preparedExecuteRunners.set(this, runExecute); }

  async execute(sql: string, parameters: PostgresParameter[], options: QueryOptions): Promise<PostgresQueryResult> {
    const run = this.delegate();
    if (!(options instanceof QueryOptions)) throw ArkDbError.validation('QueryOptions is required.');
    const opts = options.clone(); validateQueryOptions(opts);
    if (opts.statementTimeoutMs > 0) throw ArkDbError.unsupported('PostgreSQL statement deadlines are not implemented.');
    const frames = encodePostgresPreparedFrames(sql, parameters, '', '', [POSTGRES_PARAMETER_FORMAT_TEXT]);
    try { return await run(frames, opts); } finally { scrubPostgresPreparedFrames(frames); }
  }

  async queryStream(_sql: string, _parameters: PostgresParameter[], _options: QueryOptions, _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    this.delegate(); throw ArkDbError.unsupported('PostgreSQL parameterized result streaming is not implemented.');
  }

  private delegate(): PostgresPreparedExecuteRunner {
    const runner = preparedExecuteRunners.get(this);
    if (runner === undefined) throw ArkDbError.protocol('PostgreSQL prepared executor is uninitialized.');
    return runner;
  }
}
