import { ArkDbError, QueryOptions } from '@arkdb/core';
import { validateQueryOptions } from '../command/ResultStream';

const MAX_CURSOR_FETCH_ROWS = 10000;
const MAX_CURSOR_BUFFERED_BYTES = 32 * 1024 * 1024;

export class MySqlCursorOptions extends QueryOptions {
  fetchRows: number = 200;
  maxBufferedBytes: number = 32 * 1024 * 1024;

  validate(): ArkDbError[] {
    return validateMySqlCursorOptions(this);
  }

  clone(): MySqlCursorOptions {
    const copy = new MySqlCursorOptions();
    copy.fetchRows = this.fetchRows;
    copy.maxBufferedBytes = this.maxBufferedBytes;
    copy.statementTimeoutMs = this.statementTimeoutMs;
    copy.maxRows = this.maxRows;
    copy.maxChunkRows = this.maxChunkRows;
    copy.maxChunkBytes = this.maxChunkBytes;
    copy.maxResultBytes = this.maxResultBytes;
    copy.maxResultSets = this.maxResultSets;
    copy.maxDrainBytes = this.maxDrainBytes;
    copy.maxDrainTimeMs = this.maxDrainTimeMs;
    return copy;
  }
}

export function validateMySqlCursorOptions(options: MySqlCursorOptions): ArkDbError[] {
  const errors: ArkDbError[] = [];
  if (!Number.isSafeInteger(options.fetchRows) ||
    options.fetchRows < 1 || options.fetchRows > MAX_CURSOR_FETCH_ROWS) {
    errors.push(ArkDbError.validation(
      'fetchRows must be between 1 and 10000.'));
  }
  if (!Number.isSafeInteger(options.maxBufferedBytes) ||
    options.maxBufferedBytes < 1 ||
    options.maxBufferedBytes > MAX_CURSOR_BUFFERED_BYTES) {
    errors.push(ArkDbError.validation(
      'maxBufferedBytes must be between 1 and 33554432.'));
  }
  try {
    validateQueryOptions(options);
  } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    errors.push(error);
  }
  return errors;
}
