import { MySqlParameter } from '../model/MySqlParameter';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import { MySqlDeadlineOptions } from '../model/MySqlDeadlineOptions';

export interface MySqlDeadlineExecutor {
  query(sql: string, options?: MySqlDeadlineOptions): Promise<MySqlQueryResult>;
  execute(sql: string, parameters: MySqlParameter[],
    options?: MySqlDeadlineOptions): Promise<MySqlQueryResult>;
}

type MySqlDeadlineQueryRunner =
  (sql: string, options: MySqlDeadlineOptions) => Promise<MySqlQueryResult>;
type MySqlDeadlineExecuteRunner =
  (sql: string, parameters: MySqlParameter[],
    options: MySqlDeadlineOptions) => Promise<MySqlQueryResult>;

export class MySqlConnectionDeadlineExecutor implements MySqlDeadlineExecutor {
  private queryRunner: MySqlDeadlineQueryRunner;
  private executeRunner: MySqlDeadlineExecuteRunner;

  constructor(query: MySqlDeadlineQueryRunner, execute: MySqlDeadlineExecuteRunner) {
    this.queryRunner = query;
    this.executeRunner = execute;
  }

  async query(sql: string, options?: MySqlDeadlineOptions): Promise<MySqlQueryResult> {
    return this.queryRunner(sql, deadlineOptions(options));
  }

  async execute(sql: string, parameters: MySqlParameter[],
    options?: MySqlDeadlineOptions): Promise<MySqlQueryResult> {
    return this.executeRunner(sql, parameters.slice(), deadlineOptions(options));
  }
}

function deadlineOptions(options?: MySqlDeadlineOptions): MySqlDeadlineOptions {
  const snapshot = options === undefined ? new MySqlDeadlineOptions() : options.clone();
  const errors = snapshot.validate();
  if (errors.length > 0) throw errors[0];
  return snapshot;
}
