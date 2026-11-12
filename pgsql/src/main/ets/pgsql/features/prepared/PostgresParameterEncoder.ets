import { buffer } from '@kit.ArkTS';
import { ArkDbError } from '@arkdb/core';
import { PostgresFrontendSerializer } from '../../protocol/PostgresByteCodec';
import {
  MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_LENGTH_BYTES
} from '../../protocol/PostgresProtocolConstants';
import {
  POSTGRES_OID_BOOL, POSTGRES_OID_BYTEA, POSTGRES_OID_DATE, POSTGRES_OID_FLOAT4,
  POSTGRES_OID_FLOAT8, POSTGRES_OID_INT2, POSTGRES_OID_INT4, POSTGRES_OID_INT8,
  POSTGRES_OID_JSON, POSTGRES_OID_JSONB, POSTGRES_OID_NUMERIC, POSTGRES_OID_TEXT,
  POSTGRES_OID_TIME, POSTGRES_OID_TIMESTAMP, POSTGRES_OID_TIMESTAMPTZ,
  POSTGRES_OID_UNSPECIFIED, POSTGRES_OID_UUID
} from '../../value/PostgresTypeOids';
import {
  PostgresParameter, PostgresParameterType, PostgresParameterValue,
  validatePostgresParameterValue
} from './PostgresParameter';

export const POSTGRES_PARAMETER_FORMAT_TEXT: number = 0;
export const POSTGRES_PARAMETER_FORMAT_BINARY: number = 1;
export const MAX_POSTGRES_PARAMETERS: number = 65535;

const MIN_BIND_BASE_LENGTH_WORD: number = POSTGRES_LENGTH_BYTES + 8;

export class PostgresEncodedParameters {
  readonly parameterTypeOids: number[];
  readonly parameterFormats: number[];
  readonly parameterValues: Array<Uint8Array | null>;

  constructor(parameterTypeOids: number[], parameterFormats: number[],
    parameterValues: Array<Uint8Array | null>) {
    this.parameterTypeOids = parameterTypeOids;
    this.parameterFormats = parameterFormats;
    this.parameterValues = parameterValues;
  }
}

export class PostgresPreparedFrames {
  readonly parameters: PostgresEncodedParameters;
  readonly parseFrame: Uint8Array;
  readonly bindFrame: Uint8Array;

  constructor(parameters: PostgresEncodedParameters, parseFrame: Uint8Array,
    bindFrame: Uint8Array) {
    this.parameters = parameters;
    this.parseFrame = parseFrame;
    this.bindFrame = bindFrame;
  }
}

export function encodePostgresParameters(
  parameters: PostgresParameter[]): PostgresEncodedParameters {
  if (!Array.isArray(parameters)) {
    throw ArkDbError.validation('PostgreSQL parameters must be an array.');
  }
  const count = parameters.length;
  if (count > MAX_POSTGRES_PARAMETERS) {
    throw ArkDbError.validation('PostgreSQL supports at most 65535 parameters.');
  }
  const captured: Array<PostgresParameter | undefined> = [];
  for (let index = 0; index < count; index += 1) captured.push(parameters[index]);
  const parameterTypeOids: number[] = [];
  const parameterFormats: number[] = [];
  const parameterValues: Array<Uint8Array | null> = [];
  let bindLengthWord = MIN_BIND_BASE_LENGTH_WORD;

  for (let index = 0; index < count; index += 1) {
    const parameter = captured[index];
    if (!(parameter instanceof PostgresParameter)) {
      throw ArkDbError.validation('PostgreSQL parameters must be PostgresParameter instances.');
    }
    const type = parameter.type;
    const value = parameter.value;
    validatePostgresParameterValue(type, value);
    bindLengthWord += 6;
    if (bindLengthWord > MAX_POSTGRES_MESSAGE_BYTES) throw bindOverflowError();
    parameterTypeOids.push(parameterTypeOid(type));
    parameterFormats.push(type === PostgresParameterType.Bytea
      ? POSTGRES_PARAMETER_FORMAT_BINARY : POSTGRES_PARAMETER_FORMAT_TEXT);
    if (value === null) {
      parameterValues.push(null);
    } else {
      const encoded = encodeNonNullValue(type, value, MAX_POSTGRES_MESSAGE_BYTES - bindLengthWord);
      bindLengthWord += encoded.length;
      parameterValues.push(encoded);
    }
  }
  return new PostgresEncodedParameters(parameterTypeOids, parameterFormats, parameterValues);
}

export function encodePostgresPreparedFrames(
  sql: string,
  parameters: PostgresParameter[],
  statementName: string = '',
  portalName: string = '',
  resultFormats: number[] = [POSTGRES_PARAMETER_FORMAT_TEXT]
): PostgresPreparedFrames {
  if (typeof sql !== 'string' || typeof statementName !== 'string' ||
    typeof portalName !== 'string') {
    throw ArkDbError.validation('PostgreSQL prepared SQL and target names must be strings.');
  }
  if (!Array.isArray(resultFormats)) {
    throw ArkDbError.validation('PostgreSQL Bind result formats must be an array.');
  }
  const resultFormatCount = resultFormats.length;
  if (resultFormatCount > MAX_POSTGRES_PARAMETERS) {
    throw ArkDbError.validation('PostgreSQL Bind result format count exceeds 65535.');
  }
  const capturedResultFormats: number[] = [];
  for (let index = 0; index < resultFormatCount; index += 1) {
    const format = resultFormats[index];
    if (format !== POSTGRES_PARAMETER_FORMAT_TEXT &&
      format !== POSTGRES_PARAMETER_FORMAT_BINARY) {
      throw ArkDbError.validation('PostgreSQL format code must be text or binary.');
    }
    capturedResultFormats.push(format);
  }
  const encoded = encodePostgresParameters(parameters);
  const parseFrame = PostgresFrontendSerializer.parse(
    statementName, sql, encoded.parameterTypeOids);
  const bindFrame = PostgresFrontendSerializer.bind(portalName, statementName,
    encoded.parameterFormats, encoded.parameterValues, capturedResultFormats);
  return new PostgresPreparedFrames(encoded, parseFrame, bindFrame);
}

function parameterTypeOid(type: PostgresParameterType): number {
  switch (type) {
    case PostgresParameterType.Unspecified: return POSTGRES_OID_UNSPECIFIED;
    case PostgresParameterType.Boolean: return POSTGRES_OID_BOOL;
    case PostgresParameterType.Int2: return POSTGRES_OID_INT2;
    case PostgresParameterType.Int4: return POSTGRES_OID_INT4;
    case PostgresParameterType.Int8: return POSTGRES_OID_INT8;
    case PostgresParameterType.Numeric: return POSTGRES_OID_NUMERIC;
    case PostgresParameterType.Float4: return POSTGRES_OID_FLOAT4;
    case PostgresParameterType.Float8: return POSTGRES_OID_FLOAT8;
    case PostgresParameterType.Text: return POSTGRES_OID_TEXT;
    case PostgresParameterType.Bytea: return POSTGRES_OID_BYTEA;
    case PostgresParameterType.Uuid: return POSTGRES_OID_UUID;
    case PostgresParameterType.Json: return POSTGRES_OID_JSON;
    case PostgresParameterType.Jsonb: return POSTGRES_OID_JSONB;
    case PostgresParameterType.Date: return POSTGRES_OID_DATE;
    case PostgresParameterType.Time: return POSTGRES_OID_TIME;
    case PostgresParameterType.Timestamp: return POSTGRES_OID_TIMESTAMP;
    case PostgresParameterType.TimestampTz: return POSTGRES_OID_TIMESTAMPTZ;
  }
}

function encodeNonNullValue(type: PostgresParameterType,
  value: PostgresParameterValue, maxRemainingBytes: number): Uint8Array {
  if (type === PostgresParameterType.Bytea) {
    const raw = value as Uint8Array;
    if (raw.length > maxRemainingBytes) throw bindOverflowError();
    const copy = new Uint8Array(raw.length);
    copy.set(raw);
    return copy;
  }
  const text = formatTextParameter(type, value);
  const byteLength = utf8ByteLength(text);
  if (byteLength > maxRemainingBytes) throw bindOverflowError();
  if (byteLength === 0) return new Uint8Array(0);
  if (byteLength === text.length) {
    const ascii = new Uint8Array(byteLength);
    for (let index = 0; index < byteLength; index += 1) ascii[index] = text.charCodeAt(index);
    return ascii;
  }
  const bytes = new Uint8Array(byteLength);
  try {
    const encoded = buffer.from(text, 'utf8');
    if (encoded.length !== byteLength) {
      throw ArkDbError.validation('PostgreSQL UTF-8 parameter length mismatch.');
    }
    encoded.copy(bytes);
  } catch (error) {
    if (error instanceof ArkDbError) throw error;
    throw ArkDbError.validation('PostgreSQL UTF-8 parameter encoding failed.');
  }
  return bytes;
}

function formatTextParameter(type: PostgresParameterType, value: PostgresParameterValue): string {
  switch (type) {
    case PostgresParameterType.Boolean: return (value as boolean) ? 'true' : 'false';
    case PostgresParameterType.Int2:
    case PostgresParameterType.Int4:
      return (value as number) === 0 ? '0' : (value as number).toString(10);
    case PostgresParameterType.Int8: return (value as bigint).toString(10);
    case PostgresParameterType.Float4:
    case PostgresParameterType.Float8: {
      const n = type === PostgresParameterType.Float4
        ? Math.fround(value as number)
        : (value as number);
      return n === 0 && (1 / n) === Number.NEGATIVE_INFINITY ? '-0' : String(n);
    }
    default: return value as string;
  }
}

function utf8ByteLength(text: string): number {
  let total = 0;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code <= 0x7f) total += 1;
    else if (code <= 0x7ff) total += 2;
    else if (code >= 0xd800 && code <= 0xdbff) { total += 4; index += 1; }
    else total += 3;
  }
  return total;
}

function bindOverflowError(): ArkDbError {
  return ArkDbError.validation('PostgreSQL Bind message exceeds MAX_POSTGRES_MESSAGE_BYTES.');
}
