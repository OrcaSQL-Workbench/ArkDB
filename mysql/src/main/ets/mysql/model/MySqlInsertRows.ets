import { ArkDbError } from '@arkdb/core';
import {
  MySqlBatchOptions, validateMySqlBatchOptions
} from './MySqlBatch';

const MAX_INSERT_PACKET_BYTES: number = 16 * 1024 * 1024;

export class MySqlInsertRowsOptions extends MySqlBatchOptions {
  maxPacketBytes: number = MAX_INSERT_PACKET_BYTES;

  validate(): ArkDbError[] {
    return validateMySqlInsertRowsOptions(this);
  }

  clone(): MySqlInsertRowsOptions {
    const copy = new MySqlInsertRowsOptions();
    copy.maxItems = this.maxItems;
    copy.maxBufferedBytes = this.maxBufferedBytes;
    copy.queryOptions = this.queryOptions.clone();
    copy.maxPacketBytes = this.maxPacketBytes;
    return copy;
  }
}

export function validateMySqlInsertRowsOptions(options: MySqlInsertRowsOptions,
  itemCount?: number): ArkDbError[] {
  const errors: ArkDbError[] = validateMySqlBatchOptions(options, itemCount);
  if (!Number.isInteger(options.maxPacketBytes) ||
    options.maxPacketBytes < 1 ||
    options.maxPacketBytes > MAX_INSERT_PACKET_BYTES) {
    errors.push(ArkDbError.validation(
      'maxPacketBytes must be between 1 and 16777216.'));
  }
  return errors;
}
