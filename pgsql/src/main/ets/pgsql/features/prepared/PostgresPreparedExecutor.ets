import { ArkDbError, QueryExecutionSummary, QueryOptions, QueryResultSink, validateQueryOptions } from '@arkdb/core';
import { PostgresPreparedExecutor } from '../../api/PostgresPreparedContracts';
import { PostgresQueryResult } from '../../model/PostgresModels';
import { PostgresParameter } from './PostgresParameter';
import { encodePostgresPreparedFrames, POSTGRES_PARAMETER_FORMAT_TEXT, PostgresPreparedFrames, scrubPostgresPreparedFrames } from './PostgresParameterEncoder';

export type PostgresPreparedExecuteRunner = (frames: PostgresPreparedFrames, options: QueryOptions) => Promise<PostgresQueryResult>;
export type PostgresPreparedStreamRunner = (frames: PostgresPreparedFrames, options: QueryOptions, sink: QueryResultSink) => Promise<QueryExecutionSummary>;
const preparedExecuteRunners = new WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedExecuteRunner>();
const preparedStreamRunners = new WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedStreamRunner>();
const preparedPrechecks = new WeakMap<PostgresConnectionPreparedExecutor, () => void>();

function requireRunner<T>(map: WeakMap<PostgresConnectionPreparedExecutor, T>, owner: PostgresConnectionPreparedExecutor): T {
  const runner = map.get(owner);
  if (runner === undefined) throw ArkDbError.protocol('PostgreSQL prepared executor is uninitialized.');
  const precheck = preparedPrechecks.get(owner); if (precheck !== undefined) precheck();
  return runner;
}

export class PostgresConnectionPreparedExecutor implements PostgresPreparedExecutor {
  constructor(runExecute: PostgresPreparedExecuteRunner, runStream?: PostgresPreparedStreamRunner, precheck?: () => void) {
    preparedExecuteRunners.set(this, runExecute);
    if (runStream !== undefined) preparedStreamRunners.set(this, runStream);
    if (precheck !== undefined) preparedPrechecks.set(this, precheck);
  }

  async execute(sql: string, parameters: PostgresParameter[], options: QueryOptions): Promise<PostgresQueryResult> {
    const run = requireRunner(preparedExecuteRunners, this);
    if (!(options instanceof QueryOptions)) throw ArkDbError.validation('QueryOptions is required.');
    const opts = options.clone(); validateQueryOptions(opts);
    const frames = encodePostgresPreparedFrames(sql, parameters, '', '', [POSTGRES_PARAMETER_FORMAT_TEXT]);
    try { return await run(frames, opts); } finally { scrubPostgresPreparedFrames(frames); }
  }

  async queryStream(sql: string, parameters: PostgresParameter[], options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    const runStream = requireRunner(preparedStreamRunners, this);
    if (!(options instanceof QueryOptions)) throw ArkDbError.validation('QueryOptions is required.');
    const opts = options.clone(); validateQueryOptions(opts);
    if (sink === null || sink === undefined || typeof sink !== 'object') throw ArkDbError.validation('QueryResultSink is required.');
    const frames = encodePostgresPreparedFrames(sql, parameters, '', '', [POSTGRES_PARAMETER_FORMAT_TEXT]);
    try { return await runStream(frames, opts, sink); } finally { scrubPostgresPreparedFrames(frames); }
  }
}
