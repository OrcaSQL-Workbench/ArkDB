import {
  ArkDbError, ConnectionState, DatabaseContext, DriverCapabilities, CatalogInfo, SchemaInfo,
  DbObjectKind, DbObjectInfo, ColumnInfo, IndexInfo, ForeignKeyInfo, QueryOptions,
  DbConnection as CoreDbConnection
} from '@arkdb/core';
import { ConnectionConfig } from '../model/ConnectionConfig';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import { MySqlServerInfo } from '../model/MySqlServerInfo';
import {
  MySqlDatabaseSessionStatus, MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';
import { MySqlMetricsProvider } from '../metrics/MySqlMetricsProvider';
import { MySqlConnectionFeatures } from './MySqlConnectionFeatures';

export class MySqlDriverCapabilities extends DriverCapabilities {
  supportsSchemas: boolean = true;
  supportsTransactions: boolean = true;
}

export interface MySqlDbConnection extends CoreDbConnection {
  connect(): Promise<void>;
  ping(): Promise<void>;
  query(sql: string): Promise<MySqlQueryResult>;
  queryStream(sql: string, options: QueryOptions, sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
  changeContext(context: DatabaseContext): Promise<void>;
  setAutocommit(enabled: boolean): Promise<MySqlDatabaseSessionStatus>;
  commit(): Promise<MySqlDatabaseSessionStatus>;
  rollback(): Promise<MySqlDatabaseSessionStatus>;
  close(): Promise<void>;
  readonly state: ConnectionState;
  readonly serverInfo: MySqlServerInfo;
  readonly sessionStatus: MySqlDatabaseSessionStatus;
  readonly mysqlFeatures?: MySqlConnectionFeatures;
}

export interface MySqlDbExecutionController {
  cancel(connectionHandle: string): Promise<void>;
  isInterruptionError(error: ArkDbError): boolean;
}

export interface MySqlMetadataProviderContract {
  listCatalogs(): Promise<CatalogInfo[]>;
  listSchemas(catalog: string): Promise<SchemaInfo[]>;
  listObjects(context: DatabaseContext, kind: DbObjectKind): Promise<DbObjectInfo[]>;
  listColumns(context: DatabaseContext, objectName: string): Promise<ColumnInfo[]>;
  listIndexes(context: DatabaseContext, objectName: string): Promise<IndexInfo[]>;
  listForeignKeys(context: DatabaseContext, objectName: string): Promise<ForeignKeyInfo[]>;
}

export interface MySqlDbDriverFactory {
  readonly driverId: string;
  readonly capabilities: MySqlDriverCapabilities;
  createConnection(config: ConnectionConfig, password: string): MySqlDbConnection;
  createMetadataProvider(connection: MySqlDbConnection): MySqlMetadataProviderContract;
  createExecutionController(controlConnection: MySqlDbConnection): MySqlDbExecutionController;
  createServerMetricsProvider(connection: MySqlDbConnection): MySqlMetricsProvider;
}
