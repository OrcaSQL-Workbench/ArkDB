import { ArkDbError } from '@arkdb/core';

export type MySqlParameterValue = string | number | bigint | boolean | Uint8Array | null;

export enum MySqlParameterType {
  Null = 'null',
  Boolean = 'boolean',
  Int32 = 'int32',
  Int64 = 'int64',
  UInt64 = 'uint64',
  Float64 = 'float64',
  Decimal = 'decimal',
  Text = 'text',
  Binary = 'binary',
  Date = 'date',
  DateTime = 'datetime',
  Timestamp = 'timestamp',
  Time = 'time',
  Json = 'json'
}

/** An input value snapshot, separate from the native MySQL result union. */
export class MySqlParameter {
  readonly type: MySqlParameterType;
  private readonly storedValue: MySqlParameterValue;

  constructor(type: MySqlParameterType, value: MySqlParameterValue) {
    if (!isValidParameter(type, value)) {
      throw ArkDbError.validation('Invalid value for MySQL parameter type ' + type);
    }
    this.type = type;
    this.storedValue = value instanceof Uint8Array ? value.slice() : value;
  }

  get value(): MySqlParameterValue {
    return this.storedValue instanceof Uint8Array ? this.storedValue.slice() : this.storedValue;
  }
}

function isValidParameter(type: MySqlParameterType, value: MySqlParameterValue): boolean {
  switch (type) {
    case MySqlParameterType.Null:
      return value === null;
    case MySqlParameterType.Boolean:
      return value === null || typeof value === 'boolean';
    case MySqlParameterType.Int32:
      return value === null || (typeof value === 'number' && Number.isInteger(value) &&
        value >= -2147483648 && value <= 2147483647);
    case MySqlParameterType.Int64:
      return value === null || (typeof value === 'bigint' &&
        value >= -9223372036854775808n && value <= 9223372036854775807n);
    case MySqlParameterType.UInt64:
      return value === null || (typeof value === 'bigint' && value >= 0n &&
        value <= 18446744073709551615n);
    case MySqlParameterType.Float64:
      return value === null || (typeof value === 'number' && Number.isFinite(value));
    case MySqlParameterType.Decimal:
      return value === null || (typeof value === 'string' && isDecimal(value));
    case MySqlParameterType.Text:
      return value === null || typeof value === 'string';
    case MySqlParameterType.Binary:
      return value === null || value instanceof Uint8Array;
    case MySqlParameterType.Date:
      return value === null || (typeof value === 'string' && isDate(value));
    case MySqlParameterType.DateTime:
    case MySqlParameterType.Timestamp:
      return value === null || (typeof value === 'string' && isDateTime(value));
    case MySqlParameterType.Time:
      return value === null || (typeof value === 'string' && isTime(value));
    case MySqlParameterType.Json:
      return value === null || (typeof value === 'string' && isJson(value));
    default:
      return false;
  }
}

function matchesEntire(value: string, pattern: RegExp): boolean {
  const match = pattern.exec(value);
  return match !== null && match[0].length === value.length;
}

function isDecimal(value: string): boolean {
  if (!matchesEntire(value, /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/)) {
    return false;
  }
  const point = value.indexOf('.');
  const digits = value.length - (value.startsWith('-') ? 1 : 0) - (point >= 0 ? 1 : 0);
  return digits <= 65 && (point < 0 || value.length - point - 1 <= 30);
}

function isDate(value: string): boolean {
  if (!matchesEntire(value, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)) {
    return false;
  }
  if (value === '0000-00-00') {
    return true;
  }
  const year = Number(value.substring(0, 4));
  const month = Number(value.substring(5, 7));
  const day = Number(value.substring(8, 10));
  if (year < 1 || month < 1 || month > 12 || day < 1) {
    return false;
  }
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days: number[] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= days[month - 1];
}

function isDateTime(value: string): boolean {
  if (!matchesEntire(value, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?$/)) {
    return false;
  }
  const date = value.substring(0, 10);
  const hours = Number(value.substring(11, 13));
  const minutes = Number(value.substring(14, 16));
  const seconds = Number(value.substring(17));
  if (!isDate(date) || hours > 23 || minutes > 59 || seconds >= 60) {
    return false;
  }
  return date !== '0000-00-00' || (hours === 0 && minutes === 0 && seconds === 0);
}

function isTime(value: string): boolean {
  if (!matchesEntire(value, /^-?[0-9]{1,3}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?$/)) {
    return false;
  }
  const start = value.startsWith('-') ? 1 : 0;
  const colon = value.indexOf(':');
  return Number(value.substring(start, colon)) <= 838 &&
    Number(value.substring(colon + 1, colon + 3)) <= 59 &&
    Number(value.substring(colon + 4)) < 60;
}

function isJson(value: string): boolean {
  try {
    JSON.parse(value);
    return true;
  } catch (error) {
    if (error instanceof SyntaxError) {
      return false;
    }
    throw error as Error;
  }
}
