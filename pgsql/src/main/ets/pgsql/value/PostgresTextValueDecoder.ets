import { buffer } from '@kit.ArkTS';
import { ArkDbError, SqlValue } from '@arkdb/core';
import { PostgresColumnDef } from '../model/PostgresModels';
import {
  PostgresDataRow, PostgresRowDescription, PostgresRowDescriptionColumn
} from '../protocol/PostgresMessageChannel';
import {
  MAX_POSTGRES_OID, POSTGRES_OID_BOOL, POSTGRES_OID_BYTEA, POSTGRES_OID_DATE,
  POSTGRES_OID_FLOAT4, POSTGRES_OID_FLOAT8, POSTGRES_OID_INT2, POSTGRES_OID_INT4,
  POSTGRES_OID_INT8, POSTGRES_OID_INTERVAL, POSTGRES_OID_NUMERIC, POSTGRES_OID_OID,
  POSTGRES_OID_TIME, POSTGRES_OID_TIMESTAMP, POSTGRES_OID_TIMESTAMPTZ,
  POSTGRES_OID_TIMETZ, POSTGRES_OID_UUID, requirePostgresTypeOid,
  resolvePostgresTypeMetadata
} from './PostgresTypeOids';

export const POSTGRES_TEXT_FORMAT_CODE: number = 0;

const MIN_INT8: bigint = -9223372036854775808n;
const MAX_INT8: bigint = 9223372036854775807n;
const BINARY32_OVERFLOW_THRESHOLD: bigint = ((1n << 25n) - 1n) << 103n;
const FLOAT64_BIT52: bigint = 1n << 52n;
const FLOAT64_BIT53: bigint = 1n << 53n;
const FLOAT64_FRAC_MASK: bigint = FLOAT64_BIT52 - 1n;
const MAX_FLOAT64_SIG_DIGITS: number = 768;
const FLOAT64_VIEW: DataView = new DataView(new ArrayBuffer(8));

export function toPostgresColumnDef(
  column: PostgresRowDescriptionColumn): PostgresColumnDef {
  const metadata = resolvePostgresTypeMetadata(column.typeOid);
  const definition = new PostgresColumnDef();
  definition.name = column.name;
  definition.sourceSchema = '';
  definition.sourceTable = '';
  definition.nativeTypeId = metadata.nativeTypeId;
  definition.nativeTypeName = metadata.nativeTypeName;
  definition.valueKind = metadata.valueKind;
  definition.nullable = true;
  definition.tableOid = column.tableOid;
  definition.columnAttributeNumber = column.columnAttributeNumber;
  definition.typeOid = column.typeOid;
  definition.typeSize = column.typeSize;
  definition.typeModifier = column.typeModifier;
  definition.formatCode = column.formatCode;
  return definition;
}

export function toPostgresColumnDefs(
  description: PostgresRowDescription): PostgresColumnDef[] {
  return description.columns.map(toPostgresColumnDef);
}

export function decodePostgresColumnValue(
  column: PostgresColumnDef, raw: Uint8Array | null): SqlValue {
  return decodePostgresTextValue(column.typeOid, column.formatCode, raw);
}

export function decodePostgresDataRow(
  row: PostgresDataRow, columns: PostgresColumnDef[]): SqlValue[] {
  if (row.fields.length !== columns.length) {
    throw ArkDbError.protocol(
      'PostgreSQL DataRow field count ' + row.fields.length +
      ' does not match RowDescription column count ' + columns.length
    );
  }
  const decoded: SqlValue[] = [];
  for (let index = 0; index < columns.length; index += 1) {
    decoded.push(decodePostgresColumnValue(columns[index], row.fields[index]));
  }
  return decoded;
}

export function decodePostgresTextValue(
  typeOid: number, formatCode: number, raw: Uint8Array | null): SqlValue {
  if (raw === null) return null;
  if (!Number.isInteger(formatCode) || formatCode !== POSTGRES_TEXT_FORMAT_CODE) {
    throw ArkDbError.unsupported(
      'PostgreSQL non-text result format code ' + formatCode + ' is not supported');
  }
  const checkedOid = requirePostgresTypeOid(typeOid);
  if (checkedOid === POSTGRES_OID_BYTEA) return decodeBytea(raw);

  const text = decodeStrictUtf8Text(raw);
  switch (checkedOid) {
    case POSTGRES_OID_BOOL:
      if (text === 't') return true;
      if (text === 'f') return false;
      throw malformed('bool');
    case POSTGRES_OID_INT2:
      return Number(parseCanonicalInteger(text, true, -32768n, 32767n, 6, 'int2'));
    case POSTGRES_OID_INT4:
      return Number(parseCanonicalInteger(text, true, -2147483648n, 2147483647n, 11, 'int4'));
    case POSTGRES_OID_OID:
      return Number(parseCanonicalInteger(text, false, 0n, BigInt(MAX_POSTGRES_OID), 10, 'oid'));
    case POSTGRES_OID_INT8:
      return parseCanonicalInteger(text, true, MIN_INT8, MAX_INT8,
        text.length > 0 && text.charCodeAt(0) === 0x2d ? 20 : 19, 'int8');
    case POSTGRES_OID_NUMERIC:
      if (text === 'NaN' || text === 'Infinity' || text === '-Infinity' ||
        isCanonicalDecimalOrScientific(text)) {
        return text;
      }
      throw malformed('numeric');
    case POSTGRES_OID_FLOAT4:
      return decodeFloat(text, true);
    case POSTGRES_OID_FLOAT8:
      return decodeFloat(text, false);
    case POSTGRES_OID_UUID:
      return decodeUuid(text);
    case POSTGRES_OID_DATE:
    case POSTGRES_OID_TIME:
    case POSTGRES_OID_TIMETZ:
    case POSTGRES_OID_TIMESTAMP:
    case POSTGRES_OID_TIMESTAMPTZ:
    case POSTGRES_OID_INTERVAL:
      if (text.trim().length === 0) throw malformed('temporal');
      return text;
    default:
      return text;
  }
}

function parseCanonicalInteger(text: string, allowNegative: boolean, minimum: bigint,
  maximum: bigint, maximumLength: number, label: string): bigint {
  if (text === '0') return 0n;
  if (text.length === 0 || text.length > maximumLength) throw malformed(label);
  const negative = text.charCodeAt(0) === 0x2d;
  if (negative && !allowNegative) throw malformed(label);
  if (!isNonZeroDigits(text, negative ? 1 : 0)) throw malformed(label);
  let parsed: bigint;
  try {
    parsed = BigInt(text);
  } catch (_error) {
    throw malformed(label);
  }
  if (parsed < minimum || parsed > maximum) throw malformed(label);
  return parsed;
}

function decodeFloat(text: string, singlePrecision: boolean): SqlValue {
  if (text === 'NaN' || text === 'Infinity' || text === '-Infinity') return text;
  if (!isCanonicalDecimalOrScientific(text)) throw malformed('floating-point');
  const negative = text.charCodeAt(0) === 0x2d;
  const start = negative ? 1 : 0;
  let expIndex = text.indexOf('e', start);
  if (expIndex < 0) expIndex = text.indexOf('E', start);
  const mantissaEnd = expIndex < 0 ? text.length : expIndex;
  const maxIntDigits = singlePrecision ? 39 : 309;
  let seenDot = false;
  let fracTotal = 0;
  let sigTotal = 0;
  let lastNonZeroSig = 0;
  let prefix = '';
  for (let index = start; index < mantissaEnd; index += 1) {
    const code = text.charCodeAt(index);
    if (code === 0x2e) { seenDot = true; continue; }
    if (seenDot) fracTotal += 1;
    if (sigTotal === 0 && code === 0x30) continue;
    sigTotal += 1;
    if (sigTotal <= MAX_FLOAT64_SIG_DIGITS) prefix += String.fromCharCode(code);
    if (code !== 0x30) lastNonZeroSig = sigTotal;
  }
  if (lastNonZeroSig === 0) return packFloat64Bits(negative, 0, 0n);
  let exp10 = 0;
  if (expIndex >= 0) {
    let cursor = expIndex + 1;
    const expNeg = text.charCodeAt(cursor) === 0x2d;
    if (expNeg || text.charCodeAt(cursor) === 0x2b) cursor += 1;
    while (cursor < text.length && text.charCodeAt(cursor) === 0x30) cursor += 1;
    const maxAbsExp = mantissaEnd + maxIntDigits + 400;
    let magnitude = 0;
    while (cursor < text.length) {
      magnitude = magnitude * 10 + (text.charCodeAt(cursor) - 0x30);
      if (magnitude > maxAbsExp) {
        if (expNeg) return packFloat64Bits(negative, 0, 0n);
        throw malformed('floating-point');
      }
      cursor += 1;
    }
    exp10 = expNeg ? -magnitude : magnitude;
  }
  const intDigits = lastNonZeroSig + exp10 - fracTotal + (sigTotal - lastNonZeroSig);
  if (intDigits > maxIntDigits) throw malformed('floating-point');
  if (intDigits <= -325) return packFloat64Bits(negative, 0, 0n);
  if (singlePrecision && intDigits === 39) {
    const trimmed32 = prefix.slice(0, Math.min(lastNonZeroSig, 39));
    const scale32 = 39 - trimmed32.length;
    const intPart32 = scale32 > 0 ? BigInt(trimmed32) * (10n ** BigInt(scale32)) : BigInt(trimmed32);
    if (intPart32 >= BINARY32_OVERFLOW_THRESHOLD) throw malformed('floating-point');
  }
  const kept = lastNonZeroSig < prefix.length ? prefix.slice(0, lastNonZeroSig) : prefix;
  return decimalToBinary64(negative, kept, intDigits - kept.length, lastNonZeroSig > prefix.length);
}

function decimalToBinary64(negative: boolean, kept: string,
  p10: number, hasStickyTail: boolean): number {
  const digits = BigInt(kept);
  const numBase = p10 >= 0 ? digits * (5n ** BigInt(p10)) : digits;
  const denBase = p10 >= 0 ? 1n : (5n ** BigInt(-p10));
  const diff = bitLength(numBase) - bitLength(denBase);
  const lhs = diff < 0 ? (numBase << BigInt(-diff)) : numBase;
  const rhs = diff >= 0 ? (denBase << BigInt(diff)) : denBase;
  const floorLog2 = (lhs >= rhs ? diff : diff - 1) + p10;
  if (floorLog2 > 1023) throw malformed('floating-point');
  if (floorLog2 < -1075) return packFloat64Bits(negative, 0, 0n);
  let ulpExp = floorLog2 - 52;
  if (ulpExp < -1074) ulpExp = -1074;
  const shift = p10 - ulpExp;
  const num = shift >= 0 ? (numBase << BigInt(shift)) : numBase;
  const den = shift >= 0 ? denBase : (denBase << BigInt(-shift));
  let sig = num / den;
  const twiceRem = (num % den) << 1n;
  if (twiceRem > den || (twiceRem === den && (hasStickyTail || (sig & 1n) === 1n))) sig += 1n;
  if (sig === 0n) return packFloat64Bits(negative, 0, 0n);
  if (sig === FLOAT64_BIT53) { sig >>= 1n; ulpExp += 1; }
  if (ulpExp > 971) throw malformed('floating-point');
  return packFloat64Bits(negative, sig < FLOAT64_BIT52 ? 0 : ulpExp + 1075, sig & FLOAT64_FRAC_MASK);
}

function packFloat64Bits(negative: boolean, biasedExp: number, frac52: bigint): number {
  const high = ((negative ? 0x80000000 : 0) | (biasedExp << 20) | Number(frac52 >> 32n)) >>> 0;
  FLOAT64_VIEW.setUint32(0, high, false);
  FLOAT64_VIEW.setUint32(4, Number(frac52 & 0xffffffffn) >>> 0, false);
  return FLOAT64_VIEW.getFloat64(0, false);
}

function bitLength(value: bigint): number {
  const hex = value.toString(16);
  const code = hex.charCodeAt(0);
  const nibble = code <= 0x39 ? code - 0x30 : code - 0x61 + 10;
  const lead = nibble >= 8 ? 4 : nibble >= 4 ? 3 : nibble >= 2 ? 2 : 1;
  return (hex.length - 1) * 4 + lead;
}

function decodeUuid(text: string): string {
  if (text.length !== 36) throw malformed('uuid');
  for (let index = 0; index < 36; index += 1) {
    const code = text.charCodeAt(index);
    if (index === 8 || index === 13 || index === 18 || index === 23) {
      if (code !== 0x2d) throw malformed('uuid');
    } else if (!isLowerHexChar(code)) {
      throw malformed('uuid');
    }
  }
  return text;
}

function decodeBytea(raw: Uint8Array): Uint8Array {
  if (raw.length >= 2 && raw[0] === 0x5c && raw[1] === 0x78) {
    if ((raw.length & 1) !== 0) throw malformed('bytea hex');
    const output = new Uint8Array((raw.length - 2) >> 1);
    for (let index = 2, writeOffset = 0; index < raw.length; index += 2, writeOffset += 1) {
      const high = hexNibble(raw[index]);
      const low = hexNibble(raw[index + 1]);
      if (high < 0 || low < 0) throw malformed('bytea hex');
      output[writeOffset] = (high << 4) | low;
    }
    return output;
  }
  const scratch = new Uint8Array(raw.length);
  let writeOffset = 0;
  for (let index = 0; index < raw.length; index += 1) {
    const current = raw[index];
    if (current < 0x20 || current > 0x7e) throw malformed('bytea escape');
    if (current !== 0x5c) {
      scratch[writeOffset] = current;
    } else if (index + 1 < raw.length && raw[index + 1] === 0x5c) {
      scratch[writeOffset] = 0x5c;
      index += 1;
    } else if (index + 3 < raw.length && raw[index + 1] >= 0x30 && raw[index + 1] <= 0x33 &&
      isOctalDigit(raw[index + 2]) && isOctalDigit(raw[index + 3])) {
      scratch[writeOffset] = ((raw[index + 1] - 0x30) << 6) |
        ((raw[index + 2] - 0x30) << 3) | (raw[index + 3] - 0x30);
      index += 3;
    } else {
      throw malformed('bytea escape');
    }
    writeOffset += 1;
  }
  return writeOffset === scratch.length ? scratch : scratch.slice(0, writeOffset);
}

function decodeStrictUtf8Text(raw: Uint8Array): string {
  validateUtf8WithoutNul(raw);
  if (raw.length === 0) return '';
  try {
    return buffer.from(raw).toString('utf8');
  } catch (_error) {
    throw ArkDbError.protocol('PostgreSQL UTF-8 text decoding failed');
  }
}

function validateUtf8WithoutNul(raw: Uint8Array): void {
  let index = 0;
  while (index < raw.length) {
    const first = raw[index];
    if (first === 0x00) {
      throw ArkDbError.protocol('PostgreSQL text value contains an embedded NUL byte');
    }
    if (first <= 0x7f) index += 1;
    else if (first >= 0xc2 && first <= 0xdf) index = requireUtf8Tail(raw, index, 0x80, 0xbf, 0);
    else if (first === 0xe0) index = requireUtf8Tail(raw, index, 0xa0, 0xbf, 1);
    else if ((first >= 0xe1 && first <= 0xec) || (first >= 0xee && first <= 0xef)) {
      index = requireUtf8Tail(raw, index, 0x80, 0xbf, 1);
    } else if (first === 0xed) index = requireUtf8Tail(raw, index, 0x80, 0x9f, 1);
    else if (first === 0xf0) index = requireUtf8Tail(raw, index, 0x90, 0xbf, 2);
    else if (first >= 0xf1 && first <= 0xf3) index = requireUtf8Tail(raw, index, 0x80, 0xbf, 2);
    else if (first === 0xf4) index = requireUtf8Tail(raw, index, 0x80, 0x8f, 2);
    else throw ArkDbError.protocol('PostgreSQL text value contains invalid UTF-8');
  }
}

function requireUtf8Tail(raw: Uint8Array, index: number,
  secondMinimum: number, secondMaximum: number, extraContinuations: number): number {
  const nextEnd = index + 2 + extraContinuations;
  if (nextEnd > raw.length || raw[index + 1] < secondMinimum || raw[index + 1] > secondMaximum) {
    throw ArkDbError.protocol('PostgreSQL text value contains invalid UTF-8');
  }
  for (let offset = index + 2; offset < nextEnd; offset += 1) {
    if (raw[offset] < 0x80 || raw[offset] > 0xbf) {
      throw ArkDbError.protocol('PostgreSQL text value contains invalid UTF-8');
    }
  }
  return nextEnd;
}

function malformed(label: string): ArkDbError {
  return ArkDbError.protocol('Malformed PostgreSQL ' + label + ' text value');
}

function isNonZeroDigits(text: string, start: number): boolean {
  if (start >= text.length || text.charCodeAt(start) < 0x31 || text.charCodeAt(start) > 0x39) {
    return false;
  }
  for (let index = start + 1; index < text.length; index += 1) {
    if (!isAsciiDigit(text.charCodeAt(index))) return false;
  }
  return true;
}

function isCanonicalDecimalOrScientific(text: string): boolean {
  if (text.length === 0) return false;
  let index = text.charCodeAt(0) === 0x2d ? 1 : 0;
  if (index >= text.length) return false;
  const first = text.charCodeAt(index);
  if (first === 0x30) {
    index += 1;
    if (index < text.length && isAsciiDigit(text.charCodeAt(index))) return false;
  } else if (first >= 0x31 && first <= 0x39) {
    while (index < text.length && isAsciiDigit(text.charCodeAt(index))) index += 1;
  } else {
    return false;
  }
  if (index < text.length && text.charCodeAt(index) === 0x2e) {
    if (++index >= text.length || !isAsciiDigit(text.charCodeAt(index))) return false;
    while (index < text.length && isAsciiDigit(text.charCodeAt(index))) index += 1;
  }
  if (index < text.length && (text.charCodeAt(index) === 0x65 || text.charCodeAt(index) === 0x45)) {
    index += 1;
    if (index < text.length &&
      (text.charCodeAt(index) === 0x2b || text.charCodeAt(index) === 0x2d)) {
      index += 1;
    }
    if (index >= text.length || !isAsciiDigit(text.charCodeAt(index))) return false;
    while (index < text.length && isAsciiDigit(text.charCodeAt(index))) index += 1;
  }
  return index === text.length;
}

function isAsciiDigit(code: number): boolean { return code >= 0x30 && code <= 0x39; }
function isOctalDigit(code: number): boolean { return code >= 0x30 && code <= 0x37; }
function isLowerHexChar(code: number): boolean {
  return (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66);
}

function hexNibble(code: number): number {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  return code >= 0x41 && code <= 0x46 ? code - 0x41 + 10 : -1;
}
