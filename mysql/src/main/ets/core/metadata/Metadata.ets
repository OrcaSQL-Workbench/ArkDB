import { DatabaseContext } from '../model/DatabaseContext';

export enum DbObjectKind {
  Table = 'table',
  View = 'view',
  Routine = 'routine',
  Trigger = 'trigger',
  Event = 'event'
}

export class CatalogInfo {
  name: string = '';
}

export class SchemaInfo {
  catalog: string = '';
  name: string = '';
  system: boolean = false;
}

export class DbObjectInfo {
  context: DatabaseContext = new DatabaseContext();
  name: string = '';
  kind: DbObjectKind = DbObjectKind.Table;
  subtype: string = '';
}

export class ColumnInfo {
  context: DatabaseContext = new DatabaseContext();
  objectName: string = '';
  name: string = '';
  nativeTypeName: string = '';
  ordinal: number = 0;
  nullable: boolean = true;
}

export class IndexColumnInfo {
  name: string = '';
  ordinal: number = 0;
}

export class IndexInfo {
  context: DatabaseContext = new DatabaseContext();
  objectName: string = '';
  name: string = '';
  unique: boolean = false;
  primary: boolean = false;
  columns: IndexColumnInfo[] = [];
}

export class ForeignKeyColumnInfo {
  localName: string = '';
  referencedName: string = '';
  ordinal: number = 0;
}

export class ForeignKeyInfo {
  context: DatabaseContext = new DatabaseContext();
  objectName: string = '';
  name: string = '';
  referencedSchema: string = '';
  referencedTable: string = '';
  columns: ForeignKeyColumnInfo[] = [];
}
