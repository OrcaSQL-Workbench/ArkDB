import { ArkDbError, ContextChangeMode, DatabaseContext, DatabaseContextPolicy } from '@arkdb/core';

export function mysqlContextPolicy(): DatabaseContextPolicy {
  const policy = new DatabaseContextPolicy();
  policy.catalogChange = ContextChangeMode.InPlace;
  policy.schemaChange = ContextChangeMode.InPlace;
  policy.catalogsAreSchemas = true;
  return policy;
}

export function mysqlDatabaseForContext(context: DatabaseContext): string {
  if (context.catalog.length > 0 && context.schema.length > 0 && context.catalog !== context.schema) {
    throw ArkDbError.validation('MySQL catalog and schema identify the same database and must agree.');
  }
  const database = context.schema.length > 0 ? context.schema : context.catalog;
  if (database.length === 0) throw ArkDbError.validation('A database name is required');
  return database;
}
