import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, DatabaseContext, DbObjectKind, QueryExecutionSummary, QueryOptions, QueryResultSink, SqlValue } from '@arkdb/core';
import { PostgresColumnDef, PostgresConnection, PostgresConnectionConfig, PostgresDriverCapabilities, PostgresDriverFactory, PostgresError, PostgresParameter, PostgresParameterType, PostgresQueryResult, PostgresSslMode } from '../../../../../Index';
import { PostgresPreparedExecutor } from '../../../../main/ets/pgsql/api/PostgresPreparedContracts';
import { PostgresLifecycleTransport } from '../../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandGate } from '../../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresMetadataProvider } from '../../../../main/ets/pgsql/features/metadata/PostgresMetadataProvider';
import { LIST_POSTGRES_CATALOGS_SQL, LIST_POSTGRES_ROUTINES_SQL, LIST_POSTGRES_SCHEMAS_SQL, LIST_POSTGRES_TABLES_SQL, LIST_POSTGRES_TRIGGERS_SQL, LIST_POSTGRES_VIEWS_SQL, MAX_POSTGRES_METADATA_IDENTIFIER_BYTES, validateConnectedCatalog } from '../../../../main/ets/pgsql/features/metadata/PostgresMetadataSql';
import { resolvePostgresDatabaseName } from '../../../../main/ets/pgsql/model/PostgresConnectionConfig';
import { PostgresFrontendSerializer } from '../../../../main/ets/pgsql/protocol/PostgresByteCodec';

export default function postgresMetadataObjectsTest(): void {
  describe('PostgresMetadataObjects', () => {
    it('exposesDefensiveSupportedKindsCycleFreeStateAndConstructorValidation', 0, async () => {
      expect(MAX_POSTGRES_METADATA_IDENTIFIER_BYTES).assertEqual(512);
      const rec = new RecordingPreparedExecutor();
      const provider = new PostgresMetadataProvider(rec, (): string => 'app_db');
      expect(JSON.stringify(provider)).assertEqual('{}');
      const kinds1 = provider.supportedObjectKinds;
      expect(kinds1.length === 4 && kinds1[0] === DbObjectKind.Table && kinds1[1] === DbObjectKind.View &&
        kinds1[2] === DbObjectKind.Routine && kinds1[3] === DbObjectKind.Trigger).assertTrue();
      kinds1.push(DbObjectKind.Event); kinds1[0] = DbObjectKind.Event;
      const kinds2 = provider.supportedObjectKinds;
      expect(kinds2.length === 4 && kinds2[0] === DbObjectKind.Table && kinds2[3] === DbObjectKind.Trigger).assertTrue();
      kinds2.length = 0;
      expect(provider.supportedObjectKinds.length).assertEqual(4);
      expectSyncValidation((): Object => new PostgresMetadataProvider(asPrepared(null), (): string => 'app_db'));
      expectSyncValidation((): Object => new PostgresMetadataProvider(rec, asCatalogFn(null)));
      expectSyncValidation((): Object => new PostgresMetadataProvider(rec, (): string => 'app_db', asDispatchFn('bad')));
      for (const badConnected of ['', 'bad\u0000db', String.fromCharCode(0xD800), String.fromCharCode(0xDC00), 'a'.repeat(513)]) {
        expectSyncValidation((): Object => validateConnectedCatalog(badConnected));
        const badProvider = new PostgresMetadataProvider(rec, (): string => badConnected);
        expect((await asyncFail((): Promise<Object> => badProvider.listSchemas('app_db'))).kind).assertEqual(ArkDbErrorKind.Validation);
      }
    });

    it('listsCatalogsOverExtendedQueryWireAndRejectsMalformedRows', 0, async () => {
      expect(LIST_POSTGRES_CATALOGS_SQL.indexOf('FROM pg_catalog.pg_database AS d') >= 0 &&
        LIST_POSTGRES_CATALOGS_SQL.indexOf("pg_catalog.has_database_privilege(d.oid, 'CONNECT')") >= 0 &&
        LIST_POSTGRES_CATALOGS_SQL.indexOf('ORDER BY d.datname COLLATE "C"') >= 0).assertTrue();
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = openConn('alice', 'app_db', tp); await conn.connect(); tp.writes.length = 0;
      const provider = makeConnProvider(conn, makeCfg('alice', 'app_db'));
      tp.enqueue([extOk([msgRowDesc([colSpec('datname', 1262, 2, 25)]),
        msgDataRow(['analytics']), msgDataRow(['app_db']), msgDataRow(['postgres']), msgCmd('SELECT 3')])]);
      const catalogs = await provider.listCatalogs();
      expect(tp.writes.length).assertEqual(5);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', LIST_POSTGRES_CATALOGS_SQL, []));
      assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [], [], [0]));
      assertBytes(tp.writes[2], new Uint8Array([0x44, 0x00, 0x00, 0x00, 0x06, 0x50, 0x00]));
      assertBytes(tp.writes[3], PostgresFrontendSerializer.execute('', 0));
      assertBytes(tp.writes[4], new Uint8Array([0x53, 0x00, 0x00, 0x00, 0x04]));
      expect(catalogs.length === 3 && catalogs[0].name === 'analytics' &&
        catalogs[1].name === 'app_db' && catalogs[2].name === 'postgres').assertTrue();
      tp.enqueue([extOk([msgRowDesc([colSpec('datname', 1262, 2, 25)]), msgCmd('SELECT 0')])]);
      expect((await provider.listCatalogs()).length).assertEqual(0);
      await conn.close();
      const rec = new RecordingPreparedExecutor();
      const unitProvider = new PostgresMetadataProvider(rec, (): string => 'app_db');
      for (const badRows of [[[]], [['']], [[null]], [[123]], [['app_db', 'extra']], [['bad\u0000db']]] as SqlValue[][][]) {
        rec.nextResult = makeResult(badRows, 1);
        expect((await asyncFail((): Promise<Object> => unitProvider.listCatalogs())).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      rec.nextResult = makeResult([], 0);
      expect((await asyncFail((): Promise<Object> => unitProvider.listCatalogs())).kind).assertEqual(ArkDbErrorKind.Protocol);
      const truncated = makeResult([['app_db']], 1); truncated.truncated = true; rec.nextResult = truncated;
      expect((await asyncFail((): Promise<Object> => unitProvider.listCatalogs())).kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('listsSchemasForConnectedCatalogAndValidatesBoundariesWithoutWireWrites', 0, async () => {
      expect(LIST_POSTGRES_SCHEMAS_SQL.indexOf("n.nspname <> 'pg_toast'") >= 0 &&
        LIST_POSTGRES_SCHEMAS_SQL.indexOf("NOT LIKE E'pg\\\\_temp\\\\_%' ESCAPE E'\\\\'") >= 0 &&
        LIST_POSTGRES_SCHEMAS_SQL.indexOf("NOT LIKE E'pg\\\\_toast\\\\_temp\\\\_%' ESCAPE E'\\\\'") >= 0 &&
        LIST_POSTGRES_SCHEMAS_SQL.indexOf("n.nspname LIKE E'pg\\\\_%' ESCAPE E'\\\\'") >= 0 &&
        LIST_POSTGRES_SCHEMAS_SQL.indexOf("pg_catalog.has_schema_privilege(n.oid, 'USAGE, CREATE')") >= 0).assertTrue();
      for (const dbCfg of ['analytics_db', undefined, ''] as Array<string | undefined>) {
        const cfg = makeCfg('alice', dbCfg); const expectedCatalog = resolvePostgresDatabaseName(cfg);
        const tp = new QueueTransport([bootFrames(0x49)]);
        const conn = openConn('alice', dbCfg, tp); await conn.connect(); tp.writes.length = 0;
        const provider = makeConnProvider(conn, cfg);
        for (const badCat of ['', 'bad\u0000c', String.fromCharCode(0xD800), String.fromCharCode(0xDC00),
          'a'.repeat(513), '中'.repeat(171), '🚀'.repeat(129)]) {
          expect((await asyncFail((): Promise<Object> => provider.listSchemas(badCat))).kind).assertEqual(ArkDbErrorKind.Validation);
        }
        expect((await asyncFail((): Promise<Object> => provider.listSchemas(asStr(null)))).kind).assertEqual(ArkDbErrorKind.Validation);
        for (const otherCat of ['other_db', 'a'.repeat(512), '🚀'.repeat(128)]) {
          const err = await asyncFail((): Promise<Object> => provider.listSchemas(otherCat));
          expect(err.kind === ArkDbErrorKind.Unsupported &&
            err.message === 'Inspecting metadata in another PostgreSQL catalog requires reconnecting to that database.').assertTrue();
        }
        expect(tp.writes.length).assertEqual(0);
        tp.enqueue([extOk([msgRowDesc([colSpec('nspname', 2615, 2, 25), colSpec('system', 0, 0, 16)]),
          msgDataRow(['information_schema', 't']), msgDataRow(['pg_catalog', 't']),
          msgDataRow(['pgdata', 'f']), msgDataRow(['public', 'f']), msgCmd('SELECT 4')])]);
        const schemas = await provider.listSchemas(expectedCatalog);
        expect(tp.writes.length).assertEqual(5);
        assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', LIST_POSTGRES_SCHEMAS_SQL, []));
        expect(schemas.length === 4 &&
          schemas[0].catalog === expectedCatalog && schemas[0].name === 'information_schema' && schemas[0].system &&
          schemas[1].catalog === expectedCatalog && schemas[1].name === 'pg_catalog' && schemas[1].system &&
          schemas[2].catalog === expectedCatalog && schemas[2].name === 'pgdata' && !schemas[2].system &&
          schemas[3].catalog === expectedCatalog && schemas[3].name === 'public' && !schemas[3].system).assertTrue();
        await conn.close();
      }
      const rec = new RecordingPreparedExecutor();
      const unitProvider = new PostgresMetadataProvider(rec, (): string => 'app_db');
      for (const badRows of [[['public']], [['', false]], [['public', 't']], [['public', null]], [['public', false, 'x']]] as SqlValue[][][]) {
        rec.nextResult = makeResult(badRows, 2);
        expect((await asyncFail((): Promise<Object> => unitProvider.listSchemas('app_db'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      rec.nextResult = makeResult([], 1);
      expect((await asyncFail((): Promise<Object> => unitProvider.listSchemas('app_db'))).kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('listsObjectsAcrossAllSupportedKindsSnapshotsContextAndParameterizesSpecialSchemas', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]); const cfg = makeCfg('alice', 'app_db');
      const conn = openConn('alice', 'app_db', tp); await conn.connect(); tp.writes.length = 0;
      const provider = makeConnProvider(conn, cfg);
      const specialSchema = 'my "quoted" \'apostrophe\' \\backslash space 中文 🚀';
      tp.enqueue([extOk([msgRowDesc([colSpec('relname', 1259, 2, 25), colSpec('subtype', 0, 0, 25)]),
        msgDataRow(['audit_events', 'PARTITIONED TABLE']), msgDataRow(['users_中文', 'TABLE']), msgCmd('SELECT 2')])]);
      const mutableCtx = makeCtx('app_db', specialSchema);
      const pendingTables = provider.listObjects(mutableCtx, DbObjectKind.Table);
      mutableCtx.catalog = 'mutated_db'; mutableCtx.schema = 'mutated_schema';
      const tables = await pendingTables;
      expect(tp.writes.length).assertEqual(5);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', LIST_POSTGRES_TABLES_SQL, [25]));
      assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [0], [utf8Bytes(specialSchema)], [0]));
      expect(LIST_POSTGRES_TABLES_SQL.indexOf(specialSchema)).assertEqual(-1);
      expect(tables.length === 2 &&
        tables[0].context.catalog === 'app_db' && tables[0].context.schema === specialSchema &&
        tables[0].name === 'audit_events' && tables[0].kind === DbObjectKind.Table && tables[0].subtype === 'PARTITIONED TABLE' &&
        tables[1].context.catalog === 'app_db' && tables[1].context.schema === specialSchema &&
        tables[1].name === 'users_中文' && tables[1].kind === DbObjectKind.Table && tables[1].subtype === 'TABLE').assertTrue();
      tables[0].context.schema = 'changed_locally';
      expect(tables[1].context.schema).assertEqual(specialSchema);
      tp.writes.length = 0;
      tp.enqueue([extOk([msgRowDesc([colSpec('relname', 1259, 2, 25), colSpec('subtype', 0, 0, 25)]),
        msgDataRow(['active_users', 'VIEW']), msgDataRow(['daily_rollup', 'MATERIALIZED VIEW']), msgCmd('SELECT 2')])]);
      const views = await provider.listObjects(makeCtx('', 'reporting'), DbObjectKind.View);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', LIST_POSTGRES_VIEWS_SQL, [25]));
      expect(views.length === 2 && views[0].context.catalog === 'app_db' && views[0].context.schema === 'reporting' &&
        views[0].subtype === 'VIEW' && views[1].subtype === 'MATERIALIZED VIEW').assertTrue();
      tp.writes.length = 0;
      tp.enqueue([extOk([msgRowDesc([colSpec('proname', 1255, 2, 25), colSpec('subtype', 0, 0, 25)]),
        msgDataRow(['calc_tax', 'FUNCTION']), msgDataRow(['calc_tax', 'FUNCTION']),
        msgDataRow(['purge_archive', 'PROCEDURE']), msgCmd('SELECT 3')])]);
      const routines = await provider.listObjects(makeCtx('app_db', 'billing'), DbObjectKind.Routine);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', LIST_POSTGRES_ROUTINES_SQL, [25]));
      expect(routines.length === 3 && routines[0].name === 'calc_tax' && routines[0].subtype === 'FUNCTION' &&
        routines[1].name === 'calc_tax' && routines[1].subtype === 'FUNCTION' &&
        routines[2].name === 'purge_archive' && routines[2].subtype === 'PROCEDURE').assertTrue();
      tp.writes.length = 0;
      expect(LIST_POSTGRES_TRIGGERS_SQL.indexOf("pg_catalog.has_table_privilege(c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')") >= 0 &&
        LIST_POSTGRES_TRIGGERS_SQL.indexOf("pg_catalog.has_any_column_privilege(c.oid, 'INSERT, UPDATE, REFERENCES')") >= 0).assertTrue();
      tp.enqueue([extOk([msgRowDesc([colSpec('tgname', 2620, 2, 25)]), msgDataRow(['trg_users_touch']), msgCmd('SELECT 1')])]);
      const triggers = await provider.listObjects(makeCtx('', '   '), DbObjectKind.Trigger);
      assertBytes(tp.writes[0], PostgresFrontendSerializer.parse('', LIST_POSTGRES_TRIGGERS_SQL, [25]));
      assertBytes(tp.writes[1], PostgresFrontendSerializer.bind('', '', [0], [utf8Bytes('   ')], [0]));
      expect(triggers.length === 1 && triggers[0].context.catalog === 'app_db' && triggers[0].context.schema === '   ' &&
        triggers[0].name === 'trg_users_touch' && triggers[0].kind === DbObjectKind.Trigger && triggers[0].subtype === '').assertTrue();
      tp.writes.length = 0;
      const evErr = await asyncFail((): Promise<Object> => provider.listObjects(makeCtx('', 'public'), DbObjectKind.Event));
      expect(evErr.kind === ArkDbErrorKind.Unsupported &&
        evErr.message === 'PostgreSQL metadata does not support scheduled events.' && tp.writes.length === 0).assertTrue();
      const catBeforeSchemaErr = await asyncFail((): Promise<Object> => provider.listObjects(makeCtx('other_db', ''), DbObjectKind.Event));
      expect(catBeforeSchemaErr.kind === ArkDbErrorKind.Unsupported &&
        catBeforeSchemaErr.message === 'Inspecting metadata in another PostgreSQL catalog requires reconnecting to that database.').assertTrue();
      for (const badCall of [
        (): Promise<Object> => provider.listObjects(asCtx(null), DbObjectKind.Table),
        (): Promise<Object> => provider.listObjects(makeCtx('', 'public'), asKind('sequence')),
        (): Promise<Object> => provider.listObjects(makeCtx('bad\u0000db', 'public'), DbObjectKind.Table),
        (): Promise<Object> => provider.listObjects(makeCtx('a'.repeat(513), 'public'), DbObjectKind.Table),
        (): Promise<Object> => provider.listObjects(makeCtx('', ''), DbObjectKind.Table),
        (): Promise<Object> => provider.listObjects(makeCtx('', 'bad\u0000s'), DbObjectKind.Table),
        (): Promise<Object> => provider.listObjects(makeCtx('', String.fromCharCode(0xD800)), DbObjectKind.Table),
        (): Promise<Object> => provider.listObjects(makeCtx('', 'a'.repeat(513)), DbObjectKind.Table)
      ]) expect((await asyncFail(badCall)).kind).assertEqual(ArkDbErrorKind.Validation);
      expect(tp.writes.length).assertEqual(0);
      await conn.close();
      const rec = new RecordingPreparedExecutor();
      const unitProvider = new PostgresMetadataProvider(rec, (): string => 'app_db');
      for (const item of [
        [DbObjectKind.Table, [['users', '']]], [DbObjectKind.Table, [['users', 'FOREIGN TABLE']]],
        [DbObjectKind.Table, [['', 'TABLE']]], [DbObjectKind.Table, [['users']]],
        [DbObjectKind.View, [['v1', 'TABLE']]], [DbObjectKind.Routine, [['fn1', 'AGGREGATE']]],
        [DbObjectKind.Trigger, [['']]], [DbObjectKind.Trigger, [['trg', 'TRIGGER']]]
      ] as Array<[DbObjectKind, Array<Array<string | null>>]>) {
        rec.nextResult = makeResult(item[1], item[0] === DbObjectKind.Trigger ? 1 : 2);
        expect((await asyncFail((): Promise<Object> => unitProvider.listObjects(makeCtx('', 'public'), item[0]))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      rec.nextResult = makeResult([], 1);
      expect((await asyncFail((): Promise<Object> => unitProvider.listObjects(makeCtx('', 'public'), DbObjectKind.Table))).kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('integratesWithPostgresConnectionLifecycleErrorsAndPreservesNoHiddenColumnEnrichment', 0, async () => {
      const gate = new PostgresCommandGate(); const cfg = makeCfg('alice', 'app_db');
      const idleTp = new QueueTransport([]); const idleConn = openConn('alice', 'app_db', idleTp, gate);
      expect(idleConn.features.metadata === undefined &&
        JSON.stringify(idleConn.features) === '{"streaming":{},"health":{},"context":{},"transactions":{},"cancellation":{}}' &&
        !new PostgresDriverCapabilities().supportsMetadata && !new PostgresDriverFactory().capabilities.supportsMetadata).assertTrue();
      const idleProvider = makeConnProvider(idleConn, cfg, gate);
      for (const idleOp of [
        (): Promise<Object> => idleProvider.listCatalogs(), (): Promise<Object> => idleProvider.listSchemas(''),
        (): Promise<Object> => idleProvider.listObjects(asCtx(null), asKind('bad')),
        (): Promise<Object> => idleProvider.listColumns(asCtx(null), '')
      ]) {
        const err = await asyncFail(idleOp);
        expect(err.kind === ArkDbErrorKind.Protocol && err.message === 'PostgreSQL connection is not connected.').assertTrue();
      }
      expect(idleTp.writes.length).assertEqual(0);
      const tp = new QueueTransport([bootFrames(0x49)]); const connGate = new PostgresCommandGate();
      const conn = openConn('alice', 'app_db', tp, connGate); const provider = makeConnProvider(conn, cfg, connGate);
      await conn.connect();
      tp.writes.length = 0;
      tp.enqueue([concatFrames([msgRowDesc([colSpec('id', 16384, 1, 23), colSpec('email', 16384, 2, 25)]),
        msgDataRow(['1', 'a@b.c']), msgCmd('SELECT 1'), msgReady(0x49)])]);
      const simpleRes = await conn.query('SELECT id, email FROM users');
      expect(tp.writes.length === 1 && simpleRes.columns.length === 2 && simpleRes.columns[0].tableOid === 16384 &&
        simpleRes.columns[0].columnAttributeNumber === 1 && simpleRes.columns[0].sourceSchema === '' &&
        simpleRes.columns[0].sourceTable === '' && simpleRes.columns[0].nullable).assertTrue();
      tp.writes.length = 0;
      tp.enqueue([extOk([msgRowDesc([colSpec('id', 16384, 1, 23)]), msgDataRow(['7']), msgCmd('SELECT 1')])]);
      const prepRes = await conn.postgresFeatures.prepared!.execute(
        'SELECT id FROM users WHERE id = $1', [new PostgresParameter(PostgresParameterType.Int4, 7)], new QueryOptions());
      expect(tp.writes.length === 5 && prepRes.columns[0].tableOid === 16384 && prepRes.columns[0].columnAttributeNumber === 1 &&
        prepRes.columns[0].sourceSchema === '' && prepRes.columns[0].sourceTable === '' && prepRes.columns[0].nullable).assertTrue();
      tp.writes.length = 0; tp.hangAtEmpty = true;
      const inFlight = provider.listCatalogs();
      for (let i = 0; i < 256 && !tp.waitingRead; i += 1) await Promise.resolve();
      expect(tp.waitingRead).assertTrue();
      const busyErr = await asyncFail((): Promise<Object> => provider.listSchemas('other_db'));
      expect(busyErr.kind === ArkDbErrorKind.Protocol && busyErr.message === 'Another command already owns this PostgreSQL connection.').assertTrue();
      tp.hangAtEmpty = false;
      tp.resolveHungRead(extOk([msgRowDesc([colSpec('datname', 1262, 2, 25)]), msgDataRow(['app_db']), msgCmd('SELECT 1')]));
      expect((await inFlight).length).assertEqual(1);
      tp.enqueue([concatFrames([msgParseComplete(), msgBindComplete(),
        msgError('ERROR', 'ERROR', '42501', 'permission denied for relation pg_proc'), msgReady(0x49)])]);
      const permErr = await asyncFail((): Promise<Object> => provider.listObjects(makeCtx('', 'secret'), DbObjectKind.Routine));
      expect(permErr instanceof PostgresError && permErr.kind === ArkDbErrorKind.Server &&
        permErr.sqlState === '42501' && conn.state === ConnectionState.Ready).assertTrue();
      tp.enqueue([extOk([msgRowDesc([colSpec('datname', 1262, 2, 25)]), msgDataRow(['app_db']), msgCmd('SELECT 1')])]);
      expect((await provider.listCatalogs())[0].name).assertEqual('app_db');
      tp.enqueue([concatFrames([msgError('FATAL', 'FATAL', '57P01', 'terminating connection due to administrator command')])]);
      const fatalErr = await asyncFail((): Promise<Object> => provider.listCatalogs());
      expect(fatalErr instanceof PostgresError && fatalErr.sqlState === '57P01' && conn.state === ConnectionState.Error).assertTrue();
      tp.writes.length = 0;
      for (const retiredOp of [(): Promise<Object> => provider.listCatalogs(), (): Promise<Object> => provider.listSchemas('other_db')]) {
        const retiredErr = await asyncFail(retiredOp);
        expect(retiredErr.kind === ArkDbErrorKind.Protocol && retiredErr.message === 'PostgreSQL connection is retired after an unrecoverable error.').assertTrue();
      }
      expect(tp.writes.length).assertEqual(0);
      await conn.close();
      const closedErr = await asyncFail((): Promise<Object> => provider.listCatalogs());
      expect(closedErr.kind === ArkDbErrorKind.Protocol && closedErr.message === 'PostgreSQL connection is closed.').assertTrue();
    });

    it('validatesAndRejectsUnimplementedColumnIndexAndForeignKeyMethodsInP24', 0, async () => {
      const rec = new RecordingPreparedExecutor();
      const provider = new PostgresMetadataProvider(rec, (): string => 'app_db');
      for (const invoke of [
        (ctx: DatabaseContext, obj: string): Promise<Object> => provider.listColumns(ctx, obj),
        (ctx: DatabaseContext, obj: string): Promise<Object> => provider.listIndexes(ctx, obj),
        (ctx: DatabaseContext, obj: string): Promise<Object> => provider.listForeignKeys(ctx, obj)
      ]) {
        expect((await asyncFail((): Promise<Object> => invoke(asCtx(null), 'users'))).kind).assertEqual(ArkDbErrorKind.Validation);
        expect((await asyncFail((): Promise<Object> => invoke(makeCtx('bad\u0000c', 'public'), 'users'))).kind).assertEqual(ArkDbErrorKind.Validation);
        const catErr = await asyncFail((): Promise<Object> => invoke(makeCtx('other_db', ''), ''));
        expect(catErr.kind === ArkDbErrorKind.Unsupported &&
          catErr.message === 'Inspecting metadata in another PostgreSQL catalog requires reconnecting to that database.').assertTrue();
        expect((await asyncFail((): Promise<Object> => invoke(makeCtx('', ''), 'users'))).kind).assertEqual(ArkDbErrorKind.Validation);
        for (const badObj of ['', 'bad\u0000o', String.fromCharCode(0xD800), 'a'.repeat(513)]) {
          expect((await asyncFail((): Promise<Object> => invoke(makeCtx('', 'public'), badObj))).kind).assertEqual(ArkDbErrorKind.Validation);
        }
        expect((await asyncFail((): Promise<Object> => invoke(makeCtx('', 'public'), asStr(undefined)))).kind).assertEqual(ArkDbErrorKind.Validation);
        const mutable = makeCtx('app_db', 'public'); const pending = invoke(mutable, 'users'); mutable.catalog = 'other_db';
        const notImpl = await asyncFail((): Promise<Object> => pending);
        expect(notImpl.kind === ArkDbErrorKind.Unsupported && notImpl.message === 'PostgreSQL column/index/foreign-key metadata is not implemented.').assertTrue();
        const emptyCatErr = await asyncFail((): Promise<Object> => invoke(makeCtx('', 'public'), 'users'));
        expect(emptyCatErr.kind === ArkDbErrorKind.Unsupported && emptyCatErr.message === 'PostgreSQL column/index/foreign-key metadata is not implemented.').assertTrue();
      }
      expect(rec.calls).assertEqual(0);
    });
  });
}

class RecordingPreparedExecutor implements PostgresPreparedExecutor {
  calls: number = 0; nextResult: PostgresQueryResult = new PostgresQueryResult();
  execute(_sql: string, _parameters: PostgresParameter[], _options: QueryOptions): Promise<PostgresQueryResult> {
    this.calls += 1; return Promise.resolve(this.nextResult);
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
function openConn(user: string, database: string | undefined, tp: QueueTransport, gate?: PostgresCommandGate): PostgresConnection {
  return new PostgresConnection(makeCfg(user, database), '', new StepTimers(), (): PostgresLifecycleTransport => tp, undefined, gate);
}
function makeConnProvider(conn: PostgresConnection, cfg: PostgresConnectionConfig, gate?: PostgresCommandGate): PostgresMetadataProvider {
  return new PostgresMetadataProvider(conn.postgresFeatures.prepared!, (): string => resolvePostgresDatabaseName(cfg), (): void => {
    if (conn.state === ConnectionState.Closed) throw ArkDbError.protocol('PostgreSQL connection is closed.');
    if (conn.state === ConnectionState.Idle) throw ArkDbError.protocol('PostgreSQL connection is not connected.');
    if (conn.state === ConnectionState.Error) throw ArkDbError.protocol('PostgreSQL connection is retired after an unrecoverable error.');
    if (gate !== undefined && gate.current !== null) throw ArkDbError.protocol('Another command already owns this PostgreSQL connection.');
  });
}
function makeCtx(catalog: string, schema: string): DatabaseContext { const ctx = new DatabaseContext(); ctx.catalog = catalog; ctx.schema = schema; return ctx; }
function makeResult(rows: SqlValue[][], colCount: number): PostgresQueryResult {
  const res = new PostgresQueryResult(); for (let i = 0; i < colCount; i += 1) res.columns.push(new PostgresColumnDef()); res.rows = rows; return res;
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
function colSpec(name: string, tbl: number, attr: number, oid: number): Uint8Array {
  const p: number[] = []; pushCStr(p, name); const t = new Uint8Array(18); const v = new DataView(t.buffer);
  v.setUint32(0, tbl, false); v.setInt16(4, attr, false); v.setUint32(6, oid, false); v.setInt16(10, -1, false); v.setInt32(12, -1, false); v.setInt16(16, 0, false);
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
function expectSyncValidation(op: () => Object): void {
  let err: Object | null = null; try { op(); } catch (e) { err = e as Object; }
  expect(err instanceof ArkDbError && (err as ArkDbError).kind === ArkDbErrorKind.Validation).assertTrue();
}
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> {
  let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; }
  expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError;
}
function asPrepared(v: PostgresPreparedExecutor | null): PostgresPreparedExecutor { return v as PostgresPreparedExecutor; }
function asCatalogFn(v: (() => string) | null): () => string { return v as () => string; }
function asDispatchFn(v: string): () => void { return v as Object as () => void; }
function asStr(v: string | null | undefined): string { return v as string; }
function asCtx(v: DatabaseContext | null): DatabaseContext { return v as DatabaseContext; }
function asKind(v: string): DbObjectKind { return v as DbObjectKind; }
