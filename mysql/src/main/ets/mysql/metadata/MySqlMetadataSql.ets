import { ArkDbError } from '@arkdb/core';
import { utf8Encode } from '../protocol/Charsets';
import { mysqlUtf8BytesExpression } from '../value/MySqlSqlHelpers';

const MAX_METADATA_IDENTIFIER_BYTES: number = 512;

export function mysqlMetadataLiteral(value: string): string {
  const bytes = utf8Encode(value);
  if (bytes.length > MAX_METADATA_IDENTIFIER_BYTES) {
    throw ArkDbError.validation('Metadata identifier exceeds the 512-byte limit.');
  }
  return mysqlUtf8BytesExpression(bytes);
}
