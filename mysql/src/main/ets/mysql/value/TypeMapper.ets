import { ColumnType, Collation } from '../protocol/Constants';
import { ColumnDef, SqlValue } from '../../core/model/QueryResult';
import { utf8Decode } from '../protocol/Charsets';

/**
 * Map a text-protocol field value (raw bytes, or null) to a typed SqlValue.
 * Numbers → number, BIGINT → bigint, DECIMAL/dates → string (precision/TZ-safe),
 * binary/BLOB → Uint8Array, text → decoded string, NULL → null.
 */
export function mapTextValue(col: ColumnDef, raw: Uint8Array | null): SqlValue {
  if (raw === null) {
    return null;
  }
  const t = col.type;
  if (t === ColumnType.BIT || (col.charset === Collation.BINARY && !isDecodedScalar(t))) {
    return raw;
  }
  return mapDecodedTextValue(col, utf8Decode(raw));
}

export function mapDecodedTextValue(col: ColumnDef, text: string): SqlValue {
  const t = col.type;
  if (t === ColumnType.TINY || t === ColumnType.SHORT || t === ColumnType.LONG
    || t === ColumnType.INT24 || t === ColumnType.YEAR) {
    return Number(text);
  }
  if (t === ColumnType.LONGLONG) {
    return BigInt(text);
  }
  if (t === ColumnType.FLOAT || t === ColumnType.DOUBLE) {
    return Number(text);
  }
  if (t === ColumnType.DECIMAL || t === ColumnType.NEWDECIMAL) {
    return text;
  }
  if (t === ColumnType.DATE || t === ColumnType.DATETIME || t === ColumnType.TIMESTAMP
    || t === ColumnType.TIME || t === ColumnType.NEWDATE) {
    return text;
  }
  return text;
}

function isDecodedScalar(type: number): boolean {
  return type === ColumnType.TINY || type === ColumnType.SHORT || type === ColumnType.LONG ||
    type === ColumnType.INT24 || type === ColumnType.YEAR || type === ColumnType.LONGLONG ||
    type === ColumnType.FLOAT || type === ColumnType.DOUBLE || type === ColumnType.DECIMAL ||
    type === ColumnType.NEWDECIMAL || type === ColumnType.DATE || type === ColumnType.DATETIME ||
    type === ColumnType.TIMESTAMP || type === ColumnType.TIME || type === ColumnType.NEWDATE;
}
