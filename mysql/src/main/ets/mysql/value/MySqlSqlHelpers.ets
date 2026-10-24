import { ArkDbError } from '@arkdb/core';

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
