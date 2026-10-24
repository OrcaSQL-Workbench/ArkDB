import { describe, it, expect } from '@ohos/hypium';
import {
  DbConnection, DatabaseContext, ArkDbError, ArkDbErrorKind, DatabaseSessionStatus, QueryExecutionSummary,
  QueryOptions, QueryResultSink, ConnectionState, DbObjectKind
} from '@arkdb/core';
import { MySqlQueryResult as QueryResult } from '../../../main/ets/mysql/model/MySqlQueryResult';
import { MySqlServerInfo as ServerInfo } from '../../../main/ets/mysql/model/MySqlServerInfo';
import { MySqlMetadataProvider } from '../../../main/ets/mysql/metadata/MySqlMetadataProvider';
import { mysqlMetadataLiteral } from '../../../main/ets/mysql/metadata/MySqlMetadataSql';
import { utf8Encode } from '../../../main/ets/mysql/protocol/Charsets';

class MetadataConnection implements DbConnection {
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();
  readonly state: ConnectionState = ConnectionState.Ready;
  readonly result: QueryResult = new QueryResult();
  readonly queries: string[] = [];

  async connect(): Promise<void> {}

  async ping(): Promise<void> {}

  async query(sql: string): Promise<QueryResult> {
    this.queries.push(sql);
    return this.result;
  }

  async queryStream(sql: string, options: QueryOptions,
    sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return new QueryExecutionSummary();
  }

  async changeContext(context: DatabaseContext): Promise<void> {}

  async setAutocommit(enabled: boolean): Promise<DatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async commit(): Promise<DatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async rollback(): Promise<DatabaseSessionStatus> {
    return this.sessionStatus;
  }

  async close(): Promise<void> {}
}

export default function mySqlMetadataProviderTest() {
  describe('MySqlMetadataProvider', () => {
    it('mapsCatalogAndSchemaAliasesConsistentlyAndRejectsContradictions', 0, async () => {
      const connection = new MetadataConnection();
      const provider = new MySqlMetadataProvider(connection);
      const context = new DatabaseContext();
      context.catalog = 'sales';
      await provider.listObjects(context, DbObjectKind.Table);
      expect(connection.queries[0].indexOf("CONVERT(X'73616C6573' USING utf8mb4)") >= 0).assertTrue();
      context.schema = 'other';
      let error: ArkDbError | null = null;
      try { await provider.listObjects(context, DbObjectKind.Table); } catch (failure) { error = failure as ArkDbError; }
      expect(error!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(connection.queries.length).assertEqual(1);
      connection.result.rows = [['sales'], ['other']];
      const schemas = await provider.listSchemas('sales');
      expect(schemas.length).assertEqual(1);
      expect(schemas[0].catalog).assertEqual('sales');
      expect(schemas[0].name).assertEqual('sales');
    });
    it('encodesMetadataNamesWithoutSqlModeDependentEscapes', 0, () => {
      expect(mysqlMetadataLiteral("o'brien"))
        .assertEqual("CONVERT(X'6F27627269656E' USING utf8mb4)");
      expect(mysqlMetadataLiteral('a\\b'))
        .assertEqual("CONVERT(X'615C62' USING utf8mb4)");
      expect(mysqlMetadataLiteral('\u0000\r\n'))
        .assertEqual("CONVERT(X'000D0A' USING utf8mb4)");
      expect(mysqlMetadataLiteral('表😀'))
        .assertEqual("CONVERT(X'E8A1A8F09F9880' USING utf8mb4)");
    });

    it('rejectsMetadataNamesAboveTheIdentifierBudget', 0, () => {
      let caught: ArkDbError | null = null;
      try {
        mysqlMetadataLiteral('x'.repeat(513));
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
    });

    it('usesHexLiteralsForEveryScopedMetadataQuery', 0, async () => {
      const connection = new MetadataConnection();
      const provider = new MySqlMetadataProvider(connection);
      const context = new DatabaseContext();
      context.schema = "s'\\\u0000表";
      const objectName = 't\r\n😀';

      await provider.listObjects(context, DbObjectKind.Table);
      await provider.listColumns(context, objectName);
      await provider.listIndexes(context, objectName);
      await provider.listForeignKeys(context, objectName);

      const schemaLiteral = "CONVERT(X'73275C00E8A1A8' USING utf8mb4)";
      const objectLiteral = "CONVERT(X'740D0AF09F9880' USING utf8mb4)";
      expect(connection.queries.length).assertEqual(4);
      for (const sql of connection.queries) {
        expect(sql.indexOf(context.schema)).assertEqual(-1);
        expect(sql.indexOf(schemaLiteral) >= 0).assertTrue();
      }
      for (let i = 1; i < connection.queries.length; i++) {
        expect(connection.queries[i].indexOf(objectName)).assertEqual(-1);
        expect(connection.queries[i].indexOf(objectLiteral) >= 0).assertTrue();
      }
    });

    it('exposesTableIndexMetadataThroughTheProviderSeam', 0, async () => {
      const connection = new MetadataConnection();
      connection.result.rows = [
        ['PRIMARY', 0, 1, 'id'],
        ['idx_status', 1, 1, 'status'],
        ['ux_order', 0, 1, 'tenant_id'],
        ['ux_order', 0, 2, 'order_no']
      ];
      const provider = new MySqlMetadataProvider(connection);
      const context = new DatabaseContext();
      context.schema = 'sales';

      const indexes = await provider.listIndexes(context, 'orders');

      expect(connection.queries[0]).assertEqual(
        "SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME FROM information_schema.STATISTICS " +
        "WHERE TABLE_SCHEMA = CONVERT(X'73616C6573' USING utf8mb4) " +
        "AND TABLE_NAME = CONVERT(X'6F7264657273' USING utf8mb4) ORDER BY INDEX_NAME, SEQ_IN_INDEX");
      expect(indexes.length).assertEqual(3);
      expect(indexes[0].name).assertEqual('PRIMARY');
      expect(indexes[0].unique).assertTrue();
      expect(indexes[0].primary).assertTrue();
      expect(indexes[0].columns[0].name).assertEqual('id');
      expect(indexes[0].columns[0].ordinal).assertEqual(1);
      expect(indexes[1].name).assertEqual('idx_status');
      expect(indexes[1].unique).assertFalse();
      expect(indexes[2].name).assertEqual('ux_order');
      expect(indexes[2].columns.length).assertEqual(2);
      expect(indexes[2].columns[0].name).assertEqual('tenant_id');
      expect(indexes[2].columns[1].name).assertEqual('order_no');
      expect(indexes[2].columns[1].ordinal).assertEqual(2);
    });

    it('exposesTableForeignKeyMetadataThroughTheProviderSeam', 0, async () => {
      const connection = new MetadataConnection();
      connection.result.rows = [
        ['fk_order_customer', 1, 'customer_id', 'crm', 'customers', 'id'],
        ['fk_order_line', 1, 'tenant_id', 'catalog', 'products', 'tenant_id'],
        ['fk_order_line', 2, 'product_id', 'catalog', 'products', 'id']
      ];
      const provider = new MySqlMetadataProvider(connection);
      const context = new DatabaseContext();
      context.schema = 'sales';

      const foreignKeys = await provider.listForeignKeys(context, 'orders');

      expect(connection.queries[0]).assertEqual(
        'SELECT CONSTRAINT_NAME, ORDINAL_POSITION, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, ' +
        'REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE ' +
        "WHERE TABLE_SCHEMA = CONVERT(X'73616C6573' USING utf8mb4) " +
        "AND TABLE_NAME = CONVERT(X'6F7264657273' USING utf8mb4) " +
        'AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION');
      expect(foreignKeys.length).assertEqual(2);
      expect(foreignKeys[0].name).assertEqual('fk_order_customer');
      expect(foreignKeys[0].referencedSchema).assertEqual('crm');
      expect(foreignKeys[0].referencedTable).assertEqual('customers');
      expect(foreignKeys[0].columns[0].localName).assertEqual('customer_id');
      expect(foreignKeys[0].columns[0].referencedName).assertEqual('id');
      expect(foreignKeys[1].name).assertEqual('fk_order_line');
      expect(foreignKeys[1].columns.length).assertEqual(2);
      expect(foreignKeys[1].columns[0].localName).assertEqual('tenant_id');
      expect(foreignKeys[1].columns[0].ordinal).assertEqual(1);
      expect(foreignKeys[1].columns[1].localName).assertEqual('product_id');
      expect(foreignKeys[1].columns[1].referencedName).assertEqual('id');
      expect(foreignKeys[1].columns[1].ordinal).assertEqual(2);
    });

    it('decodesBinaryMetadataTextAsUtf8', 0, async () => {
      const connection = new MetadataConnection();
      const provider = new MySqlMetadataProvider(connection);
      const context = new DatabaseContext();
      context.schema = 'sales';
      connection.result.rows = [
        [utf8Encode('PRIMARY'), 0, 1, utf8Encode('编号')]
      ];

      const indexes = await provider.listIndexes(context, 'orders');

      expect(indexes[0].name).assertEqual('PRIMARY');
      expect(indexes[0].columns[0].name).assertEqual('编号');

      connection.result.rows = [
        [utf8Encode('fk_customer'), 1, utf8Encode('customer_id'), utf8Encode('crm'),
          utf8Encode('customers'), utf8Encode('id')]
      ];
      const foreignKeys = await provider.listForeignKeys(context, 'orders');

      expect(foreignKeys[0].name).assertEqual('fk_customer');
      expect(foreignKeys[0].referencedSchema).assertEqual('crm');
      expect(foreignKeys[0].referencedTable).assertEqual('customers');
      expect(foreignKeys[0].columns[0].localName).assertEqual('customer_id');
      expect(foreignKeys[0].columns[0].referencedName).assertEqual('id');
    });

    it('rejectsNullableIndexColumnsAsProtocolMetadataErrors', 0, async () => {
      const connection = new MetadataConnection();
      connection.result.rows = [['idx_expression', 1, 1, null]];
      const provider = new MySqlMetadataProvider(connection);
      const context = new DatabaseContext();
      context.schema = 'sales';
      let caught: ArkDbError | null = null;

      try {
        await provider.listIndexes(context, 'orders');
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('rejectsInconsistentCompositeForeignKeyTargets', 0, async () => {
      const connection = new MetadataConnection();
      connection.result.rows = [
        ['fk_order_line', 1, 'tenant_id', 'catalog', 'products', 'tenant_id'],
        ['fk_order_line', 2, 'product_id', 'catalog', 'archived_products', 'id']
      ];
      const provider = new MySqlMetadataProvider(connection);
      const context = new DatabaseContext();
      context.schema = 'sales';
      let caught: ArkDbError | null = null;

      try {
        await provider.listForeignKeys(context, 'orders');
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });
  });
}
