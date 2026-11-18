import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, DatabaseContext, DbObjectKind,
  QueryExecutionSummary, QueryOptions, QueryResultSink, SqlValue
} from '@arkdb/core';
import {
  PostgresColumnDef, PostgresConnection, PostgresConnectionConfig, PostgresDriverCapabilities,
  PostgresDriverFactory, PostgresError, PostgresParameter, PostgresQueryResult, PostgresSslMode
} from '../../../../../Index';
import { PostgresPreparedExecutor } from '../../../../main/ets/pgsql/api/PostgresPreparedContracts';
import { PostgresLifecycleTransport } from '../../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandGate } from '../../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresMetadataProvider } from '../../../../main/ets/pgsql/features/metadata/PostgresMetadataProvider';
import { resolvePostgresDatabaseName } from '../../../../main/ets/pgsql/model/PostgresConnectionConfig';
import { PostgresFrontendSerializer } from '../../../../main/ets/pgsql/protocol/PostgresByteCodec';

export default function postgresMetadataRelationsTest(): void {
  describe('PostgresMetadataRelations', () => {
    it('listsColumnsSnapshotsContextParameterizesSpecialNamesAndRejectsMalformedRows', 0, async () => {
      for (const dbCfg of ['app_db', undefined] as Array<string | undefined>) {
        const cfg = makeCfg('alice', dbCfg); const expectedCat = resolvePostgresDatabaseName(cfg);
        const tp = new QueueTransport([bootFrames(0x49)]);
        const conn = openConn('alice', dbCfg, tp); await conn.connect(); tp.writes.length = 0;
        const meta = conn.features.metadata!;
        const specialSchema = 'sch "q" \'a\' \\b $1 $2 中文 🚀';
        const specialObj = 'tbl "q" \'a\' \\b $1 $2 -- /*x*/ 🚀';
        tp.enqueue([extOk([msgRowDesc([colSpec('attname', 25), colSpec('fmt', 25), colSpec('attnum', 23), colSpec('nullable', 16)]),
          msgDataRow(['id', 'integer', '1', 'f']),
          msgDataRow(['email', 'character varying(64)', '3', 'f']),
          msgDataRow(['balance', 'numeric(10,2)', '4', 't']),
          msgDataRow(['created_at', 'timestamp with time zone', '6', 't']), msgCmd('SELECT 4')])]);
        const mutableCtx = makeCtx(dbCfg === undefined ? '' : expectedCat, specialSchema);
        const pending = meta.listColumns(mutableCtx, specialObj);
        mutableCtx.catalog = 'other_db'; mutableCtx.schema = 'mutated_schema';
        const cols = await pending;
        expect(tp.writes.length).assertEqual(5);
        const sql = extractParseSql(tp.writes[0]);
        assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', sql, [25, 25]));
        assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [0, 0], [utf8Bytes(specialSchema), utf8Bytes(specialObj)], [0]));
        expect(sql.indexOf(specialSchema) === -1 && sql.indexOf(specialObj) === -1 &&
          sql.indexOf("c.relkind IN ('r', 'p', 'v', 'm')") >= 0 &&
          sql.indexOf('a.attnum > 0 AND NOT a.attisdropped') >= 0 &&
          sql.indexOf('pg_catalog.format_type(a.atttypid, a.atttypmod)::text') >= 0 &&
          sql.indexOf("pg_catalog.has_schema_privilege(n.oid, 'USAGE')") >= 0 &&
          sql.indexOf("pg_catalog.has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')") >= 0 &&
          sql.indexOf("pg_catalog.has_column_privilege(c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES')") >= 0 &&
          sql.indexOf('ORDER BY a.attnum') >= 0 && sql.indexOf('MAINTAIN') === -1).assertTrue();
        expect(cols.length === 4 &&
          cols[0].context.catalog === expectedCat && cols[0].context.schema === specialSchema && cols[0].objectName === specialObj &&
          cols[0].name === 'id' && cols[0].nativeTypeName === 'integer' && cols[0].ordinal === 1 && !cols[0].nullable &&
          cols[1].name === 'email' && cols[1].nativeTypeName === 'character varying(64)' && cols[1].ordinal === 3 && !cols[1].nullable &&
          cols[2].name === 'balance' && cols[2].nativeTypeName === 'numeric(10,2)' && cols[2].ordinal === 4 && cols[2].nullable &&
          cols[3].name === 'created_at' && cols[3].nativeTypeName === 'timestamp with time zone' && cols[3].ordinal === 6 && cols[3].nullable).assertTrue();
        cols[0].context.schema = 'local_mutation';
        expect(cols[1].context.schema).assertEqual(specialSchema);
        tp.enqueue([extOk([msgRowDesc([colSpec('attname', 25), colSpec('fmt', 25), colSpec('attnum', 23), colSpec('nullable', 16)]), msgCmd('SELECT 0')])]);
        expect((await meta.listColumns(makeCtx(expectedCat, 'public'), 'missing_view')).length).assertEqual(0);
        await conn.close();
      }
      const rec = new RecordingPreparedExecutor();
      const unit = new PostgresMetadataProvider(rec, (): string => 'app_db');
      for (const badRows of [
        [['id', 'int4', 1]], [['id', 'int4', 1, false, 'x']], [['', 'int4', 1, false]], [['id', '', 1, false]],
        [['bad\u0000c', 'int4', 1, false]], [['id', 'bad\u0000t', 1, false]], [['id', 'int4', 0, false]],
        [['id', 'int4', -1, false]], [['id', 'int4', 1.5, false]], [['id', 'int4', '1', false]],
        [['id', 'int4', 1, 'f']], [['id', 'int4', 1, null]],
        [['a', 'int4', 2, false], ['b', 'int4', 2, true]], [['a', 'int4', 3, false], ['b', 'int4', 1, true]]
      ] as SqlValue[][][]) {
        rec.nextResult = makeResult(badRows, 4);
        expect((await asyncFail((): Promise<Object> => unit.listColumns(makeCtx('', 'public'), 'users'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      rec.nextResult = makeResult([], 3);
      expect((await asyncFail((): Promise<Object> => unit.listColumns(makeCtx('', 'public'), 'users'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      const trunc = makeResult([['id', 'integer', 1, false]], 4); trunc.truncated = true; rec.nextResult = trunc;
      expect((await asyncFail((): Promise<Object> => unit.listColumns(makeCtx('', 'public'), 'users'))).kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('listsIndexesIncludingPrimaryCompositeExpressionAndZeroKeyAndRejectsMalformedRows', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openConn('alice', 'app_db', tp); await conn.connect(); tp.writes.length = 0;
      const meta = conn.features.metadata!;
      tp.enqueue([extOk([msgRowDesc([colSpec('relname', 25), colSpec('indisunique', 16), colSpec('indisprimary', 16), colSpec('ord', 23), colSpec('colname', 25)]),
        msgDataRow(['idx_bloom_zero', 'f', 'f', null, null]),
        msgDataRow(['idx_users_Created', 'f', 'f', '1', 'created_at']),
        msgDataRow(['idx_users_lower_email', 't', 'f', '1', 'lower(email)']),
        msgDataRow(['idx_users_tenant_email', 't', 'f', '1', 'tenant_id']),
        msgDataRow(['idx_users_tenant_email', 't', 'f', '2', 'email']),
        msgDataRow(['users_pkey', 't', 't', '1', 'id']), msgCmd('SELECT 6')])]);
      const mutableCtx = makeCtx('', 'app_schema');
      const pending = meta.listIndexes(mutableCtx, 'users_part');
      mutableCtx.catalog = 'other_db'; mutableCtx.schema = 'mutated';
      const idxs = await pending;
      const sql = extractParseSql(tp.writes[0]);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', sql, [25, 25]));
      assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [0, 0], [utf8Bytes('app_schema'), utf8Bytes('users_part')], [0]));
      expect(sql.indexOf("c.relkind IN ('r', 'p', 'm')") >= 0 &&
        sql.indexOf('ix.indislive') >= 0 && sql.indexOf("ic.relkind IN ('i', 'I')") >= 0 &&
        sql.indexOf('pg_catalog.unnest(ix.indkey) WITH ORDINALITY') >= 0 && sql.indexOf('k.ord <= ix.indnkeyatts') >= 0 &&
        sql.indexOf('pg_catalog.pg_get_indexdef(ix.indexrelid, key_col.ord, true)::text') >= 0 &&
        sql.indexOf('ORDER BY ic.relname COLLATE "C", ic.oid, key_col.ord NULLS FIRST') >= 0 &&
        sql.indexOf('MAINTAIN') === -1).assertTrue();
      expect(idxs.length === 5 &&
        idxs[0].name === 'idx_bloom_zero' && !idxs[0].unique && !idxs[0].primary && idxs[0].columns.length === 0 &&
        idxs[0].context.catalog === 'app_db' && idxs[0].context.schema === 'app_schema' && idxs[0].objectName === 'users_part' &&
        idxs[1].name === 'idx_users_Created' && !idxs[1].unique && !idxs[1].primary && idxs[1].columns.length === 1 &&
        idxs[1].columns[0].name === 'created_at' && idxs[1].columns[0].ordinal === 1 &&
        idxs[2].name === 'idx_users_lower_email' && idxs[2].unique && !idxs[2].primary &&
        idxs[2].columns.length === 1 && idxs[2].columns[0].name === 'lower(email)' && idxs[2].columns[0].ordinal === 1 &&
        idxs[3].name === 'idx_users_tenant_email' && idxs[3].unique && !idxs[3].primary && idxs[3].columns.length === 2 &&
        idxs[3].columns[0].name === 'tenant_id' && idxs[3].columns[0].ordinal === 1 &&
        idxs[3].columns[1].name === 'email' && idxs[3].columns[1].ordinal === 2 &&
        idxs[4].name === 'users_pkey' && idxs[4].unique && idxs[4].primary &&
        idxs[4].columns.length === 1 && idxs[4].columns[0].name === 'id' && idxs[4].columns[0].ordinal === 1).assertTrue();
      idxs[0].context.schema = 'mutated_local';
      expect(idxs[4].context.schema).assertEqual('app_schema');
      await conn.close();
      const rec = new RecordingPreparedExecutor();
      const unit = new PostgresMetadataProvider(rec, (): string => 'app_db');
      for (const badRows of [
        [['users_pkey', false, true, 1, 'id']],
        [['idx_u', true, false, 1, 'a'], ['idx_u', false, false, 2, 'b']],
        [['idx_p', true, true, 1, 'a'], ['idx_p', true, false, 2, 'b']],
        [['idx_o', false, false, 1, 'a'], ['idx_o', false, false, 1, 'b']],
        [['idx_o', false, false, 2, 'a'], ['idx_o', false, false, 1, 'b']],
        [['idx_o', false, false, 0, 'a']],
        [['idx_n', false, false, null, 'a']],
        [['idx_n', false, false, 1, null]],
        [['idx_z', false, false, null, null], ['idx_z', false, false, null, null]],
        [['idx_z', false, false, null, null], ['idx_z', false, false, 1, 'a']],
        [['idx_z', false, false, 1, 'a'], ['idx_z', false, false, null, null]],
        [['idx_dup', false, false, 1, 'a'], ['idx_other', false, false, 1, 'b'], ['idx_dup', false, false, 2, 'c']],
        [['', false, false, 1, 'a']],
        [['idx_e', false, false, 1, '']],
        [['idx_s', 't', false, 1, 'a']],
        [['idx_len', false, false, 1]]
      ] as SqlValue[][][]) {
        rec.nextResult = makeResult(badRows, 5);
        expect((await asyncFail((): Promise<Object> => unit.listIndexes(makeCtx('app_db', 'public'), 'users'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      rec.nextResult = makeResult([], 4);
      expect((await asyncFail((): Promise<Object> => unit.listIndexes(makeCtx('', 'public'), 'users'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      const trunc = makeResult([['users_pkey', true, true, 1, 'id']], 5); trunc.truncated = true; rec.nextResult = trunc;
      expect((await asyncFail((): Promise<Object> => unit.listIndexes(makeCtx('', 'public'), 'users'))).kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('listsForeignKeysIncludingCompositeCrossSchemaAndSelfRefAndRejectsMalformedRows', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openConn('alice', 'commerce_db', tp); await conn.connect(); tp.writes.length = 0;
      const meta = conn.features.metadata!;
      tp.enqueue([extOk([msgRowDesc([colSpec('conname', 25), colSpec('ord', 23), colSpec('la', 25), colSpec('rn', 25), colSpec('rc', 25), colSpec('ra', 25)]),
        msgDataRow(['invoices_account_fkey', '1', 'org_id', 'core', 'accounts', 'org_id']),
        msgDataRow(['invoices_account_fkey', '2', 'account_id', 'core', 'accounts', 'id']),
        msgDataRow(['invoices_parent_fkey', '1', 'parent_invoice_id', 'billing', 'invoices', 'id']), msgCmd('SELECT 3')])]);
      const mutableCtx = makeCtx('commerce_db', 'billing');
      const pending = meta.listForeignKeys(mutableCtx, 'invoices');
      mutableCtx.catalog = 'other_db'; mutableCtx.schema = 'mutated';
      const fks = await pending;
      const sql = extractParseSql(tp.writes[0]);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', sql, [25, 25]));
      assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [0, 0], [utf8Bytes('billing'), utf8Bytes('invoices')], [0]));
      expect(sql.indexOf("c.relkind IN ('r', 'p')") >= 0 && sql.indexOf("con.contype = 'f'") >= 0 &&
        sql.indexOf('con.conparentid = 0 OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint AS pcon WHERE pcon.oid = con.conparentid AND pcon.conrelid = con.conrelid)') >= 0 &&
        sql.indexOf('unnest(con.conkey, con.confkey) WITH ORDINALITY') >= 0 &&
        sql.indexOf('NOT la.attisdropped') >= 0 && sql.indexOf('NOT ra.attisdropped') >= 0 &&
        sql.indexOf("pg_catalog.has_schema_privilege(n.oid, 'USAGE')") >= 0 &&
        sql.indexOf("pg_catalog.has_schema_privilege(rn.oid, 'USAGE')") >= 0 &&
        sql.indexOf("pg_catalog.has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')") >= 0 &&
        sql.indexOf("pg_catalog.has_table_privilege(rc.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')") >= 0 &&
        sql.indexOf("pg_catalog.has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')") >= 0 &&
        sql.indexOf("pg_catalog.has_any_column_privilege(rc.oid, 'SELECT, INSERT, UPDATE, REFERENCES')") >= 0 &&
        sql.indexOf('ORDER BY con.conname COLLATE "C", con.oid, fk_col.ord') >= 0 &&
        sql.indexOf('MAINTAIN') === -1).assertTrue();
      expect(fks.length === 2 &&
        fks[0].name === 'invoices_account_fkey' && fks[0].context.catalog === 'commerce_db' &&
        fks[0].context.schema === 'billing' && fks[0].objectName === 'invoices' &&
        fks[0].referencedCatalog === 'commerce_db' && fks[0].referencedSchema === 'core' && fks[0].referencedTable === 'accounts' &&
        fks[0].columns.length === 2 &&
        fks[0].columns[0].localName === 'org_id' && fks[0].columns[0].referencedName === 'org_id' && fks[0].columns[0].ordinal === 1 &&
        fks[0].columns[1].localName === 'account_id' && fks[0].columns[1].referencedName === 'id' && fks[0].columns[1].ordinal === 2 &&
        fks[1].name === 'invoices_parent_fkey' && fks[1].referencedCatalog === 'commerce_db' &&
        fks[1].referencedSchema === 'billing' && fks[1].referencedTable === 'invoices' && fks[1].columns.length === 1 &&
        fks[1].columns[0].localName === 'parent_invoice_id' && fks[1].columns[0].referencedName === 'id' && fks[1].columns[0].ordinal === 1).assertTrue();
      fks[0].context.schema = 'mutated_local';
      expect(fks[1].context.schema).assertEqual('billing');
      await conn.close();
      const rec = new RecordingPreparedExecutor();
      const unit = new PostgresMetadataProvider(rec, (): string => 'commerce_db');
      for (const badRows of [
        [['fk_1', 1, 'a', 's1', 't1', 'id'], ['fk_1', 2, 'b', 's2', 't1', 'id']],
        [['fk_1', 1, 'a', 's1', 't1', 'id'], ['fk_1', 2, 'b', 's1', 't2', 'id']],
        [['fk_1', 1, 'a', 's1', 't1', 'id'], ['fk_1', 1, 'b', 's1', 't1', 'id2']],
        [['fk_1', 2, 'a', 's1', 't1', 'id'], ['fk_1', 1, 'b', 's1', 't1', 'id2']],
        [['fk_1', 0, 'a', 's1', 't1', 'id']],
        [['fk_1', 1, 'a', 's1', 't1', 'id'], ['fk_2', 1, 'x', 's1', 't1', 'id'], ['fk_1', 2, 'b', 's1', 't1', 'id2']],
        [['', 1, 'a', 's1', 't1', 'id']],
        [['fk_1', 1, '', 's1', 't1', 'id']],
        [['fk_1', 1, 'a', '', 't1', 'id']],
        [['fk_1', 1, 'a', 's1', '', 'id']],
        [['fk_1', 1, 'a', 's1', 't1', '']],
        [['fk_1', 1, 'a', 's1', 't1']]
      ] as SqlValue[][][]) {
        rec.nextResult = makeResult(badRows, 6);
        expect((await asyncFail((): Promise<Object> => unit.listForeignKeys(makeCtx('', 'billing'), 'invoices'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      rec.nextResult = makeResult([], 5);
      expect((await asyncFail((): Promise<Object> => unit.listForeignKeys(makeCtx('', 'billing'), 'invoices'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      const trunc = makeResult([['fk_1', 1, 'a', 's1', 't1', 'id']], 6); trunc.truncated = true; rec.nextResult = trunc;
      expect((await asyncFail((): Promise<Object> => unit.listForeignKeys(makeCtx('', 'billing'), 'invoices'))).kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('wiresConnectionMetadataFeatureIndependentlyOfPostgresFeaturesAndEnforcesLifecycle', 0, async () => {
      expect(new PostgresDriverCapabilities().supportsMetadata && new PostgresDriverFactory().capabilities.supportsMetadata).assertTrue();
      const gate = new PostgresCommandGate(); const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = new PostgresConnection(makeCfg('alice', 'app_db'), 'top-secret-pw', new StepTimers(), (): PostgresLifecycleTransport => tp, undefined, gate);
      expect(conn.features.metadata !== undefined &&
        JSON.stringify(conn.features) === '{"streaming":{},"health":{},"context":{},"transactions":{},"cancellation":{},"metadata":{}}' &&
        JSON.stringify(conn).indexOf('top-secret-pw') === -1).assertTrue();
      const meta = conn.features.metadata!;
      for (const idleOp of [
        (): Promise<Object> => meta.listColumns(asCtx(null), ''),
        (): Promise<Object> => meta.listIndexes(asCtx(null), ''),
        (): Promise<Object> => meta.listForeignKeys(asCtx(null), '')
      ]) {
        const err = await asyncFail(idleOp);
        expect(err.kind === ArkDbErrorKind.Protocol && err.message === 'PostgreSQL connection is not connected.').assertTrue();
      }
      expect(tp.writes.length).assertEqual(0);
      await conn.connect(); tp.writes.length = 0;
      conn.postgresFeatures.prepared = undefined;
      tp.enqueue([
        extOk([msgRowDesc([colSpec('datname', 25)]), msgDataRow(['app_db']), msgCmd('SELECT 1')]),
        extOk([msgRowDesc([colSpec('nspname', 25), colSpec('sys', 16)]), msgDataRow(['public', 'f']), msgCmd('SELECT 1')]),
        extOk([msgRowDesc([colSpec('relname', 25), colSpec('sub', 25)]), msgDataRow(['orders', 'TABLE']), msgCmd('SELECT 1')]),
        extOk([msgRowDesc([colSpec('attname', 25), colSpec('fmt', 25), colSpec('ord', 23), colSpec('null', 16)]), msgDataRow(['id', 'bigint', '1', 'f']), msgCmd('SELECT 1')]),
        extOk([msgRowDesc([colSpec('idx', 25), colSpec('u', 16), colSpec('p', 16), colSpec('ord', 23), colSpec('col', 25)]), msgDataRow(['orders_pkey', 't', 't', '1', 'id']), msgCmd('SELECT 1')]),
        extOk([msgRowDesc([colSpec('con', 25), colSpec('ord', 23), colSpec('la', 25), colSpec('rn', 25), colSpec('rc', 25), colSpec('ra', 25)]), msgDataRow(['orders_user_fkey', '1', 'user_id', 'public', 'users', 'id']), msgCmd('SELECT 1')])
      ]);
      expect((await meta.listCatalogs())[0].name).assertEqual('app_db');
      expect((await meta.listSchemas('app_db'))[0].name).assertEqual('public');
      expect((await meta.listObjects(makeCtx('', 'public'), DbObjectKind.Table))[0].name).assertEqual('orders');
      expect((await meta.listColumns(makeCtx('', 'public'), 'orders'))[0].nativeTypeName).assertEqual('bigint');
      expect((await meta.listIndexes(makeCtx('', 'public'), 'orders'))[0].primary).assertTrue();
      expect((await meta.listForeignKeys(makeCtx('', 'public'), 'orders'))[0].referencedTable).assertEqual('users');
      expect(tp.writes.length).assertEqual(30);
      tp.writes.length = 0;
      for (const crossOp of [
        (): Promise<Object> => meta.listColumns(makeCtx('other_db', 'public'), 'orders'),
        (): Promise<Object> => meta.listIndexes(makeCtx('other_db', 'public'), 'orders'),
        (): Promise<Object> => meta.listForeignKeys(makeCtx('other_db', 'public'), 'orders')
      ]) {
        const crossErr = await asyncFail(crossOp);
        expect(crossErr.kind === ArkDbErrorKind.Unsupported &&
          crossErr.message === 'Inspecting metadata in another PostgreSQL catalog requires reconnecting to that database.').assertTrue();
      }
      expect(tp.writes.length).assertEqual(0);
      tp.hangAtEmpty = true;
      const inFlight = meta.listColumns(makeCtx('', 'public'), 'orders');
      for (let i = 0; i < 256 && !tp.waitingRead; i += 1) await Promise.resolve();
      expect(tp.waitingRead).assertTrue();
      const busyErr = await asyncFail((): Promise<Object> => meta.listIndexes(makeCtx('other_db', ''), ''));
      expect(busyErr.kind === ArkDbErrorKind.Protocol && busyErr.message === 'Another command already owns this PostgreSQL connection.').assertTrue();
      tp.hangAtEmpty = false;
      tp.resolveHungRead(extOk([msgRowDesc([colSpec('attname', 25), colSpec('fmt', 25), colSpec('ord', 23), colSpec('null', 16)]), msgCmd('SELECT 0')]));
      expect((await inFlight).length).assertEqual(0);
      tp.enqueue([concatFrames([msgParseComplete(), msgBindComplete(),
        msgError('ERROR', 'ERROR', '42501', 'permission denied for schema secret'), msgReady(0x49)])]);
      const permErr = await asyncFail((): Promise<Object> => meta.listForeignKeys(makeCtx('', 'secret'), 'orders'));
      expect(permErr instanceof PostgresError && permErr.kind === ArkDbErrorKind.Server &&
        permErr.sqlState === '42501' && conn.state === ConnectionState.Ready).assertTrue();
      tp.enqueue([extOk([msgRowDesc([colSpec('datname', 25)]), msgDataRow(['app_db']), msgCmd('SELECT 1')])]);
      expect((await meta.listCatalogs()).length).assertEqual(1);
      tp.enqueue([concatFrames([msgError('FATAL', 'FATAL', '57P01', 'admin shutdown')])]);
      const fatalErr = await asyncFail((): Promise<Object> => meta.listIndexes(makeCtx('', 'public'), 'orders'));
      expect(fatalErr instanceof PostgresError && fatalErr.sqlState === '57P01' && conn.state === ConnectionState.Error).assertTrue();
      const retiredErr = await asyncFail((): Promise<Object> => meta.listColumns(makeCtx('other_db', ''), ''));
      expect(retiredErr.kind === ArkDbErrorKind.Protocol && retiredErr.message === 'PostgreSQL connection is retired after an unrecoverable error.').assertTrue();
      await conn.close();
      const closedErr = await asyncFail((): Promise<Object> => meta.listForeignKeys(makeCtx('other_db', ''), ''));
      expect(closedErr.kind === ArkDbErrorKind.Protocol && closedErr.message === 'PostgreSQL connection is closed.').assertTrue();
    });
  });
}

class RecordingPreparedExecutor implements PostgresPreparedExecutor {
  nextResult: PostgresQueryResult = new PostgresQueryResult();
  execute(_sql: string, _parameters: PostgresParameter[], _options: QueryOptions): Promise<PostgresQueryResult> {
    return Promise.resolve(this.nextResult);
  }
  queryStream(_sql: string, _parameters: PostgresParameter[], _options: QueryOptions, _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return Promise.reject(ArkDbError.unsupported('Unused in metadata unit tests.'));
  }
}

class StepTimers implements ConnectionTimerPort {
  private clock: number = 100; private nextId: number = 1;
  nowMs(): number { this.clock += 1; return this.clock; }
  schedule(_fn: () => void, _ms: number): number { return this.nextId++; }
  cancel(_id: number): void {}
}

class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; hangAtEmpty: boolean = false; waitingRead: boolean = false;
  private pendingMax: number = 0;
  private resolveWait: ((chunk: Uint8Array | null) => void) | null = null;
  private rejectWait: ((err: Object) => void) | null = null;
  private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  resolveHungRead(chunk: Uint8Array): void {
    this.reads.push(chunk); const res = this.resolveWait; const max = this.pendingMax;
    this.resolveWait = null; this.rejectWait = null; this.waitingRead = false; this.pendingMax = 0;
    if (res !== null) res(this.take(max));
  }
  private take(max: number): Uint8Array | null {
    if (this.reads.length === 0) return null;
    const head = this.reads[0]; if (head.length <= max) return this.reads.shift()!;
    this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) {
      if (!this.hangAtEmpty) return null;
      this.waitingRead = true; this.pendingMax = max;
      return new Promise<Uint8Array | null>((res: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => {
        this.resolveWait = res; this.rejectWait = rej;
      });
    }
    return this.take(max);
  }
  write(data: Uint8Array): Promise<number> { const copy = new Uint8Array(data.length); copy.set(data); this.writes.push(copy); return Promise.resolve(data.length); }
  async close(): Promise<void> {}
  async abort(err: ArkDbError): Promise<void> {
    const rej = this.rejectWait; this.resolveWait = null; this.rejectWait = null; this.waitingRead = false;
    if (rej !== null) rej(err);
  }
}

function makeCfg(user: string, database?: string): PostgresConnectionConfig {
  const c = new PostgresConnectionConfig(); c.host = 'pg.local'; c.user = user; c.database = database; c.ssl.mode = PostgresSslMode.DISABLED; return c;
}
function openConn(user: string, database: string | undefined, tp: QueueTransport): PostgresConnection {
  return new PostgresConnection(makeCfg(user, database), '', new StepTimers(), (): PostgresLifecycleTransport => tp);
}
function makeCtx(catalog: string, schema: string): DatabaseContext { const ctx = new DatabaseContext(); ctx.catalog = catalog; ctx.schema = schema; return ctx; }
function makeResult(rows: SqlValue[][], colCount: number): PostgresQueryResult {
  const res = new PostgresQueryResult(); for (let i = 0; i < colCount; i += 1) res.columns.push(new PostgresColumnDef()); res.rows = rows; return res;
}
function extractParseSql(frame: Uint8Array): string {
  expect(frame.length > 7 && frame[0] === 0x50 && frame[5] === 0).assertTrue();
  let end = 6; while (end < frame.length && frame[end] !== 0) end += 1;
  let out = ''; for (let i = 6; i < end; i += 1) out += String.fromCharCode(frame[i]); return out;
}
function bootFrames(ready: number): Uint8Array { return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]); }
function extOk(mid: Uint8Array[], ready: number = 0x49): Uint8Array { return concatFrames([msgParseComplete(), msgBindComplete(), ...mid, msgReady(ready)]); }
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array {
  const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload); const out = new Uint8Array(src.length + 5);
  out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5); return out;
}
function msgParseComplete(): Uint8Array { return backendFrame(0x31, []); }
function msgBindComplete(): Uint8Array { return backendFrame(0x32, []); }
function msgCmd(tag: string): Uint8Array { const p: number[] = []; pushCStr(p, tag); return backendFrame(0x43, p); }
function msgReady(status: number): Uint8Array { return backendFrame(0x5a, [status]); }
function msgParam(name: string, val: string): Uint8Array { const p: number[] = []; pushCStr(p, name); pushCStr(p, val); return backendFrame(0x53, p); }
function msgError(loc: string, sev: string, st: string, m: string): Uint8Array {
  const p: number[] = [0x53]; pushCStr(p, loc); p.push(0x56); pushCStr(p, sev); p.push(0x43); pushCStr(p, st); p.push(0x4d); pushCStr(p, m); p.push(0);
  return backendFrame(0x45, p);
}
function colSpec(name: string, oid: number): Uint8Array {
  const p: number[] = []; pushCStr(p, name); const t = new Uint8Array(18); const v = new DataView(t.buffer);
  v.setUint32(0, 0, false); v.setInt16(4, 0, false); v.setUint32(6, oid, false); v.setInt16(10, -1, false); v.setInt32(12, -1, false); v.setInt16(16, 0, false);
  const out = new Uint8Array(p.length + 18); out.set(p, 0); out.set(t, p.length); return out;
}
function msgRowDesc(cols: Uint8Array[]): Uint8Array {
  let len = 2; for (const c of cols) len += c.length; const p = new Uint8Array(len); new DataView(p.buffer).setInt16(0, cols.length, false);
  let off = 2; for (const c of cols) { p.set(c, off); off += c.length; } return backendFrame(0x54, p);
}
function msgDataRow(vals: Array<string | null>): Uint8Array {
  const encoded: Array<Uint8Array | null> = vals.map((v: string | null): Uint8Array | null => v === null ? null : utf8Bytes(v));
  let len = 2; for (const b of encoded) len += b === null ? 4 : 4 + b.length;
  const p = new Uint8Array(len); const dv = new DataView(p.buffer); dv.setInt16(0, encoded.length, false);
  let off = 2;
  for (const b of encoded) {
    if (b === null) { dv.setInt32(off, -1, false); off += 4; } else { dv.setInt32(off, b.length, false); p.set(b, off + 4); off += 4 + b.length; }
  }
  return backendFrame(0x44, p);
}
function utf8Bytes(text: string): Uint8Array {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charCodeAt(i);
    if (c <= 0x7F) bytes.push(c); else if (c <= 0x7FF) bytes.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
    else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
      const cp = 0x10000 + (((c - 0xD800) << 10) | (text.charCodeAt(++i) - 0xDC00));
      bytes.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
    } else bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
  }
  return new Uint8Array(bytes);
}
function pushCStr(dst: number[], text: string): void { const b = utf8Bytes(text); for (let i = 0; i < b.length; i += 1) dst.push(b[i]); dst.push(0); }
function concatFrames(frames: Uint8Array[]): Uint8Array {
  let len = 0; for (const f of frames) len += f.length; const out = new Uint8Array(len); let off = 0;
  for (const f of frames) { out.set(f, off); off += f.length; } return out;
}
function assertBytes(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]);
}
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> {
  let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; }
  expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError;
}
function asCtx(v: DatabaseContext | null): DatabaseContext { return v as DatabaseContext; }
