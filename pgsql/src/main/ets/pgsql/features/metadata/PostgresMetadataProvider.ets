import {
  ArkDbError, CatalogInfo, ColumnInfo, DatabaseContext, DbObjectInfo, DbObjectKind,
  ForeignKeyColumnInfo, ForeignKeyInfo, IndexColumnInfo, IndexInfo, MetadataProvider,
  QueryOptions, SchemaInfo, SqlValue
} from '@arkdb/core';
import { PostgresPreparedExecutor } from '../../api/PostgresPreparedContracts';
import { PostgresQueryResult } from '../../model/PostgresModels';
import { PostgresParameter, PostgresParameterType } from '../prepared/PostgresParameter';
import {
  isWellFormedWireMetadataName, LIST_POSTGRES_CATALOGS_SQL, LIST_POSTGRES_COLUMNS_SQL,
  LIST_POSTGRES_FOREIGN_KEYS_SQL, LIST_POSTGRES_INDEXES_SQL, LIST_POSTGRES_ROUTINES_SQL,
  LIST_POSTGRES_SCHEMAS_SQL, LIST_POSTGRES_TABLES_SQL, LIST_POSTGRES_TRIGGERS_SQL,
  LIST_POSTGRES_VIEWS_SQL, snapshotPostgresMetadataContext, validateConnectedCatalog,
  validateOptionalPostgresMetadataCatalog, validatePostgresMetadataIdentifier
} from './PostgresMetadataSql';

const CROSS_CATALOG_UNSUPPORTED_MESSAGE: string =
  'Inspecting metadata in another PostgreSQL catalog requires reconnecting to that database.';
const EVENTS_UNSUPPORTED_MESSAGE: string = 'PostgreSQL metadata does not support scheduled events.';

class PostgresMetadataDelegate {
  readonly prepared: PostgresPreparedExecutor;
  readonly getConnectedCatalog: () => string;
  readonly assertDispatchable?: () => void;
  constructor(prepared: PostgresPreparedExecutor, getConnectedCatalog: () => string, assertDispatchable?: () => void) {
    this.prepared = prepared; this.getConnectedCatalog = getConnectedCatalog; this.assertDispatchable = assertDispatchable;
  }
}

class RelationMetadataTarget {
  readonly delegate: PostgresMetadataDelegate;
  readonly context: DatabaseContext;
  readonly objectName: string;
  constructor(delegate: PostgresMetadataDelegate, context: DatabaseContext, objectName: string) {
    this.delegate = delegate; this.context = context; this.objectName = objectName;
  }
}

const metadataDelegates = new WeakMap<PostgresMetadataProvider, PostgresMetadataDelegate>();

export class PostgresMetadataProvider implements MetadataProvider {
  constructor(prepared: PostgresPreparedExecutor, getConnectedCatalog: () => string, assertDispatchable?: () => void) {
    if (prepared === null || prepared === undefined || typeof prepared !== 'object' || typeof prepared.execute !== 'function') {
      throw ArkDbError.validation('PostgreSQL metadata prepared executor is required.');
    }
    if (typeof getConnectedCatalog !== 'function') {
      throw ArkDbError.validation('PostgreSQL metadata connected catalog callback is required.');
    }
    if (assertDispatchable !== undefined && typeof assertDispatchable !== 'function') {
      throw ArkDbError.validation('PostgreSQL metadata dispatch validator must be a function.');
    }
    metadataDelegates.set(this, new PostgresMetadataDelegate(prepared, getConnectedCatalog, assertDispatchable));
  }

  get supportedObjectKinds(): DbObjectKind[] {
    return [DbObjectKind.Table, DbObjectKind.View, DbObjectKind.Routine, DbObjectKind.Trigger];
  }

  async listCatalogs(): Promise<CatalogInfo[]> {
    const delegate = this.requireDelegate();
    delegate.assertDispatchable?.();
    const result = await delegate.prepared.execute(LIST_POSTGRES_CATALOGS_SQL, [], new QueryOptions());
    const rows = requireCompleteRows(result, 1, 'catalog');
    const catalogs: CatalogInfo[] = new Array<CatalogInfo>(rows.length);
    for (let i = 0; i < rows.length; i += 1) {
      const row = rows[i];
      if (!Array.isArray(row) || row.length !== 1 || !isWellFormedWireMetadataName(row[0])) {
        throw ArkDbError.protocol('PostgreSQL catalog metadata row is malformed.');
      }
      const info = new CatalogInfo(); info.name = row[0] as string;
      catalogs[i] = info;
    }
    return catalogs;
  }

  async listSchemas(catalog: string): Promise<SchemaInfo[]> {
    const delegate = this.requireDelegate();
    delegate.assertDispatchable?.();
    const requestedCatalog = validatePostgresMetadataIdentifier(catalog, 'PostgreSQL metadata catalog');
    const connectedCatalog = validateConnectedCatalog(delegate.getConnectedCatalog());
    if (requestedCatalog !== connectedCatalog) throw ArkDbError.unsupported(CROSS_CATALOG_UNSUPPORTED_MESSAGE);
    const result = await delegate.prepared.execute(LIST_POSTGRES_SCHEMAS_SQL, [], new QueryOptions());
    const rows = requireCompleteRows(result, 2, 'schema');
    const schemas: SchemaInfo[] = new Array<SchemaInfo>(rows.length);
    for (let i = 0; i < rows.length; i += 1) {
      const row = rows[i];
      if (!Array.isArray(row) || row.length !== 2 || !isWellFormedWireMetadataName(row[0]) || typeof row[1] !== 'boolean') {
        throw ArkDbError.protocol('PostgreSQL schema metadata row is malformed.');
      }
      const info = new SchemaInfo(); info.catalog = connectedCatalog; info.name = row[0] as string; info.system = row[1] as boolean;
      schemas[i] = info;
    }
    return schemas;
  }

  async listObjects(context: DatabaseContext, kind: DbObjectKind): Promise<DbObjectInfo[]> {
    const delegate = this.requireDelegate();
    delegate.assertDispatchable?.();
    const snapshot = snapshotPostgresMetadataContext(context);
    validateObjectKind(kind);
    const requestedCatalog = validateOptionalPostgresMetadataCatalog(snapshot.catalog);
    const connectedCatalog = validateConnectedCatalog(delegate.getConnectedCatalog());
    if (requestedCatalog.length > 0 && requestedCatalog !== connectedCatalog) {
      throw ArkDbError.unsupported(CROSS_CATALOG_UNSUPPORTED_MESSAGE);
    }
    const schemaName = validatePostgresMetadataIdentifier(snapshot.schema, 'PostgreSQL metadata schema');
    if (kind === DbObjectKind.Event) throw ArkDbError.unsupported(EVENTS_UNSUPPORTED_MESSAGE);
    const resolvedContext = new DatabaseContext(); resolvedContext.catalog = connectedCatalog; resolvedContext.schema = schemaName;
    const params: PostgresParameter[] = [new PostgresParameter(PostgresParameterType.Text, schemaName)];
    const result = await delegate.prepared.execute(selectListObjectsSql(kind), params, new QueryOptions());
    const rows = requireCompleteRows(result, kind === DbObjectKind.Trigger ? 1 : 2, 'object');
    const objects: DbObjectInfo[] = new Array<DbObjectInfo>(rows.length);
    for (let i = 0; i < rows.length; i += 1) objects[i] = decodeObjectRow(rows[i], resolvedContext, kind);
    return objects;
  }

  async listColumns(context: DatabaseContext, objectName: string): Promise<ColumnInfo[]> {
    const target = this.resolveRelationTarget(context, objectName);
    const result = await this.executeRelationQuery(target, LIST_POSTGRES_COLUMNS_SQL);
    return decodeColumnRows(requireCompleteRows(result, 4, 'column'), target.context, target.objectName);
  }

  async listIndexes(context: DatabaseContext, objectName: string): Promise<IndexInfo[]> {
    const target = this.resolveRelationTarget(context, objectName);
    const result = await this.executeRelationQuery(target, LIST_POSTGRES_INDEXES_SQL);
    return decodeIndexRows(requireCompleteRows(result, 5, 'index'), target.context, target.objectName);
  }

  async listForeignKeys(context: DatabaseContext, objectName: string): Promise<ForeignKeyInfo[]> {
    const target = this.resolveRelationTarget(context, objectName);
    const result = await this.executeRelationQuery(target, LIST_POSTGRES_FOREIGN_KEYS_SQL);
    return decodeForeignKeyRows(requireCompleteRows(result, 6, 'foreign-key'), target.context, target.objectName);
  }

  private resolveRelationTarget(context: DatabaseContext, objectName: string): RelationMetadataTarget {
    const delegate = this.requireDelegate();
    delegate.assertDispatchable?.();
    const snapshot = snapshotPostgresMetadataContext(context);
    const requestedCatalog = validateOptionalPostgresMetadataCatalog(snapshot.catalog);
    const connectedCatalog = validateConnectedCatalog(delegate.getConnectedCatalog());
    if (requestedCatalog.length > 0 && requestedCatalog !== connectedCatalog) {
      throw ArkDbError.unsupported(CROSS_CATALOG_UNSUPPORTED_MESSAGE);
    }
    const schemaName = validatePostgresMetadataIdentifier(snapshot.schema, 'PostgreSQL metadata schema');
    const checkedObjectName = validatePostgresMetadataIdentifier(objectName, 'PostgreSQL metadata object name');
    const resolved = new DatabaseContext(); resolved.catalog = connectedCatalog; resolved.schema = schemaName;
    return new RelationMetadataTarget(delegate, resolved, checkedObjectName);
  }

  private executeRelationQuery(target: RelationMetadataTarget, sql: string): Promise<PostgresQueryResult> {
    const params: PostgresParameter[] = [
      new PostgresParameter(PostgresParameterType.Text, target.context.schema),
      new PostgresParameter(PostgresParameterType.Text, target.objectName)
    ];
    return target.delegate.prepared.execute(sql, params, new QueryOptions());
  }

  private requireDelegate(): PostgresMetadataDelegate {
    const delegate = metadataDelegates.get(this);
    if (delegate === undefined) throw ArkDbError.protocol('PostgreSQL metadata provider is not initialized.');
    return delegate;
  }
}

function validateObjectKind(kind: DbObjectKind): void {
  if (kind !== DbObjectKind.Table && kind !== DbObjectKind.View &&
    kind !== DbObjectKind.Routine && kind !== DbObjectKind.Trigger && kind !== DbObjectKind.Event) {
    throw ArkDbError.validation('Unsupported PostgreSQL metadata object kind.');
  }
}

function selectListObjectsSql(kind: DbObjectKind): string {
  if (kind === DbObjectKind.Table) return LIST_POSTGRES_TABLES_SQL;
  if (kind === DbObjectKind.View) return LIST_POSTGRES_VIEWS_SQL;
  if (kind === DbObjectKind.Routine) return LIST_POSTGRES_ROUTINES_SQL;
  return LIST_POSTGRES_TRIGGERS_SQL;
}

function requireCompleteRows(result: PostgresQueryResult, expectedCols: number, label: string): SqlValue[][] {
  if (result === null || result === undefined || !Array.isArray(result.columns) ||
    result.columns.length !== expectedCols || !Array.isArray(result.rows) || result.truncated) {
    throw ArkDbError.protocol('PostgreSQL ' + label + ' metadata result is incomplete.');
  }
  return result.rows;
}

function decodeObjectRow(row: SqlValue[], resolvedContext: DatabaseContext, kind: DbObjectKind): DbObjectInfo {
  if (!Array.isArray(row)) throw ArkDbError.protocol('PostgreSQL object metadata row is malformed.');
  if (kind === DbObjectKind.Trigger) {
    if (row.length !== 1 || !isWellFormedWireMetadataName(row[0])) {
      throw ArkDbError.protocol('PostgreSQL trigger metadata row is malformed.');
    }
    const info = new DbObjectInfo(); info.context = resolvedContext.clone(); info.name = row[0] as string;
    info.kind = DbObjectKind.Trigger; info.subtype = '';
    return info;
  }
  if (row.length !== 2 || !isWellFormedWireMetadataName(row[0]) || typeof row[1] !== 'string' ||
    !isValidObjectSubtype(kind, row[1] as string)) {
    throw ArkDbError.protocol('PostgreSQL object metadata row is malformed.');
  }
  const info = new DbObjectInfo(); info.context = resolvedContext.clone(); info.name = row[0] as string;
  info.kind = kind; info.subtype = row[1] as string;
  return info;
}

function isValidObjectSubtype(kind: DbObjectKind, subtype: string): boolean {
  if (kind === DbObjectKind.Table) return subtype === 'TABLE' || subtype === 'PARTITIONED TABLE';
  if (kind === DbObjectKind.View) return subtype === 'VIEW' || subtype === 'MATERIALIZED VIEW';
  if (kind === DbObjectKind.Routine) return subtype === 'FUNCTION' || subtype === 'PROCEDURE';
  return false;
}

function isPositiveSafeInteger(value: SqlValue): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1;
}

function decodeColumnRows(rows: SqlValue[][], resolvedContext: DatabaseContext, objectName: string): ColumnInfo[] {
  const columns: ColumnInfo[] = new Array<ColumnInfo>(rows.length);
  let lastOrd = 0;
  for (let i = 0; i < rows.length; i += 1) {
    const row = rows[i];
    if (!Array.isArray(row) || row.length !== 4 || !isWellFormedWireMetadataName(row[0]) ||
      !isWellFormedWireMetadataName(row[1]) || !isPositiveSafeInteger(row[2]) || typeof row[3] !== 'boolean') {
      throw ArkDbError.protocol('PostgreSQL column metadata row is malformed.');
    }
    const ord = row[2] as number;
    if (ord <= lastOrd) throw ArkDbError.protocol('PostgreSQL column metadata ordinal order is malformed.');
    const info = new ColumnInfo(); info.context = resolvedContext.clone(); info.objectName = objectName;
    info.name = row[0] as string; info.nativeTypeName = row[1] as string; info.ordinal = ord; info.nullable = row[3] as boolean;
    columns[i] = info; lastOrd = ord;
  }
  return columns;
}

function decodeIndexRows(rows: SqlValue[][], resolvedContext: DatabaseContext, objectName: string): IndexInfo[] {
  const indexes: IndexInfo[] = [];
  const seenNames = new Set<string>();
  let current: IndexInfo | undefined = undefined;
  let lastOrd = 0;
  let currentZeroKey = false;
  for (let i = 0; i < rows.length; i += 1) {
    const row = rows[i];
    if (!Array.isArray(row) || row.length !== 5 || !isWellFormedWireMetadataName(row[0]) ||
      typeof row[1] !== 'boolean' || typeof row[2] !== 'boolean') {
      throw ArkDbError.protocol('PostgreSQL index metadata row is malformed.');
    }
    const name = row[0] as string; const unique = row[1] as boolean; const primary = row[2] as boolean;
    if (primary && !unique) throw ArkDbError.protocol('PostgreSQL primary index metadata must be unique.');
    if (current === undefined || current.name !== name) {
      if (seenNames.has(name)) throw ArkDbError.protocol('PostgreSQL index metadata rows are out of order.');
      seenNames.add(name);
      current = new IndexInfo(); current.context = resolvedContext.clone(); current.objectName = objectName;
      current.name = name; current.unique = unique; current.primary = primary; current.columns = [];
      indexes.push(current); lastOrd = 0; currentZeroKey = false;
      if (row[3] === null && row[4] === null) { currentZeroKey = true; continue; }
    } else if (currentZeroKey || current.unique !== unique || current.primary !== primary) {
      throw ArkDbError.protocol('PostgreSQL index metadata group is inconsistent.');
    }
    if (!isPositiveSafeInteger(row[3]) || !isWellFormedWireMetadataName(row[4])) {
      throw ArkDbError.protocol('PostgreSQL index key metadata is malformed.');
    }
    const ord = row[3] as number;
    if (ord <= lastOrd) throw ArkDbError.protocol('PostgreSQL index column ordinal order is malformed.');
    const col = new IndexColumnInfo(); col.name = row[4] as string; col.ordinal = ord;
    current.columns.push(col); lastOrd = ord;
  }
  return indexes;
}

function decodeForeignKeyRows(rows: SqlValue[][], resolvedContext: DatabaseContext, objectName: string): ForeignKeyInfo[] {
  const foreignKeys: ForeignKeyInfo[] = [];
  const seenNames = new Set<string>();
  let current: ForeignKeyInfo | undefined = undefined;
  let lastOrd = 0;
  for (let i = 0; i < rows.length; i += 1) {
    const row = rows[i];
    if (!Array.isArray(row) || row.length !== 6 || !isWellFormedWireMetadataName(row[0]) ||
      !isPositiveSafeInteger(row[1]) || !isWellFormedWireMetadataName(row[2]) ||
      !isWellFormedWireMetadataName(row[3]) || !isWellFormedWireMetadataName(row[4]) ||
      !isWellFormedWireMetadataName(row[5])) {
      throw ArkDbError.protocol('PostgreSQL foreign-key metadata row is malformed.');
    }
    const name = row[0] as string; const ord = row[1] as number; const localName = row[2] as string;
    const refSchema = row[3] as string; const refTable = row[4] as string; const refName = row[5] as string;
    if (current === undefined || current.name !== name) {
      if (seenNames.has(name)) throw ArkDbError.protocol('PostgreSQL foreign-key metadata rows are out of order.');
      seenNames.add(name);
      current = new ForeignKeyInfo(); current.context = resolvedContext.clone(); current.objectName = objectName;
      current.name = name; current.referencedCatalog = resolvedContext.catalog;
      current.referencedSchema = refSchema; current.referencedTable = refTable; current.columns = [];
      foreignKeys.push(current); lastOrd = 0;
    } else if (current.referencedSchema !== refSchema || current.referencedTable !== refTable) {
      throw ArkDbError.protocol('PostgreSQL foreign-key metadata group is inconsistent.');
    }
    if (ord <= lastOrd) throw ArkDbError.protocol('PostgreSQL foreign-key column ordinal order is malformed.');
    const col = new ForeignKeyColumnInfo(); col.localName = localName; col.referencedName = refName; col.ordinal = ord;
    current.columns.push(col); lastOrd = ord;
  }
  return foreignKeys;
}
