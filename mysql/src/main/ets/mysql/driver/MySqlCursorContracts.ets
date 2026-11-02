import { MySqlParameter } from '../model/MySqlParameter';
import { MySqlColumnDef, MySqlValue } from '../model/MySqlQueryResult';
import { MySqlCursorOptions } from '../model/MySqlCursorOptions';

export interface MySqlCursorExecutor {
  open(sql: string, parameters: MySqlParameter[],
    options?: MySqlCursorOptions): Promise<MySqlCursor>;
}

export interface MySqlCursor {
  readonly columns: MySqlColumnDef[];
  readonly done: boolean;
  fetch(): Promise<MySqlValue[][]>;
  close(): Promise<void>;
}
