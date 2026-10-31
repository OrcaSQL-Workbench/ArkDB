import { ArkDbError, QueryOptions } from '@arkdb/core';
import { MySqlPreparedExecutorHost } from '../command/PreparedExecutor';
import {
  MySqlPreparedSession, preparedCleanup, preparedFailure
} from '../command/PreparedStatement';
import {
  MySqlResultTerminatorObservation, validateQueryOptions
} from '../command/ResultStream';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import { MySqlExecutionOutcome, MySqlOperationError } from '../model/MySqlOperationError';
import { MySqlParameter, MySqlParameterType } from '../model/MySqlParameter';
import {
  MySqlProcedureArgument, MySqlParameterDirection, MySqlProcedureResult
} from '../model/MySqlProcedure';
import {
  MySqlColumnDef, MySqlQueryResult, MySqlValue, mysqlColumnDecodesAsBytes
} from '../model/MySqlQueryResult';
import {
  Capabilities, ColumnType, FieldFlag, StatusFlags
} from '../protocol/Constants';
import {
  EncodedBinaryParameters, encodeBinaryParameters
} from '../value/BinaryParameterEncoder';
import {
  mysqlPlaceholders, quoteMySqlIdentifier
} from '../value/MySqlSqlHelpers';
import { MySqlCommandKind, MySqlCommandScope } from './MySqlCommandGate';

export interface MySqlProcedureCaller {
  call(procedure: string[], procedureArguments: MySqlProcedureArgument[],
    options?: QueryOptions): Promise<MySqlProcedureResult>;
}

export class MySqlPreparedProcedureCaller implements MySqlProcedureCaller {
  private host: MySqlPreparedExecutorHost;
  private session: MySqlPreparedSession;

  constructor(host: MySqlPreparedExecutorHost) {
    this.host = host;
    this.session = new MySqlPreparedSession(host);
  }

  async call(procedure: string[], procedureArguments: MySqlProcedureArgument[],
    options?: QueryOptions): Promise<MySqlProcedureResult> {
    const input: ProcedureInput = procedureInput(
      procedure, procedureArguments, options);
    return this.host.runCommand(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<MySqlProcedureResult> =>
        this.callOwned(scope, input));
  }

  private async callOwned(scope: MySqlCommandScope,
    input: ProcedureInput): Promise<MySqlProcedureResult> {
    let statement: MySqlPreparedStatement | null = null;
    let value: MySqlProcedureResult | undefined;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      if ((this.host.capabilities & Capabilities.PS_MULTI_RESULTS) === 0) {
        throw ArkDbError.unsupported(
          'Binary procedure calls require server support for CLIENT_PS_MULTI_RESULTS.');
      }
      statement = await this.session.prepareOwned(scope, input.sql);
      if (statement.parameterCount !== input.parameters.length) {
        throw ArkDbError.protocol(
          'Prepared CALL parameter metadata does not match the generated placeholders.');
      }
      this.host.commandGate.assertDeadlineActive(scope);
      const observations: MySqlResultTerminatorObservation[] = [];
      const result: MySqlQueryResult = await this.session.executeOwned(
        scope, statement, input.encoded,
        (command: Uint8Array): Promise<MySqlQueryResult> =>
          this.host.executePrepared(scope, command, input.options, undefined, observations));
      try {
        value = procedureResult(result, observations, input.parameters);
      } catch (error) {
        throw preparedFailure(error as Object, [], MySqlExecutionOutcome.Completed);
      }
    } catch (error) {
      primary = error as Object;
    }
    if (statement !== null) {
      try {
        await this.session.closeOwned(scope, statement);
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

class ProcedureInput {
  readonly sql: string;
  readonly parameters: MySqlProcedureArgument[];
  readonly encoded: EncodedBinaryParameters;
  readonly options: QueryOptions;

  constructor(sql: string, parameters: MySqlProcedureArgument[],
    encoded: EncodedBinaryParameters, options: QueryOptions) {
    this.sql = sql;
    this.parameters = parameters;
    this.encoded = encoded;
    this.options = options;
  }
}

function procedureInput(procedure: string[], parameters: MySqlProcedureArgument[],
  options?: QueryOptions): ProcedureInput {
  try {
    const identifier: string[] = procedure.slice();
    if (identifier.length < 1 || identifier.length > 2) {
      throw ArkDbError.validation(
        'MySQL procedure identifiers require a routine or schema and routine.');
    }
    const captured: MySqlProcedureArgument[] = parameters.slice();
    const snapshots: MySqlProcedureArgument[] = [];
    const positional: MySqlParameter[] = [];
    for (let index = 0; index < captured.length; index += 1) {
      const parameter: MySqlProcedureArgument = captured[index];
      if (!(parameter instanceof MySqlProcedureArgument)) {
        throw ArkDbError.validation(
          'Procedure arguments must be MySqlProcedureArgument instances.');
      }
      const snapshot = new MySqlProcedureArgument(
        parameter.direction, parameter.parameter);
      snapshots.push(snapshot);
      positional.push(snapshot.parameter);
    }
    const queryOptions: QueryOptions =
      options === undefined ? new QueryOptions() : options.clone();
    validateQueryOptions(queryOptions);
    const placeholders: string =
      snapshots.length === 0 ? '' : mysqlPlaceholders(snapshots.length);
    const sql = 'CALL ' + quoteMySqlIdentifier(identifier) + '(' + placeholders + ')';
    return new ProcedureInput(
      sql, snapshots, encodeBinaryParameters(positional), queryOptions);
  } catch (error) {
    throw preparedFailure(error as Object, [], MySqlExecutionOutcome.NotDispatched);
  }
}

function procedureResult(root: MySqlQueryResult,
  observations: MySqlResultTerminatorObservation[],
  parameters: MySqlProcedureArgument[]): MySqlProcedureResult {
  const results: MySqlQueryResult[] = flattenResults(root);
  if (results.length !== observations.length || results.length === 0) {
    throw ArkDbError.protocol(
      'Prepared CALL result observations do not match the consumed results.');
  }

  const completionIndex: number = results.length - 1;
  const completionObservation: MySqlResultTerminatorObservation =
    observations[completionIndex];
  if (completionObservation.hasRows ||
    hasOutMarker(completionObservation)) {
    throw ArkDbError.protocol(
      'Prepared CALL response is missing its final unmarked OK status.');
  }

  const expected: ProcedureOutputExpectation[] = outputExpectations(parameters);
  let outIndex = -1;
  for (let index = 0; index < completionIndex; index += 1) {
    if (!hasOutMarker(observations[index])) continue;
    if (outIndex >= 0) {
      throw ArkDbError.protocol(
        'Prepared CALL response contains multiple SERVER_PS_OUT_PARAMS results.');
    }
    outIndex = index;
  }

  if (expected.length === 0 && outIndex >= 0) {
    throw ArkDbError.protocol(
      'Prepared CALL returned SERVER_PS_OUT_PARAMS without OUT or INOUT parameters.');
  }
  if (expected.length > 0 && outIndex < 0) {
    throw ArkDbError.protocol(
      'Prepared CALL response is missing the SERVER_PS_OUT_PARAMS result. Observed flags: ' +
      observedFlags(observations));
  }

  const outValues: MySqlValue[] = [];
  if (outIndex >= 0) {
    const observation: MySqlResultTerminatorObservation = observations[outIndex];
    if (!observation.hasRows) {
      throw ArkDbError.protocol(
        'SERVER_PS_OUT_PARAMS must identify a row result.');
    }
    const outResult: MySqlQueryResult = results[outIndex];
    if (outResult.columns.length !== expected.length) {
      throw ArkDbError.protocol(
        'Prepared CALL output column count does not match OUT and INOUT parameters.');
    }
    if (!observation.rowCountKnown || observation.rowCount !== 1) {
      throw ArkDbError.protocol(
        'Prepared CALL output result must contain exactly one known row.');
    }
    if (observation.truncated || outResult.truncated ||
      observation.loadedRowCount !== 1) {
      throw ArkDbError.protocol(
        'Prepared CALL output result is truncated and cannot produce OUT values.');
    }
    if (outResult.rows.length !== 1 ||
      outResult.rows[0].length !== expected.length) {
      throw ArkDbError.protocol(
        'Prepared CALL output result must contain exactly one complete row.');
    }
    for (let index = 0; index < expected.length; index += 1) {
      const output: ProcedureOutputExpectation = expected[index];
      const column: MySqlColumnDef = outResult.columns[index];
      validateOutputColumn(output, column);
      outValues.push(outResult.rows[0][index]);
    }
  }

  return new MySqlProcedureResult(results, outIndex, outValues);
}

class ProcedureOutputExpectation {
  readonly parameterIndex: number;
  readonly direction: MySqlParameterDirection;
  readonly type: MySqlParameterType;

  constructor(parameterIndex: number,
    direction: MySqlParameterDirection, type: MySqlParameterType) {
    this.parameterIndex = parameterIndex;
    this.direction = direction;
    this.type = type;
  }
}

function outputExpectations(
  parameters: MySqlProcedureArgument[]): ProcedureOutputExpectation[] {
  const outputs: ProcedureOutputExpectation[] = [];
  for (let index = 0; index < parameters.length; index += 1) {
    const parameter: MySqlProcedureArgument = parameters[index];
    if (parameter.direction !== MySqlParameterDirection.In) {
      outputs.push(new ProcedureOutputExpectation(
        index, parameter.direction, parameter.parameter.type));
    }
  }
  return outputs;
}

function flattenResults(root: MySqlQueryResult): MySqlQueryResult[] {
  const results: MySqlQueryResult[] = [root];
  for (const additional of root.additionalResults) results.push(additional);
  return results;
}

function hasOutMarker(observation: MySqlResultTerminatorObservation): boolean {
  return ((observation.metadataStatusFlags |
    observation.completionStatusFlags) & StatusFlags.PS_OUT_PARAMS) !== 0;
}

function observedFlags(
  observations: MySqlResultTerminatorObservation[]): string {
  const values: string[] = [];
  for (const observation of observations) {
    values.push(observation.resultIndex + ':' +
      observation.metadataStatusFlags.toString(16) + '/' +
      observation.completionStatusFlags.toString(16));
  }
  return values.join(',');
}

function validateOutputColumn(expectation: ProcedureOutputExpectation,
  column: MySqlColumnDef): void {
  if (!matchesOutputType(expectation.type, column)) {
    throw ArkDbError.protocol(
      'Prepared CALL output metadata does not match parameter ' +
      expectation.parameterIndex + ' type ' + expectation.type + '.');
  }
}

function matchesOutputType(type: MySqlParameterType,
  column: MySqlColumnDef): boolean {
  const unsigned: boolean = (column.flags & FieldFlag.UNSIGNED) !== 0;
  const binary: boolean = mysqlColumnDecodesAsBytes(
    column.type, column.charset);
  switch (type) {
    case MySqlParameterType.Boolean:
      return column.type === ColumnType.TINY;
    case MySqlParameterType.Int32:
      return column.type === ColumnType.LONG && !unsigned;
    case MySqlParameterType.Int64:
      return column.type === ColumnType.LONGLONG && !unsigned;
    case MySqlParameterType.UInt64:
      return column.type === ColumnType.LONGLONG && unsigned;
    case MySqlParameterType.Float64:
      return column.type === ColumnType.DOUBLE;
    case MySqlParameterType.Decimal:
      return column.type === ColumnType.DECIMAL ||
        column.type === ColumnType.NEWDECIMAL;
    case MySqlParameterType.Text:
      return (isStringType(column.type) || isBlobType(column.type)) && !binary;
    case MySqlParameterType.Binary:
      return binary;
    case MySqlParameterType.Date:
      return column.type === ColumnType.DATE ||
        column.type === ColumnType.NEWDATE;
    case MySqlParameterType.DateTime:
      return column.type === ColumnType.DATETIME;
    case MySqlParameterType.Timestamp:
      return column.type === ColumnType.TIMESTAMP;
    case MySqlParameterType.Time:
      return column.type === ColumnType.TIME;
    case MySqlParameterType.Json:
      return column.type === ColumnType.JSON ||
        (isStringType(column.type) && !binary);
    default:
      return false;
  }
}

function isStringType(type: number): boolean {
  return type === ColumnType.VARCHAR || type === ColumnType.VAR_STRING ||
    type === ColumnType.STRING || type === ColumnType.ENUM ||
    type === ColumnType.SET;
}

function isBlobType(type: number): boolean {
  return type === ColumnType.TINY_BLOB || type === ColumnType.MEDIUM_BLOB ||
    type === ColumnType.LONG_BLOB || type === ColumnType.BLOB;
}
