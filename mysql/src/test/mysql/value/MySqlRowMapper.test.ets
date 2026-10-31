import { describe, expect, it } from '@ohos/hypium';
import {
  MySqlColumnDef, MySqlQueryResult, MySqlValue
} from '../../../main/ets/mysql/model/MySqlQueryResult';
import { ColumnType } from '../../../main/ets/mysql/protocol/Constants';
import { mapMySqlRows } from '../../../main/ets/mysql/value/MySqlRowMapper';

export default function mySqlRowMapperTest(): void {
  describe('MySqlRowMapper', () => {
    it('doesNotCoerceDecimalOrTemporalByDefault', 0, () => {
      const result = new MySqlQueryResult();
      result.columns.push(
        column('amount', ColumnType.NEWDECIMAL),
        column('created_date', ColumnType.DATE),
        column('elapsed', ColumnType.TIME),
        column('created_at', ColumnType.DATETIME)
      );
      result.rows.push([
        '12345678901234567890.1234567890',
        '2026-10-30',
        '-838:59:59.000001',
        '2026-10-30 23:02:24.123456'
      ]);

      const mapped = mapMySqlRows<string[]>(result,
        (row: MySqlValue[], columns: MySqlColumnDef[], rowIndex: number): string[] => {
          expect(rowIndex).assertEqual(0);
          expect(columns === result.columns).assertTrue();
          return [
            row[0] as string,
            row[1] as string,
            row[2] as string,
            row[3] as string
          ];
        });

      expect(mapped.length).assertEqual(1);
      expect(mapped[0][0]).assertEqual('12345678901234567890.1234567890');
      expect(mapped[0][1]).assertEqual('2026-10-30');
      expect(mapped[0][2]).assertEqual('-838:59:59.000001');
      expect(mapped[0][3]).assertEqual('2026-10-30 23:02:24.123456');
    });

    it('keepsJsonNullSqlNullBytesAndDuplicateColumnsPositional', 0, () => {
      const result = new MySqlQueryResult();
      result.columns.push(
        column('payload', ColumnType.JSON),
        column('payload', ColumnType.NULL),
        column('payload', ColumnType.BLOB),
        column('duplicate_name', ColumnType.VAR_STRING),
        column('duplicate_name', ColumnType.VAR_STRING)
      );
      const bytes = new Uint8Array([0, 127, 255]);
      result.rows.push(['null', null, bytes, 'first', 'second']);
      let observedRow: MySqlValue[] | null = null;
      let observedColumns: MySqlColumnDef[] | null = null;

      const mapped = mapMySqlRows<string>(result,
        (row: MySqlValue[], columns: MySqlColumnDef[], rowIndex: number): string => {
          observedRow = row;
          observedColumns = columns;
          expect(rowIndex).assertEqual(0);
          expect(row[0]).assertEqual('null');
          expect(row[1] === null).assertTrue();
          expect(row[2] === bytes).assertTrue();
          expect(columns[3].name).assertEqual('duplicate_name');
          expect(columns[4].name).assertEqual('duplicate_name');
          return (row[3] as string) + '|' + (row[4] as string);
        });

      expect(mapped.length).assertEqual(1);
      expect(mapped[0]).assertEqual('first|second');
      expect(observedRow === result.rows[0]).assertTrue();
      expect(observedColumns === result.columns).assertTrue();
      expect((result.rows[0][2] as Uint8Array)[2]).assertEqual(255);
    });

    it('propagatesMapperFailureIdentityWithoutReturningPartialRows', 0, () => {
      const result = new MySqlQueryResult();
      result.columns.push(column('value', ColumnType.LONG));
      result.rows.push([1], [2], [3]);
      const failure = new Error('mapper-failure');
      let calls = 0;
      let returned: number[] | null = null;
      let caught: Object | null = null;

      try {
        returned = mapMySqlRows<number>(result,
          (row: MySqlValue[], columns: MySqlColumnDef[], rowIndex: number): number => {
            calls += 1;
            if (rowIndex === 1) throw failure;
            return row[0] as number;
          });
      } catch (error) {
        caught = error as Object;
      }

      expect(returned === null).assertTrue();
      expect(caught === failure).assertTrue();
      expect(calls).assertEqual(2);
    });
  });
}

function column(name: string, type: number): MySqlColumnDef {
  const value = new MySqlColumnDef();
  value.name = name;
  value.type = type;
  return value;
}
