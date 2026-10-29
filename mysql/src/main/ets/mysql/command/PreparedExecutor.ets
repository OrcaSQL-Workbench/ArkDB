import { ArkDbError, QueryOptions } from '@arkdb/core';
import {
  MySqlPreparedExecutor as PreparedExecutorContract, MySqlPreparedStatement
} from '../driver/MySqlPreparedContracts';
import { MySqlParameter } from '../model/MySqlParameter';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import { MySqlQueryExecutionSummary, MySqlQueryResultSink } from '../model/MySqlQueryStream';
import { MySqlCommandKind, MySqlCommandScope } from '../execution/MySqlCommandGate';
import { MySqlStatementCache, MySqlStatementCacheBorrow } from '../execution/MySqlStatementCache';
import { MySqlExecutionOutcome, MySqlOperationError } from '../model/MySqlOperationError';
import { EncodedBinaryParameters, encodeBinaryParameters } from '../value/BinaryParameterEncoder';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost, MySqlPreparedStatementRunner,
  preparedCleanup, preparedFailure
} from './PreparedStatement';
import { validateQueryOptions } from './ResultStream';

export interface MySqlPreparedExecutorHost extends MySqlPreparedSessionHost {
  readonly preparedCacheSize: number;
  runCommand<T>(kind: MySqlCommandKind, operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience?: boolean): Promise<T>;
  executePrepared(scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions): Promise<MySqlQueryResult>;
  streamPrepared(scope: MySqlCommandScope, command: Uint8Array, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
}

export class MySqlPreparedExecutor implements PreparedExecutorContract, MySqlPreparedStatementRunner {
  private host: MySqlPreparedExecutorHost;
  private session: MySqlPreparedSession;
  private cache: MySqlStatementCache;

  constructor(host: MySqlPreparedExecutorHost) {
    this.host = host;
    this.session = new MySqlPreparedSession(host, this);
    this.cache = new MySqlStatementCache(host.preparedCacheSize, host.commandGate, this.session);
  }

  invalidate(): void {
    this.cache.invalidate();
  }

  retireCacheContext(scope: MySqlCommandScope): void {
    this.cache.retireOwned(scope);
  }

  prepare(sql: string): Promise<MySqlPreparedStatement> {
    return this.session.prepare(sql);
  }

  async execute(sql: string, parameters: MySqlParameter[], options?: QueryOptions): Promise<MySqlQueryResult> {
    const input = preparedInput(parameters, options);
    return this.convenience(MySqlCommandKind.Query, sql,
      (scope: MySqlCommandScope, statement: MySqlPreparedStatement): Promise<MySqlQueryResult> =>
        this.bufferedOwned(scope, statement, input));
  }

  async executeStream(sql: string, parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    const input = preparedInput(parameters, options);
    return this.convenience(MySqlCommandKind.QueryStream, sql,
      (scope: MySqlCommandScope, statement: MySqlPreparedStatement): Promise<MySqlQueryExecutionSummary> =>
        this.streamOwned(scope, statement, input, sink));
  }

  async executeStatement(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    const input = preparedInput(parameters, options);
    return this.host.runCommand(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<MySqlQueryResult> => this.bufferedOwned(scope, statement, input));
  }

  async streamStatement(statement: MySqlPreparedStatement, parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    const input = preparedInput(parameters, options);
    return this.host.runCommand(MySqlCommandKind.QueryStream,
      (scope: MySqlCommandScope): Promise<MySqlQueryExecutionSummary> => this.streamOwned(scope, statement, input, sink));
  }

  private bufferedOwned(scope: MySqlCommandScope, statement: MySqlPreparedStatement,
    input: PreparedInput): Promise<MySqlQueryResult> {
    return this.session.executeOwned(scope, statement, input.encoded,
      (command: Uint8Array): Promise<MySqlQueryResult> =>
        this.host.executePrepared(scope, command, input.options));
  }

  private streamOwned(scope: MySqlCommandScope, statement: MySqlPreparedStatement,
    input: PreparedInput, sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.session.executeOwned(scope, statement, input.encoded,
      (command: Uint8Array): Promise<MySqlQueryExecutionSummary> =>
        this.host.streamPrepared(scope, command, input.options, sink));
  }

  private convenience<T>(kind: MySqlCommandKind, sql: string,
    execute: (scope: MySqlCommandScope, statement: MySqlPreparedStatement) => Promise<T>): Promise<T> {
    return this.host.runCommand(kind, async (scope: MySqlCommandScope): Promise<T> => {
      let statement: MySqlPreparedStatement | null = null;
      let borrow: MySqlStatementCacheBorrow | null = null;
      let value: T | undefined;
      let primary: Object | null = null;
      const cleanup: ArkDbError[] = [];
      try {
        if (this.cache.enabled) {
          borrow = await this.cache.borrow(scope, sql);
          statement = borrow.statement;
        } else {
          statement = await this.session.prepareOwned(scope, sql);
        }
        value = await execute(scope, statement);
      } catch (error) {
        primary = error as Object;
      }
      if (statement !== null) {
        try {
          if (borrow !== null) await this.cache.release(scope, borrow, primary === null);
          else await this.session.closeOwned(scope, statement);
        } catch (error) {
          if (primary === null) {
            throw preparedFailure(error as Object, [], MySqlExecutionOutcome.Completed);
          }
          cleanup.push(preparedCleanup(error as Object));
        }
      }
      if (primary !== null && this.cache.enabled && borrow === null) {
        try {
          await this.cache.clearOwned(scope);
        } catch (error) {
          cleanup.push(preparedCleanup(error as Object));
        }
      }
      if (primary !== null) {
        throw preparedFailure(primary, cleanup, primary instanceof MySqlOperationError ?
          primary.outcome : MySqlExecutionOutcome.NotDispatched);
      }
      return value!;
    }, this.cache.enabled);
  }
}

class PreparedInput {
  readonly encoded: EncodedBinaryParameters;
  readonly options: QueryOptions;

  constructor(encoded: EncodedBinaryParameters, options: QueryOptions) {
    this.encoded = encoded;
    this.options = options;
  }
}

function preparedInput(parameters: MySqlParameter[], options?: QueryOptions): PreparedInput {
  try {
    const encoded = encodeBinaryParameters(parameters);
    const snapshot = options === undefined ? new QueryOptions() : options.clone();
    validateQueryOptions(snapshot);
    return new PreparedInput(encoded, snapshot);
  } catch (error) {
    throw preparedFailure(error as Object, [], MySqlExecutionOutcome.NotDispatched);
  }
}
