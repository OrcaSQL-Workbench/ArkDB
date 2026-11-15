import { ArkDbError } from '@arkdb/core';

export const MAX_POSTGRES_IDENTIFIER_BYTES: number = 63;

const MAX_POSTGRES_PLACEHOLDERS: number = 65535;

export function quotePostgresIdentifier(parts: string[]): string {
  if (parts === null || parts === undefined || parts.length === 0) {
    throw ArkDbError.validation('At least one PostgreSQL identifier segment is required.');
  }
  const quoted: string[] = new Array<string>(parts.length);
  for (let index = 0; index < parts.length; index += 1) {
    quoted[index] = quoteSegment(parts[index]);
  }
  return quoted.join('.');
}

export function postgresPlaceholders(count: number, startIndex: number = 1): string {
  if (!Number.isSafeInteger(count) || count < 1 || count > MAX_POSTGRES_PLACEHOLDERS) {
    throw ArkDbError.validation('PostgreSQL placeholder count must be an integer between 1 and 65535.');
  }
  if (!Number.isSafeInteger(startIndex) || startIndex < 1 ||
    startIndex > MAX_POSTGRES_PLACEHOLDERS || startIndex + count - 1 > MAX_POSTGRES_PLACEHOLDERS) {
    throw ArkDbError.validation('PostgreSQL placeholder range must stay within $1..$65535.');
  }
  const tokens: string[] = new Array<string>(count);
  for (let offset = 0; offset < count; offset += 1) {
    tokens[offset] = '$' + (startIndex + offset).toString();
  }
  return tokens.join(',');
}

function quoteSegment(segment: string): string {
  if (segment === null || segment === undefined || segment.length === 0) {
    throw ArkDbError.validation('PostgreSQL identifier segments must not be empty.');
  }
  let utf8Bytes = 0;
  for (let i = 0; i < segment.length; i += 1) {
    const code = segment.charCodeAt(i);
    if (code === 0) {
      throw ArkDbError.validation('PostgreSQL identifier segments must not contain NUL bytes.');
    }
    if (code <= 0x7F) {
      utf8Bytes += 1;
    } else if (code <= 0x7FF) {
      utf8Bytes += 2;
    } else if (code >= 0xD800 && code <= 0xDBFF) {
      if (i + 1 >= segment.length) {
        throw ArkDbError.validation(
          'PostgreSQL identifier segments must not contain unpaired UTF-16 surrogates.');
      }
      const low = segment.charCodeAt(i + 1);
      if (low < 0xDC00 || low > 0xDFFF) {
        throw ArkDbError.validation(
          'PostgreSQL identifier segments must not contain unpaired UTF-16 surrogates.');
      }
      utf8Bytes += 4;
      i += 1;
    } else if (code >= 0xDC00 && code <= 0xDFFF) {
      throw ArkDbError.validation(
        'PostgreSQL identifier segments must not contain unpaired UTF-16 surrogates.');
    } else {
      utf8Bytes += 3;
    }
  }
  if (utf8Bytes > MAX_POSTGRES_IDENTIFIER_BYTES) {
    throw ArkDbError.validation(
      'PostgreSQL identifier segment exceeds the 63-byte NAMEDATALEN limit.');
  }
  return '"' + segment.split('"').join('""') + '"';
}
