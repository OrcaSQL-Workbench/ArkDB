import { MySqlColumnDef, MySqlQueryResult, MySqlValue } from '../model/MySqlQueryResult';

export function mapMySqlRows<T>(result: MySqlQueryResult,
  mapper: (row: MySqlValue[], columns: MySqlColumnDef[], rowIndex: number) => T): T[] {
  const mapped: T[] = [];
  for (let rowIndex = 0; rowIndex < result.rows.length; rowIndex += 1) {
    mapped.push(mapper(result.rows[rowIndex], result.columns, rowIndex));
  }
  return mapped;
}
