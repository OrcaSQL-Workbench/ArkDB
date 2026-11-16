import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, ContextChangeMode,
  DatabaseContext, DatabaseContextPolicy, Logger, LogLevel, LogSink
} from '@arkdb/core';
import { PostgresConnection } from '../../../main/ets/pgsql/PostgresConnection';
import { PostgresLifecycleTransport } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { createPostgresContextPolicy } from '../../../main/ets/pgsql/connection/PostgresFeatureFacades';
import {
  PostgresCommandGate, PostgresCommandKind, PostgresCommandLifecycleObserver, PostgresCommandScope
} from '../../../main/ets/pgsql/execution/PostgresCommandGate';
import {
  PostgresConnectionConfig, PostgresSslMode, resolvePostgresDatabaseName
} from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
import { PostgresError, PostgresTransactionState } from '../../../main/ets/pgsql/model/PostgresModels';

export default function postgresContextTest(): void {
  describe('PostgresContext', () => {
    it('resolvesConnectedCatalogPolicyAndCycleFreeContextFacade', 0, async () => {
      const explicitCfg = makeConfig('alice', 'analytics_db');
      const omittedCfg = makeConfig('alice', undefined);
      const emptyCfg = makeConfig('alice', '');
      expect(resolvePostgresDatabaseName(explicitCfg)).assertEqual('analytics_db');
      expect(resolvePostgresDatabaseName(omittedCfg)).assertEqual('alice');
      expect(resolvePostgresDatabaseName(emptyCfg)).assertEqual('alice');

      const conn = new PostgresConnection(explicitCfg, 'secret-pw');
      const policy = createPostgresContextPolicy();
      expect(policy.catalogChange === ContextChangeMode.Reconnect &&
        policy.schemaChange === ContextChangeMode.InPlace && !policy.catalogsAreSchemas).assertTrue();
      const p1 = conn.contextPolicy;
      p1.catalogChange = ContextChangeMode.InPlace;
      p1.schemaChange = ContextChangeMode.Unsupported;
      p1.catalogsAreSchemas = true;
      const p2 = conn.features.context!.contextPolicy;
      expect(p2.catalogChange === ContextChangeMode.Reconnect &&
        p2.schemaChange === ContextChangeMode.InPlace && !p2.catalogsAreSchemas).assertTrue();
      p2.schemaChange = ContextChangeMode.Reconnect;
      expect(conn.contextPolicy.schemaChange).assertEqual(ContextChangeMode.InPlace);
      expect(JSON.stringify(conn.features)).assertEqual('{"streaming":{},"health":{},"context":{},"transactions":{}}');
      expect(JSON.stringify(conn).indexOf('secret-pw')).assertEqual(-1);

      const sub = new CustomContextConnection(explicitCfg);
      expect(sub.features.context!.contextPolicy.catalogsAreSchemas).assertTrue();
      await sub.features.context!.changeContext(makeCtx('', 'tenant_a'));
      expect(sub.recordedSchemas.length === 1 && sub.recordedSchemas[0] === 'tenant_a').assertTrue();
    });

    it('enforcesLifecycleStatesSingleCommandGateAndSynchronousContextSnapshot', 0, async () => {
      const idleConn = new PostgresConnection(makeConfig('alice', 'app_db'), '');
      const nullCtx: DatabaseContext | null = null;
      const undefCtx: DatabaseContext | undefined = undefined;
      expect((await asyncFail((): Promise<void> =>
        idleConn.changeContext(nullCtx!))).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      expect((await asyncFail((): Promise<void> =>
        idleConn.features.context!.changeContext(undefCtx!))).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      const notConnErr = await asyncFail((): Promise<void> =>
        idleConn.changeContext(makeCtx('', 'public')));
      expect(notConnErr.kind === ArkDbErrorKind.Protocol &&
        notConnErr.message === 'PostgreSQL connection is not connected.').assertTrue();
      await idleConn.close();
      const closedErr = await asyncFail((): Promise<void> =>
        idleConn.features.context!.changeContext(makeCtx('', 'public')));
      expect(closedErr.kind === ArkDbErrorKind.Protocol &&
        closedErr.message === 'PostgreSQL connection is closed.').assertTrue();

      const kinds: PostgresCommandKind[] = [];
      const gate = new PostgresCommandGate(new KindObserver(kinds));
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = new PostgresConnection(makeConfig('alice', 'app_db'), '',
        new FixedTimers(), (): PostgresLifecycleTransport => tp, undefined, gate);
      await conn.connect();
      tp.writes.length = 0; tp.rawWrites.length = 0;
      tp.hangAtEmpty = true;
      const mutable = makeCtx('app_db', 'snap_schema');
      const inFlight = conn.features.context!.changeContext(mutable);
      mutable.catalog = 'mutated_catalog';
      mutable.schema = 'mutated_schema';
      for (let i = 0; i < 32 && !tp.waitingRead; i += 1) await Promise.resolve();
      const busyErr = await asyncFail((): Promise<void> =>
        conn.changeContext(makeCtx('', 'other')));
      expect(busyErr.kind === ArkDbErrorKind.Protocol &&
        busyErr.message === 'Another command already owns this PostgreSQL connection.').assertTrue();
      tp.resolveHungRead(concatFrames([msgCmd('SET'), msgReady(0x49)]));
      await inFlight;
      assertBytes(tp.writes[0], expectedQueryFrame('SET search_path TO "snap_schema"'));
      expect(kinds.length === 2 && kinds[0] === PostgresCommandKind.Connect &&
        kinds[1] === PostgresCommandKind.Context).assertTrue();
      await conn.close();
    });

    it('validatesCatalogAndSchemaBeforeDispatchWithoutWireWritesOrRetiringReadySession', 0, async () => {
      const configuredDbs: Array<string | undefined> = ['app_db', undefined, ''];
      const expectedDbs: string[] = ['app_db', 'alice', 'alice'];
      for (let caseIdx = 0; caseIdx < configuredDbs.length; caseIdx += 1) {
        const cfgDb = configuredDbs[caseIdx];
        const resolvedDb = expectedDbs[caseIdx];
        const tp = new QueueTransport([bootFrames(0x54)]);
        const conn = new PostgresConnection(makeConfig('alice', cfgDb), '',
          new FixedTimers(), (): PostgresLifecycleTransport => tp);
        await conn.connect();
        assertBytes(tp.writes[0], expectedStartupFrame('alice', resolvedDb, 'arkdb'));
        tp.writes.length = 0; tp.rawWrites.length = 0;

        for (const badCatalog of ['bad\u0000db', String.fromCharCode(0xD800), String.fromCharCode(0xDC00)]) {
          const err = await asyncFail((): Promise<void> => conn.changeContext(makeCtx(badCatalog, 'public')));
          expect(err.kind === ArkDbErrorKind.Validation).assertTrue();
        }
        for (const otherCatalog of ['other_db', resolvedDb + '_2']) {
          const err = await asyncFail((): Promise<void> => conn.changeContext(makeCtx(otherCatalog, '')));
          expect(err.kind === ArkDbErrorKind.Unsupported &&
            err.message === 'Changing the PostgreSQL catalog requires reconnecting to the target database.')
            .assertTrue();
        }
        for (const badSchema of [
          '', '$user', 'bad\u0000s', String.fromCharCode(0xD800), String.fromCharCode(0xDC00),
          'a'.repeat(64), '\u4E2D'.repeat(22)
        ]) {
          const err = await asyncFail((): Promise<void> =>
            conn.changeContext(makeCtx(resolvedDb, badSchema)));
          expect(err.kind === ArkDbErrorKind.Validation).assertTrue();
        }
        expect(tp.writes.length === 0 && conn.state === ConnectionState.Ready &&
          conn.sessionStatus.known && conn.sessionStatus.inTransaction &&
          conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction).assertTrue();

        const cjk63 = '\u4E2D'.repeat(21);
        tp.enqueue([concatFrames([msgCmd('SET'), msgReady(0x49)])]);
        await conn.changeContext(makeCtx(resolvedDb, cjk63));
        assertBytes(tp.writes[0], expectedQueryFrame('SET search_path TO "' + cjk63 + '"'));
        expect(conn.state === ConnectionState.Ready && !conn.sessionStatus.inTransaction).assertTrue();
        await conn.close();
      }
    });

    it('executesQuotedSearchPathDrainsErrorsAndSettlesFatalOrClose', 0, async () => {
      const tp = new QueueTransport([bootFrames(0x49)]);
      const conn = new PostgresConnection(makeConfig('alice', 'app_db'), '',
        new FixedTimers(), (): PostgresLifecycleTransport => tp);
      await conn.connect();
      tp.writes.length = 0; tp.rawWrites.length = 0;

      const sink = new MemoryLogSink(); const prev = Logger.level;
      Logger.setLevel(LogLevel.DEBUG); Logger.addSink(sink);
      tp.enqueue([concatFrames([
        msgNotice('NOTICE', '00000', 'note'),
        msgNotification(77, 'chan', 'secret-payload'),
        msgParam('TimeZone', 'UTC'),
        msgCmd('SET'),
        msgReady(0x54)
      ])]);
      try {
        await conn.features.context!.changeContext(makeCtx('', 'my"schema.v2'));
      } finally {
        Logger.removeSink(sink); Logger.setLevel(prev);
      }
      assertBytes(tp.writes[0], expectedQueryFrame('SET search_path TO "my""schema.v2"'));
      assertZeroed(tp.rawWrites[0]);
      expect(conn.state === ConnectionState.Ready && conn.serverInfo.timeZone === 'UTC' &&
        conn.sessionStatus.inTransaction &&
        conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction &&
        sink.messages.length === 1 && sink.messages[0].indexOf('secret-payload') === -1).assertTrue();

      tp.enqueue([concatFrames([
        msgError('ERROR', 'ERROR', '25P02', 'current transaction is aborted'),
        msgReady(0x45)
      ])]);
      const abortedErr = await asyncFail((): Promise<void> => conn.changeContext(makeCtx('app_db', 'public')));
      expect(abortedErr instanceof PostgresError && abortedErr.kind === ArkDbErrorKind.Server &&
        abortedErr.sqlState === '25P02' && conn.state === ConnectionState.Ready &&
        conn.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();

      tp.enqueue([msgError('FATAL', 'FATAL', '57P01', 'terminating connection')]);
      const fatalErr = await asyncFail((): Promise<void> => conn.changeContext(makeCtx('', 'public')));
      expect(fatalErr instanceof PostgresError && fatalErr.sqlState === '57P01' &&
        conn.state === ConnectionState.Error).assertTrue();
      const retiredErr = await asyncFail((): Promise<void> => conn.changeContext(makeCtx('', 'public')));
      expect(retiredErr.kind === ArkDbErrorKind.Protocol &&
        retiredErr.message === 'PostgreSQL connection is retired after an unrecoverable error.').assertTrue();

      const raceTp = new QueueTransport([bootFrames(0x49)]);
      const raceConn = new PostgresConnection(makeConfig('alice', 'app_db'), '',
        new FixedTimers(), (): PostgresLifecycleTransport => raceTp);
      await raceConn.connect();
      raceTp.hangAtEmpty = true;
      const pending = raceConn.changeContext(makeCtx('', 'public'));
      for (let i = 0; i < 32 && !raceTp.waitingRead; i += 1) await Promise.resolve();
      const closeTask = raceConn.close();
      expect((await asyncFail((): Promise<void> => pending)).kind).assertEqual(ArkDbErrorKind.Cancelled);
      await closeTask;
      expect(raceConn.state).assertEqual(ConnectionState.Closed);
    });
  });
}

class CustomContextConnection extends PostgresConnection {
  readonly recordedSchemas: string[] = [];
  constructor(config: PostgresConnectionConfig) { super(config, ''); }
  get contextPolicy(): DatabaseContextPolicy {
    const p = createPostgresContextPolicy(); p.catalogsAreSchemas = true; return p;
  }
  async changeContext(context: DatabaseContext): Promise<void> {
    this.recordedSchemas.push(context.schema);
  }
}
class KindObserver implements PostgresCommandLifecycleObserver {
  private readonly kinds: PostgresCommandKind[];
  constructor(kinds: PostgresCommandKind[]) { this.kinds = kinds; }
  onStart(scope: PostgresCommandScope): void { this.kinds.push(scope.kind); }
  onTerminal(_scope: PostgresCommandScope): void {}
}
class MemoryLogSink implements LogSink {
  readonly messages: string[] = [];
  write(_l: LogLevel, _t: string, m: string, _ts: number): void { this.messages.push(m); }
}
class FixedTimers implements ConnectionTimerPort {
  private now: number = 100; private id: number = 1;
  nowMs(): number { this.now += 1; return this.now; }
  schedule(_h: () => void, _ms: number): number { return this.id++; }
  cancel(_id: number): void {}
}
class QueueTransport implements PostgresLifecycleTransport {
  readonly writes: Uint8Array[] = []; readonly rawWrites: Uint8Array[] = [];
  hangAtEmpty: boolean = false; waitingRead: boolean = false;
  private resolveHung: ((v: Uint8Array | null) => void) | null = null;
  private rejectHung: ((e: Object) => void) | null = null;
  private hungMax: number = 0; private readonly reads: Uint8Array[];
  constructor(reads: Uint8Array[]) { this.reads = reads.slice(); }
  enqueue(chunks: Uint8Array[]): void { for (const c of chunks) this.reads.push(c); }
  resolveHungRead(chunk: Uint8Array): void {
    const fn = this.resolveHung; const max = this.hungMax;
    this.resolveHung = null; this.rejectHung = null; this.waitingRead = false; this.hangAtEmpty = false;
    if (chunk.length > max) this.reads.unshift(chunk.subarray(max));
    if (fn !== null) fn(chunk.length > max ? chunk.subarray(0, max) : chunk);
  }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  async read(max: number): Promise<Uint8Array | null> {
    if (this.reads.length === 0) {
      if (!this.hangAtEmpty) return null;
      this.waitingRead = true; this.hungMax = max;
      return new Promise<Uint8Array | null>((res: (v: Uint8Array | null) => void, rej: (e: Object) => void): void => {
        this.resolveHung = res; this.rejectHung = rej;
      });
    }
    const head = this.reads[0];
    if (head.length <= max) return this.reads.shift()!;
    this.reads[0] = head.subarray(max); return head.subarray(0, max);
  }
  write(data: Uint8Array): Promise<number> {
    this.rawWrites.push(data); const cp = new Uint8Array(data.length); cp.set(data); this.writes.push(cp);
    return Promise.resolve(data.length);
  }
  async close(): Promise<void> {}
  async abort(e: ArkDbError): Promise<void> {
    if (this.rejectHung !== null) { const r = this.rejectHung; this.rejectHung = null; this.waitingRead = false; r(e); }
  }
}
function makeConfig(user: string, database: string | undefined): PostgresConnectionConfig {
  const c = new PostgresConnectionConfig();
  c.host = 'pg.local'; c.user = user; c.database = database; c.ssl.mode = PostgresSslMode.DISABLED;
  return c;
}
function makeCtx(catalog: string, schema: string): DatabaseContext {
  const ctx = new DatabaseContext(); ctx.catalog = catalog; ctx.schema = schema; return ctx;
}
function bootFrames(ready: number): Uint8Array {
  return concatFrames([backendFrame(0x52, [0, 0, 0, 0]), msgParam('client_encoding', 'UTF8'), msgReady(ready)]);
}
function backendFrame(type: number, payload: number[] | Uint8Array): Uint8Array {
  const src = payload instanceof Uint8Array ? payload : new Uint8Array(payload);
  const out = new Uint8Array(src.length + 5);
  out[0] = type; new DataView(out.buffer).setInt32(1, src.length + 4, false); out.set(src, 5);
  return out;
}
function expectedStartupFrame(user: string, database: string, app: string): Uint8Array {
  const p: number[] = [0, 3, 0, 0];
  pushUtf8CStr(p, 'user'); pushUtf8CStr(p, user);
  pushUtf8CStr(p, 'database'); pushUtf8CStr(p, database);
  pushUtf8CStr(p, 'application_name'); pushUtf8CStr(p, app);
  pushUtf8CStr(p, 'client_encoding'); pushUtf8CStr(p, 'UTF8');
  p.push(0);
  const out = new Uint8Array(p.length + 4);
  new DataView(out.buffer).setInt32(0, p.length + 4, false); out.set(new Uint8Array(p), 4);
  return out;
}
function expectedQueryFrame(sql: string): Uint8Array {
  const p: number[] = []; pushUtf8CStr(p, sql); return backendFrame(0x51, p);
}
function msgCmd(tag: string): Uint8Array { const p: number[] = []; pushUtf8CStr(p, tag); return backendFrame(0x43, p); }
function msgReady(status: number): Uint8Array { return backendFrame(0x5a, [status]); }
function msgParam(n: string, v: string): Uint8Array {
  const p: number[] = []; pushUtf8CStr(p, n); pushUtf8CStr(p, v); return backendFrame(0x53, p);
}
function msgNotice(loc: string, st: string, m: string): Uint8Array {
  const p: number[] = [0x53]; pushUtf8CStr(p, loc); p.push(0x43); pushUtf8CStr(p, st);
  p.push(0x4d); pushUtf8CStr(p, m); p.push(0); return backendFrame(0x4e, p);
}
function msgError(loc: string, sev: string, st: string, m: string): Uint8Array {
  const p: number[] = [0x53]; pushUtf8CStr(p, loc); p.push(0x56); pushUtf8CStr(p, sev);
  p.push(0x43); pushUtf8CStr(p, st); p.push(0x4d); pushUtf8CStr(p, m); p.push(0); return backendFrame(0x45, p);
}
function msgNotification(pid: number, ch: string, pay: string): Uint8Array {
  const h = new Uint8Array(4); new DataView(h.buffer).setInt32(0, pid, false);
  const p = Array.from(h); pushUtf8CStr(p, ch); pushUtf8CStr(p, pay); return backendFrame(0x41, p);
}
function pushUtf8CStr(dst: number[], text: string): void {
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charCodeAt(i);
    if (c <= 0x7f) dst.push(c);
    else if (c <= 0x7ff) { dst.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
    else if (c >= 0xd800 && c <= 0xdbff) {
      const cp = 0x10000 + (((c - 0xd800) << 10) | (text.charCodeAt(++i) - 0xdc00));
      dst.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else dst.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
  }
  dst.push(0);
}
function concatFrames(frames: Uint8Array[]): Uint8Array {
  let len = 0; for (const f of frames) len += f.length;
  const out = new Uint8Array(len); let off = 0;
  for (const f of frames) { out.set(f, off); off += f.length; }
  return out;
}
function assertBytes(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length);
  for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]);
}
function assertZeroed(buf: Uint8Array): void {
  for (let i = 0; i < buf.length; i += 1) expect(buf[i]).assertEqual(0);
}
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> {
  let err: Object | null = null;
  try { await op(); } catch (e) { err = e as Object; }
  expect(err instanceof ArkDbError).assertTrue();
  return err as ArkDbError;
}
