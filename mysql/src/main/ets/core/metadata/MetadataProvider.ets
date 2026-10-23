import { DatabaseContext } from '../model/DatabaseContext';
import { CatalogInfo, SchemaInfo, DbObjectKind, DbObjectInfo, ColumnInfo, ForeignKeyInfo, IndexInfo } from
  './Metadata';

export interface MetadataProvider {
  listCatalogs(): Promise<CatalogInfo[]>;
  listSchemas(catalog: string): Promise<SchemaInfo[]>;
  listObjects(context: DatabaseContext, kind: DbObjectKind): Promise<DbObjectInfo[]>;
  listColumns(context: DatabaseContext, objectName: string): Promise<ColumnInfo[]>;
  listIndexes(context: DatabaseContext, objectName: string): Promise<IndexInfo[]>;
  listForeignKeys(context: DatabaseContext, objectName: string): Promise<ForeignKeyInfo[]>;
}
