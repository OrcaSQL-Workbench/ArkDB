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
