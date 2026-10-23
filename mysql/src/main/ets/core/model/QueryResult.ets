/**
 * A decoded cell value (text protocol). Binary/BLOB columns decode to Uint8Array,
 * BIGINT to bigint, DECIMAL/dates stay strings to preserve precision, NULL is null.
 */
export type SqlValue = string | number | bigint | Uint8Array | null;

export enum DbValueKind {
  Unknown = 'unknown',
  Boolean = 'boolean',
  Integer = 'integer',
  BigInteger = 'big_integer',
  Decimal = 'decimal',
  FloatingPoint = 'floating_point',
  Text = 'text',
  Binary = 'binary',
  Date = 'date',
  Time = 'time',
  DateTime = 'date_time',
  Json = 'json',
  Uuid = 'uuid',
  Array = 'array'
}

/** Column metadata from a result set's column-definition packets. */
export class ColumnDef {
  name: string = '';
  sourceSchema: string = '';
  sourceTable: string = '';
  nativeTypeId: string = '';
  nativeTypeName: string = '';
  valueKind: DbValueKind = DbValueKind.Unknown;
  nullable: boolean = true;
  table: string = '';
  type: number = 0;                // MySQL column type code
  charset: number = 0;             // collation id
  columnLength: number = 0;
  flags: number = 0;
  decimals: number = 0;
}

/** Outcome of a single statement. */
export class QueryResult {
  columns: ColumnDef[] = [];
  rows: SqlValue[][] = [];
  affectedRows: number = 0;
  lastInsertId: bigint = 0n;
  warningCount: number = 0;
  loadedBytes: number = 0;
  executionTimeMs: number = 0;
  autocommit: boolean = true;
  inTransaction: boolean = false;
  truncated: boolean = false;
  truncationReason: string = '';
  additionalResults: QueryResult[] = [];
}
