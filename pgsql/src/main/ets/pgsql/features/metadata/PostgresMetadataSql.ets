import { ArkDbError, DatabaseContext } from '@arkdb/core';

export const MAX_POSTGRES_METADATA_IDENTIFIER_BYTES: number = 512;

export const LIST_POSTGRES_CATALOGS_SQL: string =
  'SELECT d.datname::text FROM pg_catalog.pg_database AS d ' +
  "WHERE d.datallowconn AND pg_catalog.has_database_privilege(d.oid, 'CONNECT') " +
  'ORDER BY d.datname COLLATE "C"';

export const LIST_POSTGRES_SCHEMAS_SQL: string =
  "SELECT n.nspname::text, (n.nspname = 'information_schema' OR n.nspname LIKE E'pg\\\\_%' ESCAPE E'\\\\') " +
  "FROM pg_catalog.pg_namespace AS n WHERE n.nspname <> 'pg_toast' " +
  "AND n.nspname NOT LIKE E'pg\\\\_temp\\\\_%' ESCAPE E'\\\\' AND n.nspname NOT LIKE E'pg\\\\_toast\\\\_temp\\\\_%' ESCAPE E'\\\\' " +
  "AND pg_catalog.has_schema_privilege(n.oid, 'USAGE, CREATE') ORDER BY n.nspname COLLATE \"C\"";

function relationVisible(nsAlias: string, relAlias: string): string {
  return 'pg_catalog.has_schema_privilege(' + nsAlias + ".oid, 'USAGE') AND (pg_catalog.pg_has_role(" +
    relAlias + ".relowner, 'USAGE') OR pg_catalog.has_table_privilege(" + relAlias +
    ".oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') OR pg_catalog.has_any_column_privilege(" +
    relAlias + ".oid, 'SELECT, INSERT, UPDATE, REFERENCES'))";
}

const RELATION_VISIBILITY_PREDICATE: string =
  'AND ' + relationVisible('n', 'c') + ' ORDER BY c.relname COLLATE "C", c.oid';

export const LIST_POSTGRES_TABLES_SQL: string =
  "SELECT c.relname::text, CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'PARTITIONED TABLE' ELSE '' END::text " +
  "FROM pg_catalog.pg_class AS c JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace " +
  "WHERE n.nspname = $1 AND c.relkind IN ('r', 'p') " + RELATION_VISIBILITY_PREDICATE;

export const LIST_POSTGRES_VIEWS_SQL: string =
  "SELECT c.relname::text, CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE '' END::text " +
  "FROM pg_catalog.pg_class AS c JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace " +
  "WHERE n.nspname = $1 AND c.relkind IN ('v', 'm') " + RELATION_VISIBILITY_PREDICATE;

export const LIST_POSTGRES_COLUMNS_SQL: string =
  'WITH RECURSIVE notnull_domains(oid) AS (' +
  "SELECT t.oid FROM pg_catalog.pg_type AS t WHERE t.typtype = 'd' AND t.typnotnull UNION " +
  "SELECT child.oid FROM pg_catalog.pg_type AS child JOIN notnull_domains AS parent ON child.typtype = 'd' AND child.typbasetype = parent.oid) " +
  'SELECT a.attname::text, pg_catalog.format_type(a.atttypid, a.atttypmod)::text, a.attnum::int4, NOT (a.attnotnull OR nd.oid IS NOT NULL) ' +
  'FROM pg_catalog.pg_class AS c JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace ' +
  'JOIN pg_catalog.pg_attribute AS a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped ' +
  'LEFT JOIN notnull_domains AS nd ON nd.oid = a.atttypid ' +
  "WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p', 'v', 'm') " +
  "AND pg_catalog.has_schema_privilege(n.oid, 'USAGE') AND (pg_catalog.pg_has_role(c.relowner, 'USAGE') " +
  "OR pg_catalog.has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES') " +
  "OR pg_catalog.has_column_privilege(c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES')) " +
  'ORDER BY a.attnum';

export const LIST_POSTGRES_INDEXES_SQL: string =
  'WITH idx_rows AS MATERIALIZED (' +
  'SELECT ic.oid AS index_oid, ic.relname::text AS index_name, ix.indisunique, ix.indisprimary, key_col.ord, ' +
  'CASE WHEN key_col.ord IS NULL THEN NULL::text WHEN key_col.attnum > 0 THEN a.attname::text ' +
  'WHEN key_col.attnum = 0 THEN pg_catalog.pg_get_indexdef(ix.indexrelid, key_col.ord, true)::text ELSE NULL::text END AS key_name ' +
  'FROM pg_catalog.pg_class AS c JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace ' +
  'JOIN pg_catalog.pg_index AS ix ON ix.indrelid = c.oid AND ix.indislive ' +
  "JOIN pg_catalog.pg_class AS ic ON ic.oid = ix.indexrelid AND ic.relkind IN ('i', 'I') " +
  'LEFT JOIN LATERAL (SELECT k.attnum, k.ord::int4 AS ord FROM pg_catalog.unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ' +
  'WHERE k.ord <= ix.indnkeyatts) AS key_col ON TRUE ' +
  'LEFT JOIN pg_catalog.pg_attribute AS a ON a.attrelid = c.oid AND a.attnum = key_col.attnum ' +
  'AND key_col.attnum > 0 AND NOT a.attisdropped ' +
  "WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p', 'm') AND " + relationVisible('n', 'c') + ') ' +
  'SELECT r.index_name, r.indisunique, r.indisprimary, r.ord, r.key_name FROM idx_rows AS r ' +
  'WHERE NOT EXISTS (SELECT 1 FROM idx_rows AS bad WHERE bad.index_oid = r.index_oid AND bad.ord IS NOT NULL AND bad.key_name IS NULL) ' +
  'ORDER BY r.index_name COLLATE "C", r.index_oid, r.ord NULLS FIRST';

export const LIST_POSTGRES_FOREIGN_KEYS_SQL: string =
  'SELECT con.conname::text, fk_col.ord::int4, la.attname::text, rn.nspname::text, rc.relname::text, ra.attname::text ' +
  'FROM pg_catalog.pg_class AS c JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace ' +
  "JOIN pg_catalog.pg_constraint AS con ON con.conrelid = c.oid AND con.contype = 'f' " +
  'JOIN pg_catalog.pg_class AS rc ON rc.oid = con.confrelid ' +
  'JOIN pg_catalog.pg_namespace AS rn ON rn.oid = rc.relnamespace ' +
  'CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS fk_col(local_attnum, ref_attnum, ord) ' +
  'JOIN pg_catalog.pg_attribute AS la ON la.attrelid = c.oid AND la.attnum = fk_col.local_attnum AND NOT la.attisdropped ' +
  'JOIN pg_catalog.pg_attribute AS ra ON ra.attrelid = rc.oid AND ra.attnum = fk_col.ref_attnum AND NOT ra.attisdropped ' +
  "WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p') " +
  'AND (con.conparentid = 0 OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint AS pcon WHERE pcon.oid = con.conparentid AND pcon.conrelid = con.conrelid)) AND ' +
  relationVisible('n', 'c') + ' AND ' + relationVisible('rn', 'rc') +
  ' ORDER BY con.conname COLLATE "C", con.oid, fk_col.ord';

export const LIST_POSTGRES_ROUTINES_SQL: string =
  "SELECT p.proname::text, CASE p.prokind WHEN 'f' THEN 'FUNCTION' WHEN 'p' THEN 'PROCEDURE' ELSE '' END::text " +
  'FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace ' +
  "WHERE n.nspname = $1 AND p.prokind IN ('f', 'p') AND pg_catalog.has_schema_privilege(n.oid, 'USAGE') " +
  "AND (pg_catalog.pg_has_role(p.proowner, 'USAGE') OR pg_catalog.has_function_privilege(p.oid, 'EXECUTE')) " +
  'ORDER BY p.proname COLLATE "C", pg_catalog.pg_get_function_identity_arguments(p.oid) COLLATE "C", p.oid';

export const LIST_POSTGRES_TRIGGERS_SQL: string =
  'SELECT t.tgname::text FROM pg_catalog.pg_trigger AS t ' +
  'JOIN pg_catalog.pg_class AS c ON c.oid = t.tgrelid JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace ' +
  "WHERE n.nspname = $1 AND NOT t.tgisinternal AND pg_catalog.has_schema_privilege(n.oid, 'USAGE') " +
  "AND (pg_catalog.pg_has_role(c.relowner, 'USAGE') " +
  "OR pg_catalog.has_table_privilege(c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') " +
  "OR pg_catalog.has_any_column_privilege(c.oid, 'INSERT, UPDATE, REFERENCES')) " +
  'ORDER BY t.tgname COLLATE "C", c.relname COLLATE "C", t.oid';

export function validatePostgresMetadataIdentifier(value: string, label: string): string {
  if (typeof value !== 'string' || value.length === 0) throw ArkDbError.validation(label + ' must be a non-empty string.');
  const utf8Bytes = measureWellFormedUtf8Bytes(value);
  if (utf8Bytes === -1) throw ArkDbError.validation(label + ' must not contain NUL bytes.');
  if (utf8Bytes < 0) throw ArkDbError.validation(label + ' must not contain unpaired UTF-16 surrogates.');
  if (utf8Bytes > MAX_POSTGRES_METADATA_IDENTIFIER_BYTES) throw ArkDbError.validation(label + ' exceeds the 512-byte UTF-8 limit.');
  return value;
}

export function validateOptionalPostgresMetadataCatalog(catalog: string): string {
  if (typeof catalog !== 'string') throw ArkDbError.validation('PostgreSQL metadata catalog must be a string.');
  return catalog.length === 0 ? '' : validatePostgresMetadataIdentifier(catalog, 'PostgreSQL metadata catalog');
}

export function validateConnectedCatalog(catalog: string): string {
  return validatePostgresMetadataIdentifier(catalog, 'Connected PostgreSQL catalog');
}

export function snapshotPostgresMetadataContext(context: DatabaseContext): DatabaseContext {
  if (context === null || context === undefined || !(context instanceof DatabaseContext) ||
    typeof context.catalog !== 'string' || typeof context.schema !== 'string') {
    throw ArkDbError.validation('A PostgreSQL metadata DatabaseContext is required.');
  }
  const cloned = context.clone();
  if (cloned === null || cloned === undefined || !(cloned instanceof DatabaseContext)) {
    throw ArkDbError.validation('A PostgreSQL metadata DatabaseContext snapshot is required.');
  }
  const catalog = cloned.catalog; const schema = cloned.schema;
  if (typeof catalog !== 'string' || typeof schema !== 'string') {
    throw ArkDbError.validation('A PostgreSQL metadata DatabaseContext snapshot is required.');
  }
  const snapshot = new DatabaseContext(); snapshot.catalog = catalog; snapshot.schema = schema;
  return snapshot;
}

export function isWellFormedWireMetadataName(value: Object | null | undefined): boolean {
  return typeof value === 'string' && value.length > 0 && measureWellFormedUtf8Bytes(value) > 0;
}

function measureWellFormedUtf8Bytes(value: string): number {
  let utf8Bytes = 0;
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    if (code === 0) return -1;
    if (code <= 0x7F) utf8Bytes += 1;
    else if (code <= 0x7FF) utf8Bytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF) {
      if (i + 1 >= value.length) return -2;
      const low = value.charCodeAt(i + 1);
      if (low < 0xDC00 || low > 0xDFFF) return -2;
      utf8Bytes += 4; i += 1;
    } else if (code >= 0xDC00 && code <= 0xDFFF) return -2;
    else utf8Bytes += 3;
  }
  return utf8Bytes;
}
