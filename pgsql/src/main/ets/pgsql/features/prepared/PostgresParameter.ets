import { ArkDbError } from '@arkdb/core';

export enum PostgresParameterType {
  Unspecified = 'unspecified',
  Boolean = 'boolean',
  Int2 = 'int2',
  Int4 = 'int4',
  Int8 = 'int8',
  Numeric = 'numeric',
  Float4 = 'float4',
  Float8 = 'float8',
  Text = 'text',
  Bytea = 'bytea',
  Uuid = 'uuid',
  Json = 'json',
  Jsonb = 'jsonb',
  Date = 'date',
  Time = 'time',
  Timestamp = 'timestamp',
  TimestampTz = 'timestamptz'
}

export type PostgresParameterValue =
  string | number | bigint | boolean | Uint8Array | null;

const MIN_INT8: bigint = -9223372036854775808n;
const MAX_INT8: bigint = 9223372036854775807n;
const KNOWN_TYPES: Set<string> = new Set<string>([
  PostgresParameterType.Unspecified, PostgresParameterType.Boolean,
  PostgresParameterType.Int2, PostgresParameterType.Int4, PostgresParameterType.Int8,
  PostgresParameterType.Numeric, PostgresParameterType.Float4, PostgresParameterType.Float8,
  PostgresParameterType.Text, PostgresParameterType.Bytea, PostgresParameterType.Uuid,
  PostgresParameterType.Json, PostgresParameterType.Jsonb, PostgresParameterType.Date,
  PostgresParameterType.Time, PostgresParameterType.Timestamp, PostgresParameterType.TimestampTz
]);

export class PostgresParameter {
  readonly type: PostgresParameterType;
  private readonly storedValue: PostgresParameterValue;

  constructor(type: PostgresParameterType, value: PostgresParameterValue) {
    validatePostgresParameterValue(type, value);
    this.type = type;
    this.storedValue = value instanceof Uint8Array ? copyBytes(value) : value;
  }

  get value(): PostgresParameterValue {
    return this.storedValue instanceof Uint8Array ? copyBytes(this.storedValue) : this.storedValue;
  }
}

export function validatePostgresParameterValue(
  type: PostgresParameterType, value: PostgresParameterValue): void {
  if (typeof type !== 'string' || !KNOWN_TYPES.has(type)) {
    throw ArkDbError.validation('Invalid PostgreSQL parameter type: ' + String(type));
  }
  if (value === null) return;
  switch (type) {
    case PostgresParameterType.Unspecified:
    case PostgresParameterType.Text:
      requireWellFormedText(value, type, false);
      return;
    case PostgresParameterType.Boolean:
      if (typeof value !== 'boolean') throw invalidValue(type);
      return;
    case PostgresParameterType.Int2:
      if (typeof value !== 'number' || !Number.isSafeInteger(value) ||
        value < -32768 || value > 32767) throw invalidValue(type);
      return;
    case PostgresParameterType.Int4:
      if (typeof value !== 'number' || !Number.isSafeInteger(value) ||
        value < -2147483648 || value > 2147483647) throw invalidValue(type);
      return;
    case PostgresParameterType.Int8:
      if (typeof value !== 'bigint' || value < MIN_INT8 || value > MAX_INT8) {
        throw invalidValue(type);
      }
      return;
    case PostgresParameterType.Numeric:
    case PostgresParameterType.Date:
    case PostgresParameterType.Time:
    case PostgresParameterType.Timestamp:
    case PostgresParameterType.TimestampTz:
      requireWellFormedText(value, type, true);
      return;
    case PostgresParameterType.Float4:
      if (typeof value !== 'number' ||
        (Number.isFinite(value) && !Number.isFinite(Math.fround(value)))) {
        throw invalidValue(type);
      }
      return;
    case PostgresParameterType.Float8:
      if (typeof value !== 'number') throw invalidValue(type);
      return;
    case PostgresParameterType.Bytea:
      if (!(value instanceof Uint8Array)) throw invalidValue(type);
      return;
    case PostgresParameterType.Uuid:
      if (typeof value !== 'string' || !isCanonicalUuid(value)) throw invalidValue(type);
      return;
    case PostgresParameterType.Json:
    case PostgresParameterType.Jsonb:
      requireWellFormedText(value, type, true);
      if (!isValidJson(value as string)) throw invalidValue(type);
      return;
  }
}

function requireWellFormedText(value: PostgresParameterValue,
  type: PostgresParameterType, nonEmpty: boolean): void {
  if (typeof value !== 'string' || (nonEmpty && value.trim().length === 0)) {
    throw invalidValue(type);
  }
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code === 0) throw invalidValue(type);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) throw invalidValue(type);
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) throw invalidValue(type);
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      throw invalidValue(type);
    }
  }
}

function isCanonicalUuid(value: string): boolean {
  if (value.length !== 36) return false;
  for (let index = 0; index < 36; index += 1) {
    const code = value.charCodeAt(index);
    if (index === 8 || index === 13 || index === 18 || index === 23) {
      if (code !== 0x2d) return false;
    } else if (!((code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x46) || (code >= 0x61 && code <= 0x66))) {
      return false;
    }
  }
  return true;
}

function isValidJson(value: string): boolean {
  try { JSON.parse(value); return true; } catch (_error) { return false; }
}

function copyBytes(value: Uint8Array): Uint8Array {
  const copy = new Uint8Array(value.length);
  copy.set(value);
  return copy;
}

function invalidValue(type: PostgresParameterType): ArkDbError {
  return ArkDbError.validation('Invalid value for PostgreSQL parameter type ' + type);
}
