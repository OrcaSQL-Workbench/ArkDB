import { ArkDbError, DbValueKind } from '@arkdb/core';

export const MAX_POSTGRES_OID: number = 4294967295;

export const POSTGRES_OID_BOOL: number = 16;
export const POSTGRES_OID_BYTEA: number = 17;
export const POSTGRES_OID_INT8: number = 20;
export const POSTGRES_OID_INT2: number = 21;
export const POSTGRES_OID_INT4: number = 23;
export const POSTGRES_OID_OID: number = 26;
export const POSTGRES_OID_FLOAT4: number = 700;
export const POSTGRES_OID_FLOAT8: number = 701;
export const POSTGRES_OID_DATE: number = 1082;
export const POSTGRES_OID_TIME: number = 1083;
export const POSTGRES_OID_TIMESTAMP: number = 1114;
export const POSTGRES_OID_TIMESTAMPTZ: number = 1184;
export const POSTGRES_OID_INTERVAL: number = 1186;
export const POSTGRES_OID_TIMETZ: number = 1266;
export const POSTGRES_OID_NUMERIC: number = 1700;
export const POSTGRES_OID_UUID: number = 2950;

export class PostgresTypeMetadata {
  readonly typeOid: number;
  readonly nativeTypeId: string;
  readonly nativeTypeName: string;
  readonly valueKind: DbValueKind;

  constructor(typeOid: number, nativeTypeName: string, valueKind: DbValueKind) {
    this.typeOid = typeOid;
    this.nativeTypeId = String(typeOid);
    this.nativeTypeName = nativeTypeName;
    this.valueKind = valueKind;
  }
}

const BUILTIN_POSTGRES_TYPES: Map<number, PostgresTypeMetadata> = buildCatalog();

export function requirePostgresTypeOid(typeOid: number): number {
  if (!Number.isInteger(typeOid) || typeOid < 0 || typeOid > MAX_POSTGRES_OID) {
    throw ArkDbError.protocol('Invalid PostgreSQL type OID');
  }
  return typeOid;
}

export function resolvePostgresTypeMetadata(typeOid: number): PostgresTypeMetadata {
  const checked = requirePostgresTypeOid(typeOid);
  const builtin = BUILTIN_POSTGRES_TYPES.get(checked);
  if (builtin !== undefined) return builtin;
  return new PostgresTypeMetadata(checked, '', DbValueKind.Unknown);
}

function buildCatalog(): Map<number, PostgresTypeMetadata> {
  const catalog = new Map<number, PostgresTypeMetadata>();
  const scalars: Array<[number, string, DbValueKind]> = [
    [POSTGRES_OID_BOOL, 'bool', DbValueKind.Boolean], [POSTGRES_OID_BYTEA, 'bytea', DbValueKind.Binary],
    [18, 'char', DbValueKind.Text], [19, 'name', DbValueKind.Text],
    [POSTGRES_OID_INT8, 'int8', DbValueKind.BigInteger], [POSTGRES_OID_INT2, 'int2', DbValueKind.Integer],
    [POSTGRES_OID_INT4, 'int4', DbValueKind.Integer], [25, 'text', DbValueKind.Text],
    [POSTGRES_OID_OID, 'oid', DbValueKind.Integer], [114, 'json', DbValueKind.Json],
    [142, 'xml', DbValueKind.Text], [POSTGRES_OID_FLOAT4, 'float4', DbValueKind.FloatingPoint],
    [POSTGRES_OID_FLOAT8, 'float8', DbValueKind.FloatingPoint], [790, 'money', DbValueKind.Text],
    [1042, 'bpchar', DbValueKind.Text], [1043, 'varchar', DbValueKind.Text],
    [POSTGRES_OID_DATE, 'date', DbValueKind.Date], [POSTGRES_OID_TIME, 'time', DbValueKind.Time],
    [POSTGRES_OID_TIMESTAMP, 'timestamp', DbValueKind.DateTime],
    [POSTGRES_OID_TIMESTAMPTZ, 'timestamptz', DbValueKind.DateTime],
    [POSTGRES_OID_INTERVAL, 'interval', DbValueKind.Text], [POSTGRES_OID_TIMETZ, 'timetz', DbValueKind.Time],
    [1560, 'bit', DbValueKind.Text], [1562, 'varbit', DbValueKind.Text],
    [POSTGRES_OID_NUMERIC, 'numeric', DbValueKind.Decimal], [POSTGRES_OID_UUID, 'uuid', DbValueKind.Uuid],
    [3802, 'jsonb', DbValueKind.Json]
  ];
  for (const entry of scalars) {
    catalog.set(entry[0], new PostgresTypeMetadata(entry[0], entry[1], entry[2]));
  }
  const arrays: Array<[number, string]> = [
    [143, '_xml'], [199, '_json'], [791, '_money'], [1000, '_bool'], [1001, '_bytea'],
    [1002, '_char'], [1003, '_name'], [1005, '_int2'], [1007, '_int4'], [1009, '_text'],
    [1014, '_bpchar'], [1015, '_varchar'], [1016, '_int8'], [1021, '_float4'],
    [1022, '_float8'], [1028, '_oid'], [1115, '_timestamp'], [1182, '_date'],
    [1183, '_time'], [1185, '_timestamptz'], [1187, '_interval'], [1231, '_numeric'],
    [1270, '_timetz'], [1561, '_bit'], [1563, '_varbit'], [2951, '_uuid'], [3807, '_jsonb']
  ];
  for (const entry of arrays) {
    catalog.set(entry[0], new PostgresTypeMetadata(entry[0], entry[1], DbValueKind.Array));
  }
  return catalog;
}
