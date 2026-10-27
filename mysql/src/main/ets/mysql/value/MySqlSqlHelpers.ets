import { ArkDbError } from '@arkdb/core';

const HEX_DIGITS: string = '0123456789ABCDEF';

export function quoteMySqlIdentifier(parts: string[]): string {
  if (parts.length === 0) {
    throw ArkDbError.validation('MySQL identifier must contain at least one segment.');
  }
  const quoted: string[] = [];
  for (const part of parts) {
    if (part.length === 0 || part.indexOf('\u0000') !== -1) {
      throw ArkDbError.validation('MySQL identifier segments must not be empty or contain NUL.');
    }
    quoted.push('`' + part.replace(/`/g, '``') + '`');
  }
  return quoted.join('.');
}

export function mysqlPlaceholders(count: number): string {
  if (!Number.isInteger(count) || count < 1 || count > 65535) {
    throw ArkDbError.validation('MySQL placeholder count must be an integer between 1 and 65535.');
  }
  return '?,'.repeat(count - 1) + '?';
}

export function mysqlUtf8BytesExpression(bytes: Uint8Array): string {
  let hex = '';
  for (const byte of bytes) {
    hex += HEX_DIGITS.charAt((byte >> 4) & 0x0f);
    hex += HEX_DIGITS.charAt(byte & 0x0f);
  }
  return "CONVERT(X'" + hex + "' USING utf8mb4)";
}
