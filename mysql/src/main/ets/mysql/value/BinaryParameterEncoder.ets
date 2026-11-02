import { buffer } from '@kit.ArkTS';
import { ArkDbError } from '@arkdb/core';
import { MySqlParameter, MySqlParameterType } from '../model/MySqlParameter';
import { utf8Encode } from '../protocol/Charsets';
import { ColumnType } from '../protocol/Constants';
import { PacketWriter } from '../protocol/PacketWriter';

export interface EncodedBinaryParameters {
  readonly nullBitmap: Uint8Array;
  readonly types: Uint8Array;
  readonly values: Uint8Array;
  readonly valueOffsets: number[];
}

const MAX_PARAMETERS = 65535;
const MAX_COMMAND_BYTES = 16 * 1024 * 1024;
const EXECUTE_HEADER_BYTES = 10;

/** Parameter-only sections; the caller emits new_params_bound_flag=1 for nonempty bindings. */
export function encodeBinaryParameters(parameters: MySqlParameter[], expectedCount?: number): EncodedBinaryParameters {
  const capturedParameters = parameters.slice();
  const parameterCount = capturedParameters.length;
  if (parameterCount > MAX_PARAMETERS) {
    throw ArkDbError.validation('MySQL supports at most 65535 parameters');
  }
  if (expectedCount !== undefined && (!Number.isInteger(expectedCount) ||
    expectedCount < 0 || expectedCount > MAX_PARAMETERS || expectedCount !== parameterCount)) {
    throw ArkDbError.validation('Parameter count must match the prepared statement');
  }
  const bitmapBytes = Math.ceil(parameterCount / 8);
  const metadataBytes = parameterCount === 0 ? 0 : bitmapBytes + 1 + parameterCount * 2;
  let valueBytes = 0;
  const snapshots: MySqlParameter[] = [];
  for (let index = 0; index < parameterCount; index += 1) {
    const parameter = capturedParameters[index];
    if (!(parameter instanceof MySqlParameter)) {
      throw ArkDbError.validation('Binary parameters must be MySqlParameter instances');
    }
    const snapshot = new MySqlParameter(parameter.type, parameter.value);
    valueBytes += parameterValueLength(snapshot);
    if (EXECUTE_HEADER_BYTES + metadataBytes + valueBytes > MAX_COMMAND_BYTES) {
      throw ArkDbError.validation('Binary parameter command exceeds 16 MiB');
    }
    snapshots.push(snapshot);
  }

  const nullBitmap = new Uint8Array(bitmapBytes);
  const types = new Uint8Array(parameterCount * 2);
  const values = new Uint8Array(valueBytes);
  const valueOffsets: number[] = new Array<number>(parameterCount + 1).fill(0);
  let offset = 0;
  for (let index = 0; index < parameterCount; index += 1) {
    const parameter = snapshots[index];
    valueOffsets[index] = offset;
    types[index * 2] = parameterColumnType(parameter.type);
    types[index * 2 + 1] = parameter.type === MySqlParameterType.UInt64 ? 0x80 : 0;
    if (parameter.value === null) {
      nullBitmap[index >> 3] |= 1 << (index & 7);
    } else {
      offset = writeParameterValue(values, offset, parameter);
    }
  }
  valueOffsets[parameterCount] = offset;
  return {
    nullBitmap: nullBitmap, types: types, values: values,
    valueOffsets: valueOffsets
  };
}

function parameterColumnType(type: MySqlParameterType): number {
  switch (type) {
    case MySqlParameterType.Null: return ColumnType.NULL;
    case MySqlParameterType.Boolean: return ColumnType.TINY;
    case MySqlParameterType.Int32: return ColumnType.LONG;
    case MySqlParameterType.Int64:
    case MySqlParameterType.UInt64: return ColumnType.LONGLONG;
    case MySqlParameterType.Float64: return ColumnType.DOUBLE;
    case MySqlParameterType.Decimal: return ColumnType.NEWDECIMAL;
    case MySqlParameterType.Text:
    case MySqlParameterType.Json: return ColumnType.VAR_STRING;
    case MySqlParameterType.Binary: return ColumnType.BLOB;
    case MySqlParameterType.Date: return ColumnType.DATE;
    case MySqlParameterType.DateTime: return ColumnType.DATETIME;
    case MySqlParameterType.Timestamp: return ColumnType.TIMESTAMP;
    case MySqlParameterType.Time: return ColumnType.TIME;
    default: throw ArkDbError.validation('Unknown MySQL parameter type');
  }
}

function lengthEncodedSize(length: number): number {
  if (length < 0xfb) return 1;
  if (length <= 0xffff) return 3;
  if (length <= 0xffffff) return 4;
  return 9;
}

function parameterValueLength(parameter: MySqlParameter): number {
  const value = parameter.value;
  if (value === null) return 0;
  if (typeof value === 'boolean') return 1;
  if (typeof value === 'number') return parameter.type === MySqlParameterType.Int32 ? 4 : 8;
  if (typeof value === 'bigint') return 8;
  if (value instanceof Uint8Array) return lengthEncodedSize(value.length) + value.length;
  if (isTemporal(parameter.type)) return parseTemporal(parameter.type, value).length + 1;
  const length = buffer.byteLength(value, 'utf8');
  return lengthEncodedSize(length) + length;
}

function writeParameterValue(target: Uint8Array, offset: number, parameter: MySqlParameter): number {
  const value = parameter.value;
  if (value === null) return offset;
  if (value instanceof Uint8Array) return writeLengthEncoded(target, offset, value);
  if (typeof value === 'string' && !isTemporal(parameter.type)) {
    return writeLengthEncoded(target, offset, utf8Encode(value));
  }
  const writer = new PacketWriter();
  if (typeof value === 'boolean') {
    writer.writeUInt8(value ? 1 : 0);
  } else if (typeof value === 'number') {
    if (parameter.type === MySqlParameterType.Int32) {
      writer.writeInt32(value);
    } else {
      writer.writeFloat64(value);
    }
  } else if (typeof value === 'bigint') {
    if (parameter.type === MySqlParameterType.Int64) {
      writer.writeInt64(value);
    } else {
      writer.writeUInt64(value);
    }
  } else {
    writeTemporal(writer, parameter.type, parseTemporal(parameter.type, value));
  }
  const encoded = writer.toUint8Array();
  target.set(encoded, offset);
  return offset + encoded.length;
}

function writeLengthEncoded(target: Uint8Array, offset: number, value: Uint8Array): number {
  const prefix = new PacketWriter().writeLenEncInt(value.length).toUint8Array();
  target.set(prefix, offset);
  target.set(value, offset + prefix.length);
  return offset + prefix.length + value.length;
}

function isTemporal(type: MySqlParameterType): boolean {
  return type === MySqlParameterType.Date || type === MySqlParameterType.DateTime ||
    type === MySqlParameterType.Timestamp || type === MySqlParameterType.Time;
}

class BinaryTemporalValue {
  length: number = 0;
  year: number = 0;
  month: number = 0;
  day: number = 0;
  negative: boolean = false;
  days: number = 0;
  hours: number = 0;
  minutes: number = 0;
  seconds: number = 0;
  microseconds: number = 0;
}

function parseTemporal(type: MySqlParameterType, value: string): BinaryTemporalValue {
  const parts = new BinaryTemporalValue();
  const point = value.indexOf('.');
  parts.microseconds = point < 0 ? 0 : Number(value.substring(point + 1).padEnd(6, '0'));
  if (type === MySqlParameterType.Time) {
    parts.negative = value.startsWith('-');
    const colon = value.indexOf(':');
    const hours = Number(value.substring(parts.negative ? 1 : 0, colon));
    parts.days = Math.floor(hours / 24);
    parts.hours = hours % 24;
    parts.minutes = Number(value.substring(colon + 1, colon + 3));
    parts.seconds = Number(value.substring(colon + 4, colon + 6));
    if (hours !== 0 || parts.minutes !== 0 || parts.seconds !== 0 || parts.microseconds !== 0) {
      parts.length = parts.microseconds === 0 ? 8 : 12;
    }
    return parts;
  }
  parts.year = Number(value.substring(0, 4));
  parts.month = Number(value.substring(5, 7));
  parts.day = Number(value.substring(8, 10));
  if (parts.year === 0) return parts;
  parts.length = 4;
  if (type !== MySqlParameterType.Date) {
    parts.hours = Number(value.substring(11, 13));
    parts.minutes = Number(value.substring(14, 16));
    parts.seconds = Number(value.substring(17, 19));
    if (parts.microseconds !== 0) {
      parts.length = 11;
    } else if (parts.hours !== 0 || parts.minutes !== 0 || parts.seconds !== 0) {
      parts.length = 7;
    }
  }
  return parts;
}

function writeTemporal(writer: PacketWriter, type: MySqlParameterType, parts: BinaryTemporalValue): void {
  writer.writeUInt8(parts.length);
  if (parts.length === 0) return;
  if (type === MySqlParameterType.Time) {
    writer.writeUInt8(parts.negative ? 1 : 0).writeUInt32(parts.days)
      .writeUInt8(parts.hours).writeUInt8(parts.minutes).writeUInt8(parts.seconds);
    if (parts.length === 12) writer.writeUInt32(parts.microseconds);
  } else {
    writer.writeUInt16(parts.year).writeUInt8(parts.month).writeUInt8(parts.day);
    if (parts.length >= 7) {
      writer.writeUInt8(parts.hours).writeUInt8(parts.minutes).writeUInt8(parts.seconds);
    }
    if (parts.length === 11) writer.writeUInt32(parts.microseconds);
  }
}
