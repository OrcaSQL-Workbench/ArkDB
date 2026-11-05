import {
  ArkDbError, ConnectionState, QueryOptions
} from '@arkdb/core';
import {
  MySqlConnectionFeatures
} from '../api/MySqlConnectionFeatures';
import {
  MySqlInsertRowsSnapshot
} from '../api/MySqlFeatureContracts';
import {
  MySqlTransactionRunnerHost
} from '../features/transaction/MySqlTransactionRunner';
import { MySqlCommandScope } from '../execution/MySqlCommandGate';
import { MySqlBatchResult } from '../features/batch/MySqlBatch';
import { MySqlInsertRowsOptions } from '../model/MySqlInsertRows';
import { MySqlParameter } from '../features/prepared/MySqlParameter';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary,
  MySqlQueryResultSink
} from '../model/MySqlQueryStream';
import { MySqlServerInfo } from '../model/MySqlServerInfo';

export class MySqlTransactionConnectionHost
  implements MySqlTransactionRunnerHost {
  private readState: () => ConnectionState;
  private readFeatures: () => MySqlConnectionFeatures;
  private readServerInfo: () => MySqlServerInfo;
  private readSessionStatus: () => MySqlDatabaseSessionStatus;
  private reserve: () => MySqlCommandScope;
  private settle: (scope: MySqlCommandScope) => Promise<ArkDbError[]>;
  private finish: (scope: MySqlCommandScope) => Promise<ArkDbError[]>;
  private refreshStatus: (scope: MySqlCommandScope) => Promise<void>;
  private retire: (scope: MySqlCommandScope,
    error: ArkDbError) => Promise<void>;
  private executeQuery: (scope: MySqlCommandScope,
    sql: string) => Promise<MySqlQueryResult>;
  private executeStream: (scope: MySqlCommandScope, sql: string,
    options: QueryOptions,
    sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>;
  private snapshotInsertRowsInput: (tableParts: string[],
    columns: string[], rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions) => MySqlInsertRowsSnapshot;
  private executeInsertRows: (scope: MySqlCommandScope,
    input: MySqlInsertRowsSnapshot) => Promise<MySqlBatchResult>;

  constructor(readState: () => ConnectionState,
    readFeatures: () => MySqlConnectionFeatures,
    readServerInfo: () => MySqlServerInfo,
    readSessionStatus: () => MySqlDatabaseSessionStatus,
    reserve: () => MySqlCommandScope,
    settle: (scope: MySqlCommandScope) => Promise<ArkDbError[]>,
    finish: (scope: MySqlCommandScope) => Promise<ArkDbError[]>,
    refreshStatus: (scope: MySqlCommandScope) => Promise<void>,
    retire: (scope: MySqlCommandScope, error: ArkDbError) => Promise<void>,
    executeQuery: (scope: MySqlCommandScope,
      sql: string) => Promise<MySqlQueryResult>,
    executeStream: (scope: MySqlCommandScope, sql: string,
      options: QueryOptions,
      sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>,
    snapshotInsertRowsInput: (tableParts: string[], columns: string[],
      rows: MySqlParameter[][],
      options?: MySqlInsertRowsOptions) => MySqlInsertRowsSnapshot,
    executeInsertRows: (scope: MySqlCommandScope,
      input: MySqlInsertRowsSnapshot) => Promise<MySqlBatchResult>) {
    this.readState = readState;
    this.readFeatures = readFeatures;
    this.readServerInfo = readServerInfo;
    this.readSessionStatus = readSessionStatus;
    this.reserve = reserve;
    this.settle = settle;
    this.finish = finish;
    this.refreshStatus = refreshStatus;
    this.retire = retire;
    this.executeQuery = executeQuery;
    this.executeStream = executeStream;
    this.snapshotInsertRowsInput = snapshotInsertRowsInput;
    this.executeInsertRows = executeInsertRows;
  }

  get state(): ConnectionState { return this.readState(); }
  get mysqlFeatures(): MySqlConnectionFeatures { return this.readFeatures(); }
  get serverInfo(): MySqlServerInfo { return this.readServerInfo(); }
  get sessionStatus(): MySqlDatabaseSessionStatus {
    return this.readSessionStatus();
  }

  reserveTransaction(): MySqlCommandScope { return this.reserve(); }

  settleTransaction(scope: MySqlCommandScope): Promise<ArkDbError[]> {
    return this.settle(scope);
  }

  finishTransaction(scope: MySqlCommandScope): Promise<ArkDbError[]> {
    return this.finish(scope);
  }

  refreshTransactionStatus(scope: MySqlCommandScope): Promise<void> {
    return this.refreshStatus(scope);
  }

  retireTransaction(scope: MySqlCommandScope,
    error: ArkDbError): Promise<void> {
    return this.retire(scope, error);
  }

  query(scope: MySqlCommandScope, sql: string): Promise<MySqlQueryResult> {
    return this.executeQuery(scope, sql);
  }

  queryStream(scope: MySqlCommandScope, sql: string, options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.executeStream(scope, sql, options, sink);
  }

  snapshotInsertRows(tableParts: string[], columns: string[],
    rows: MySqlParameter[][],
    options?: MySqlInsertRowsOptions): MySqlInsertRowsSnapshot {
    return this.snapshotInsertRowsInput(
      tableParts, columns, rows, options);
  }

  insertRows(scope: MySqlCommandScope,
    input: MySqlInsertRowsSnapshot): Promise<MySqlBatchResult> {
    return this.executeInsertRows(scope, input);
  }
}
