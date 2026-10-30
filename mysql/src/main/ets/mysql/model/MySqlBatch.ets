import { ArkDbError, QueryOptions } from '@arkdb/core';
import { validateQueryOptions } from '../command/ResultStream';
import { MySqlExecutionOutcome, MySqlOperationError } from './MySqlOperationError';
import { MySqlQueryResult } from './MySqlQueryResult';

const MAX_BATCH_ITEMS = 1000;
const MAX_BATCH_BUFFERED_BYTES = 32 * 1024 * 1024;

export class MySqlBatchResult {
  readonly results: MySqlQueryResult[];

  constructor(results: MySqlQueryResult[] = []) {
    this.results = results.slice();
  }
}

export class MySqlBatchOptions {
  maxItems: number = 1000;
  maxBufferedBytes: number = 33554432;
  queryOptions: QueryOptions = new QueryOptions();

  validate(): ArkDbError[] {
    return validateMySqlBatchOptions(this);
  }

  clone(): MySqlBatchOptions {
    const copy = new MySqlBatchOptions();
    copy.maxItems = this.maxItems;
    copy.maxBufferedBytes = this.maxBufferedBytes;
    copy.queryOptions = this.queryOptions.clone();
    return copy;
  }
}

export function validateMySqlBatchOptions(options: MySqlBatchOptions,
  itemCount?: number): ArkDbError[] {
  const errors: ArkDbError[] = [];
  if (!Number.isInteger(options.maxItems) || options.maxItems < 1 ||
    options.maxItems > MAX_BATCH_ITEMS) {
    errors.push(ArkDbError.validation('maxItems must be between 1 and 1000.'));
  } else if (itemCount !== undefined && itemCount > options.maxItems) {
    errors.push(ArkDbError.validation('Prepared batch item count exceeds maxItems.'));
  }
  if (!Number.isInteger(options.maxBufferedBytes) || options.maxBufferedBytes < 1 ||
    options.maxBufferedBytes > MAX_BATCH_BUFFERED_BYTES) {
    errors.push(ArkDbError.validation('maxBufferedBytes must be between 1 and 33554432.'));
  }
  try {
    validateQueryOptions(options.queryOptions);
  } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    errors.push(error);
  }
  return errors;
}

export class MySqlBatchError extends MySqlOperationError {
  readonly completedResults: MySqlQueryResult[];
  readonly failedIndex: number;
  readonly failedOutcome: MySqlExecutionOutcome;

  constructor(failure: MySqlOperationError, completedResults: MySqlQueryResult[], failedIndex: number) {
    super(failure.primary, failure.cleanupErrors, failure.outcome, failure.originalCause);
    this.name = 'MySqlBatchError';
    this.completedResults = completedResults.slice();
    this.failedIndex = failedIndex;
    this.failedOutcome = failure.outcome;
  }
}
