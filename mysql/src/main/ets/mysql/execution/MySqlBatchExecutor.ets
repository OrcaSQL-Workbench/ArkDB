import { ArkDbError, DatabaseSessionStatus, QueryOptions } from '@arkdb/core';
import { MySqlPreparedExecutorHost } from '../features/prepared/PreparedExecutor';
import {
  MySqlPreparedSession, preparedFailure
} from '../features/prepared/PreparedStatement';
import { MySqlBatchExecutor } from '../api/MySqlFeatureContracts';
import { MySqlPreparedStatement } from '../api/MySqlPreparedContracts';
import {
  OwnedStatementLifecycle
} from '../features/prepared/OwnedStatementLifecycle';
import {
  MySqlBatchError, MySqlBatchOptions, MySqlBatchResult, validateMySqlBatchOptions
} from '../model/MySqlBatch';
import { MySqlExecutionOutcome, MySqlOperationError } from '../model/MySqlOperationError';
import { MySqlParameter } from '../features/prepared/MySqlParameter';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  EncodedBinaryParameters, encodeBinaryParameters
} from '../features/prepared/BinaryParameterEncoder';
import {
  mySqlBatchItemOptions, mySqlBatchResultBytes
} from './MySqlBatchSupport';
import { MySqlCommandKind, MySqlCommandScope } from './MySqlCommandGate';

export class MySqlPreparedBatchExecutor implements MySqlBatchExecutor {
  private host: MySqlPreparedExecutorHost;
  private session: MySqlPreparedSession;
  private lifecycle: OwnedStatementLifecycle;
  private readSessionStatus: () => DatabaseSessionStatus;

  constructor(host: MySqlPreparedExecutorHost, readSessionStatus: () => DatabaseSessionStatus) {
    this.host = host;
    this.session = new MySqlPreparedSession(host);
    this.lifecycle = new OwnedStatementLifecycle(this.session);
    this.readSessionStatus = readSessionStatus;
  }

  async execute(sql: string, rows: MySqlParameter[][],
    options?: MySqlBatchOptions): Promise<MySqlBatchResult> {
    const batchRows = rows.slice();
    const snapshot = options === undefined ? new MySqlBatchOptions() : options.clone();
    const completed: MySqlQueryResult[] = [];
    let failedIndex = 0;
    let scopeEntered = false;
    try {
      validateBatchOptions(snapshot, batchRows.length);
      if (batchRows.length === 0) return new MySqlBatchResult();
      const encodedRows: EncodedBinaryParameters[] = [];
      for (let index = 0; index < batchRows.length; index += 1) {
        failedIndex = index;
        encodedRows.push(encodeBinaryParameters(batchRows[index]));
      }
      failedIndex = 0;
      const sessionStatus = this.readSessionStatus();
      if (sessionStatus.known !== true) {
        throw ArkDbError.protocol('Prepared batch requires known session transaction status.');
      }
      if (sessionStatus.inTransaction) {
        throw ArkDbError.protocol('Prepared batch cannot run inside an active transaction.');
      }
      return await this.host.runCommand(MySqlCommandKind.Query,
        async (scope: MySqlCommandScope): Promise<MySqlBatchResult> => {
          scopeEntered = true;
          return this.lifecycle.withOwnedStatement<MySqlBatchResult>(
            scope, sql,
            async (statement: MySqlPreparedStatement):
              Promise<MySqlBatchResult> => {
              for (let index = 0; index < encodedRows.length; index += 1) {
                failedIndex = index;
                if (encodedRows[index].types.length / 2 !== statement.parameterCount) {
                  throw ArkDbError.validation('Parameter count must match the prepared statement');
                }
              }
              let remainingBytes = snapshot.maxBufferedBytes;
              for (let index = 0; index < encodedRows.length; index += 1) {
                failedIndex = index;
                if (remainingBytes === 0) {
                  throw ArkDbError.validation(
                    'Prepared batch buffered result budget is exhausted.');
                }
                let capturedResult: MySqlQueryResult | null = null;
                let result: MySqlQueryResult;
                try {
                  result = await this.executeItem(scope, statement, encodedRows[index],
                    mySqlBatchItemOptions(snapshot.queryOptions, remainingBytes),
                    (decoded: MySqlQueryResult): void => { capturedResult = decoded; });
                } catch (error) {
                  if (error instanceof MySqlOperationError &&
                    error.outcome === MySqlExecutionOutcome.Completed &&
                    capturedResult !== null) {
                    completed.push(capturedResult);
                  }
                  throw error as Error;
                }
                completed.push(result);
                const loadedBytes = mySqlBatchResultBytes(result);
                remainingBytes = loadedBytes >= remainingBytes ?
                  0 : remainingBytes - loadedBytes;
              }
              return new MySqlBatchResult(completed);
            });
        });
    } catch (error) {
      const failure = preparedFailure(error as Object, [],
        error instanceof MySqlOperationError ?
        error.outcome : (scopeEntered ? MySqlExecutionOutcome.Unknown : MySqlExecutionOutcome.NotDispatched));
      throw new MySqlBatchError(failure, completed, failedIndex);
    }
  }

  private executeItem(scope: MySqlCommandScope, statement: MySqlPreparedStatement,
    encoded: EncodedBinaryParameters, options: QueryOptions,
    observer?: (result: MySqlQueryResult) => void): Promise<MySqlQueryResult> {
    return this.session.executeOwned(scope, statement, encoded,
      (command: Uint8Array): Promise<MySqlQueryResult> =>
        this.host.executePrepared(scope, command, options, observer));
  }
}

function validateBatchOptions(options: MySqlBatchOptions, itemCount: number): void {
  const errors = validateMySqlBatchOptions(options, itemCount);
  if (errors.length > 0) throw errors[0];
}
