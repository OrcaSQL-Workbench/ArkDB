import { ColumnDef, SqlValue } from './QueryResult';

export const MAX_STATEMENT_TIMEOUT_MS: number = 24 * 60 * 60 * 1000;
export const MAX_QUERY_DRAIN_TIME_MS: number = 60 * 1000;

export class DatabaseSessionStatus {
  known?: boolean = false;
  autocommit: boolean = false;
  inTransaction: boolean = false;

  clone(): DatabaseSessionStatus {
    const status = new DatabaseSessionStatus();
    status.known = this.known;
    status.autocommit = this.autocommit;
    status.inTransaction = this.inTransaction;
    return status;
  }
}

export class QueryOptions {
  statementTimeoutMs: number = 0;
  maxRows: number = 0;
  maxChunkRows: number = 200;
  maxChunkBytes: number = 256 * 1024;
  maxResultBytes: number = 32 * 1024 * 1024;
  maxResultSets: number = 64;
  maxDrainBytes: number = 32 * 1024 * 1024;
  maxDrainTimeMs: number = 5000;

  clone(): QueryOptions {
    const options = new QueryOptions();
    options.statementTimeoutMs = this.statementTimeoutMs;
    options.maxRows = this.maxRows;
    options.maxChunkRows = this.maxChunkRows;
    options.maxChunkBytes = this.maxChunkBytes;
    options.maxResultBytes = this.maxResultBytes;
    options.maxResultSets = this.maxResultSets;
    options.maxDrainBytes = this.maxDrainBytes;
    options.maxDrainTimeMs = this.maxDrainTimeMs;
    return options;
  }
}

export class QueryResultMeta {
  resultIndex: number = 0;
  columns: ColumnDef[] = [];
  hasRows: boolean = false;
}

export class QueryRowChunk {
  resultIndex: number = 0;
  rowOffset: number = 0;
  encodedBytes: number = 0;
  rows: SqlValue[][] = [];
}

export class QueryTruncation {
  resultIndex: number = 0;
  loadedRowCount: number = 0;
  loadedBytes: number = 0;
  reason: string = '';
}

export class QueryResultSummary {
  resultIndex: number = 0;
  rowCount: number = 0;
  rowCountKnown: boolean = true;
  loadedRowCount: number = 0;
  loadedBytes: number = 0;
  affectedRows: number = 0;
  lastInsertId?: bigint;
  warningCount?: number;
  truncated: boolean = false;
  truncationReason: string = '';
  statusKnown: boolean = false;
  status: DatabaseSessionStatus = new DatabaseSessionStatus();
}

export class QueryExecutionSummary {
  resultSetCount: number = 0;
  rowCount: number = 0;
  rowCountKnown: boolean = true;
  loadedRowCount: number = 0;
  loadedBytes: number = 0;
  executionTimeMs: number = 0;
  statusKnown: boolean = false;
  truncationInterrupted: boolean = false;
  synchronizationDeadlineMs: number = -1;
  status: DatabaseSessionStatus = new DatabaseSessionStatus();
}

export interface QueryResultSink {
  onResultStart(meta: QueryResultMeta): Promise<void>;
  onRows(chunk: QueryRowChunk): Promise<void>;
  onTruncation?(truncation: QueryTruncation): Promise<boolean>;
  onResultEnd(summary: QueryResultSummary): Promise<void>;
}

export function estimateSqlValueBytes(value: SqlValue): number {
  if (value === null) {
    return 1;
  }
  if (typeof value === 'string') {
    return value.length * 2;
  }
  if (typeof value === 'number') {
    return 8;
  }
  if (typeof value === 'boolean') {
    return 1;
  }
  if (typeof value === 'bigint') {
    return value.toString().length * 2;
  }
  return value.length;
}

export function estimateSqlRowBytes(row: SqlValue[]): number {
  let bytes = 0;
  for (const value of row) {
    bytes += estimateSqlValueBytes(value);
  }
  return bytes;
}

export function estimateSqlRowsBytes(rows: SqlValue[][]): number {
  let bytes = 0;
  for (const row of rows) {
    bytes += estimateSqlRowBytes(row);
  }
  return bytes;
}