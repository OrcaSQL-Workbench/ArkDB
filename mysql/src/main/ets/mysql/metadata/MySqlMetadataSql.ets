import { ArkDbError } from '@arkdb/core';
import { utf8Encode } from '../protocol/Charsets';

const MAX_METADATA_IDENTIFIER_BYTES: number = 512;
const HEX_DIGITS: string = '0123456789ABCDEF';

export function mysqlMetadataLiteral(value: string): string {
  const bytes = utf8Encode(value);
  if (bytes.length > MAX_METADATA_IDENTIFIER_BYTES) {
    throw ArkDbError.validation('Metadata identifier exceeds the 512-byte limit.');
  }
  let hex = '';
  for (const byte of bytes) {
    hex += HEX_DIGITS.charAt((byte >> 4) & 0x0f);
    hex += HEX_DIGITS.charAt(byte & 0x0f);
  }
  return "CONVERT(X'" + hex + "' USING utf8mb4)";
}
