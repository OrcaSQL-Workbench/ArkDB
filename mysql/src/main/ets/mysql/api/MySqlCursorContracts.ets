import { MySqlParameter } from '../features/prepared/MySqlParameter';
import { MySqlColumnDef, MySqlValue } from '../model/MySqlQueryResult';
import { MySqlCursorOptions } from '../features/cursor/MySqlCursorOptions';

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
