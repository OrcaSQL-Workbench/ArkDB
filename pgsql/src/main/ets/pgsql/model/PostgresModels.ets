import {
  ArkDbError, ColumnDef, DatabaseSessionStatus, QueryResult, ServerInfo
} from '@arkdb/core';

export enum PostgresTransactionState {
  Idle = 'idle',
  InTransaction = 'in_transaction',
  FailedTransaction = 'failed_transaction'
}

export class PostgresColumnDef extends ColumnDef {
  tableOid: number = 0;
  columnAttributeNumber: number = 0;
  typeOid: number = 0;
  typeSize: number = 0;
  typeModifier: number = 0;
  formatCode: number = 0;
}

export class PostgresQueryResult extends QueryResult {
  columns: PostgresColumnDef[] = [];
  additionalResults: PostgresQueryResult[] = [];
  commandTag: string = '';
  affectedRowsExact?: bigint;
  rowCountExact?: bigint;
}

export class PostgresServerInfo extends ServerInfo {
  backendProcessId: number = 0;
  protocolMajor: number = 3;
  protocolMinor: number = 0;
  serverEncoding: string = '';
  integerDatetimes: boolean = true;
  dateStyle: string = '';
  timeZone: string = '';
}

export class PostgresDatabaseSessionStatus extends DatabaseSessionStatus {
  transactionState: PostgresTransactionState = PostgresTransactionState.Idle;

  clone(): PostgresDatabaseSessionStatus {
    const status = new PostgresDatabaseSessionStatus();
    status.known = this.known;
    status.autocommit = this.autocommit;
    status.inTransaction = this.inTransaction;
    status.transactionState = this.transactionState;
    return status;
  }
}

export class PostgresError extends ArkDbError {
  severity: string = '';
  localizedSeverity?: string;
  detail?: string;
  hint?: string;
  position?: number;
  internalPosition?: number;
  internalQuery?: string;
  where?: string;
  schemaName?: string;
  tableName?: string;
  columnName?: string;
  dataTypeName?: string;
  constraintName?: string;
  sourceFile?: string;
  sourceLine?: number;
  sourceRoutine?: string;
}
