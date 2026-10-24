import { PacketReader } from '../protocol/PacketReader';
import { MySqlColumnDef as ColumnDef } from '../model/MySqlQueryResult';
import { DbValueKind } from '@arkdb/core';
import { ColumnType, Collation, FieldFlag } from '../protocol/Constants';

/** Parse a ColumnDefinition41 packet into a ColumnDef. */
export function parseColumnDef(payload: Uint8Array): ColumnDef {
  const r = new PacketReader(payload);
  r.readLenEncString(); // catalog ("def")
  const schema = r.readLenEncString();
  const table = r.readLenEncString();
  r.readLenEncString(); // org_table
  const name = r.readLenEncString();
  r.readLenEncString(); // org_name
  r.readLenEncInt();    // length of the fixed-length fields (0x0c)
  const charset = r.readUInt16();
  const columnLength = r.readUInt32();
  const type = r.readUInt8();
  const flags = r.readUInt16();
  const decimals = r.readUInt8();
  // trailing 2 filler bytes are ignored

  const col = new ColumnDef();
  col.name = name !== null ? name : '';
  col.table = table !== null ? table : '';
  col.sourceSchema = schema !== null ? schema : '';
  col.sourceCatalog = col.sourceSchema;
  col.sourceTable = col.table;
  col.nativeTypeId = String(type);
  col.nativeTypeName = mysqlTypeName(type);
  col.valueKind = mysqlValueKind(type, charset);
  col.nullable = (flags & FieldFlag.NOT_NULL) === 0;
  col.type = type;
  col.charset = charset;
  col.columnLength = columnLength;
  col.flags = flags;
  col.decimals = decimals;
  return col;
}

function mysqlTypeName(type: number): string {
  if (type === ColumnType.TINY) return 'TINYINT';
  if (type === ColumnType.SHORT) return 'SMALLINT';
  if (type === ColumnType.LONG) return 'INT';
  if (type === ColumnType.LONGLONG) return 'BIGINT';
  if (type === ColumnType.FLOAT) return 'FLOAT';
  if (type === ColumnType.DOUBLE) return 'DOUBLE';
  if (type === ColumnType.DECIMAL || type === ColumnType.NEWDECIMAL) return 'DECIMAL';
  if (type === ColumnType.DATE || type === ColumnType.NEWDATE) return 'DATE';
  if (type === ColumnType.TIME) return 'TIME';
  if (type === ColumnType.DATETIME) return 'DATETIME';
  if (type === ColumnType.TIMESTAMP) return 'TIMESTAMP';
  if (type === ColumnType.JSON) return 'JSON';
  if (type === ColumnType.BIT) return 'BIT';
  if (type === ColumnType.BLOB || type === ColumnType.TINY_BLOB || type === ColumnType.MEDIUM_BLOB ||
    type === ColumnType.LONG_BLOB) return 'BLOB';
  if (type === ColumnType.VARCHAR || type === ColumnType.VAR_STRING || type === ColumnType.STRING) return 'TEXT';
  return 'UNKNOWN';
}

function mysqlValueKind(type: number, charset: number): DbValueKind {
  if (type === ColumnType.TINY || type === ColumnType.SHORT || type === ColumnType.LONG ||
    type === ColumnType.INT24 || type === ColumnType.YEAR) return DbValueKind.Integer;
  if (type === ColumnType.LONGLONG) return DbValueKind.BigInteger;
  if (type === ColumnType.FLOAT || type === ColumnType.DOUBLE) return DbValueKind.FloatingPoint;
  if (type === ColumnType.DECIMAL || type === ColumnType.NEWDECIMAL) return DbValueKind.Decimal;
  if (type === ColumnType.DATE || type === ColumnType.NEWDATE) return DbValueKind.Date;
  if (type === ColumnType.TIME) return DbValueKind.Time;
  if (type === ColumnType.DATETIME || type === ColumnType.TIMESTAMP) return DbValueKind.DateTime;
  if (type === ColumnType.JSON) return DbValueKind.Json;
  if (type === ColumnType.BIT || charset === Collation.BINARY) return DbValueKind.Binary;
  return DbValueKind.Text;
}
