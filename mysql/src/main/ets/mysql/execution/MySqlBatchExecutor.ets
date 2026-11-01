import { ArkDbError, DatabaseSessionStatus, QueryOptions } from '@arkdb/core';
import { MySqlPreparedExecutorHost } from '../command/PreparedExecutor';
import {
  MySqlPreparedSession, preparedCleanup, preparedFailure
} from '../command/PreparedStatement';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import {
  MySqlBatchError, MySqlBatchOptions, MySqlBatchResult, validateMySqlBatchOptions
} from '../model/MySqlBatch';
import { MySqlExecutionOutcome, MySqlOperationError } from '../model/MySqlOperationError';
import { MySqlParameter } from '../model/MySqlParameter';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  EncodedBinaryParameters, encodeBinaryParameters
} from '../value/BinaryParameterEncoder';
import {
  mySqlBatchItemOptions, mySqlBatchResultBytes
} from './MySqlBatchSupport';
import { MySqlCommandKind, MySqlCommandScope } from './MySqlCommandGate';

export interface MySqlBatchExecutor {
  execute(sql: string, rows: MySqlParameter[][], options?: MySqlBatchOptions): Promise<MySqlBatchResult>;
}

export class MySqlPreparedBatchExecutor implements MySqlBatchExecutor {
  private host: MySqlPreparedExecutorHost;
  private session: MySqlPreparedSession;
  private readSessionStatus: () => DatabaseSessionStatus;

  constructor(host: MySqlPreparedExecutorHost, readSessionStatus: () => DatabaseSessionStatus) {
    this.host = host;
    this.session = new MySqlPreparedSession(host);
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
          let statement: MySqlPreparedStatement | null = null;
          let primary: Object | null = null;
          const cleanup: ArkDbError[] = [];
          try {
            statement = await this.session.prepareOwned(scope, sql);
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
                throw ArkDbError.validation('Prepared batch buffered result budget is exhausted.');
              }
              let capturedResult: MySqlQueryResult | null = null;
              let result: MySqlQueryResult;
              try {
                result = await this.executeItem(scope, statement, encodedRows[index],
                  mySqlBatchItemOptions(snapshot.queryOptions, remainingBytes),
                  (decoded: MySqlQueryResult): void => { capturedResult = decoded; });
              } catch (error) {
                if (error instanceof MySqlOperationError &&
                  error.outcome === MySqlExecutionOutcome.Completed && capturedResult !== null) {
                  completed.push(capturedResult);
                }
                throw error as Error;
              }
              completed.push(result);
              const loadedBytes = mySqlBatchResultBytes(result);
              remainingBytes = loadedBytes >= remainingBytes ? 0 : remainingBytes - loadedBytes;
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
          if (cleanup.length > 0) {
            throw preparedFailure(cleanup[0], cleanup.slice(1), MySqlExecutionOutcome.Completed);
          }
          return new MySqlBatchResult(completed);
        });
    } catch (error) {
      const failure = preparedFailure(error as Object, [], error instanceof MySqlOperationError ?
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
