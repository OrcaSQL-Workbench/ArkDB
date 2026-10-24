import { ArkDbError, ColumnDef, QueryResult, SqlValue as CoreSqlValue } from '@arkdb/core';

export type MySqlValue = string | number | bigint | Uint8Array | null;

export function mysqlValues(values: CoreSqlValue[]): MySqlValue[] {
  const row: MySqlValue[] = [];
  for (const value of values) {
    if (typeof value === 'boolean') {
      throw ArkDbError.protocol('The MySQL text decoder returned a non-MySQL scalar.');
    }
    row.push(value);
  }
  return row;
}

export class MySqlColumnDef extends ColumnDef {
  table: string = '';
  type: number = 0;
  charset: number = 0;
  columnLength: number = 0;
  flags: number = 0;
  decimals: number = 0;
}

export class MySqlQueryResult extends QueryResult {
  columns: MySqlColumnDef[] = [];
  rows: MySqlValue[][] = [];
  additionalResults: MySqlQueryResult[] = [];
  lastInsertId: bigint = 0n;
  warningCount: number = 0;
  autocommit: boolean = true;
}
