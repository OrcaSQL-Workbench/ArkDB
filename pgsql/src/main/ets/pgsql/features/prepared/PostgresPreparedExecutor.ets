import { ArkDbError, QueryExecutionSummary, QueryOptions, QueryResultSink, validateQueryOptions } from '@arkdb/core';
import { PostgresPreparedExecutor } from '../../api/PostgresPreparedContracts';
import { PostgresQueryResult } from '../../model/PostgresModels';
import { PostgresParameter } from './PostgresParameter';
import { encodePostgresPreparedFrames, POSTGRES_PARAMETER_FORMAT_TEXT, PostgresPreparedFrames, scrubPostgresPreparedFrames } from './PostgresParameterEncoder';

export type PostgresPreparedExecuteRunner = (frames: PostgresPreparedFrames, options: QueryOptions) => Promise<PostgresQueryResult>;
export type PostgresPreparedStreamRunner = (
  frames: PostgresPreparedFrames, options: QueryOptions, sink: QueryResultSink) => Promise<QueryExecutionSummary>;
const preparedExecuteRunners: WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedExecuteRunner> =
  new WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedExecuteRunner>();
const preparedStreamRunners: WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedStreamRunner> =
  new WeakMap<PostgresConnectionPreparedExecutor, PostgresPreparedStreamRunner>();

export class PostgresConnectionPreparedExecutor implements PostgresPreparedExecutor {
  constructor(runExecute: PostgresPreparedExecuteRunner, runStream?: PostgresPreparedStreamRunner) {
    preparedExecuteRunners.set(this, runExecute);
    if (runStream !== undefined) preparedStreamRunners.set(this, runStream);
  }

  async execute(sql: string, parameters: PostgresParameter[], options: QueryOptions): Promise<PostgresQueryResult> {
    const run = this.executeDelegate();
    if (!(options instanceof QueryOptions)) throw ArkDbError.validation('QueryOptions is required.');
    const opts = options.clone(); validateQueryOptions(opts);
    if (opts.statementTimeoutMs > 0) throw ArkDbError.unsupported('PostgreSQL statement deadlines are not implemented.');
    const frames = encodePostgresPreparedFrames(sql, parameters, '', '', [POSTGRES_PARAMETER_FORMAT_TEXT]);
    try { return await run(frames, opts); } finally { scrubPostgresPreparedFrames(frames); }
  }

  async queryStream(sql: string, parameters: PostgresParameter[], options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    const runStream = this.streamDelegate();
    if (!(options instanceof QueryOptions)) throw ArkDbError.validation('QueryOptions is required.');
    const opts = options.clone(); validateQueryOptions(opts);
    if (opts.statementTimeoutMs > 0) throw ArkDbError.unsupported('PostgreSQL statement deadlines are not implemented.');
    if (sink === null || sink === undefined || typeof sink !== 'object') throw ArkDbError.validation('QueryResultSink is required.');
    const frames = encodePostgresPreparedFrames(sql, parameters, '', '', [POSTGRES_PARAMETER_FORMAT_TEXT]);
    try { return await runStream(frames, opts, sink); } finally { scrubPostgresPreparedFrames(frames); }
  }

  private executeDelegate(): PostgresPreparedExecuteRunner {
    const runner = preparedExecuteRunners.get(this);
    if (runner === undefined) throw ArkDbError.protocol('PostgreSQL prepared executor is uninitialized.');
    return runner;
  }

  private streamDelegate(): PostgresPreparedStreamRunner {
    const runner = preparedStreamRunners.get(this);
    if (runner === undefined) throw ArkDbError.protocol('PostgreSQL prepared executor is uninitialized.');
    return runner;
  }
}
