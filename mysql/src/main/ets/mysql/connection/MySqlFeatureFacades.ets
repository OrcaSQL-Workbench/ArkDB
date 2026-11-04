import { QueryOptions } from '@arkdb/core';
import {
  MySqlBatchExecutor, MySqlInsertRowsExecutor, MySqlLongDataExecutor,
  MySqlNamedExecutor, MySqlProcedureCaller
} from '../api/MySqlFeatureContracts';
import {
  MySqlCursor, MySqlCursorExecutor
} from '../api/MySqlCursorContracts';
import {
  MySqlPreparedExecutor, MySqlPreparedStatement
} from '../api/MySqlPreparedContracts';
import {
  MySqlInsertRowsInput,
  MySqlPreparedInsertRowsExecutor, snapshotMySqlInsertRowsInput
} from '../execution/MySqlInsertRowsExecutor';
import {
  mysqlOperationFailure as operationFailure
} from '../execution/MySqlFailure';
import {
  MySqlExecutionOutcome
} from '../model/MySqlOperationError';
import {
  MySqlBatchError, MySqlBatchOptions, MySqlBatchResult, validateMySqlBatchOptions
} from '../model/MySqlBatch';
import { MySqlCursorOptions } from '../features/cursor/MySqlCursorOptions';
import { MySqlInsertRowsOptions } from '../model/MySqlInsertRows';
import {
  MySqlLongDataOptions, MySqlLongParameter
} from '../features/longdata/MySqlLongDataOptions';
import { MySqlNamedParameter } from '../model/MySqlNamedParameter';
import { MySqlParameter } from '../features/prepared/MySqlParameter';
import {
  MySqlProcedureArgument, MySqlProcedureResult
} from '../model/MySqlProcedure';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';

export class MySqlConnectionPreparedExecutor implements MySqlPreparedExecutor {
  private getExecutor: () => MySqlPreparedExecutor;

  constructor(getExecutor: () => MySqlPreparedExecutor) {
    this.getExecutor = getExecutor;
  }

  async prepare(sql: string): Promise<MySqlPreparedStatement> {
    return this.getExecutor().prepare(sql);
  }

  async execute(sql: string, parameters: MySqlParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    return this.getExecutor().execute(sql, parameters, options);
  }

  async executeStream(sql: string, parameters: MySqlParameter[],
    options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.getExecutor().executeStream(sql, parameters, options, sink);
  }
}

export class MySqlConnectionLongDataExecutor implements MySqlLongDataExecutor {
  private getExecutor: () => MySqlLongDataExecutor;

  constructor(getExecutor: () => MySqlLongDataExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(statement: MySqlPreparedStatement,
    parameters: MySqlParameter[],
    sources: MySqlLongParameter[],
    options?: MySqlLongDataOptions): Promise<MySqlQueryResult> {
    return this.getExecutor().execute(statement, parameters, sources, options);
  }
}

export class MySqlConnectionCursorExecutor implements MySqlCursorExecutor {
  private getExecutor: () => MySqlCursorExecutor;

  constructor(getExecutor: () => MySqlCursorExecutor) {
    this.getExecutor = getExecutor;
  }

  async open(sql: string, parameters: MySqlParameter[],
    options?: MySqlCursorOptions): Promise<MySqlCursor> {
    return this.getExecutor().open(
      sql, parameters.slice(),
      options === undefined ? undefined : options.clone());
  }
}

export class MySqlConnectionNamedExecutor implements MySqlNamedExecutor {
  private getExecutor: () => MySqlNamedExecutor;

  constructor(getExecutor: () => MySqlNamedExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(sql: string, parameters: MySqlNamedParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    return this.getExecutor().execute(sql, parameters, options);
  }

  async executeStream(sql: string, parameters: MySqlNamedParameter[],
    options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.getExecutor().executeStream(sql, parameters, options, sink);
  }
}

export class MySqlConnectionInsertRowsExecutor implements MySqlInsertRowsExecutor {
  private getExecutor: () => MySqlPreparedInsertRowsExecutor;

  constructor(getExecutor: () => MySqlPreparedInsertRowsExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(tableParts: string[], columns: string[],
    rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions): Promise<MySqlBatchResult> {
    const input: MySqlInsertRowsInput = snapshotMySqlInsertRowsInput(
      tableParts, columns, rows, options);
    if (input.groups.length === 0) return new MySqlBatchResult();
    let executor: MySqlPreparedInsertRowsExecutor;
    try {
      executor = this.getExecutor();
    } catch (error) {
      throw new MySqlBatchError(
        operationFailure(error as Object, [],
          MySqlExecutionOutcome.NotDispatched),
        [], 0);
    }
    return executor.executeInput(input);
  }
}

export class MySqlConnectionProcedureCaller implements MySqlProcedureCaller {
  private getCaller: () => MySqlProcedureCaller;

  constructor(getCaller: () => MySqlProcedureCaller) {
    this.getCaller = getCaller;
  }

  async call(procedure: string[],
    procedureArguments: MySqlProcedureArgument[],
    options?: QueryOptions): Promise<MySqlProcedureResult> {
    return this.getCaller().call(procedure, procedureArguments, options);
  }
}

export class MySqlConnectionBatchExecutor implements MySqlBatchExecutor {
  private getExecutor: () => MySqlBatchExecutor;

  constructor(getExecutor: () => MySqlBatchExecutor) {
    this.getExecutor = getExecutor;
  }

  async execute(sql: string, rows: MySqlParameter[][],
    options?: MySqlBatchOptions): Promise<MySqlBatchResult> {
    const snapshot = options === undefined ?
      new MySqlBatchOptions() : options.clone();
    const errors = validateMySqlBatchOptions(snapshot, rows.length);
    if (errors.length > 0) {
      throw new MySqlBatchError(
        operationFailure(errors[0], [],
          MySqlExecutionOutcome.NotDispatched), [], 0);
    }
    if (rows.length === 0) {
      return new MySqlBatchResult();
    }
    let executor: MySqlBatchExecutor;
    try {
      executor = this.getExecutor();
    } catch (error) {
      throw new MySqlBatchError(
        operationFailure(error as Object, [],
          MySqlExecutionOutcome.NotDispatched), [], 0);
    }
    return executor.execute(sql, rows, snapshot);
  }
}
