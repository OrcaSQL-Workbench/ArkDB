import {
  ArkDbError, ConnectionState, QueryOptions
} from '@arkdb/core';
import {
  MySqlConnectionFeatures
} from '../api/MySqlConnectionFeatures';
import {
  MySqlTransactionRunnerHost
} from '../execution/MySqlTransactionRunner';
import {
  MySqlInsertRowsInput
} from '../execution/MySqlInsertRowsExecutor';
import { MySqlCommandScope } from '../execution/MySqlCommandGate';
import { MySqlBatchResult } from '../model/MySqlBatch';
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
  private executeInsertRows: (scope: MySqlCommandScope,
    input: MySqlInsertRowsInput) => Promise<MySqlBatchResult>;

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
    executeInsertRows: (scope: MySqlCommandScope,
      input: MySqlInsertRowsInput) => Promise<MySqlBatchResult>) {
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

  insertRows(scope: MySqlCommandScope,
    input: MySqlInsertRowsInput): Promise<MySqlBatchResult> {
    return this.executeInsertRows(scope, input);
  }
}
