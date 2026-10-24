export enum ContextChangeMode {
  Unsupported = 'unsupported',
  InPlace = 'in_place',
  Reconnect = 'reconnect'
}

export class DatabaseContextPolicy {
  catalogChange: ContextChangeMode = ContextChangeMode.Unsupported;
  schemaChange: ContextChangeMode = ContextChangeMode.Unsupported;
  catalogsAreSchemas: boolean = false;
}

export class DatabaseContext {
  catalog: string = '';
  schema: string = '';

  clone(): DatabaseContext {
    const context = new DatabaseContext();
    context.catalog = this.catalog;
    context.schema = this.schema;
    return context;
  }
}
