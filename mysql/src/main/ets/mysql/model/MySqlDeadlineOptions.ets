import { ArkDbError, QueryOptions } from '@arkdb/core';
import { validateQueryOptions } from '../command/ResultStream';

export class MySqlDeadlineOptions {
  timeoutMs: number = 0;
  cancellationGraceMs: number = 2000;
  queryOptions: QueryOptions = new QueryOptions();

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    if (!Number.isSafeInteger(this.timeoutMs) || this.timeoutMs < 0) {
      errors.push(ArkDbError.validation('timeoutMs must be a non-negative safe integer.'));
    }
    if (!Number.isSafeInteger(this.cancellationGraceMs) || this.cancellationGraceMs < 0) {
      errors.push(ArkDbError.validation(
        'cancellationGraceMs must be a non-negative safe integer.'));
    }
    try {
      validateQueryOptions(this.queryOptions);
    } catch (error) {
      if (!(error instanceof ArkDbError)) throw error as Error;
      errors.push(error);
    }
    return errors;
  }

  clone(): MySqlDeadlineOptions {
    const copy = new MySqlDeadlineOptions();
    copy.timeoutMs = this.timeoutMs;
    copy.cancellationGraceMs = this.cancellationGraceMs;
    copy.queryOptions = this.queryOptions.clone();
    return copy;
  }
}
