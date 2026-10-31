import { QueryOptions } from '@arkdb/core';
import { MySqlQueryResult } from '../model/MySqlQueryResult';

export function mySqlBatchItemOptions(options: QueryOptions,
  remainingBytes: number): QueryOptions {
  const item = options.clone();
  if (item.maxResultBytes > remainingBytes) {
    item.maxResultBytes = remainingBytes;
  }
  return item;
}

export function mySqlBatchResultBytes(result: MySqlQueryResult): number {
  let bytes = result.loadedBytes;
  for (const additional of result.additionalResults) {
    bytes += mySqlBatchResultBytes(additional);
  }
  return bytes;
}
