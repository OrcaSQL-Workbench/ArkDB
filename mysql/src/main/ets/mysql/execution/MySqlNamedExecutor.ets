import { ArkDbError, QueryOptions } from '@arkdb/core';
import { MySqlPreparedExecutorHost } from '../command/PreparedExecutor';
import {
  MySqlPreparedSession, preparedCleanup, preparedFailure
} from '../command/PreparedStatement';
import { validateQueryOptions } from '../command/ResultStream';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import { MySqlNamedParameter } from '../model/MySqlNamedParameter';
import { MySqlExecutionOutcome, MySqlOperationError } from '../model/MySqlOperationError';
import { MySqlParameter } from '../model/MySqlParameter';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';
import {
  EncodedBinaryParameters, encodeBinaryParameters
} from '../value/BinaryParameterEncoder';
import {
  CompiledSqlTemplate, SqlTemplateScanner
} from '../value/SqlTemplateScanner';
import { MySqlCommandKind, MySqlCommandScope } from './MySqlCommandGate';

export interface MySqlNamedExecutor {
  execute(sql: string, parameters: MySqlNamedParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult>;
  executeStream(sql: string, parameters: MySqlNamedParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
}

export interface MySqlNamedExecutorHost extends MySqlPreparedExecutorHost {
  readSessionSqlMode(scope: MySqlCommandScope): Promise<string>;
}

export class MySqlPreparedNamedExecutor implements MySqlNamedExecutor {
  private host: MySqlNamedExecutorHost;
  private session: MySqlPreparedSession;
  private scanner: SqlTemplateScanner = new SqlTemplateScanner();

  constructor(host: MySqlNamedExecutorHost) {
    this.host = host;
    this.session = new MySqlPreparedSession(host);
  }

  execute(sql: string, parameters: MySqlNamedParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    const input: NamedInput = namedInput(parameters, options);
    return this.host.runCommand(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<MySqlQueryResult> =>
        this.executeOwned(scope, sql, input));
  }

  executeStream(sql: string, parameters: MySqlNamedParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    const input: NamedInput = namedInput(parameters, options);
    return this.host.runCommand(MySqlCommandKind.QueryStream,
      (scope: MySqlCommandScope): Promise<MySqlQueryExecutionSummary> =>
        this.streamOwned(scope, sql, input, sink));
  }

  private async executeOwned(scope: MySqlCommandScope, sql: string,
    input: NamedInput): Promise<MySqlQueryResult> {
    return this.withStatement<MySqlQueryResult>(scope, sql, input,
      (statement: MySqlNamedStatement): Promise<MySqlQueryResult> =>
        this.session.executeOwned(scope, statement.statement, statement.encoded,
          (command: Uint8Array): Promise<MySqlQueryResult> =>
            this.host.executePrepared(scope, command, input.options)));
  }

  private async streamOwned(scope: MySqlCommandScope, sql: string,
    input: NamedInput, sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.withStatement<MySqlQueryExecutionSummary>(scope, sql, input,
      (statement: MySqlNamedStatement): Promise<MySqlQueryExecutionSummary> =>
        this.session.executeOwned(scope, statement.statement, statement.encoded,
          (command: Uint8Array): Promise<MySqlQueryExecutionSummary> =>
            this.host.streamPrepared(scope, command, input.options, sink)));
  }

  private async withStatement<T>(scope: MySqlCommandScope, sql: string, input: NamedInput,
    execute: (statement: MySqlNamedStatement) => Promise<T>): Promise<T> {
    let owned: MySqlNamedStatement | null = null;
    let value: T | undefined;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      const sqlMode: string = await this.host.readSessionSqlMode(scope);
      this.host.commandGate.assertDeadlineActive(scope);
      const compiled: CompiledSqlTemplate = this.scanner.compile(sql, sqlMode);
      const encoded: EncodedBinaryParameters = bindNamedParameters(compiled, input.parameters);
      const statement = await this.session.prepareOwned(scope, compiled.sql);
      owned = new MySqlNamedStatement(statement, encoded);
      this.host.commandGate.assertDeadlineActive(scope);
      value = await execute(owned);
    } catch (error) {
      primary = error as Object;
    }
    if (owned !== null) {
      try {
        await this.session.closeOwned(scope, owned.statement);
      } catch (error) {
        if (primary === null) {
          throw preparedFailure(error as Object, [], MySqlExecutionOutcome.Completed);
        }
        cleanup.push(preparedCleanup(error as Object));
      }
    }
    if (primary !== null) {
      throw preparedFailure(primary, cleanup, primary instanceof MySqlOperationError ?
        primary.outcome : MySqlExecutionOutcome.NotDispatched);
    }
    return value!;
  }
}

class NamedInput {
  readonly parameters: MySqlNamedParameter[];
  readonly options: QueryOptions;

  constructor(parameters: MySqlNamedParameter[], options: QueryOptions) {
    this.parameters = parameters;
    this.options = options;
  }
}

class MySqlNamedStatement {
  readonly statement: MySqlPreparedStatement;
  readonly encoded: EncodedBinaryParameters;

  constructor(statement: MySqlPreparedStatement, encoded: EncodedBinaryParameters) {
    this.statement = statement;
    this.encoded = encoded;
  }
}

function namedInput(parameters: MySqlNamedParameter[], options?: QueryOptions): NamedInput {
  try {
    const captured: MySqlNamedParameter[] = parameters.slice();
    const snapshots: MySqlNamedParameter[] = [];
    const names: Set<string> = new Set<string>();
    for (let index = 0; index < captured.length; index += 1) {
      const parameter: MySqlNamedParameter = captured[index];
      if (!(parameter instanceof MySqlNamedParameter)) {
        throw ArkDbError.validation(
          'Named parameters must be MySqlNamedParameter instances.');
      }
      const snapshot = new MySqlNamedParameter(parameter.name, parameter.parameter);
      if (names.has(snapshot.name)) {
        throw ArkDbError.validation('Duplicate named parameter: ' + snapshot.name);
      }
      names.add(snapshot.name);
      snapshots.push(snapshot);
    }
    const queryOptions: QueryOptions = options === undefined ? new QueryOptions() : options.clone();
    validateQueryOptions(queryOptions);
    return new NamedInput(snapshots, queryOptions);
  } catch (error) {
    throw preparedFailure(error as Object, [], MySqlExecutionOutcome.NotDispatched);
  }
}

function bindNamedParameters(compiled: CompiledSqlTemplate,
  parameters: MySqlNamedParameter[]): EncodedBinaryParameters {
  const byName: Map<string, MySqlParameter> = new Map<string, MySqlParameter>();
  for (const parameter of parameters) byName.set(parameter.name, parameter.parameter);
  const used: Set<string> = new Set<string>();
  const positional: MySqlParameter[] = [];
  for (const name of compiled.parameterNames) {
    const parameter: MySqlParameter | undefined = byName.get(name);
    if (parameter === undefined) {
      throw ArkDbError.validation('Missing named parameter: ' + name);
    }
    positional.push(parameter);
    used.add(name);
  }
  for (const parameter of parameters) {
    if (!used.has(parameter.name)) {
      throw ArkDbError.validation('Unused named parameter: ' + parameter.name);
    }
  }
  return encodeBinaryParameters(positional);
}
