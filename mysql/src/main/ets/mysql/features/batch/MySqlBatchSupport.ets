import { QueryOptions } from '@arkdb/core';
import {
  MySqlBatchSupportContract
} from '../../api/MySqlFeatureContracts';
import { MySqlQueryResult } from '../../model/MySqlQueryResult';

export class MySqlBatchSupport implements MySqlBatchSupportContract {
  itemOptions(options: QueryOptions,
    remainingBytes: number): QueryOptions {
    const item = options.clone();
    if (item.maxResultBytes > remainingBytes) {
      item.maxResultBytes = remainingBytes;
    }
    return item;
  }

  resultBytes(result: MySqlQueryResult): number {
    let bytes = result.loadedBytes;
    for (const additional of result.additionalResults) {
      bytes += this.resultBytes(additional);
    }
    return bytes;
  }
}
