import { ArkDbError } from '@arkdb/core';
import { MySqlPreparedExecutorHost } from '../command/PreparedExecutor';
import {
  MySqlPreparedSession, preparedCleanup, preparedFailure
} from '../command/PreparedStatement';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import { MySqlParameter } from '../model/MySqlParameter';
import {
  MySqlInsertRowsOptions, validateMySqlInsertRowsOptions
} from '../model/MySqlInsertRows';
import {
  MySqlBatchError, MySqlBatchResult
} from '../model/MySqlBatch';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../model/MySqlOperationError';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import { utf8Encode } from '../protocol/Charsets';
import {
  EncodedBinaryParameters, encodeBinaryParameters
} from '../value/BinaryParameterEncoder';
import {
  mysqlPlaceholders, quoteMySqlIdentifier
} from '../value/MySqlSqlHelpers';
import {
  mySqlBatchItemOptions, mySqlBatchResultBytes
} from './MySqlBatchSupport';
import { MySqlCommandKind, MySqlCommandScope } from './MySqlCommandGate';

export interface MySqlInsertRowsExecutor {
  execute(tableParts: string[], columns: string[], rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions): Promise<MySqlBatchResult>;
}

export class MySqlInsertRowsInput {
  readonly tableParts: string[];
  readonly columns: string[];
  readonly groups: MySqlInsertRowsGroup[];
  readonly options: MySqlInsertRowsOptions;

  constructor(tableParts: string[], columns: string[],
    groups: MySqlInsertRowsGroup[],
    options: MySqlInsertRowsOptions) {
    this.tableParts = tableParts;
    this.columns = columns;
    this.groups = groups;
    this.options = options;
  }
}

export class MySqlInsertRowsGroup {
  readonly startIndex: number;
  readonly rows: MySqlParameter[][];

  constructor(startIndex: number, rows: MySqlParameter[][]) {
    this.startIndex = startIndex;
    this.rows = rows;
  }
}

export class MySqlPreparedInsertRowsExecutor implements MySqlInsertRowsExecutor {
  private host: MySqlPreparedExecutorHost;
  private session: MySqlPreparedSession;
  private executionBarrier: ((
    scope: MySqlCommandScope) => Promise<void>) | null;

  constructor(host: MySqlPreparedExecutorHost,
    executionBarrier?: (
      scope: MySqlCommandScope) => Promise<void>) {
    this.host = host;
    this.session = new MySqlPreparedSession(host);
    this.executionBarrier =
      executionBarrier === undefined ? null : executionBarrier;
  }

  async execute(tableParts: string[], columns: string[], rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions): Promise<MySqlBatchResult> {
    return this.executeInput(snapshotMySqlInsertRowsInput(
      tableParts, columns, rows, options));
  }

  async executeInput(input: MySqlInsertRowsInput): Promise<MySqlBatchResult> {
    if (input.groups.length === 0) return new MySqlBatchResult();
    const progress = new InsertRowsProgress();
    let scopeEntered = false;
    try {
      return await this.host.runCommand(MySqlCommandKind.Query,
        (scope: MySqlCommandScope): Promise<MySqlBatchResult> => {
          scopeEntered = true;
          return this.executeOwnedCore(scope, input, progress);
        });
    } catch (error) {
      throw insertRowsError(error as Object, progress,
        scopeEntered ? MySqlExecutionOutcome.Unknown :
          MySqlExecutionOutcome.NotDispatched);
    }
  }

  async executeInputOwned(scope: MySqlCommandScope,
    input: MySqlInsertRowsInput): Promise<MySqlBatchResult> {
    if (input.groups.length === 0) return new MySqlBatchResult();
    const progress = new InsertRowsProgress();
    try {
      return await this.executeOwnedCore(scope, input, progress);
    } catch (error) {
      throw insertRowsError(
        error as Object, progress, MySqlExecutionOutcome.NotDispatched);
    }
  }

  private async executeOwnedCore(scope: MySqlCommandScope,
    input: MySqlInsertRowsInput,
    progress: InsertRowsProgress): Promise<MySqlBatchResult> {
    let remainingBytes: number = input.options.maxBufferedBytes;
    for (const group of input.groups) {
      progress.failedIndex = group.startIndex;
      if (remainingBytes === 0) {
        throw ArkDbError.validation(
          'Restricted INSERT buffered result budget is exhausted.');
      }
      let statement: MySqlPreparedStatement | null = null;
      let primary: Object | null = null;
      const cleanup: ArkDbError[] = [];
      try {
        const sql = insertSql(
          input.tableParts, input.columns, group.rows.length);
        statement = await this.session.prepareOwned(scope, sql);
        const parameters: MySqlParameter[] =
          flattenParameters(group.rows);
        const encoded: EncodedBinaryParameters =
          encodeBinaryParameters(parameters, statement.parameterCount);
        this.host.commandGate.assertDeadlineActive(scope);
        let capturedResult: MySqlQueryResult | null = null;
        let result: MySqlQueryResult | null = null;
        let executionFailure: Object | null = null;
        try {
          result = await this.session.executeOwned(
            scope, statement, encoded,
            (command: Uint8Array): Promise<MySqlQueryResult> =>
              this.host.executePrepared(
                scope, command,
                mySqlBatchItemOptions(
                  input.options.queryOptions, remainingBytes),
                (decoded: MySqlQueryResult): void => {
                  capturedResult = decoded;
                }));
        } catch (error) {
          executionFailure = error as Object;
        }

        const decodedResult: MySqlQueryResult | null =
          capturedResult === null ? result : capturedResult;
        if (decodedResult !== null) {
          progress.completed.push(decodedResult);
          const loadedBytes = mySqlBatchResultBytes(decodedResult);
          remainingBytes = loadedBytes >= remainingBytes ?
            0 : remainingBytes - loadedBytes;
        }

        let barrierFailure: Object | null = null;
        if (this.executionBarrier !== null) {
          try {
            await this.executionBarrier(scope);
          } catch (error) {
            barrierFailure = error as Object;
          }
        }
        if (executionFailure !== null) {
          if (barrierFailure !== null) {
            throw combinedExecutionFailure(
              executionFailure, barrierFailure);
          }
          throw executionFailure as Error;
        }
        if (barrierFailure !== null) {
          throw barrierFailure as Error;
        }
      } catch (error) {
        primary = error as Object;
      }
      if (statement !== null) {
        try {
          await this.session.closeOwned(scope, statement);
        } catch (error) {
          if (primary === null) {
            throw preparedFailure(
              error as Object, [], MySqlExecutionOutcome.Completed);
          }
          cleanup.push(preparedCleanup(error as Object));
        }
      }
      if (primary !== null) {
        throw preparedFailure(
          primary, cleanup,
          primary instanceof MySqlOperationError ?
            primary.outcome : MySqlExecutionOutcome.NotDispatched);
      }
      if (cleanup.length > 0) {
        throw preparedFailure(
          cleanup[0], cleanup.slice(1),
          MySqlExecutionOutcome.Completed);
      }
    }
    return new MySqlBatchResult(progress.completed);
  }
}

export function snapshotMySqlInsertRowsInput(tableParts: string[],
  columns: string[], rows: MySqlParameter[][],
  options?: MySqlInsertRowsOptions): MySqlInsertRowsInput {
  let failedIndex: number = 0;
  try {
    if (options !== undefined && !(options instanceof MySqlInsertRowsOptions)) {
      throw ArkDbError.unsupported(
        'Restricted INSERT options do not accept raw SQL or upsert fragments.');
    }
    if (!Array.isArray(tableParts) ||
      !Array.isArray(columns) ||
      !Array.isArray(rows)) {
      throw ArkDbError.validation(
        'Restricted INSERT identifiers and rows must be arrays.');
    }
    const snapshot = options === undefined ?
      new MySqlInsertRowsOptions() : options.clone();
    const capturedRows: MySqlParameter[][] = rows.slice();
    const optionErrors = validateMySqlInsertRowsOptions(
      snapshot, capturedRows.length);
    if (optionErrors.length > 0) throw optionErrors[0];

    const table = tableParts.slice();
    if (table.length < 1 || table.length > 2) {
      throw ArkDbError.validation(
        'MySQL INSERT table identifiers require a table or schema and table.');
    }
    requireIdentifierStrings(table);
    quoteMySqlIdentifier(table);

    const capturedColumns = columns.slice();
    if (capturedColumns.length < 1 || capturedColumns.length > 65535) {
      throw ArkDbError.validation(
        'MySQL INSERT columns must contain between 1 and 65535 identifiers.');
    }
    requireIdentifierStrings(capturedColumns);
    for (const column of capturedColumns) quoteMySqlIdentifier([column]);

    const rowSnapshots: MySqlParameter[][] = [];
    const rowValueBytes: number[] = [];
    for (let index = 0; index < capturedRows.length; index += 1) {
      failedIndex = index;
      const row = capturedRows[index];
      if (!Array.isArray(row) ||
        row.length !== capturedColumns.length) {
        throw ArkDbError.validation(
          'Each MySQL INSERT row must match the column count.');
      }
      const rowSnapshot: MySqlParameter[] = [];
      for (const parameter of row) {
        if (!(parameter instanceof MySqlParameter)) {
          throw ArkDbError.validation(
            'MySQL INSERT rows must contain MySqlParameter instances.');
        }
        rowSnapshot.push(
          new MySqlParameter(parameter.type, parameter.value));
      }
      const encoded = encodeBinaryParameters(rowSnapshot);
      rowSnapshots.push(rowSnapshot);
      rowValueBytes.push(encoded.values.length);
    }

    const plan = planInsertRowsGroups(
      table, capturedColumns, rowSnapshots, rowValueBytes, snapshot);
    if (plan.error !== null) {
      failedIndex = plan.failedIndex;
      throw plan.error;
    }
    return new MySqlInsertRowsInput(
      table, capturedColumns, plan.groups, snapshot);
  } catch (error) {
    throw new MySqlBatchError(
      preparedFailure(error as Object, [], MySqlExecutionOutcome.NotDispatched),
      [], failedIndex);
  }
}

function requireIdentifierStrings(parts: string[]): void {
  for (const part of parts) {
    if (typeof part !== 'string') {
      throw ArkDbError.validation('MySQL INSERT identifiers must be strings.');
    }
  }
}

class InsertRowsProgress {
  readonly completed: MySqlQueryResult[] = [];
  failedIndex: number = 0;
}

class InsertRowsPlan {
  readonly groups: MySqlInsertRowsGroup[];
  readonly error: ArkDbError | null;
  readonly failedIndex: number;

  constructor(groups: MySqlInsertRowsGroup[],
    error: ArkDbError | null = null, failedIndex: number = 0) {
    this.groups = groups;
    this.error = error;
    this.failedIndex = failedIndex;
  }
}

function insertRowsError(error: Object, progress: InsertRowsProgress,
  fallback: MySqlExecutionOutcome): MySqlBatchError {
  const failure = preparedFailure(
    error, [], error instanceof MySqlOperationError ?
      error.outcome : fallback);
  return new MySqlBatchError(
    failure, progress.completed, progress.failedIndex);
}

function combinedExecutionFailure(primary: Object,
  barrier: Object): MySqlOperationError {
  const primaryOutcome = primary instanceof MySqlOperationError ?
    primary.outcome : MySqlExecutionOutcome.Unknown;
  const barrierOutcome = barrier instanceof MySqlOperationError ?
    barrier.outcome : MySqlExecutionOutcome.Unknown;
  const outcome = primaryOutcome === MySqlExecutionOutcome.Unknown ||
    barrierOutcome === MySqlExecutionOutcome.Unknown ?
    MySqlExecutionOutcome.Unknown : primaryOutcome;
  return preparedFailure(
    primary, [preparedCleanup(barrier)], outcome);
}

function insertSql(tableParts: string[], columns: string[],
  rowCount: number): string {
  const prefix = insertSqlPrefix(tableParts, columns);
  const tuple = insertTuple(columns.length);
  const tuples: string[] = [];
  for (let index = 0; index < rowCount; index += 1) {
    tuples.push(tuple);
  }
  return prefix + tuples.join(',');
}

function flattenParameters(rows: MySqlParameter[][]): MySqlParameter[] {
  const parameters: MySqlParameter[] = [];
  for (const row of rows) {
    for (const parameter of row) parameters.push(parameter);
  }
  return parameters;
}

function planInsertRowsGroups(tableParts: string[], columns: string[],
  rows: MySqlParameter[][], rowValueBytes: number[],
  options: MySqlInsertRowsOptions): InsertRowsPlan {
  const groups: MySqlInsertRowsGroup[] = [];
  if (rows.length === 0) return new InsertRowsPlan(groups);
  const prefixBytes = utf8Encode(
    insertSqlPrefix(tableParts, columns)).length;
  const tupleBytes = utf8Encode(insertTuple(columns.length)).length;
  let startIndex: number = 0;
  while (startIndex < rows.length) {
    let groupRows: number = 0;
    let valueBytes: number = 0;
    while (startIndex + groupRows < rows.length) {
      const candidateRows = groupRows + 1;
      const parameterCount = candidateRows * columns.length;
      const candidateValueBytes =
        valueBytes + rowValueBytes[startIndex + groupRows];
      const prepareBytes = 1 + prefixBytes +
        candidateRows * tupleBytes + candidateRows - 1;
      const executeBytes = 10 + Math.ceil(parameterCount / 8) + 1 +
        parameterCount * 2 + candidateValueBytes;
      if (parameterCount > 65535 ||
        prepareBytes > options.maxPacketBytes ||
        executeBytes > options.maxPacketBytes) {
        break;
      }
      groupRows = candidateRows;
      valueBytes = candidateValueBytes;
    }
    if (groupRows === 0) {
      return new InsertRowsPlan(
        groups,
        ArkDbError.validation(
          'A MySQL INSERT row exceeds maxPacketBytes or the parameter limit.'),
        startIndex);
    }
    groups.push(new MySqlInsertRowsGroup(
      startIndex, rows.slice(startIndex, startIndex + groupRows)));
    startIndex += groupRows;
  }
  return new InsertRowsPlan(groups);
}

function insertSqlPrefix(tableParts: string[], columns: string[]): string {
  const quotedColumns: string[] = [];
  for (const column of columns) {
    quotedColumns.push(quoteMySqlIdentifier([column]));
  }
  return 'INSERT INTO ' + quoteMySqlIdentifier(tableParts) +
    ' (' + quotedColumns.join(',') + ') VALUES ';
}

function insertTuple(columnCount: number): string {
  return '(' + mysqlPlaceholders(columnCount) + ')';
}
