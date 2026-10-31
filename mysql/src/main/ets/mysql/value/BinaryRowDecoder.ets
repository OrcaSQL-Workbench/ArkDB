import { ArkDbError } from '@arkdb/core';
import { MySqlRowDecoder } from '../command/ResultStream';
import {
  MySqlColumnDef, MySqlValue, mysqlColumnDecodesAsBytes
} from '../model/MySqlQueryResult';
import { utf8Decode } from '../protocol/Charsets';
import { ColumnType, FieldFlag } from '../protocol/Constants';
import { PacketReader } from '../protocol/PacketReader';

export class BinaryRowDecoder implements MySqlRowDecoder {
  decode(payload: Uint8Array, columns: MySqlColumnDef[]): MySqlValue[] {
    const reader = new PacketReader(payload);
    if (reader.readUInt8() !== 0x00) {
      throw ArkDbError.protocol('Invalid binary result row header');
    }
    const nullBitmap = reader.readBytes(Math.ceil((columns.length + 2) / 8));
    const row: MySqlValue[] = [];
    for (let index = 0; index < columns.length; index += 1) {
      const column = columns[index];
      if (!isSupportedType(column.type)) {
        throw ArkDbError.protocol('Unsupported binary result type ' + column.type);
      }
      const bit = index + 2;
      if ((nullBitmap[bit >> 3] & (1 << (bit & 7))) !== 0) {
        row.push(null);
      } else {
        row.push(readValue(reader, column));
      }
    }
    if (reader.remaining !== 0) {
      throw ArkDbError.protocol('Unexpected trailing binary result row bytes');
    }
    return row;
  }
}

function isSupportedType(type: number): boolean {
  switch (type) {
    case ColumnType.TINY:
    case ColumnType.SHORT:
    case ColumnType.LONG:
    case ColumnType.INT24:
    case ColumnType.LONGLONG:
    case ColumnType.YEAR:
    case ColumnType.FLOAT:
    case ColumnType.DOUBLE:
    case ColumnType.NULL:
    case ColumnType.DATE:
    case ColumnType.NEWDATE:
    case ColumnType.DATETIME:
    case ColumnType.TIMESTAMP:
    case ColumnType.TIME:
    case ColumnType.DECIMAL:
    case ColumnType.NEWDECIMAL:
    case ColumnType.VARCHAR:
    case ColumnType.VAR_STRING:
    case ColumnType.STRING:
    case ColumnType.ENUM:
    case ColumnType.SET:
    case ColumnType.BIT:
    case ColumnType.JSON:
    case ColumnType.TINY_BLOB:
    case ColumnType.MEDIUM_BLOB:
    case ColumnType.LONG_BLOB:
    case ColumnType.BLOB:
    case ColumnType.GEOMETRY:
      return true;
    default:
      return false;
  }
}

function readValue(reader: PacketReader, column: MySqlColumnDef): MySqlValue {
  const unsigned = (column.flags & FieldFlag.UNSIGNED) !== 0;
  switch (column.type) {
    case ColumnType.TINY: return unsigned ? reader.readUInt8() : reader.readInt8();
    case ColumnType.SHORT: return unsigned ? reader.readUInt16() : reader.readInt16();
    case ColumnType.LONG:
    case ColumnType.INT24: return unsigned ? reader.readUInt32() : reader.readInt32();
    case ColumnType.LONGLONG: return unsigned ? reader.readUInt64() : reader.readInt64();
    case ColumnType.YEAR: return reader.readUInt16();
    case ColumnType.FLOAT: return finiteFloat(reader.readFloat32());
    case ColumnType.DOUBLE: return finiteFloat(reader.readFloat64());
    case ColumnType.NULL: return null;
    case ColumnType.DATE:
    case ColumnType.NEWDATE:
    case ColumnType.DATETIME:
    case ColumnType.TIMESTAMP:
      return readDateTime(reader, column);
    case ColumnType.TIME:
      return readTime(reader, column.decimals);
    default:
      return readLengthEncodedValue(reader, column);
  }
}

function finiteFloat(value: number): number {
  if (!Number.isFinite(value)) {
    throw ArkDbError.protocol('Non-finite binary floating-point result');
  }
  return value;
}

function readLengthEncodedValue(reader: PacketReader, column: MySqlColumnDef): MySqlValue {
  const raw = reader.readBytes(reader.readLenEncUInt());
  if (mysqlColumnDecodesAsBytes(column.type, column.charset)) {
    return raw;
  }
  return utf8Decode(raw);
}

function readDateTime(reader: PacketReader, column: MySqlColumnDef): string {
  const length = reader.readUInt8();
  const dateOnly = column.type === ColumnType.DATE || column.type === ColumnType.NEWDATE;
  if (length !== 0 && length !== 4 && (dateOnly || (length !== 7 && length !== 11))) {
    throw ArkDbError.protocol('Invalid binary date/time length');
  }
  const body = new PacketReader(reader.readBytes(length));
  let year = 0;
  let month = 0;
  let day = 0;
  let hours = 0;
  let minutes = 0;
  let seconds = 0;
  let microseconds = 0;
  if (length >= 4) {
    year = body.readUInt16();
    month = body.readUInt8();
    day = body.readUInt8();
  }
  if (length >= 7) {
    hours = body.readUInt8();
    minutes = body.readUInt8();
    seconds = body.readUInt8();
  }
  if (length === 11) microseconds = body.readUInt32();
  if (year > 9999 || month > 12 || day > 31 || hours > 23 || minutes > 59 || seconds > 59) {
    throw ArkDbError.protocol('Invalid binary date/time components');
  }
  const date = pad(year, 4) + '-' + pad(month, 2) + '-' + pad(day, 2);
  if (dateOnly) return date;
  return date + ' ' + pad(hours, 2) + ':' + pad(minutes, 2) + ':' + pad(seconds, 2) +
    fraction(microseconds, column.decimals);
}

function readTime(reader: PacketReader, decimals: number): string {
  const length = reader.readUInt8();
  if (length !== 0 && length !== 8 && length !== 12) {
    throw ArkDbError.protocol('Invalid binary TIME length');
  }
  const body = new PacketReader(reader.readBytes(length));
  let sign = 0;
  let days = 0;
  let hours = 0;
  let minutes = 0;
  let seconds = 0;
  let microseconds = 0;
  if (length >= 8) {
    sign = body.readUInt8();
    days = body.readUInt32();
    hours = body.readUInt8();
    minutes = body.readUInt8();
    seconds = body.readUInt8();
  }
  if (length === 12) microseconds = body.readUInt32();
  const totalHours = days * 24 + hours;
  if (sign > 1 || hours > 23 || minutes > 59 || seconds > 59 || totalHours > 838) {
    throw ArkDbError.protocol('Invalid binary TIME components');
  }
  return (sign === 1 ? '-' : '') + pad(totalHours, 2) + ':' + pad(minutes, 2) + ':' +
    pad(seconds, 2) + fraction(microseconds, decimals);
}

function fraction(microseconds: number, decimals: number): string {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 6 ||
    microseconds > 999999 || microseconds % Math.pow(10, 6 - decimals) !== 0) {
    throw ArkDbError.protocol('Invalid binary temporal precision');
  }
  if (decimals === 0) return '';
  return '.' + pad(microseconds, 6).substring(0, decimals);
}

function pad(value: number, width: number): string {
  return value.toString().padStart(width, '0');
}
