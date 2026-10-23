import { DbConnection } from '../../core/connection/DbConnection';
import { DatabaseContext } from '../../core/model/DatabaseContext';
import { CatalogInfo, SchemaInfo, DbObjectKind, DbObjectInfo, ColumnInfo, ForeignKeyColumnInfo,
  ForeignKeyInfo, IndexColumnInfo, IndexInfo } from '../../core/metadata/Metadata';
import { MetadataProvider } from '../../core/metadata/MetadataProvider';
import { ArkDbError } from '../../core/model/ArkDbError';
import { SqlValue } from '../../core/model/QueryResult';
import { utf8Decode } from '../protocol/Charsets';
import { mysqlMetadataLiteral } from './MySqlMetadataSql';

const SYSTEM_SCHEMAS: string[] = ['information_schema', 'mysql', 'performance_schema', 'sys'];

export class MySqlMetadataProvider implements MetadataProvider {
  private connection: DbConnection;

  constructor(connection: DbConnection) {
    this.connection = connection;
  }

  async listCatalogs(): Promise<CatalogInfo[]> {
    const schemas = await this.listSchemas('');
    const catalogs: CatalogInfo[] = [];
    for (const schema of schemas) {
      const catalog = new CatalogInfo();
      catalog.name = schema.name;
      catalogs.push(catalog);
    }
    return catalogs;
  }

  async listSchemas(catalog: string): Promise<SchemaInfo[]> {
    const result = await this.connection.query('SHOW DATABASES');
    const schemas: SchemaInfo[] = [];
    for (const row of result.rows) {
      const schema = new SchemaInfo();
      schema.catalog = catalog;
      schema.name = valueAsString(row[0]);
      schema.system = isSystemSchema(schema.name);
      schemas.push(schema);
    }
    return schemas;
  }

  async listObjects(context: DatabaseContext, kind: DbObjectKind): Promise<DbObjectInfo[]> {
    const result = await this.connection.query(objectQuery(kind, context.schema));
    const objects: DbObjectInfo[] = [];
    for (const row of result.rows) {
      const object = new DbObjectInfo();
      object.context = context.clone();
      object.name = valueAsString(row[0]);
      object.kind = kind;
      if (kind === DbObjectKind.Routine && row.length > 1) {
        object.subtype = valueAsString(row[1]);
      }
      objects.push(object);
    }
    return objects;
  }

  async listColumns(context: DatabaseContext, objectName: string): Promise<ColumnInfo[]> {
    const schema = mysqlMetadataLiteral(context.schema);
    const table = mysqlMetadataLiteral(objectName);
    const sql = 'SELECT COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION, IS_NULLABLE ' +
      'FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ' + schema +
      ' AND TABLE_NAME = ' + table + ' ORDER BY ORDINAL_POSITION';
    const result = await this.connection.query(sql);
    const columns: ColumnInfo[] = [];
    for (const row of result.rows) {
      const column = new ColumnInfo();
      column.context = context.clone();
      column.objectName = objectName;
      column.name = valueAsString(row[0]);
      column.nativeTypeName = valueAsString(row[1]);
      column.ordinal = valueAsNumber(row[2]);
      column.nullable = row.length > 3 && valueAsString(row[3]) === 'YES';
      columns.push(column);
    }
    return columns;
  }

  async listIndexes(context: DatabaseContext, objectName: string): Promise<IndexInfo[]> {
    const schema = mysqlMetadataLiteral(context.schema);
    const table = mysqlMetadataLiteral(objectName);
    const sql = 'SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME ' +
      'FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = ' + schema +
      ' AND TABLE_NAME = ' + table + ' ORDER BY INDEX_NAME, SEQ_IN_INDEX';
    const result = await this.connection.query(sql);
    const indexes: IndexInfo[] = [];
    let current: IndexInfo | null = null;
    for (const row of result.rows) {
      if (row.length < 4) {
        throw ArkDbError.protocol('Index metadata row is incomplete.');
      }
      const name = requiredMetadataString(row[0], 'index name');
      const unique = requiredZeroOne(row[1], 'index uniqueness') === 0;
      const ordinal = requiredPositiveInteger(row[2], 'index column ordinal');
      const columnName = requiredMetadataString(row[3], 'index column name');
      if (current === null || current.name !== name) {
        current = new IndexInfo();
        current.context = context.clone();
        current.objectName = objectName;
        current.name = name;
        current.unique = unique;
        current.primary = name === 'PRIMARY';
        indexes.push(current);
      } else if (current.unique !== unique) {
        throw ArkDbError.protocol('Index metadata has inconsistent uniqueness.');
      }
      if (current.columns.length > 0 &&
        current.columns[current.columns.length - 1].ordinal >= ordinal) {
        throw ArkDbError.protocol('Index column ordinals are not strictly increasing.');
      }
      const column = new IndexColumnInfo();
      column.name = columnName;
      column.ordinal = ordinal;
      current.columns.push(column);
    }
    return indexes;
  }

  async listForeignKeys(context: DatabaseContext, objectName: string): Promise<ForeignKeyInfo[]> {
    const schema = mysqlMetadataLiteral(context.schema);
    const table = mysqlMetadataLiteral(objectName);
    const sql = 'SELECT CONSTRAINT_NAME, ORDINAL_POSITION, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, ' +
      'REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE ' +
      'WHERE TABLE_SCHEMA = ' + schema + ' AND TABLE_NAME = ' + table +
      ' AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION';
    const result = await this.connection.query(sql);
    const foreignKeys: ForeignKeyInfo[] = [];
    let current: ForeignKeyInfo | null = null;
    for (const row of result.rows) {
      if (row.length < 6) {
        throw ArkDbError.protocol('Foreign-key metadata row is incomplete.');
      }
      const name = requiredMetadataString(row[0], 'foreign-key name');
      const ordinal = requiredPositiveInteger(row[1], 'foreign-key column ordinal');
      const localName = requiredMetadataString(row[2], 'foreign-key column name');
      const referencedSchema = requiredMetadataString(row[3], 'referenced schema name');
      const referencedTable = requiredMetadataString(row[4], 'referenced table name');
      const referencedName = requiredMetadataString(row[5], 'referenced column name');
      if (current === null || current.name !== name) {
        current = new ForeignKeyInfo();
        current.context = context.clone();
        current.objectName = objectName;
        current.name = name;
        current.referencedSchema = referencedSchema;
        current.referencedTable = referencedTable;
        foreignKeys.push(current);
      } else if (current.referencedSchema !== referencedSchema || current.referencedTable !== referencedTable) {
        throw ArkDbError.protocol('Foreign-key metadata has inconsistent referenced table.');
      }
      if (current.columns.length > 0 &&
        current.columns[current.columns.length - 1].ordinal >= ordinal) {
        throw ArkDbError.protocol('Foreign-key column ordinals are not strictly increasing.');
      }
      const column = new ForeignKeyColumnInfo();
      column.localName = localName;
      column.referencedName = referencedName;
      column.ordinal = ordinal;
      current.columns.push(column);
    }
    return foreignKeys;
  }
}

function objectQuery(kind: DbObjectKind, schema: string): string {
  const escapedSchema = mysqlMetadataLiteral(schema);
  if (kind === DbObjectKind.Table) {
    return 'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ' + escapedSchema +
      " AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME";
  }
  if (kind === DbObjectKind.View) {
    return 'SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA = ' + escapedSchema +
      ' ORDER BY TABLE_NAME';
  }
  if (kind === DbObjectKind.Routine) {
    return 'SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = ' +
      escapedSchema + ' ORDER BY ROUTINE_NAME';
  }
  if (kind === DbObjectKind.Trigger) {
    return 'SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = ' + escapedSchema +
      ' ORDER BY TRIGGER_NAME';
  }
  if (kind === DbObjectKind.Event) {
    return 'SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = ' + escapedSchema +
      ' ORDER BY EVENT_NAME';
  }
  throw ArkDbError.validation('Unsupported metadata object kind: ' + String(kind));
}

function isSystemSchema(name: string): boolean {
  const normalized = name.toLowerCase();
  for (const systemSchema of SYSTEM_SCHEMAS) {
    if (systemSchema === normalized) {
      return true;
    }
  }
  return false;
}

function valueAsString(value: SqlValue): string {
  if (value === null) return '';
  if (typeof value === 'string') return value;
  if (value instanceof Uint8Array) return utf8Decode(value);
  return String(value);
}

function valueAsNumber(value: SqlValue): number {
  if (value === null) {
    return 0;
  }
  if (typeof value === 'number') {
    return value;
  }
  return Number(valueAsString(value));
}

function requiredMetadataString(value: SqlValue, field: string): string {
  let decoded = '';
  if (typeof value === 'string') {
    decoded = value;
  } else if (value instanceof Uint8Array) {
    decoded = utf8Decode(value);
  } else {
    throw ArkDbError.protocol('Invalid ' + field + ' in metadata response.');
  }
  if (decoded.length === 0) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metadata response.');
  }
  return decoded;
}

function requiredPositiveInteger(value: SqlValue, field: string): number {
  const parsed = metadataInteger(value, field);
  if (parsed < 1) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metadata response.');
  }
  return parsed;
}

function requiredZeroOne(value: SqlValue, field: string): number {
  const parsed = metadataInteger(value, field);
  if (parsed !== 0 && parsed !== 1) {
    throw ArkDbError.protocol('Invalid ' + field + ' in metadata response.');
  }
  return parsed;
}

function metadataInteger(value: SqlValue, field: string): number {
  if (typeof value === 'number' && Number.isSafeInteger(value)) {
    return value;
  }
  if (typeof value === 'bigint') {
    const converted = Number(value);
    if (Number.isSafeInteger(converted)) {
      return converted;
    }
  }
  if (typeof value === 'string' && value.length > 0) {
    const converted = Number(value);
    if (Number.isSafeInteger(converted) && String(converted) === value) {
      return converted;
    }
  }
  throw ArkDbError.protocol('Invalid ' + field + ' in metadata response.');
}
