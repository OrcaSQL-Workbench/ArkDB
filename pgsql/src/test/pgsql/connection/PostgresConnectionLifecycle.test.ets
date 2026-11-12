import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort } from '@arkdb/core';
import { PostgresConnectionLifecycle, PostgresLifecycleTransport, PostgresStartupContext, PostgresStartupRunner } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandLifecycleObserver, PostgresCommandPhase, PostgresCommandScope } from '../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement } from '../../../main/ets/pgsql/execution/PostgresSettlements';
import { PostgresConnectionConfig } from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
import { PostgresError, PostgresTransactionState } from '../../../main/ets/pgsql/model/PostgresModels';
import { PostgresMessageChannel, PostgresReadyStatus } from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresConnectionLifecycleTest(): void {
  describe('PostgresConnectionLifecycle', () => {
    it('transitionsConnectThroughAuthenticatingToReadyWithIsolatedSecrets', 0, async () => {
      expect(syncFail((): void => { new PostgresConnectionLifecycle(new PostgresConnectionConfig(), 'pw'); }).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      let unimplementedCreated = false;
      const callerCfg = validConfig();
      const unimplemented = new PostgresConnectionLifecycle(callerCfg, 'pw-default', new FakeTimerPort(),
        (): PostgresLifecycleTransport => { unimplementedCreated = true; return new FakeLifecycleTransport(); });
      callerCfg.host = '';
      expect(unimplemented.config.host === 'db.example.internal' && unimplemented.state === ConnectionState.Idle &&
        !unimplemented.sessionStatus.known && unimplemented.serverInfo.driverId === 'pgsql' &&
        unimplemented.serverInfo.productName === 'PostgreSQL').assertTrue();
      expect((await asyncFail((): Promise<void> => unimplemented.connect())).kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(!unimplementedCreated && unimplemented.state === ConnectionState.Idle &&
        unimplemented.commandGate.current === null && unimplemented.commandGate.generation === 0).assertTrue();
      await unimplemented.close(); await unimplemented.close();
      expect(!unimplementedCreated && unimplemented.state === ConnectionState.Closed &&
        unimplemented.commandGate.generation === 1).assertTrue();
      expect((await asyncFail((): Promise<void> => unimplemented.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);

      const password = 'pw-never-serialized-991';
      const secretBytes = new Uint8Array([0x12, 0x34, 0x56, 0x78]);
      const transport = new FakeLifecycleTransport();
      const states: string[] = []; let capturedCtx: PostgresStartupContext | null = null; let readPw = '';
      const lc = new PostgresConnectionLifecycle(validConfig(), password, new FakeTimerPort(),
        (): PostgresLifecycleTransport => transport, async (ctx: PostgresStartupContext): Promise<void> => {
          capturedCtx = ctx; states.push(lc.state + ':' + ctx.scope.phase);
          for (const preAuth of [(): void => { ctx.readPassword(); },
            (): void => ctx.setBackendKeyData(4242, secretBytes),
            (): void => ctx.applyReadyStatus(PostgresReadyStatus.Idle)]) {
            expect(syncFail(preAuth).kind).assertEqual(ArkDbErrorKind.Protocol);
          }
          ctx.enterAuthenticating(); ctx.enterAuthenticating();
          expect(syncFail((): void => lc.applyReadyStatus(ctx.scope, PostgresReadyStatus.Idle)).kind).assertEqual(ArkDbErrorKind.Protocol);
          states.push(lc.state + ':' + ctx.scope.phase); readPw = ctx.readPassword();
          expect(syncFail((): void => ctx.setBackendKeyData(1, new Uint8Array(3))).kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(syncFail((): void => ctx.setBackendKeyData(2147483648, secretBytes)).kind).assertEqual(ArkDbErrorKind.Protocol);
          ctx.setBackendKeyData(-2147483648, new Uint8Array([0x80, 0x00, 0x00, 0x01]));
          const firstKey = lc.readBackendKeyData()!;
          expect(firstKey.processId === -2147483648 && firstKey.secretKeyInt32 === -2147483647).assertTrue();
          ctx.setBackendKeyData(4242, secretBytes); ctx.applyReadyStatus(PostgresReadyStatus.Idle);
          for (const postReady of [(): void => { ctx.readPassword(); }, (): void => ctx.enterAuthenticating(),
            (): void => ctx.setBackendKeyData(7, secretBytes), (): void => ctx.applyReadyStatus(PostgresReadyStatus.Idle)]) {
            expect(syncFail(postReady).kind).assertEqual(ArkDbErrorKind.Protocol);
          }
        });
      transport.onConnect = (): void => { states.push(lc.state); };
      await lc.connect();
      expect(lc.state === ConnectionState.Ready && readPw === password &&
        capturedCtx!.settlement.isSettled && lc.commandGate.current === null).assertTrue();
      expect(states.join(',')).assertEqual('connecting,connecting:connecting,authenticating:authenticating');
      expect(syncFail((): void => { capturedCtx!.readPassword(); }).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<number> => capturedCtx!.transport.write(new Uint8Array([1])))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<void> => capturedCtx!.transport.close())).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(lc.state === ConnectionState.Ready && lc.serverInfo.backendProcessId === 4242 &&
        lc.serverInfo.connectionHandle === '4242' && lc.sessionStatus.known && lc.sessionStatus.autocommit && !lc.sessionStatus.inTransaction).assertTrue();
      secretBytes[0] = 0xff;
      const key = lc.readBackendKeyData()!;
      expect(key.processId === 4242 && key.secretKeyInt32 === 0x12345678).assertTrue();
      key.secretKey[0] = 0xaa;
      assertBytes(lc.readBackendKeyData()!.secretKey, [0x12, 0x34, 0x56, 0x78]);
      const dump = JSON.stringify(lc) + JSON.stringify(lc.serverInfo);
      expect(dump.indexOf(password) === -1 && dump.indexOf('305419896') === -1 &&
        dump.indexOf('18,52,86,120') === -1).assertTrue();
      expect((await asyncFail((): Promise<void> => lc.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      transport.closeFailure = ArkDbError.network('socket close failed');
      expect((await asyncFail((): Promise<void> => lc.close())).message).assertEqual('socket close failed');
      expect(lc.state === ConnectionState.Closed && lc.readBackendKeyData() === null &&
        !lc.sessionStatus.known && lc.commandGate.generation === 1 &&
        transport.closeCalls === 1 && transport.writtenFrames.length === 0).assertTrue();
    });

    it('timesOutAndCleansUpFailedConnectScrubbingSecrets', 0, async () => {
      const timers = new FakeTimerPort(); const stalled = new FakeLifecycleTransport(); stalled.hangConnect = true;
      const cfg = validConfig(); cfg.connectTimeoutMs = 2500;
      const timeoutLc = new PostgresConnectionLifecycle(cfg, 'secret-timeout', timers,
        (): PostgresLifecycleTransport => stalled, async (): Promise<void> => {});
      const attempt = timeoutLc.connect(); timers.advanceBy(2500);
      expect((await asyncFail((): Promise<void> => attempt)).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(timeoutLc.state === ConnectionState.Error && !timeoutLc.sessionStatus.known &&
        timeoutLc.commandGate.current === null && timeoutLc.commandGate.generation === 1 &&
        stalled.abortCalls === 1 && stalled.writtenFrames.length === 0 && timers.activeCount === 0).assertTrue();

      const brokenTimers = new FakeTimerPort(); brokenTimers.failCancel = true;
      const authTransport = new FakeLifecycleTransport();
      authTransport.abortFailure = ArkDbError.network('cleanup socket failure');
      const authErr = new PostgresError(ArkDbErrorKind.Auth, 'SCRAM failed', '28P01', '28P01');
      const failedLc = new PostgresConnectionLifecycle(validConfig(), 'secret-auth', brokenTimers,
        (): PostgresLifecycleTransport => authTransport, async (ctx: PostgresStartupContext): Promise<void> => {
          ctx.enterAuthenticating(); ctx.serverInfo.version = '16.4';
          ctx.setBackendKeyData(9001, new Uint8Array([9, 8, 7, 6])); throw authErr;
        });
      const caught = await asyncFail((): Promise<void> => failedLc.connect());
      expect(caught instanceof PostgresError && caught.sqlState === '28P01' &&
        caught.message.indexOf('timer cancel failed') >= 0 &&
        caught.message.indexOf('cleanup socket failure') >= 0).assertTrue();
      expect(failedLc.state === ConnectionState.Error && failedLc.readBackendKeyData() === null &&
        failedLc.commandGate.current === null && failedLc.serverInfo.backendProcessId === 0 &&
        failedLc.serverInfo.connectionHandle === '' && failedLc.serverInfo.version === '' &&
        !failedLc.sessionStatus.known).assertTrue();
      expect((await asyncFail((): Promise<void> => failedLc.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<number> =>
        failedLc.runCommand<number>(PostgresCommandKind.Query, async (): Promise<number> => 1))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      await failedLc.close();
      expect(failedLc.state === ConnectionState.Closed && authTransport.writtenFrames.length === 0).assertTrue();

      const noAuthLc = startupLifecycle(async (): Promise<void> => {});
      expect((await asyncFail((): Promise<void> => noAuthLc.connect())).kind === ArkDbErrorKind.Protocol &&
        noAuthLc.state === ConnectionState.Error).assertTrue();
      const noReadyLc = startupLifecycle(async (ctx: PostgresStartupContext): Promise<void> => { ctx.enterAuthenticating(); });
      expect((await asyncFail((): Promise<void> => noReadyLc.connect())).kind === ArkDbErrorKind.Protocol &&
        noReadyLc.state === ConnectionState.Error).assertTrue();
      const trailingLc = startupLifecycle(async (ctx: PostgresStartupContext): Promise<void> => {
        ctx.enterAuthenticating(); ctx.applyReadyStatus(PostgresReadyStatus.Idle);
        await ctx.transport.write(new Uint8Array([0x58, 0, 0, 0, 4]));
      });
      expect((await asyncFail((): Promise<void> => trailingLc.connect())).kind === ArkDbErrorKind.Protocol &&
        trailingLc.state === ConnectionState.Error && !trailingLc.sessionStatus.known).assertTrue();
      const retireTimers = new FakeTimerPort(); retireTimers.failCancel = true;
      const retireTransport = new FakeLifecycleTransport();
      retireTransport.abortFailure = ArkDbError.network('retire abort failed');
      const startupRetireErr = ArkDbError.tls('tls alert');
      let startupRetireLc: PostgresConnectionLifecycle | null = null;
      startupRetireLc = new PostgresConnectionLifecycle(validConfig(), 'pw-retire', retireTimers,
        (): PostgresLifecycleTransport => retireTransport, async (ctx: PostgresStartupContext): Promise<void> => {
          await ctx.transport.abort(startupRetireErr);
        });
      const startupRetireCaught = await asyncFail((): Promise<void> => startupRetireLc!.connect());
      expect(startupRetireCaught.kind === ArkDbErrorKind.Tls &&
        startupRetireCaught.message.split('retire abort failed').length === 2 &&
        startupRetireCaught.message.indexOf('timer cancel failed') >= 0).assertTrue();
    });

    it('serializesCommandsAndRetiresUnsynchronizedConnections', 0, async () => {
      const transport = new FakeLifecycleTransport();
      let terminalObservedSettled = false; let activeCheck: (() => boolean) | null = null;
      const gate = new PostgresCommandGate(new TerminalSettlementObserver((): void => {
        if (activeCheck !== null) terminalObservedSettled = activeCheck();
      }));
      const lc = readyLifecycle(new FakeTimerPort(), transport, 'pw-cmd', gate);
      expect((await asyncFail((): Promise<number> =>
        lc.runCommand<number>(PostgresCommandKind.Query, async (): Promise<number> => 1))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      await lc.connect();
      for (const badKind of [PostgresCommandKind.Connect, PostgresCommandKind.Close]) {
        expect((await asyncFail((): Promise<number> =>
          lc.runCommand<number>(badKind, async (): Promise<number> => 1))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      let unblock: () => void = (): void => {};
      const blocked = new Promise<void>((r: () => void): void => { unblock = r; });
      let during: ConnectionState = ConnectionState.Idle;
      let runSettlement: PostgresCommandCloseSettlement | null = null;
      let finishedScope: PostgresCommandScope | null = null;
      const first = lc.runCommand<string>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<string> => {
          during = lc.state; runSettlement = st; finishedScope = scope; activeCheck = (): boolean => st.isSettled;
          expect(scope.phase).assertEqual(PostgresCommandPhase.Executing);
          await ch.writeMessage(0x51, new Uint8Array([0])); await blocked;
          lc.applyReadyStatus(scope, PostgresReadyStatus.InTransaction); return 'ok';
        });
      expect(during).assertEqual(ConnectionState.Querying);
      expect((await asyncFail((): Promise<string> =>
        lc.runCommand<string>(PostgresCommandKind.Ping, async (): Promise<string> => 'x'))).message)
        .assertEqual('Another command already owns this PostgreSQL connection.');
      unblock();
      expect((await first) === 'ok' && lc.state === ConnectionState.Ready &&
        lc.sessionStatus.inTransaction && runSettlement!.isSettled && terminalObservedSettled).assertTrue();
      activeCheck = null;
      expect(syncFail((): void => lc.applyReadyStatus(finishedScope!, PostgresReadyStatus.Idle)).kind)
        .assertEqual(ArkDbErrorKind.Protocol);

      const sqlErr = new PostgresError(ArkDbErrorKind.Server, 'syntax error', '42601', '42601');
      expect(await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => {
          await ch.writeMessage(0x51, new Uint8Array([0]));
          lc.applyReadyStatus(scope, PostgresReadyStatus.FailedTransaction); throw sqlErr;
        }))).assertEqual(sqlErr);
      expect(lc.state === ConnectionState.Ready &&
        lc.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();
      for (const nonWireErr of [ArkDbError.validation('bad param'), ArkDbError.unsupported('not yet')]) {
        expect(await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Query,
          async (): Promise<void> => { throw nonWireErr; }))).assertEqual(nonWireErr);
      }
      expect(lc.state === ConnectionState.Ready &&
        lc.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();

      const midWireTimeoutLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-mid');
      await midWireTimeoutLc.connect();
      expect((await asyncFail((): Promise<void> => midWireTimeoutLc.runCommand<void>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => {
          await ch.writeMessage(0x51, new Uint8Array([0])); throw ArkDbError.timeout('statement deadline');
        }))).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(midWireTimeoutLc.state === ConnectionState.Error && !midWireTimeoutLc.sessionStatus.known).assertTrue();

      const noSyncReturnLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-nosync');
      await noSyncReturnLc.connect();
      expect((await asyncFail((): Promise<number> => noSyncReturnLc.runCommand<number>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<number> => {
          await ch.writeMessage(0x51, new Uint8Array([0])); return 1;
        }))).kind === ArkDbErrorKind.Protocol && noSyncReturnLc.state === ConnectionState.Error).assertTrue();

      for (const useLocalized of [false, true]) {
        const fatalLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-fatal');
        await fatalLc.connect();
        const fatalErr = new PostgresError(ArkDbErrorKind.Server, 'terminating', '57P01', '57P01');
        if (useLocalized) fatalErr.localizedSeverity = 'FATAL'; else fatalErr.severity = 'PANIC';
        expect(await asyncFail((): Promise<void> => fatalLc.runCommand<void>(PostgresCommandKind.Query,
          async (): Promise<void> => { throw fatalErr; }))).assertEqual(fatalErr);
        expect(fatalLc.state).assertEqual(ConnectionState.Error);
      }
      const closeSigLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-sig');
      await closeSigLc.connect();
      expect((await asyncFail((): Promise<void> => closeSigLc.runCommand<void>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, _ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<void> => {
          st.signalClose(ArkDbError.cancelled('closed'));
        }))).kind === ArkDbErrorKind.Cancelled && closeSigLc.state === ConnectionState.Closed).assertTrue();
      const desync = ArkDbError.protocol('Malformed DataRow frame');
      const primaryQueryErr = new PostgresError(ArkDbErrorKind.Server, 'aborted query', '57014', '57014');
      transport.abortFailure = ArkDbError.network('abort failed');
      const retiredErr = await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope): Promise<void> => {
          try { await lc.retire(scope, desync); } catch (_cleanup) { throw primaryQueryErr; }
        }));
      expect(retiredErr instanceof PostgresError && retiredErr.sqlState === '57014' &&
        retiredErr.message.indexOf('abort failed') >= 0 && lc.state === ConnectionState.Error &&
        !lc.sessionStatus.known && lc.readBackendKeyData() === null && lc.commandGate.generation === 1 &&
        transport.abortCalls === 1 && transport.writtenFrames.length === 2).assertTrue();
      expect((await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Ping, async (): Promise<void> => {}))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      await lc.close(); expect(lc.state).assertEqual(ConnectionState.Closed);
    });
  });
}
function validConfig(): PostgresConnectionConfig {
  const cfg = new PostgresConnectionConfig(); cfg.host = 'db.example.internal'; cfg.user = 'postgres'; return cfg;
}
function startupLifecycle(runner: PostgresStartupRunner): PostgresConnectionLifecycle {
  return new PostgresConnectionLifecycle(validConfig(), 'pw-startup', new FakeTimerPort(), (): PostgresLifecycleTransport => new FakeLifecycleTransport(), runner);
}
function readyLifecycle(timers: ConnectionTimerPort, transport: FakeLifecycleTransport, password: string, gate?: PostgresCommandGate): PostgresConnectionLifecycle {
  return new PostgresConnectionLifecycle(validConfig(), password, timers, (): PostgresLifecycleTransport => transport,
    async (ctx: PostgresStartupContext): Promise<void> => {
      ctx.enterAuthenticating(); ctx.setBackendKeyData(5150, new Uint8Array([10, 20, 30, 40])); ctx.applyReadyStatus(PostgresReadyStatus.Idle);
    }, gate);
}
class TerminalSettlementObserver implements PostgresCommandLifecycleObserver {
  private readonly onDone: () => void;
  constructor(onDone: () => void) { this.onDone = onDone; }
  onStart(_scope: PostgresCommandScope): void {}
  onTerminal(_scope: PostgresCommandScope): void { this.onDone(); }
}
interface ScheduledTimer { id: number; dueAtMs: number; handler: () => void; }
class FakeTimerPort implements ConnectionTimerPort {
  failCancel: boolean = false;
  private currentMs: number = 1000; private nextId: number = 1; private timers: ScheduledTimer[] = [];
  get activeCount(): number { return this.timers.length; }
  nowMs(): number { return this.currentMs; }
  schedule(handler: () => void, timeoutMs: number): number {
    const id = this.nextId++; this.timers.push({ id: id, dueAtMs: this.currentMs + timeoutMs, handler: handler }); return id;
  }
  cancel(timerId: number): void {
    for (let i = 0; i < this.timers.length; i += 1) { if (this.timers[i].id === timerId) { this.timers.splice(i, 1); break; } }
    if (this.failCancel) throw new Error('timer cancel failed');
  }
  advanceBy(deltaMs: number): void {
    const target = this.currentMs + deltaMs;
    while (true) {
      let next = -1;
      for (let i = 0; i < this.timers.length; i += 1) {
        if (this.timers[i].dueAtMs <= target && (next < 0 || this.timers[i].dueAtMs < this.timers[next].dueAtMs)) next = i;
      }
      if (next < 0) break;
      const due = this.timers[next]; this.timers.splice(next, 1); this.currentMs = due.dueAtMs; due.handler();
    }
    this.currentMs = target;
  }
}
class FakeLifecycleTransport implements PostgresLifecycleTransport {
  readonly writtenFrames: Uint8Array[] = [];
  hangConnect: boolean = false; abortFailure: ArkDbError | null = null; closeFailure: ArkDbError | null = null;
  closeCalls: number = 0; abortCalls: number = 0; onConnect: (() => void) | null = null;
  private fatal: ArkDbError | null = null; private pendingRejects: Array<(error: Object) => void> = [];
  connect(_host: string, _port: number, _timeoutMs: number): Promise<void> {
    if (this.onConnect !== null) this.onConnect();
    if (this.fatal !== null) return Promise.reject<void>(this.fatal);
    return !this.hangConnect ? Promise.resolve() :
      new Promise<void>((_r: () => void, reject: (e: Object) => void): void => { this.pendingRejects.push(reject); });
  }
  read(_maximumBytes: number): Promise<Uint8Array | null> {
    return this.fatal !== null ? Promise.reject<Uint8Array | null>(this.fatal) :
      new Promise<Uint8Array | null>((_r: (v: Uint8Array | null) => void,
        reject: (e: Object) => void): void => { this.pendingRejects.push(reject); });
  }
  write(data: Uint8Array): Promise<number> {
    if (this.fatal !== null) return Promise.reject<number>(this.fatal);
    const copy = new Uint8Array(data.length); copy.set(data); this.writtenFrames.push(copy);
    return Promise.resolve(data.length);
  }
  async close(): Promise<void> {
    this.closeCalls += 1; this.failPending(ArkDbError.network('closed'));
    if (this.closeFailure !== null) throw this.closeFailure;
  }
  async abort(error: ArkDbError): Promise<void> {
    this.abortCalls += 1; this.failPending(error);
    if (this.abortFailure !== null) throw this.abortFailure;
  }
  private failPending(error: ArkDbError): void {
    if (this.fatal === null) this.fatal = error;
    const waiters = this.pendingRejects; this.pendingRejects = [];
    for (const reject of waiters) reject(this.fatal);
  }
}
function syncFail(op: () => void): ArkDbError {
  let failure: Object | null = null;
  try { op(); } catch (e) { failure = e as Object; }
  expect(failure instanceof ArkDbError).assertTrue(); return failure as ArkDbError;
}
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> {
  let failure: Object | null = null;
  try { await op(); } catch (e) { failure = e as Object; }
  expect(failure instanceof ArkDbError).assertTrue(); return failure as ArkDbError;
}
function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]);
}
