/**
 * Lossless scalar values. Adapters retain exact decimals/temporal/structured text
 * as strings when there is no portable scalar representation.
 */
export type SqlValue = string | number | bigint | boolean | Uint8Array | null;

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

/** Portable column metadata. Adapters may extend this class with native fields. */
export class ColumnDef {
  name: string = '';
  sourceCatalog?: string = '';
  sourceSchema: string = '';
  sourceTable: string = '';
  nativeTypeId: string = '';
  nativeTypeName: string = '';
  valueKind: DbValueKind = DbValueKind.Unknown;
  nullable: boolean = true;
}

/** Outcome of a single statement. */
export class QueryResult {
  columns: ColumnDef[] = [];
  rows: SqlValue[][] = [];
  affectedRows: number = 0;
  lastInsertId?: bigint;
  warningCount?: number;
  loadedBytes: number = 0;
  executionTimeMs: number = 0;
  statusKnown?: boolean = false;
  autocommit: boolean = false;
  inTransaction: boolean = false;
  truncated: boolean = false;
  truncationReason: string = '';
  additionalResults: QueryResult[] = [];
}
