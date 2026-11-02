import { ArkDbError, QueryOptions } from '@arkdb/core';
import { validateQueryOptions } from '../command/ResultStream';
import { MySqlByteSource } from './MySqlByteSource';

const MAX_LONG_DATA_CHUNK_BYTES = 1024 * 1024;
const MAX_LONG_DATA_TIMEOUT_MS = 86400000;

export enum MySqlLongParameterKind {
  Binary = 'binary',
  Text = 'text'
}

export class MySqlLongParameter {
  readonly parameterIndex: number;
  readonly kind: MySqlLongParameterKind;
  readonly source: MySqlByteSource;

  constructor(parameterIndex: number, kind: MySqlLongParameterKind, source: MySqlByteSource) {
    if (!Number.isSafeInteger(parameterIndex) || parameterIndex < 0 || parameterIndex > 65534) {
      throw ArkDbError.validation('Long parameter index must be between 0 and 65534.');
    }
    if (kind !== MySqlLongParameterKind.Binary && kind !== MySqlLongParameterKind.Text) {
      throw ArkDbError.validation('Unknown MySQL long parameter kind.');
    }
    this.parameterIndex = parameterIndex;
    this.kind = kind;
    this.source = source;
  }
}

export class MySqlLongDataOptions {
  chunkBytes: number = 65536;
  maxTotalBytes: number = 67108864;
  uploadTimeoutMs: number = 30000;
  queryOptions: QueryOptions = new QueryOptions();

  validate(): ArkDbError[] {
    return validateMySqlLongDataOptions(this);
  }

  clone(): MySqlLongDataOptions {
    const copy = new MySqlLongDataOptions();
    copy.chunkBytes = this.chunkBytes;
    copy.maxTotalBytes = this.maxTotalBytes;
    copy.uploadTimeoutMs = this.uploadTimeoutMs;
    copy.queryOptions = this.queryOptions.clone();
    return copy;
  }
}

export function validateMySqlLongDataOptions(options: MySqlLongDataOptions): ArkDbError[] {
  const errors: ArkDbError[] = [];
  if (!Number.isSafeInteger(options.chunkBytes) || options.chunkBytes < 1 ||
    options.chunkBytes > MAX_LONG_DATA_CHUNK_BYTES) {
    errors.push(ArkDbError.validation('chunkBytes must be between 1 and 1048576.'));
  }
  if (!Number.isSafeInteger(options.maxTotalBytes) || options.maxTotalBytes < 1) {
    errors.push(ArkDbError.validation('maxTotalBytes must be a positive safe integer.'));
  }
  if (!Number.isSafeInteger(options.uploadTimeoutMs) || options.uploadTimeoutMs < 1 ||
    options.uploadTimeoutMs > MAX_LONG_DATA_TIMEOUT_MS) {
    errors.push(ArkDbError.validation('uploadTimeoutMs must be between 1 and 86400000.'));
  }
  try {
    validateQueryOptions(options.queryOptions);
  } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    errors.push(error);
  }
  return errors;
}
