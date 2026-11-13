import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort } from '@arkdb/core';
import { PostgresConnection } from '../../../main/ets/pgsql/PostgresConnection';
import { PostgresConnectionLifecycle, PostgresLifecycleTransport, PostgresStartupContext, PostgresStartupRunner } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { PostgresCommandGate, PostgresCommandKind, PostgresCommandLifecycleObserver, PostgresCommandPhase, PostgresCommandScope } from '../../../main/ets/pgsql/execution/PostgresCommandGate';
import { PostgresCommandCloseSettlement } from '../../../main/ets/pgsql/execution/PostgresSettlements';
import { PostgresConnectionConfig, PostgresSslMode } from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
import { PostgresError, PostgresTransactionState } from '../../../main/ets/pgsql/model/PostgresModels';
import { PostgresMessageChannel, PostgresReadyStatus } from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresConnectionLifecycleTest(): void {
  describe('PostgresConnectionLifecycle', () => {
    it('transitionsConnectThroughAuthenticatingToReadyWithIsolatedSecrets', 0, async () => {
      expect(syncFail((): void => { new PostgresConnectionLifecycle(new PostgresConnectionConfig(), 'pw'); }).kind).assertEqual(ArkDbErrorKind.Validation);
      const defaultTp = new FakeLifecycleTransport();
      defaultTp.queuedReads.push(new Uint8Array([0x52, 0, 0, 0, 8]), new Uint8Array([0, 0, 0, 0]), new Uint8Array([0x5a, 0, 0, 0, 5]), new Uint8Array([0x49]));
      const callerCfg = validConfig(); callerCfg.ssl.mode = PostgresSslMode.DISABLED;
      const defaultLc = new PostgresConnectionLifecycle(callerCfg, 'pw-default', new FakeTimerPort(),
        (): PostgresLifecycleTransport => defaultTp);
      callerCfg.host = '';
      expect(defaultLc.config.host === 'db.example.internal' && defaultLc.state === ConnectionState.Idle &&
        !defaultLc.sessionStatus.known && defaultLc.serverInfo.driverId === 'pgsql' && defaultLc.serverInfo.productName === 'PostgreSQL').assertTrue();
      let connErr1: Object | null = null; try { await defaultLc.connect(); } catch (e) { connErr1 = e as Object; }
      expect(connErr1 === null && defaultLc.state === ConnectionState.Ready && defaultLc.sessionStatus.known && defaultLc.commandGate.current === null).assertTrue();
      await defaultLc.close(); await defaultLc.close();
      expect(defaultLc.state === ConnectionState.Closed && defaultLc.commandGate.generation === 1).assertTrue();
      expect((await asyncFail((): Promise<void> => defaultLc.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);

      const password = 'pw-never-serialized-991'; const secretBytes = new Uint8Array([0x12, 0x34, 0x56, 0x78]);
      const transport = new FakeLifecycleTransport();
      const states: string[] = []; let capturedCtx: PostgresStartupContext | null = null; let readPw = '';
      const lc = new PostgresConnectionLifecycle(validConfig(), password, new FakeTimerPort(),
        (): PostgresLifecycleTransport => transport, async (ctx: PostgresStartupContext): Promise<void> => {
          capturedCtx = ctx; states.push(lc.state + ':' + ctx.scope.phase);
          for (const preAuth of [(): void => { ctx.readPassword(); }, (): void => ctx.setBackendKeyData(4242, secretBytes), (): void => ctx.applyReadyStatus(PostgresReadyStatus.Idle)]) {
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
          ctx.serverInfo.tlsActive = true; ctx.serverInfo.version = '16.4';
          ctx.setBackendKeyData(4242, secretBytes); ctx.applyReadyStatus(PostgresReadyStatus.Idle);
          for (const postReady of [(): void => { ctx.readPassword(); }, (): void => ctx.enterAuthenticating(), (): void => ctx.setBackendKeyData(7, secretBytes), (): void => ctx.applyReadyStatus(PostgresReadyStatus.Idle)]) {
            expect(syncFail(postReady).kind).assertEqual(ArkDbErrorKind.Protocol);
          }
        });
      transport.onConnect = (): void => { states.push(lc.state); };
      await lc.connect();
      expect(lc.state === ConnectionState.Ready && readPw === password && capturedCtx!.settlement.isSettled && lc.commandGate.current === null &&
        states.join(',') === 'connecting,connecting:connecting,authenticating:authenticating').assertTrue();
      expect(syncFail((): void => { capturedCtx!.readPassword(); }).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<number> => capturedCtx!.transport.write(new Uint8Array([1])))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<void> => capturedCtx!.transport.close())).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(lc.state === ConnectionState.Ready && lc.serverInfo.backendProcessId === 4242 && lc.serverInfo.tlsActive && lc.serverInfo.version === '16.4' &&
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
      let markClosing: () => void = (): void => {};
      const closeEntered = new Promise<void>((r: () => void): void => { markClosing = r; });
      transport.onClose = markClosing;
      transport.hangClose = true; transport.closeFailure = ArkDbError.network('socket close failed');
      const pendingClose = lc.close();
      expect(lc.state === ConnectionState.Closed && lc.readBackendKeyData() === null && !lc.sessionStatus.known && !lc.serverInfo.tlsActive &&
        lc.serverInfo.backendProcessId === 0 && lc.serverInfo.connectionHandle === '' && lc.serverInfo.version === '' &&
        lc.serverInfo.driverId === 'pgsql' && lc.serverInfo.productName === 'PostgreSQL').assertTrue();
      await closeEntered;
      transport.releaseHungAbort();
      expect((await asyncFail((): Promise<void> => pendingClose)).message).assertEqual('socket close failed');
      expect(lc.state === ConnectionState.Closed && lc.commandGate.generation === 1 &&
        transport.closeCalls === 1 && transport.writtenFrames.length === 1).assertTrue();
      assertBytes(transport.writtenFrames[0], [0x58, 0x00, 0x00, 0x00, 0x04]);
      await lc.close();
      expect(transport.closeCalls === 1 && transport.writtenFrames.length === 1).assertTrue();
    });

    it('timesOutAndCleansUpFailedConnectScrubbingSecrets', 0, async () => {
      const timers = new FakeTimerPort(); const stalled = new FakeLifecycleTransport();
      let unblockHungStartup: () => void = (): void => {}; let markEntered: () => void = (): void => {};
      const startupEntered = new Promise<void>((r: () => void): void => { markEntered = r; });
      const cfg = validConfig(); cfg.connectTimeoutMs = 2500;
      const timeoutLc = new PostgresConnectionLifecycle(cfg, 'secret-timeout', timers, (): PostgresLifecycleTransport => stalled,
        async (ctx: PostgresStartupContext): Promise<void> => {
          ctx.enterAuthenticating(); ctx.serverInfo.version = '16.4'; markEntered();
          await new Promise<void>((r: () => void): void => { unblockHungStartup = r; });
          ctx.serverInfo.version = 'late-17.0'; ctx.serverInfo.tlsActive = true;
        });
      const attempt = timeoutLc.connect(); await startupEntered; timers.advanceBy(2500);
      expect((await asyncFail((): Promise<void> => attempt)).kind).assertEqual(ArkDbErrorKind.Timeout);
      unblockHungStartup(); await Promise.resolve();
      expect(timeoutLc.state === ConnectionState.Error && !timeoutLc.sessionStatus.known && timeoutLc.serverInfo.version === '' && !timeoutLc.serverInfo.tlsActive &&
        timeoutLc.commandGate.current === null && timeoutLc.commandGate.generation === 1 && stalled.abortCalls === 1 && timers.activeCount === 0).assertTrue();

      const brokenTimers = new FakeTimerPort(); brokenTimers.failCancel = true;
      const authTransport = new FakeLifecycleTransport(); authTransport.hangAbort = true;
      let markAborting: () => void = (): void => {}; const abortEntered = new Promise<void>((r: () => void): void => { markAborting = r; });
      authTransport.onAbort = markAborting; authTransport.abortFailure = ArkDbError.network('cleanup socket failure');
      const authErr = new PostgresError(ArkDbErrorKind.Auth, 'SCRAM failed', '28P01', '28P01');
      let failedCtx: PostgresStartupContext | null = null;
      const failedLc = new PostgresConnectionLifecycle(validConfig(), 'secret-auth', brokenTimers, (): PostgresLifecycleTransport => authTransport,
        async (ctx: PostgresStartupContext): Promise<void> => {
          failedCtx = ctx; ctx.enterAuthenticating(); ctx.serverInfo.version = '16.4'; ctx.setBackendKeyData(9001, new Uint8Array([9, 8, 7, 6])); throw authErr;
        });
      const pendingFail = failedLc.connect(); await abortEntered;
      expect(failedLc.state === ConnectionState.Error && failedLc.readBackendKeyData() === null &&
        syncFail((): void => { failedCtx!.readPassword(); }).kind === ArkDbErrorKind.Protocol &&
        syncFail((): void => failedCtx!.setBackendKeyData(1, new Uint8Array([1, 2, 3, 4]))).kind === ArkDbErrorKind.Protocol &&
        (await asyncFail((): Promise<number> => failedCtx!.transport.write(new Uint8Array([1])))).kind === ArkDbErrorKind.Protocol).assertTrue();
      authTransport.releaseHungAbort();
      const caught = await asyncFail((): Promise<void> => pendingFail);
      expect(caught instanceof PostgresError && caught.sqlState === '28P01' && caught.message.indexOf('timer cancel failed') >= 0 &&
        caught.message.indexOf('cleanup socket failure') >= 0 && failedLc.state === ConnectionState.Error && failedLc.readBackendKeyData() === null &&
        failedLc.commandGate.current === null && failedLc.serverInfo.backendProcessId === 0 && failedLc.serverInfo.connectionHandle === '' &&
        failedLc.serverInfo.version === '' && !failedLc.sessionStatus.known).assertTrue();
      expect((await asyncFail((): Promise<void> => failedLc.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<number> => failedLc.runCommand<number>(PostgresCommandKind.Query, async (): Promise<number> => 1))).kind).assertEqual(ArkDbErrorKind.Protocol);
      await failedLc.close(); expect(failedLc.state === ConnectionState.Closed && authTransport.writtenFrames.length === 0).assertTrue();

      const shortStartupTp = new FakeLifecycleTransport(); shortStartupTp.shortWriteBytes = 1;
      const shortStartupLc = new PostgresConnectionLifecycle(validConfig(), 'pw-short', new FakeTimerPort(), (): PostgresLifecycleTransport => shortStartupTp,
        async (ctx: PostgresStartupContext): Promise<void> => {
          expect((await asyncFail((): Promise<number> => ctx.transport.write(new Uint8Array([1, 2])))).kind).assertEqual(ArkDbErrorKind.Protocol);
          expect((await asyncFail((): Promise<void> => ctx.channel.writeMessage(0x51, new Uint8Array([0])))).kind).assertEqual(ArkDbErrorKind.Protocol);
        });
      expect((await asyncFail((): Promise<void> => shortStartupLc.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      for (const badStartup of [async (): Promise<void> => {}, async (ctx: PostgresStartupContext): Promise<void> => { ctx.enterAuthenticating(); },
        async (ctx: PostgresStartupContext): Promise<void> => { ctx.enterAuthenticating(); ctx.applyReadyStatus(PostgresReadyStatus.Idle); await ctx.transport.write(new Uint8Array([0x58, 0, 0, 0, 4])); }]) {
        const badLc = startupLifecycle(badStartup);
        expect((await asyncFail((): Promise<void> => badLc.connect())).kind === ArkDbErrorKind.Protocol && badLc.state === ConnectionState.Error && !badLc.sessionStatus.known).assertTrue();
      }
      const retireTimers = new FakeTimerPort(); retireTimers.failCancel = true;
      const retireTransport = new FakeLifecycleTransport(); retireTransport.abortFailure = ArkDbError.network('retire abort failed');
      const startupRetireLc = new PostgresConnectionLifecycle(validConfig(), 'pw-retire', retireTimers, (): PostgresLifecycleTransport => retireTransport,
        async (ctx: PostgresStartupContext): Promise<void> => { await ctx.transport.abort(ArkDbError.tls('tls alert')); });
      const startupRetireCaught = await asyncFail((): Promise<void> => startupRetireLc.connect());
      expect(startupRetireCaught.kind === ArkDbErrorKind.Tls && startupRetireCaught.message.split('retire abort failed').length === 2 && startupRetireCaught.message.indexOf('timer cancel failed') >= 0).assertTrue();
    });

    it('serializesCommandsAndRetiresUnsynchronizedConnections', 0, async () => {
      const transport = new FakeLifecycleTransport();
      let terminalObservedSettled = false; let activeCheck: (() => boolean) | null = null;
      const gate = new PostgresCommandGate(new TerminalSettlementObserver((): void => { if (activeCheck !== null) terminalObservedSettled = activeCheck(); }));
      const lc = readyLifecycle(new FakeTimerPort(), transport, 'pw-cmd', gate);
      expect((await asyncFail((): Promise<number> => lc.runCommand<number>(PostgresCommandKind.Query, async (): Promise<number> => 1))).kind).assertEqual(ArkDbErrorKind.Protocol);
      await lc.connect();
      for (const badKind of [PostgresCommandKind.Connect, PostgresCommandKind.Close]) {
        expect((await asyncFail((): Promise<number> => lc.runCommand<number>(badKind, async (): Promise<number> => 1))).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      let unblock: () => void = (): void => {}; const blocked = new Promise<void>((r: () => void): void => { unblock = r; });
      let during: ConnectionState = ConnectionState.Idle; let runSettlement: PostgresCommandCloseSettlement | null = null;
      let finishedScope: PostgresCommandScope | null = null; let finishedChannel: PostgresMessageChannel | null = null;
      const first = lc.runCommand<string>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope, ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<string> => {
          during = lc.state; runSettlement = st; finishedScope = scope; finishedChannel = ch; activeCheck = (): boolean => st.isSettled;
          expect(scope.phase).assertEqual(PostgresCommandPhase.Executing);
          await ch.writeMessage(0x51, new Uint8Array([0])); await blocked; lc.applyReadyStatus(scope, PostgresReadyStatus.InTransaction); return 'ok';
        });
      expect(during).assertEqual(ConnectionState.Querying);
      expect((await asyncFail((): Promise<string> => lc.runCommand<string>(PostgresCommandKind.Ping, async (): Promise<string> => 'x'))).message).assertEqual('Another command already owns this PostgreSQL connection.');
      unblock();
      expect((await first) === 'ok' && lc.state === ConnectionState.Ready && lc.sessionStatus.inTransaction && runSettlement!.isSettled && terminalObservedSettled).assertTrue();
      activeCheck = null;
      expect(syncFail((): void => lc.applyReadyStatus(finishedScope!, PostgresReadyStatus.Idle)).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFail((): Promise<void> => finishedChannel!.writeMessage(999, new Uint8Array(0)))).kind).assertEqual(ArkDbErrorKind.Protocol);

      const sqlErr = new PostgresError(ArkDbErrorKind.Server, 'syntax error', '42601', '42601');
      expect(await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => {
          await ch.writeMessage(0x51, new Uint8Array([0])); lc.applyReadyStatus(scope, PostgresReadyStatus.FailedTransaction); throw sqlErr;
        }))).assertEqual(sqlErr);
      for (const nonWireErr of [ArkDbError.validation('bad param'), ArkDbError.unsupported('not yet')]) {
        expect(await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Query, async (): Promise<void> => { throw nonWireErr; }))).assertEqual(nonWireErr);
      }
      expect(lc.state === ConnectionState.Ready && lc.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction).assertTrue();

      const midWireTimeoutLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-mid');
      await midWireTimeoutLc.connect();
      expect((await asyncFail((): Promise<void> => midWireTimeoutLc.runCommand<void>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => { await ch.writeMessage(0x51, new Uint8Array([0])); throw ArkDbError.timeout('statement deadline'); }
      ))).kind === ArkDbErrorKind.Timeout && midWireTimeoutLc.state === ConnectionState.Error && !midWireTimeoutLc.sessionStatus.known).assertTrue();

      const noSyncReturnLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-nosync');
      await noSyncReturnLc.connect();
      expect((await asyncFail((): Promise<number> => noSyncReturnLc.runCommand<number>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<number> => { await ch.writeMessage(0x51, new Uint8Array([0])); return 1; }
      ))).kind === ArkDbErrorKind.Protocol && noSyncReturnLc.state === ConnectionState.Error).assertTrue();

      for (const useMalformedRead of [false, true]) {
        const damagedTransport = new FakeLifecycleTransport();
        if (useMalformedRead) damagedTransport.queuedReads.push(new Uint8Array([0x5a, 0, 0, 0, 2])); else damagedTransport.shortWriteBytes = 2;
        const damagedLc = readyLifecycle(new FakeTimerPort(), damagedTransport, 'pw-dmg');
        await damagedLc.connect();
        expect((await asyncFail((): Promise<void> => damagedLc.runCommand<void>(PostgresCommandKind.Query,
          async (scope: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => {
            try { if (useMalformedRead) await ch.readMessage(); else await ch.writeMessage(0x51, new Uint8Array([0])); } catch (_e) {}
            expect((await asyncFail((): Promise<void> => ch.writeMessage(0x51, new Uint8Array([0])))).kind).assertEqual(ArkDbErrorKind.Protocol);
            expect(syncFail((): void => damagedLc.applyReadyStatus(scope, PostgresReadyStatus.Idle)).kind).assertEqual(ArkDbErrorKind.Protocol);
          }))).kind === ArkDbErrorKind.Protocol && damagedLc.state === ConnectionState.Error).assertTrue();
      }
      const tlsWireTransport = new FakeLifecycleTransport(); const tlsWireLc = readyLifecycle(new FakeTimerPort(), tlsWireTransport, 'pw-tlswire');
      await tlsWireLc.connect(); tlsWireTransport.writeFailure = ArkDbError.tls('TLS bad record MAC');
      expect((await asyncFail((): Promise<void> => tlsWireLc.runCommand<void>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => { await ch.writeMessage(0x51, new Uint8Array([0])); }
      ))).kind === ArkDbErrorKind.Tls && tlsWireLc.state === ConnectionState.Error).assertTrue();
      const pendingIoTransport = new FakeLifecycleTransport(); pendingIoTransport.queuedReads.push(new Uint8Array([0x5a, 0, 0, 0, 5]));
      const pendingIoLc = readyLifecycle(new FakeTimerPort(), pendingIoTransport, 'pw-pend'); await pendingIoLc.connect();
      expect((await asyncFail((): Promise<void> => pendingIoLc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => {
          ch.readMessage().catch((): void => {}); await Promise.resolve();
          expect(syncFail((): void => pendingIoLc.applyReadyStatus(scope, PostgresReadyStatus.Idle)).kind).assertEqual(ArkDbErrorKind.Protocol);
        }))).kind === ArkDbErrorKind.Protocol && pendingIoLc.state === ConnectionState.Error && pendingIoTransport.abortCalls === 1).assertTrue();
      for (const useLocalized of [false, true]) {
        const fatalLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-fatal'); await fatalLc.connect();
        const fatalErr = new PostgresError(ArkDbErrorKind.Server, 'terminating', '57P01', '57P01');
        if (useLocalized) fatalErr.localizedSeverity = 'FATAL'; else fatalErr.severity = 'PANIC';
        expect(await asyncFail((): Promise<void> => fatalLc.runCommand<void>(PostgresCommandKind.Query, async (): Promise<void> => { throw fatalErr; }))).assertEqual(fatalErr);
        expect(fatalLc.state).assertEqual(ConnectionState.Error);
      }
      const closeSigLc = readyLifecycle(new FakeTimerPort(), new FakeLifecycleTransport(), 'pw-sig'); await closeSigLc.connect();
      expect((await asyncFail((): Promise<void> => closeSigLc.runCommand<void>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, _ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<void> => { st.signalClose(ArkDbError.cancelled('closed')); }
      ))).kind === ArkDbErrorKind.Cancelled && closeSigLc.state === ConnectionState.Closed).assertTrue();
      let throwTerminal = true;
      const throwingGate = (): PostgresCommandGate => new PostgresCommandGate(new TerminalSettlementObserver((): void => { if (throwTerminal) throw new Error('terminal observer boom'); }));
      const obsFailConnect = new PostgresConnectionLifecycle(validConfig(), 'pw-obs', new FakeTimerPort(), (): PostgresLifecycleTransport => new FakeLifecycleTransport(),
        async (): Promise<void> => { throw new PostgresError(ArkDbErrorKind.Auth, 'bad auth', '28P01', '28P01'); }, throwingGate());
      const obsConnectErr = await asyncFail((): Promise<void> => obsFailConnect.connect());
      expect(obsConnectErr instanceof PostgresError && obsConnectErr.sqlState === '28P01' && obsConnectErr.message.indexOf('terminal observer boom') >= 0).assertTrue();
      throwTerminal = false;
      const obsCloseTp = new FakeLifecycleTransport(); obsCloseTp.closeFailure = ArkDbError.network('close err');
      const obsCmdLc = readyLifecycle(new FakeTimerPort(), obsCloseTp, 'pw-obs2', throwingGate());
      await obsCmdLc.connect(); throwTerminal = true;
      const obsCmdErr = await asyncFail((): Promise<void> => obsCmdLc.runCommand<void>(PostgresCommandKind.Query, async (): Promise<void> => { throw new PostgresError(ArkDbErrorKind.Server, 'bad sql', '42601', '42601'); }));
      expect(obsCmdErr instanceof PostgresError && obsCmdErr.sqlState === '42601' && obsCmdErr.message.indexOf('terminal observer boom') >= 0 && obsCmdLc.state === ConnectionState.Ready).assertTrue();
      const obsCloseErr = await asyncFail((): Promise<void> => obsCmdLc.close());
      expect(obsCloseErr.message.indexOf('close err') >= 0 && obsCloseErr.message.indexOf('terminal observer boom') >= 0 && obsCmdLc.state === ConnectionState.Closed).assertTrue();      const desync = ArkDbError.protocol('Malformed DataRow frame');
      const primaryQueryErr = new PostgresError(ArkDbErrorKind.Server, 'aborted query', '57014', '57014');
      transport.abortFailure = ArkDbError.network('abort failed');
      const retiredErr = await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope): Promise<void> => {
          try { await lc.retire(scope, desync); } catch (_cleanup) { throw primaryQueryErr; }
        }));
      expect(retiredErr instanceof PostgresError && retiredErr.sqlState === '57014' &&
        retiredErr.message.split('abort failed').length === 2 && lc.state === ConnectionState.Error &&
        !lc.sessionStatus.known && lc.readBackendKeyData() === null && lc.serverInfo.backendProcessId === 0 &&
        lc.serverInfo.connectionHandle === '' && !lc.serverInfo.tlsActive && lc.serverInfo.driverId === 'pgsql' &&
        lc.commandGate.generation === 1 && transport.abortCalls === 1 && transport.writtenFrames.length === 2).assertTrue();
      expect((await asyncFail((): Promise<void> => lc.runCommand<void>(PostgresCommandKind.Ping, async (): Promise<void> => {}))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      await lc.close(); expect(lc.state).assertEqual(ConnectionState.Closed);
    });

    it('sendsBoundedTerminateOnReadyCloseAndSurvivesBrokenPipeOrTimeout', 0, async () => {
      let created = false;
      const idleLc = new PostgresConnectionLifecycle(validConfig(), 'pw-idle', new FakeTimerPort(),
        (): PostgresLifecycleTransport => { created = true; return new FakeLifecycleTransport(); });
      await idleLc.close(); await idleLc.close();
      expect(!created && idleLc.state === ConnectionState.Closed && idleLc.commandGate.generation === 1).assertTrue();

      const errorTp = new FakeLifecycleTransport(); const errorLc = readyLifecycle(new FakeTimerPort(), errorTp, 'pw-err');
      await errorLc.connect(); errorTp.writeFailure = ArkDbError.network('wire lost');
      expect((await asyncFail((): Promise<void> => errorLc.runCommand<void>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => { await ch.writeMessage(0x51, new Uint8Array([0])); }))).kind)
        .assertEqual(ArkDbErrorKind.Network);
      expect(errorLc.state).assertEqual(ConnectionState.Error);
      await errorLc.close();
      expect(errorLc.state === ConnectionState.Closed && errorTp.writtenFrames.length === 0 &&
        errorTp.abortCalls === 1 && errorTp.closeCalls === 0).assertTrue();

      const badReadyTp = new FakeLifecycleTransport(); const badReadyLc = readyLifecycle(new FakeTimerPort(), badReadyTp, 'pw-badready');
      await badReadyLc.connect();
      expect((await asyncFail((): Promise<void> => badReadyLc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope): Promise<void> => {
          try { badReadyLc.applyReadyStatus(scope, 0x3f as PostgresReadyStatus); } catch (_e) {}
        }))).kind === ArkDbErrorKind.Protocol && badReadyLc.state === ConnectionState.Error).assertTrue();
      await badReadyLc.close();
      expect(badReadyTp.writtenFrames.length === 0 && badReadyTp.abortCalls === 1).assertTrue();

      const politeTimers = new FakeTimerPort(); const politeTransport = new FakeLifecycleTransport();
      const politeLc = readyLifecycle(politeTimers, politeTransport, 'pw-polite');
      await politeLc.connect();
      const firstClose = politeLc.close(); const secondClose = politeLc.close();
      expect(firstClose === secondClose && politeLc.state === ConnectionState.Closed &&
        politeLc.readBackendKeyData() === null && !politeLc.sessionStatus.known && politeLc.serverInfo.backendProcessId === 0).assertTrue();
      await Promise.all([firstClose, secondClose]);
      expect(politeLc.state === ConnectionState.Closed && !politeLc.sessionStatus.known &&
        politeLc.commandGate.current === null && politeLc.commandGate.generation === 1 &&
        politeTransport.writtenFrames.length === 1 && politeTransport.events.join(',') === 'connect,write,close' &&
        politeTimers.activeCount === 0).assertTrue();
      assertBytes(politeTransport.writtenFrames[0], [0x58, 0x00, 0x00, 0x00, 0x04]);
      await politeLc.close();
      expect(politeTransport.writtenFrames.length === 1 && politeTransport.closeCalls === 1 && politeLc.commandGate.generation === 1).assertTrue();

      const partialTp = new FakeLifecycleTransport(); const partialLc = readyLifecycle(new FakeTimerPort(), partialTp, 'pw-partial');
      await partialLc.connect(); partialTp.shortWriteBytes = 2; await partialLc.close();
      expect(partialTp.writtenFrames.length === 3 && partialTp.closeCalls === 1).assertTrue();
      assertBytes(partialTp.writtenFrames[0], [0x58, 0x00, 0x00, 0x00, 0x04]);
      assertBytes(partialTp.writtenFrames[1], [0x00, 0x00, 0x04]); assertBytes(partialTp.writtenFrames[2], [0x04]);

      const brokenReadyTimers = new FakeTimerPort(); const brokenReady = new FakeLifecycleTransport();
      const brokenReadyLc = readyLifecycle(brokenReadyTimers, brokenReady, 'pw-epipe');
      await brokenReadyLc.connect(); brokenReadyTimers.failCancel = true; brokenReady.writeFailure = ArkDbError.network('EPIPE broken pipe');
      await brokenReadyLc.close();
      expect(brokenReadyLc.state === ConnectionState.Closed && brokenReady.closeCalls === 1 && brokenReadyTimers.activeCount === 0).assertTrue();

      const closeFailTransport = new FakeLifecycleTransport();
      const closeFailLc = readyLifecycle(new FakeTimerPort(), closeFailTransport, 'pw-close-fail');
      await closeFailLc.connect(); closeFailTransport.closeFailure = ArkDbError.network('socket close failed');
      expect((await asyncFail((): Promise<void> => closeFailLc.close())).message).assertEqual('socket close failed');
      expect(closeFailLc.state === ConnectionState.Closed && closeFailTransport.writtenFrames.length === 1).assertTrue();
      assertBytes(closeFailTransport.writtenFrames[0], [0x58, 0x00, 0x00, 0x00, 0x04]);
      await closeFailLc.close(); expect(closeFailTransport.closeCalls).assertEqual(1);

      const hungTimers = new FakeTimerPort(); const hungTransport = new FakeLifecycleTransport();
      const hungLc = readyLifecycle(hungTimers, hungTransport, 'pw-hung');
      await hungLc.connect(); hungTransport.hangWrite = true;
      let closed = false; const closing = hungLc.close().then((): void => { closed = true; });
      expect(hungLc.state === ConnectionState.Closed && hungLc.readBackendKeyData() === null && !hungLc.sessionStatus.known).assertTrue();
      hungTimers.advanceBy(999); await flushMicrotasks();
      expect(!closed && hungTransport.closeCalls === 0 && hungTimers.activeCount === 1).assertTrue();
      hungTimers.advanceBy(1); await closing;
      expect(closed && hungLc.state === ConnectionState.Closed && hungTransport.closeCalls === 1 &&
        hungTimers.activeCount === 0 && hungTransport.writtenFrames.length === 0).assertTrue();
    });

    it('abortsWithoutMidStreamTerminateWhenCloseRacesConnectOrActiveCommand', 0, async () => {
      const connectTimers = new FakeTimerPort(); const connectRace = new FakeLifecycleTransport(); connectRace.hangConnect = true;
      const connectLc = readyLifecycle(connectTimers, connectRace, 'pw-race-c');
      const pendingConnect = connectLc.connect(); const cClose1 = connectLc.close(); const cClose2 = connectLc.close();
      expect(cClose1 === cClose2 && connectLc.state === ConnectionState.Closed && connectTimers.activeCount === 0).assertTrue();
      expect((await asyncFail((): Promise<void> => pendingConnect)).kind).assertEqual(ArkDbErrorKind.Cancelled);
      await Promise.all([cClose1, cClose2]);
      expect(connectLc.state === ConnectionState.Closed && connectLc.commandGate.current === null &&
        connectLc.commandGate.generation === 1 && connectRace.abortCalls === 1 &&
        connectRace.closeCalls === 0 && connectRace.writtenFrames.length === 0).assertTrue();

      const authRaceTimers = new FakeTimerPort(); const authRaceTp = new FakeLifecycleTransport();
      authRaceTp.abortFailure = ArkDbError.network('abort during auth failed');
      let markAuthReady: () => void = (): void => {}; const authEntered = new Promise<void>((r: () => void): void => { markAuthReady = r; });
      const authRaceLc = new PostgresConnectionLifecycle(validConfig(), 'pw-race-auth', authRaceTimers, (): PostgresLifecycleTransport => authRaceTp,
        async (ctx: PostgresStartupContext): Promise<void> => {
          ctx.enterAuthenticating(); ctx.serverInfo.version = '16.4'; ctx.setBackendKeyData(7777, new Uint8Array([1, 2, 3, 4]));
          markAuthReady(); await ctx.channel.readMessage();
        });
      const pendingAuthConnect = authRaceLc.connect(); await authEntered; const authClose = authRaceLc.close();
      expect(authRaceLc.state === ConnectionState.Closed && authRaceLc.readBackendKeyData() === null &&
        authRaceLc.serverInfo.version === '' && authRaceLc.serverInfo.backendProcessId === 0).assertTrue();
      const authRaceErr = await asyncFail((): Promise<void> => pendingAuthConnect);
      expect(authRaceErr.kind === ArkDbErrorKind.Cancelled && authRaceErr.message.indexOf('abort during auth failed') >= 0).assertTrue();
      expect((await asyncFail((): Promise<void> => authClose)).message).assertEqual('abort during auth failed');
      expect(authRaceTp.writtenFrames.length === 0 && authRaceTp.abortCalls === 1).assertTrue();
      await authRaceLc.close();

      for (const queuePartialHeader of [false, true]) {
        const queryRace = new FakeLifecycleTransport();
        if (queuePartialHeader) queryRace.queuedReads.push(new Uint8Array([0x5a, 0x00]));
        const queryLc = readyLifecycle(new FakeTimerPort(), queryRace, 'pw-race-q');
        await queryLc.connect();
        let markReading: () => void = (): void => {}; const readingStarted = new Promise<void>((r: () => void): void => { markReading = r; });
        const pendingQuery = queryLc.runCommand<void>(PostgresCommandKind.Query,
          async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => {
            const readPromise = ch.readMessage(); markReading(); await readPromise;
          });
        await readingStarted; if (queuePartialHeader) await flushMicrotasks();
        const qClose1 = queryLc.close(); const qClose2 = queryLc.close();
        expect(qClose1 === qClose2 && queryLc.state === ConnectionState.Closed && queryLc.readBackendKeyData() === null &&
          !queryLc.sessionStatus.known && queryLc.serverInfo.backendProcessId === 0).assertTrue();
        expect((await asyncFail((): Promise<void> => pendingQuery)).kind).assertEqual(ArkDbErrorKind.Cancelled);
        await Promise.all([qClose1, qClose2]);
        expect(queryLc.state === ConnectionState.Closed && !queryLc.sessionStatus.known && queryLc.commandGate.current === null &&
          queryLc.commandGate.generation === 1 && queryRace.abortCalls === 1 && queryRace.closeCalls === 0 &&
          queryRace.writtenFrames.length === 0).assertTrue();
      }

      const reentrantTransport = new FakeLifecycleTransport();
      const reentrantLc = readyLifecycle(new FakeTimerPort(), reentrantTransport, 'pw-reentrant');
      await reentrantLc.connect();
      const reentrantErr = await asyncFail((): Promise<void> =>
        reentrantLc.runCommand<void>(PostgresCommandKind.QueryStream,
          async (_s: PostgresCommandScope, _ch: PostgresMessageChannel, st: PostgresCommandCloseSettlement): Promise<void> => {
            await st.raceClose((): Promise<void> => reentrantLc.close());
          }));
      expect(reentrantErr.kind === ArkDbErrorKind.Cancelled && reentrantLc.state === ConnectionState.Closed &&
        reentrantLc.commandGate.current === null && reentrantLc.commandGate.generation === 1 &&
        reentrantTransport.abortCalls === 1 && reentrantTransport.writtenFrames.length === 0).assertTrue();

      let throwDirectObs = false;
      const directObsGate = new PostgresCommandGate(
        new TerminalSettlementObserver((): void => { if (throwDirectObs) throw new Error('direct reentrant terminal boom'); }));
      const directCloseTp = new FakeLifecycleTransport(); directCloseTp.abortFailure = ArkDbError.network('direct close abort failed');
      const directCloseLc = readyLifecycle(new FakeTimerPort(), directCloseTp, 'pw-direct-close', directObsGate);
      await directCloseLc.connect(); throwDirectObs = true;
      let directCloseErrMessage = ''; let directCloseReturned = false;
      let markDirectRunnerDone: () => void = (): void => {};
      const directRunnerDone = new Promise<void>((r: () => void): void => { markDirectRunnerDone = r; });
      const directRun = directCloseLc.runCommand<void>(PostgresCommandKind.QueryStream, async (scope: PostgresCommandScope): Promise<void> => {
        try {
          const closeTask = directCloseLc.close();
          expect(syncFail((): void => directCloseLc.applyReadyStatus(scope, PostgresReadyStatus.Idle)).kind).assertEqual(ArkDbErrorKind.Cancelled);
          const raced = await Promise.race<string>([
            closeTask.then((): string => 'resolved', (e: Object): string => { directCloseErrMessage = (e as ArkDbError).message; return 'rejected'; }),
            flushManyMicrotasks(40).then((): string => 'deadlocked')
          ]);
          directCloseReturned = raced !== 'deadlocked';
        } finally { markDirectRunnerDone(); }
      });
      const directRunErr = await asyncFail((): Promise<void> => directRun);
      await directRunnerDone;
      expect(directCloseReturned && directCloseErrMessage.indexOf('direct close abort failed') >= 0 &&
        directCloseErrMessage.indexOf('direct reentrant terminal boom') >= 0 &&
        directRunErr.kind === ArkDbErrorKind.Cancelled && directRunErr.message.indexOf('direct close abort failed') >= 0 &&
        directRunErr.message.indexOf('direct reentrant terminal boom') >= 0 &&
        directCloseLc.state === ConnectionState.Closed && directCloseLc.commandGate.current === null &&
        directCloseLc.commandGate.generation === 1 && directCloseTp.abortCalls === 1 && directCloseTp.writtenFrames.length === 0).assertTrue();
      await directCloseLc.close();

      let postTermClose: Promise<void> | null = null;
      const postTermTp = new FakeLifecycleTransport(); postTermTp.abortFailure = ArkDbError.network('post-terminal abort failed');
      const postTermGate = new PostgresCommandGate(new TerminalSettlementObserver((): void => { throw new Error('connect terminal boom'); }));
      const postTermLc = readyLifecycle(new FakeTimerPort(), postTermTp, 'pw-post-term', postTermGate);
      postTermTp.onAbort = (): void => { postTermClose = postTermLc.close(); };
      const postTermConnectErr = await asyncFail((): Promise<void> => postTermLc.connect());
      expect(postTermConnectErr.message.indexOf('connect terminal boom') >= 0 &&
        postTermConnectErr.message.indexOf('post-terminal abort failed') >= 0).assertTrue();
      expect((await asyncFail((): Promise<void> => postTermClose!)).message).assertEqual('post-terminal abort failed');
      expect(postTermLc.state === ConnectionState.Closed && postTermTp.abortCalls === 1).assertTrue();

      const timerReentryTimers = new FakeTimerPort(); const timerReentryTp = new FakeLifecycleTransport();
      const timerReentryLc = readyLifecycle(timerReentryTimers, timerReentryTp, 'pw-timer-reentry');
      let timerCancelClose: Promise<void> | null = null;
      timerReentryTimers.onCancel = (): void => { if (timerCancelClose === null) timerCancelClose = timerReentryLc.close(); };
      expect((await asyncFail((): Promise<void> => timerReentryLc.connect())).kind).assertEqual(ArkDbErrorKind.Cancelled);
      await timerCancelClose!;
      expect(timerReentryLc.state === ConnectionState.Closed && timerReentryLc.readBackendKeyData() === null &&
        timerReentryLc.serverInfo.backendProcessId === 0 && timerReentryLc.commandGate.generation === 1 &&
        timerReentryTp.abortCalls === 1 && timerReentryTp.writtenFrames.length === 0).assertTrue();

      let throwRaceObs = false;
      const obsRaceGate = new PostgresCommandGate(
        new TerminalSettlementObserver((): void => { if (throwRaceObs) throw new Error('close race terminal boom'); }));
      const obsRaceTp = new FakeLifecycleTransport(); obsRaceTp.readRejectDelayTicks = 30;
      obsRaceTp.abortFailure = ArkDbError.network('close race abort failed');
      const obsRaceLc = readyLifecycle(new FakeTimerPort(), obsRaceTp, 'pw-obs-race', obsRaceGate);
      await obsRaceLc.connect(); throwRaceObs = true;
      let markObsRead: () => void = (): void => {}; const obsReadStarted = new Promise<void>((r: () => void): void => { markObsRead = r; });
      const pendingObsQuery = obsRaceLc.runCommand<void>(PostgresCommandKind.Query,
        async (_s: PostgresCommandScope, ch: PostgresMessageChannel): Promise<void> => {
          const r = ch.readMessage(); markObsRead(); await r;
        });
      await obsReadStarted;
      const obsRacingClose = obsRaceLc.close();
      const obsRacingCloseErr = await asyncFail((): Promise<void> => obsRacingClose);
      expect(obsRaceLc.commandGate.current === null && obsRaceLc.commandGate.generation === 1 &&
        obsRacingCloseErr.message.indexOf('close race abort failed') >= 0 &&
        obsRacingCloseErr.message.indexOf('close race terminal boom') >= 0).assertTrue();
      const obsQueryErr = await asyncFail((): Promise<void> => pendingObsQuery);
      expect(obsQueryErr.kind === ArkDbErrorKind.Cancelled && obsQueryErr.message.indexOf('close race abort failed') >= 0 &&
        obsQueryErr.message.indexOf('close race terminal boom') >= 0 && obsRaceLc.state === ConnectionState.Closed).assertTrue();
      await obsRaceLc.close();

      const retireRaceTp = new FakeLifecycleTransport(); retireRaceTp.hangAbort = true;
      retireRaceTp.abortFailure = ArkDbError.network('retire race abort failed');
      let markRetireAbort: () => void = (): void => {}; const retireAbortEntered = new Promise<void>((r: () => void): void => { markRetireAbort = r; });
      retireRaceTp.onAbort = markRetireAbort;
      const retireRaceLc = readyLifecycle(new FakeTimerPort(), retireRaceTp, 'pw-retire-race');
      await retireRaceLc.connect();
      const pendingRetireCmd = retireRaceLc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope): Promise<void> => { await retireRaceLc.retire(scope, ArkDbError.protocol('frame desync')); });
      await retireAbortEntered;
      const racingCloseOnRetire = retireRaceLc.close(); expect(retireRaceLc.state).assertEqual(ConnectionState.Closed);
      retireRaceTp.releaseHungAbort();
      const retireCmdErr = await asyncFail((): Promise<void> => pendingRetireCmd);
      expect(retireCmdErr.kind === ArkDbErrorKind.Protocol && retireCmdErr.message.split('retire race abort failed').length === 2).assertTrue();
      expect((await asyncFail((): Promise<void> => racingCloseOnRetire)).message).assertEqual('retire race abort failed');
      expect(retireRaceLc.state === ConnectionState.Closed && retireRaceLc.commandGate.current === null &&
        retireRaceLc.commandGate.generation === 1 && retireRaceTp.abortCalls === 1 && retireRaceTp.writtenFrames.length === 0).assertTrue();
      await retireRaceLc.close();

      const retireWinTp = new FakeLifecycleTransport();
      retireWinTp.abortFailure = ArkDbError.network('post-retire window abort failed');
      const retireWinLc = readyLifecycle(new FakeTimerPort(), retireWinTp, 'pw-retire-win');
      await retireWinLc.connect();
      let markPostRetireWindow: () => void = (): void => {};
      const postRetireWindow = new Promise<void>((r: () => void): void => { markPostRetireWindow = r; });
      let unblockRetireWindow: () => void = (): void => {};
      const holdRetireWindow = new Promise<void>((r: () => void): void => { unblockRetireWindow = r; });
      const pendingWinCmd = retireWinLc.runCommand<void>(PostgresCommandKind.Query,
        async (scope: PostgresCommandScope): Promise<void> => {
          try { await retireWinLc.retire(scope, ArkDbError.protocol('window desync')); } catch (err) {
            markPostRetireWindow(); await holdRetireWindow; throw err as Error;
          }
        });
      await postRetireWindow;
      const winClose = retireWinLc.close();
      unblockRetireWindow();
      expect((await asyncFail((): Promise<void> => pendingWinCmd)).message.indexOf('post-retire window abort failed') >= 0).assertTrue();
      expect((await asyncFail((): Promise<void> => winClose)).message).assertEqual('post-retire window abort failed');
      expect(retireWinLc.state === ConnectionState.Closed && retireWinTp.abortCalls === 1).assertTrue();
      await retireWinLc.close();

      let startCloseCreated = false; let startCloseLc: PostgresConnectionLifecycle | null = null;
      const startCloseGate = new PostgresCommandGate(
        new TerminalSettlementObserver((): void => {}, (): void => { startCloseLc!.close().catch((): void => {}); }));
      startCloseLc = new PostgresConnectionLifecycle(validConfig(), 'pw-onstart', new FakeTimerPort(),
        (): PostgresLifecycleTransport => { startCloseCreated = true; return new FakeLifecycleTransport(); },
        async (): Promise<void> => {}, startCloseGate);
      expect((await asyncFail((): Promise<void> => startCloseLc!.connect())).kind).assertEqual(ArkDbErrorKind.Cancelled);
      expect(!startCloseCreated && startCloseLc.state === ConnectionState.Closed &&
        startCloseLc.commandGate.current === null && startCloseLc.commandGate.generation === 1).assertTrue();

      let factoryCloseLc: PostgresConnectionLifecycle | null = null; let pendingFactoryClose: Promise<void> | null = null;
      const factoryAbortTp = new FakeLifecycleTransport(); factoryAbortTp.abortFailure = ArkDbError.network('factory race abort failed');
      factoryCloseLc = new PostgresConnectionLifecycle(validConfig(), 'pw-onfactory', new FakeTimerPort(),
        (): PostgresLifecycleTransport => { pendingFactoryClose = factoryCloseLc!.close(); return factoryAbortTp; },
        async (): Promise<void> => {});
      const factoryConnectErr = await asyncFail((): Promise<void> => factoryCloseLc!.connect());
      expect(factoryConnectErr.kind === ArkDbErrorKind.Cancelled && factoryConnectErr.message.indexOf('factory race abort failed') >= 0).assertTrue();
      expect((await asyncFail((): Promise<void> => pendingFactoryClose!)).message).assertEqual('factory race abort failed');
      expect(factoryCloseLc.state === ConnectionState.Closed && factoryAbortTp.abortCalls === 1 && factoryAbortTp.writtenFrames.length === 0).assertTrue();

      const extTp = new FakeLifecycleTransport(); extTp.abortFailure = ArkDbError.network('ext scope abort failed');
      const extLc = readyLifecycle(new FakeTimerPort(), extTp, 'pw-ext-scope');
      await extLc.connect();
      const extScope = extLc.commandGate.reserve(PostgresCommandKind.Transaction); extLc.commandGate.start(extScope);
      expect((await asyncFail((): Promise<void> => extLc.retire(extScope, ArkDbError.protocol('ext desync')))).message
        .indexOf('ext scope abort failed') >= 0).assertTrue();
      expect((await asyncFail((): Promise<void> => extLc.close())).message).assertEqual('ext scope abort failed');
      await extLc.close();
      expect(extLc.state === ConnectionState.Closed && extLc.readBackendKeyData() === null &&
        extScope.phase === PostgresCommandPhase.Closing && extTp.abortCalls === 1 && extTp.writtenFrames.length === 0).assertTrue();
      extLc.commandGate.release(extScope);
      await extLc.close();
      expect(extLc.commandGate.current === null && extLc.commandGate.generation === 1).assertTrue();

      expect(syncFail((): void => { new PostgresConnection(new PostgresConnectionConfig(), 'pw'); }).kind).assertEqual(ArkDbErrorKind.Validation);
      const defaultConnTp = new FakeLifecycleTransport();
      defaultConnTp.queuedReads.push(new Uint8Array([0x52, 0, 0, 0, 8]), new Uint8Array([0, 0, 0, 0]), new Uint8Array([0x5a, 0, 0, 0, 5]), new Uint8Array([0x49]));
      const defaultConnCfg = validConfig(); defaultConnCfg.ssl.mode = PostgresSslMode.DISABLED;
      const defaultConn = new PostgresConnection(defaultConnCfg, 'pw-default-conn', new FakeTimerPort(), (): PostgresLifecycleTransport => defaultConnTp);
      let connErr2: Object | null = null; try { await defaultConn.connect(); } catch (e) { connErr2 = e as Object; }
      expect(connErr2 === null && defaultConn.state === ConnectionState.Ready).assertTrue();
      const dc1 = defaultConn.close(); const dc2 = defaultConn.close();
      expect(dc1 === dc2 && defaultConn.state === ConnectionState.Closed).assertTrue();
      await Promise.all([dc1, dc2]);
      expect((await asyncFail((): Promise<void> => defaultConn.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);

      const facadePw = 'pw-conn-facade-77'; const facadeTp = new FakeLifecycleTransport();
      const facadeTimers = new FakeTimerPort(); const facadeStates: ConnectionState[] = []; const facadeCfg = validConfig();
      const conn = new PostgresConnection(facadeCfg, facadePw, facadeTimers, (): PostgresLifecycleTransport => facadeTp,
        async (ctx: PostgresStartupContext): Promise<void> => {
          facadeStates.push(conn.state); ctx.enterAuthenticating(); facadeStates.push(conn.state);
          expect(ctx.readPassword()).assertEqual(facadePw);
          ctx.serverInfo.version = '17.2'; ctx.serverInfo.tlsActive = true;
          ctx.setBackendKeyData(4242, new Uint8Array([0x12, 0x34, 0x56, 0x78])); ctx.applyReadyStatus(PostgresReadyStatus.Idle);
        });
      facadeCfg.host = ''; facadeTp.onConnect = (): void => { facadeStates.push(conn.state); };
      expect(conn.state === ConnectionState.Idle && !conn.sessionStatus.known &&
        conn.serverInfo.driverId === 'pgsql' && conn.serverInfo.productName === 'PostgreSQL').assertTrue();
      await conn.connect();
      expect(conn.state === ConnectionState.Ready && facadeStates.join(',') === 'connecting,connecting,authenticating' &&
        conn.serverInfo.backendProcessId === 4242 && conn.serverInfo.connectionHandle === '4242' &&
        conn.serverInfo.version === '17.2' && conn.serverInfo.tlsActive &&
        conn.sessionStatus.known && conn.sessionStatus.autocommit && !conn.sessionStatus.inTransaction).assertTrue();
      const statusSnapshot = conn.sessionStatus; statusSnapshot.known = false; statusSnapshot.inTransaction = true;
      expect(conn.sessionStatus.known && !conn.sessionStatus.inTransaction).assertTrue();
      const connDump = JSON.stringify(conn) + JSON.stringify(conn.serverInfo);
      expect(connDump.indexOf(facadePw) === -1 && connDump.indexOf('305419896') === -1 && connDump.indexOf('18,52,86,120') === -1).assertTrue();
      const fc1 = conn.close(); const fc2 = conn.close();
      expect(fc1 === fc2 && conn.state === ConnectionState.Closed && !conn.sessionStatus.known &&
        conn.serverInfo.backendProcessId === 0 && conn.serverInfo.version === '' && !conn.serverInfo.tlsActive).assertTrue();
      await Promise.all([fc1, fc2]);
      expect(facadeTp.writtenFrames.length === 1 && facadeTp.closeCalls === 1 && facadeTimers.activeCount === 0).assertTrue();
      assertBytes(facadeTp.writtenFrames[0], [0x58, 0x00, 0x00, 0x00, 0x04]);
      expect((await asyncFail((): Promise<void> => conn.connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      await conn.close();
      expect(facadeTp.writtenFrames.length === 1 && facadeTp.closeCalls === 1).assertTrue();
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
      ctx.enterAuthenticating(); ctx.serverInfo.tlsActive = true; ctx.setBackendKeyData(5150, new Uint8Array([10, 20, 30, 40])); ctx.applyReadyStatus(PostgresReadyStatus.Idle);
    }, gate);
}
class TerminalSettlementObserver implements PostgresCommandLifecycleObserver {
  private readonly onDone: () => void; private readonly onBegin: (() => void) | null;
  constructor(onDone: () => void, onBegin?: () => void) { this.onDone = onDone; this.onBegin = onBegin === undefined ? null : onBegin; }
  onStart(_scope: PostgresCommandScope): void { if (this.onBegin !== null) this.onBegin(); }
  onTerminal(_scope: PostgresCommandScope): void { this.onDone(); }
}
interface ScheduledTimer { id: number; dueAtMs: number; handler: () => void; }
class FakeTimerPort implements ConnectionTimerPort {
  failCancel: boolean = false; onCancel: (() => void) | null = null;
  private currentMs: number = 1000; private nextId: number = 1; private timers: ScheduledTimer[] = [];
  get activeCount(): number { return this.timers.length; } nowMs(): number { return this.currentMs; }
  schedule(handler: () => void, timeoutMs: number): number { const id = this.nextId++; this.timers.push({ id: id, dueAtMs: this.currentMs + timeoutMs, handler: handler }); return id; }
  cancel(timerId: number): void {
    for (let i = 0; i < this.timers.length; i += 1) { if (this.timers[i].id === timerId) { this.timers.splice(i, 1); break; } }
    if (this.onCancel !== null) this.onCancel();
    if (this.failCancel) throw new Error('timer cancel failed');
  }
  advanceBy(deltaMs: number): void {
    const target = this.currentMs + deltaMs;
    while (true) {
      let next = -1;
      for (let i = 0; i < this.timers.length; i += 1) { if (this.timers[i].dueAtMs <= target && (next < 0 || this.timers[i].dueAtMs < this.timers[next].dueAtMs)) next = i; }
      if (next < 0) break;
      const due = this.timers[next]; this.timers.splice(next, 1); this.currentMs = due.dueAtMs; due.handler();
    }
    this.currentMs = target;
  }
}
class FakeLifecycleTransport implements PostgresLifecycleTransport {
  readonly writtenFrames: Uint8Array[] = []; readonly queuedReads: Uint8Array[] = []; readonly events: string[] = [];
  hangConnect: boolean = false; hangWrite: boolean = false; hangAbort: boolean = false; hangClose: boolean = false;
  shortWriteBytes: number = 0; readRejectDelayTicks: number = 0;
  abortFailure: ArkDbError | null = null; closeFailure: ArkDbError | null = null; writeFailure: ArkDbError | null = null;
  closeCalls: number = 0; abortCalls: number = 0;
  onConnect: (() => void) | null = null; onAbort: (() => void) | null = null; onClose: (() => void) | null = null;
  private fatal: ArkDbError | null = null; private pendingRejects: Array<(error: Object) => void> = []; private resumeAbort: (() => void) | null = null;
  releaseHungAbort(): void { if (this.resumeAbort !== null) { const r = this.resumeAbort; this.resumeAbort = null; r(); } }
  connect(_host: string, _port: number, _timeoutMs: number): Promise<void> {
    this.events.push('connect');
    if (this.onConnect !== null) this.onConnect();
    if (this.fatal !== null) return Promise.reject<void>(this.fatal);
    return !this.hangConnect ? Promise.resolve() : new Promise<void>((_r: () => void, reject: (e: Object) => void): void => { this.pendingRejects.push(reject); });
  }
  read(_maximumBytes: number): Promise<Uint8Array | null> {
    if (this.fatal !== null) return Promise.reject<Uint8Array | null>(this.fatal);
    if (this.queuedReads.length > 0) return Promise.resolve<Uint8Array | null>(this.queuedReads.shift()!);
    return new Promise<Uint8Array | null>((_r: (v: Uint8Array | null) => void, reject: (e: Object) => void): void => {
      this.pendingRejects.push((e: Object): void => {
        if (this.readRejectDelayTicks <= 0) { reject(e); return; }
        flushManyMicrotasks(this.readRejectDelayTicks).then((): void => reject(e));
      });
    });
  }
  write(data: Uint8Array): Promise<number> {
    this.events.push('write');
    if (this.fatal !== null) return Promise.reject<number>(this.fatal);
    if (this.writeFailure !== null) return Promise.reject<number>(this.writeFailure);
    if (this.hangWrite) return new Promise<number>((_r: (v: number) => void, reject: (e: Object) => void): void => { this.pendingRejects.push(reject); });
    const copy = new Uint8Array(data.length); copy.set(data); this.writtenFrames.push(copy);
    return Promise.resolve(this.shortWriteBytes > 0 ? Math.min(this.shortWriteBytes, data.length) : data.length);
  }
  async close(): Promise<void> {
    this.events.push('close'); this.closeCalls += 1; this.failPending(ArkDbError.network('closed'));
    if (this.onClose !== null) this.onClose();
    if (this.hangClose) await new Promise<void>((r: () => void): void => { this.resumeAbort = r; });
    if (this.closeFailure !== null) throw this.closeFailure;
  }
  async abort(error: ArkDbError): Promise<void> {
    this.events.push('abort'); this.abortCalls += 1; this.failPending(error); if (this.onAbort !== null) this.onAbort();
    if (this.hangAbort) await new Promise<void>((r: () => void): void => { this.resumeAbort = r; });
    if (this.abortFailure !== null) throw this.abortFailure;
  }
  private failPending(error: ArkDbError): void { if (this.fatal === null) this.fatal = error; const w = this.pendingRejects; this.pendingRejects = []; for (const reject of w) reject(this.fatal); }
}
async function flushMicrotasks(): Promise<void> {
  await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
}
async function flushManyMicrotasks(count: number): Promise<void> {
  for (let i = 0; i < count; i += 1) await Promise.resolve();
}
function syncFail(op: () => void): ArkDbError { let f: Object | null = null; try { op(); } catch (e) { f = e as Object; } expect(f instanceof ArkDbError).assertTrue(); return f as ArkDbError; }
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> { let f: Object | null = null; try { await op(); } catch (e) { f = e as Object; } expect(f instanceof ArkDbError).assertTrue(); return f as ArkDbError; }
function assertBytes(a: Uint8Array, e: number[]): void { expect(a.length).assertEqual(e.length); for (let i = 0; i < e.length; i += 1) expect(a[i]).assertEqual(e[i]); }
