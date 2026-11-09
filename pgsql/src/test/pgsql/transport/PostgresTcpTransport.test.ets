import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionTimerPort
} from '@arkdb/core';
import {
  PostgresTcpSocket, PostgresTcpSocketFactory, PostgresTcpTransport,
  PostgresTlsSocket
} from '../../../main/ets/pgsql/transport/PostgresTcpTransport';
import {
  PostgresSslConfig, PostgresSslMode
} from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
interface MessageFailure {
  message: string;
}
export default function postgresTcpTransportTest(): void {
  describe('PostgresTcpTransport', () => {
    it('readsExactBytesAcrossFragmentedAndCoalescedDeliveries', 0, async () => {
      const peer = new MockTcpSocket();
      const transport = createTransport(peer, 8);
      await transport.connect('db.invalid', 5432, 1000);
      try {
        expect((await transport.read(0))!.length).assertEqual(0);
        const fragmented = transport.read(4);
        peer.emitMessage(new Uint8Array([1, 2]));
        peer.emitMessage(new Uint8Array([3, 4, 5, 6]));
        assertBytes(await fragmented, [1, 2, 3, 4]);
        assertBytes(await transport.read(2), [5, 6]);
        peer.emitMessage(new Uint8Array([7, 8, 9]));
        peer.emitMessage(new Uint8Array([10, 11, 12, 13, 14]));
        assertBytes(await transport.read(8), [7, 8, 9, 10, 11, 12, 13, 14]);
      } finally {
        await transport.close();
      }
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
    });
    it('rejectsUnsafeLengthsConcurrentReadsAndReceiveOverflow', 0, async () => {
      const factory = new MockTcpSocketFactory(new MockTcpSocket());
      new PostgresTcpTransport(factory, 33554432, new MockTimers());
      for (const limit of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, 33554433]) {
        assertValidation((): void => {
          new PostgresTcpTransport(factory, limit, new MockTimers());
        });
      }
      const peer = new MockTcpSocket();
      const transport = createTransport(peer, 8);
      await transport.connect('db.invalid', 5432, 1000);
      for (const length of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, 9]) {
        expect((await failure(async (): Promise<void> => {
          await transport.read(length);
        })).kind)
          .assertEqual(ArkDbErrorKind.Validation);
      }
      const first = transport.read(2);
      expect((await failure(async (): Promise<void> => {
        await transport.read(1);
      })).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      peer.emitMessage(new Uint8Array([1, 2]));
      assertBytes(await first, [1, 2]);
      const boundary = transport.read(8);
      peer.emitMessage(new Uint8Array([3, 4, 5, 6, 7, 8, 9, 10, 11]));
      assertBytes(await boundary, [3, 4, 5, 6, 7, 8, 9, 10]);
      assertBytes(await transport.read(1), [11]);
      peer.emitMessage(new Uint8Array(9));
      const terminal = await failure(async (): Promise<void> => {
        await transport.read(1);
      });
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(terminal.message).assertEqual('PostgreSQL receive buffer exceeds client limit');
      expect(await failure(async (): Promise<void> => {
        await transport.read(1);
      })).assertEqual(terminal);
      expect(await failure(async (): Promise<void> => {
        await transport.write(new Uint8Array([1]));
      })).assertEqual(terminal);
      await transport.close();
      peer.emitMessage(new Uint8Array([1]), true);
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
    });
    it('coalescesManyOneByteDeliveriesWithoutUnboundedChunkMetadata', 0, async () => {
      const peer = new MockTcpSocket();
      const transport = createTransport(peer, 131072);
      await transport.connect('db.invalid', 5432, 1000);
      try {
        for (let index = 0; index < 131072; index += 1) {
          peer.emitMessage(new Uint8Array([index & 0xff]));
        }
        const bytes = await transport.read(131072);
        for (let index = 0; index < bytes!.length; index += 1) {
          if (bytes![index] !== (index & 0xff)) {
            throw new Error('Fragmented PostgreSQL bytes changed order');
          }
        }
      } finally {
        await transport.close();
      }
      expect(peer.listenerCount).assertEqual(0);
    });
    it('preservesByteOrderAcrossReceivePrefixCompaction', 0, async () => {
      const blockBytes = 64 * 1024;
      const initial = new Uint8Array(blockBytes * 65 + 3);
      for (let index = 0; index < initial.length; index += 1) {
        initial[index] = index & 0xff;
      }
      const peer = new MockTcpSocket();
      const transport = createTransport(peer, initial.length);
      await transport.connect('db.invalid', 5432, 1000);
      try {
        peer.emitMessage(initial);
        const consumed = blockBytes * 64 + 1;
        const prefix = await transport.read(consumed);
        expect(prefix![0]).assertEqual(0);
        expect(prefix![consumed - 1]).assertEqual((consumed - 1) & 0xff);
        peer.emitMessage(new Uint8Array([201, 202, 203]));
        const remaining = initial.length - consumed;
        const tail = await transport.read(remaining + 3);
        for (let index = 0; index < remaining; index += 1) {
          if (tail![index] !== ((consumed + index) & 0xff)) {
            throw new Error('Compacted PostgreSQL bytes changed order');
          }
        }
        assertBytes(tail!.subarray(remaining), [201, 202, 203]);
      } finally {
        await transport.close();
      }
    });
    it('fansOutSocketCloseErrorAndAbortToEveryPendingOperation', 0, async () => {
      for (let mode = 0; mode < 3; mode += 1) {
        const peer = new MockTcpSocket();
        const transport = createTransport(peer, 8);
        await transport.connect('db.invalid', 5432, 1000);
        const read = failure(async (): Promise<void> => {
          await transport.read(2);
        });
        const consumer = failure((): Promise<void> => transport.runWhileOpen((): Promise<void> =>
          new Promise<void>((resolve: () => void): void => {})));
        let expected: ArkDbError | null = null;
        if (mode === 0) peer.emitClose();
        else if (mode === 1) peer.emitError();
        else {
          expected = ArkDbError.protocol('Synthetic abort');
          await transport.abort(expected);
        }
        const terminal = await read;
        expect(terminal.kind).assertEqual(
          mode === 2 ? ArkDbErrorKind.Protocol : ArkDbErrorKind.Network);
        if (mode === 1) expect(terminal.message)
          .assertEqual('PostgreSQL socket error: Synthetic socket failure');
        if (expected !== null) expect(terminal).assertEqual(expected);
        expect(await consumer).assertEqual(terminal);
        expect(await failure(async (): Promise<void> => {
          await transport.read(1);
        })).assertEqual(terminal);
        peer.emitMessage(new Uint8Array([1, 2]), true);
        peer.emitError(true);
        await transport.close();
        expect(peer.closeCalls).assertEqual(mode === 0 ? 0 : 1);
        expect(peer.listenerCount).assertEqual(0);
      }
    });
    it('boundsWritesAndFailsEveryOperationAfterSendFailure', 0, async () => {
      const peer = new MockTcpSocket();
      const transport = createTransport(peer, 8);
      await transport.connect('db.invalid', 5432, 1000);
      expect(await transport.write(new Uint8Array([1, 2, 3]))).assertEqual(3);
      assertBytes(peer.lastWrite, [1, 2, 3]);
      const sendCalls = peer.sendCalls;
      expect((await failure(async (): Promise<void> => {
        await transport.write(new Uint8Array(33554434));
      })).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      expect(peer.sendCalls).assertEqual(sendCalls);
      const read = failure(async (): Promise<void> => {
        await transport.read(1);
      });
      const consumer = failure((): Promise<void> => transport.runWhileOpen((): Promise<void> =>
        new Promise<void>((resolve: () => void): void => {})));
      peer.sendFailure = new Error('Synthetic send failure');
      const terminal = await failure(async (): Promise<void> => {
        await transport.write(new Uint8Array([4]));
      });
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Network);
      expect(await read).assertEqual(terminal);
      expect(await consumer).assertEqual(terminal);
      expect(await failure(async (): Promise<void> => {
        await transport.write(new Uint8Array(0));
      })).assertEqual(terminal);
      await transport.close();
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
    });
    it('cleansSocketWhenConnectSetupOrConnectionFails', 0, async () => {
      for (let mode = 0; mode < 3; mode += 1) {
        const peer = new MockTcpSocket();
        const message = mode === 0 ? 'Synthetic listener registration failure' :
          mode === 1 ? 'Synthetic connect failure' : 'undefined';
        if (mode === 0) peer.listenFailure = new Error(message);
        else if (mode === 1) peer.connectFailure = new Error(message);
        else peer.connectWithoutReason = true;
        const transport = createTransport(peer, 8);
        const terminal = await failure((): Promise<void> =>
          transport.connect('db.invalid', 5432, 1000));
        expect(terminal.kind).assertEqual(ArkDbErrorKind.Network);
        expect(terminal.message).assertEqual('PostgreSQL TCP connect failed: ' + message);
        expect(await failure(async (): Promise<void> => {
          await transport.read(1);
        })).assertEqual(terminal);
        expect(peer.closeCalls).assertEqual(1);
        expect(peer.listenerCount).assertEqual(0);
        await transport.close();
        expect(peer.closeCalls).assertEqual(1);
      }
    });
    it('cancelsInFlightConnectWithoutAcceptingLateSettlement', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const peer = new MockTcpSocket();
        const deferred = new Deferred();
        peer.connectResult = deferred.wait();
        const transport = createTransport(peer, 8);
        const connecting = failure((): Promise<void> =>
          transport.connect('db.invalid', 5432, 1000));
        await nextTask();
        if (mode === 0) await transport.close();
        else await transport.abort(ArkDbError.protocol('Synthetic connect abort'));
        const terminal = await connecting;
        expect(terminal.kind).assertEqual(
          mode === 0 ? ArkDbErrorKind.Network : ArkDbErrorKind.Protocol);
        if (mode === 0) deferred.complete();
        else deferred.fail();
        await nextTask();
        expect(await failure(async (): Promise<void> => {
          await transport.read(1);
        })).assertEqual(terminal);
        expect(peer.closeCalls).assertEqual(1);
        expect(peer.listenerCount).assertEqual(0);
      }
    });
    it('requiresAnEmptyIdlePlaintextStreamBeforeTlsHandoff', 0, async () => {
      const pendingPeer = new MockTcpSocket();
      const pendingTransport = createTransport(pendingPeer, 8);
      await pendingTransport.connect('db.invalid', 5432, 1000);
      const pending = pendingTransport.read(1);
      expect(syncFailure((): void => pendingTransport.prepareTlsUpgrade()).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(pendingPeer.listenerCount).assertEqual(3);
      pendingPeer.emitMessage(new Uint8Array([1]));
      assertBytes(await pending, [1]);
      const pendingTls = new MockTcpSocket();
      pendingPeer.upgradeResult = pendingTls;
      pendingTransport.prepareTlsUpgrade();
      expect(pendingPeer.listenerCount).assertEqual(2);
      pendingPeer.emitMessage(new Uint8Array([99]), true);
      await pendingTransport.upgradeToTls(
        'db.example.com', 5432, verifiedTls(), 1000);
      pendingTls.emitMessage(new Uint8Array([3]));
      assertBytes(await pendingTransport.read(1), [3]);
      await pendingTransport.close();
      const bufferedPeer = new MockTcpSocket();
      const bufferedTransport = createTransport(bufferedPeer, 8);
      await bufferedTransport.connect('db.invalid', 5432, 1000);
      bufferedPeer.emitMessage(new Uint8Array([2]));
      expect(syncFailure((): void => bufferedTransport.prepareTlsUpgrade()).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(bufferedPeer.listenerCount).assertEqual(3);
      assertBytes(await bufferedTransport.read(1), [2]);
      bufferedTransport.prepareTlsUpgrade();
      await bufferedTransport.close();
    });
    it('transfersListenersAndClassifiesTlsTrafficFailures', 0, async () => {
      for (let mode = 0; mode < 3; mode += 1) {
        const tcp = new MockTcpSocket(); const tls = new MockTcpSocket();
        tcp.upgradeResult = tls;
        const transport = createTransport(tcp, 8);
        await transport.connect('db.invalid', 5432, 1000);
        transport.prepareTlsUpgrade();
        await transport.upgradeToTls('db.example.com', 5432, verifiedTls(), 1750);
        expect(tcp.listenersAtUpgrade).assertEqual(2);
        expect(tcp.listenerCount).assertEqual(0);
        expect(tls.listenerCount).assertEqual(3);
        expect(tls.tlsVerifyCalls).assertEqual(1);
        expect(tls.lastTlsTimeoutMs).assertEqual(1750);
        tls.emitMessage(new Uint8Array([7]));
        assertBytes(await transport.read(1), [7]);
        let terminal: ArkDbError;
        if (mode === 0) {
          tls.sendFailure = new Error('Synthetic TLS send failure');
          terminal = await failure(async (): Promise<void> =>
            { await transport.write(new Uint8Array([8])); });
          expect(terminal.message).assertEqual(
            'PostgreSQL TLS send failed: Synthetic TLS send failure');
        } else if (mode === 1) {
          tls.emitError();
          terminal = await failure(async (): Promise<void> =>
            { await transport.read(1); });
          expect(terminal.message).assertEqual(
            'PostgreSQL TLS socket error: Synthetic socket failure');
        } else {
          tls.emitClose();
          terminal = await failure(async (): Promise<void> =>
            { await transport.read(1); });
          expect(terminal.message)
            .assertEqual('PostgreSQL TLS socket closed by server');
        }
        expect(terminal.kind).assertEqual(ArkDbErrorKind.Tls);
        expect(tcp.closeCalls).assertEqual(0);
        expect(tls.closeCalls).assertEqual(mode === 2 ? 0 : 1);
        expect(tls.listenerCount).assertEqual(0);
      }
    });
    it('failsClosedAcrossTlsConstructionConnectAndVerification', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const preparePeer = new MockTcpSocket();
        const original = ArkDbError.tls('Synthetic exact handoff failure', 'PREPARE');
        if (mode === 0) {
          preparePeer.prepareUpgradeFailure =
            new Error('Synthetic TLS handoff failure');
        } else preparePeer.prepareUpgradeTypedFailure = original;
        const prepareTransport = createTransport(preparePeer, 8);
        await prepareTransport.connect('db.invalid', 5432, 1000);
        const terminal = syncFailure((): void => prepareTransport.prepareTlsUpgrade());
        if (mode === 0) expect(terminal.message).assertEqual(
          'PostgreSQL TLS listener handoff failed: Synthetic TLS handoff failure');
        else expect(terminal).assertEqual(original);
        expect(preparePeer.closeCalls).assertEqual(1);
      }
      for (let mode = 0; mode < 5; mode += 1) {
        const tcp = new MockTcpSocket(); const tls = new MockTcpSocket();
        tcp.upgradeResult = tls;
        const original = ArkDbError.tls('Synthetic exact TLS failure', 'VERIFY');
        if (mode === 0) {
          tcp.upgradeFailure = new Error('Synthetic TLS construction failure');
        } else if (mode === 1) tcp.upgradeTypedFailure = original;
        else if (mode === 2) {
          tls.listenFailure = new Error('Synthetic TLS listener failure');
        } else if (mode === 3) {
          tls.tlsConnectFailure = new Error('Synthetic TLS connect failure');
        } else tls.tlsVerifyFailure = original;
        const transport = createTransport(tcp, 8);
        await transport.connect('db.invalid', 5432, 1000);
        transport.prepareTlsUpgrade();
        const terminal = await failure((): Promise<void> =>
          transport.upgradeToTls('db.example.com', 5432, verifiedTls(), 1000));
        expect(terminal.kind).assertEqual(ArkDbErrorKind.Tls);
        if (mode <= 1) {
          if (mode === 1) expect(terminal).assertEqual(original);
          if (mode === 0) expect(terminal.message).assertEqual(
            'PostgreSQL TLS socket construction failed: Synthetic TLS construction failure');
          expect(tcp.closeCalls).assertEqual(1);
        } else {
          expect(tcp.closeCalls).assertEqual(0);
          expect(tls.closeCalls).assertEqual(1);
        }
        if (mode === 4) expect(terminal).assertEqual(original);
      }
    });
    it('preservesCloseAndAbortFailuresDuringTlsUpgrade', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const tcp = new MockTcpSocket();
        const prepared = createTransport(tcp, 8);
        await prepared.connect('db.invalid', 5432, 1000);
        prepared.prepareTlsUpgrade();
        let expected: ArkDbError | null = null;
        if (mode === 0) await prepared.close();
        else {
          expected = ArkDbError.protocol('Synthetic prepared abort');
          await prepared.abort(expected);
        }
        const terminal = await failure((): Promise<void> =>
          prepared.upgradeToTls('db.example.com', 5432, verifiedTls(), 1000));
        if (expected !== null) expect(terminal).assertEqual(expected);
        expect(await failure(async (): Promise<void> =>
          { await prepared.read(1); })).assertEqual(terminal);
        expect(tcp.closeCalls).assertEqual(1);
      }
      for (let mode = 0; mode < 2; mode += 1) {
        const tcp = new MockTcpSocket(); const tls = new MockTcpSocket();
        const deferred = new Deferred();
        tls.tlsConnectResult = deferred.wait();
        tcp.upgradeResult = tls;
        const transport = createTransport(tcp, 8);
        await transport.connect('db.invalid', 5432, 1000);
        transport.prepareTlsUpgrade();
        const upgrading = failure((): Promise<void> =>
          transport.upgradeToTls('db.example.com', 5432, verifiedTls(), 1000));
        await nextTask();
        let expected: ArkDbError | null = null;
        if (mode === 0) await transport.close();
        else {
          expected = ArkDbError.protocol('Synthetic upgrade abort');
          await transport.abort(expected);
        }
        const terminal = await upgrading;
        if (expected !== null) expect(terminal).assertEqual(expected);
        else expect(terminal.message)
          .assertEqual('PostgreSQL transport closed');
        deferred.complete();
        await nextTask();
        expect(await failure(async (): Promise<void> =>
          { await transport.read(1); })).assertEqual(terminal);
        expect(tcp.closeCalls).assertEqual(0);
        expect(tls.closeCalls).assertEqual(1);
        expect(tls.listenerCount).assertEqual(0);
      }
    });
    it('keepsConnectWritesAndVerificationOutsideTheTlsHandoff', 0, async () => {
      const tcp = new MockTcpSocket();
      const connectDeferred = new Deferred(); const sendDeferred = new Deferred();
      tcp.connectResult = connectDeferred.wait();
      const transport = createTransport(tcp, 8);
      const connecting = transport.connect('db.invalid', 5432, 1000);
      await nextTask();
      expect(syncFailure((): void => transport.prepareTlsUpgrade()).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      connectDeferred.complete();
      await connecting;
      tcp.sendResult = sendDeferred.wait();
      const writing = transport.write(new Uint8Array([1]));
      await nextTask();
      expect(syncFailure((): void => transport.prepareTlsUpgrade()).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      sendDeferred.complete();
      await writing;
      const tls = new MockTcpSocket();
      const tlsConnectDeferred = new Deferred(); const verifyDeferred = new Deferred();
      tls.tlsConnectResult = tlsConnectDeferred.wait();
      tls.tlsVerifyResult = verifyDeferred.wait();
      tcp.upgradeResult = tls;
      transport.prepareTlsUpgrade();
      const config = verifiedTls();
      const upgrading = transport.upgradeToTls('db.example.com', 5432, config, 1000);
      await nextTask();
      config.mode = PostgresSslMode.VERIFY_CA;
      expect((await failure(async (): Promise<void> =>
        { await transport.read(1); })).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await failure(async (): Promise<void> =>
        { await transport.write(new Uint8Array([2])); })).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      tlsConnectDeferred.complete();
      await nextTask(); await nextTask(); await nextTask();
      expect(tls.tlsVerifyCalls).assertEqual(1);
      verifyDeferred.complete();
      await upgrading;
      await transport.close();
    });
    it('boundsHangingCloseAndKeepsCloseIdempotent', 0, async () => {
      const peer = new MockTcpSocket();
      const deferred = new Deferred();
      peer.closeResult = deferred.wait();
      const timers = new MockTimers();
      const transport = new PostgresTcpTransport(
        new MockTcpSocketFactory(peer), 8, timers);
      await transport.connect('db.invalid', 5432, 1000);
      const first = failure((): Promise<void> => transport.close());
      const second = failure((): Promise<void> => transport.close());
      expect(timers.lastTimeoutMs).assertEqual(1000);
      timers.fire();
      const terminal = await first;
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Network);
      expect(terminal.message).assertEqual('PostgreSQL socket close timed out');
      expect(await second).assertEqual(terminal);
      const readFailure = await failure(async (): Promise<void> => {
        await transport.read(1);
      });
      expect(readFailure.message).assertEqual('PostgreSQL transport closed');
      deferred.complete();
      await nextTask();
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
    });
    it('preservesOperationFailureWhenListenerCleanupFails', 0, async () => {
      const peer = new MockTcpSocket();
      peer.clearListenersFailure = new Error('Synthetic listener cleanup failure');
      const transport = createTransport(peer, 8);
      await transport.connect('db.invalid', 5432, 1000);
      const pending = failure(async (): Promise<void> => { await transport.read(1); });
      const firstClose = failure((): Promise<void> => transport.close());
      const operationFailure = await pending;
      const cleanupFailure = await firstClose;
      expect(operationFailure.message).assertEqual('PostgreSQL transport closed');
      expect(cleanupFailure.message).assertEqual(
        'PostgreSQL socket listener cleanup failed: Synthetic listener cleanup failure');
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
      expect(await failure((): Promise<void> => transport.close())).assertEqual(cleanupFailure);
      expect(await failure(async (): Promise<void> => {
        await transport.read(1);
      })).assertEqual(operationFailure);
      expect(peer.closeCalls).assertEqual(1);
    });
  });
}

class MockTcpSocketFactory implements PostgresTcpSocketFactory {
  private readonly peer: PostgresTcpSocket;
  constructor(peer: PostgresTcpSocket) { this.peer = peer; }
  create(): PostgresTcpSocket { return this.peer; }
}
class MockTcpSocket implements PostgresTcpSocket, PostgresTlsSocket {
  closeCalls: number = 0;
  sendCalls: number = 0;
  connectFailure: Error | null = null;
  connectWithoutReason: boolean = false;
  connectResult: Promise<void> | null = null;
  clearListenersFailure: Error | null = null;
  listenFailure: Error | null = null;
  sendFailure: Error | null = null;
  sendResult: Promise<void> | null = null;
  closeResult: Promise<void> | null = null;
  prepareUpgradeFailure: Error | null = null;
  prepareUpgradeTypedFailure: ArkDbError | null = null;
  upgradeResult: PostgresTlsSocket | null = null;
  upgradeFailure: Error | null = null;
  upgradeTypedFailure: ArkDbError | null = null;
  tlsConnectResult: Promise<void> | null = null;
  tlsConnectFailure: Error | null = null;
  tlsVerifyFailure: ArkDbError | null = null;
  tlsVerifyResult: Promise<void> | null = null;
  listenersAtUpgrade: number = -1;
  tlsVerifyCalls: number = 0;
  lastTlsTimeoutMs: number = 0;
  lastWrite: Uint8Array = new Uint8Array(0);
  private messageListener: ((data: Uint8Array) => void) | null = null;
  private closeListener: (() => void) | null = null;
  private errorListener: ((error: Object) => void) | null = null;
  private lastMessageListener: ((data: Uint8Array) => void) | null = null;
  private lastErrorListener: ((error: Object) => void) | null = null;
  listen(message: (data: Uint8Array) => void, close: () => void,
    error: (failure: Object) => void): void {
    this.messageListener = message;
    this.closeListener = close;
    this.errorListener = error;
    this.lastMessageListener = message;
    this.lastErrorListener = error;
    if (this.listenFailure !== null) throw this.listenFailure;
  }
  clearListeners(): void {
    this.messageListener = null;
    this.closeListener = null;
    this.errorListener = null;
    if (this.clearListenersFailure !== null) throw this.clearListenersFailure;
  }
  prepareUpgrade(): void {
    if (this.prepareUpgradeTypedFailure !== null) {
      throw this.prepareUpgradeTypedFailure;
    }
    if (this.prepareUpgradeFailure !== null) {
      throw this.prepareUpgradeFailure;
    }
    this.messageListener = null;
  }
  async connect(host: string, port: number, timeoutMs: number): Promise<void> {
    if (this.connectFailure !== null) throw this.connectFailure;
    if (this.connectWithoutReason) {
      await new Promise<void>((resolve: () => void,
        reject: (reason?: Object) => void): void => { reject(); });
    }
    if (this.connectResult !== null) await this.connectResult;
  }
  upgrade(): PostgresTlsSocket {
    this.listenersAtUpgrade = this.listenerCount;
    if (this.upgradeTypedFailure !== null) throw this.upgradeTypedFailure;
    if (this.upgradeFailure !== null) throw this.upgradeFailure;
    if (this.upgradeResult === null) {
      throw new Error('Synthetic TLS socket is not configured');
    }
    this.clearListeners();
    return this.upgradeResult;
  }
  async connectTls(host: string, port: number, config: PostgresSslConfig,
    timeoutMs: number): Promise<void> {
    this.lastTlsTimeoutMs = timeoutMs;
    if (this.tlsConnectFailure !== null) throw this.tlsConnectFailure;
    if (this.tlsConnectResult !== null) await this.tlsConnectResult;
  }
  async verifyPeerIdentity(host: string): Promise<void> {
    this.tlsVerifyCalls += 1;
    if (this.tlsVerifyFailure !== null) throw this.tlsVerifyFailure;
    if (this.tlsVerifyResult !== null) await this.tlsVerifyResult;
  }
  async send(data: Uint8Array): Promise<void> {
    this.sendCalls += 1;
    if (this.sendFailure !== null) throw this.sendFailure;
    if (this.sendResult !== null) await this.sendResult;
    this.lastWrite = data.slice();
  }
  close(): Promise<void> { this.closeCalls += 1; return this.closeResult === null ? Promise.resolve() : this.closeResult; }
  get listenerCount(): number {
    return (this.messageListener === null ? 0 : 1) +
      (this.closeListener === null ? 0 : 1) +
      (this.errorListener === null ? 0 : 1);
  }
  emitMessage(data: Uint8Array, late: boolean = false): void {
    const listener = late ? this.lastMessageListener : this.messageListener;
    if (listener !== null) listener(data.slice());
  }
  emitClose(): void { if (this.closeListener !== null) this.closeListener(); }
  emitError(late: boolean = false): void {
    const listener = late ? this.lastErrorListener : this.errorListener;
    const failure: MessageFailure = { message: 'Synthetic socket failure' };
    if (listener !== null) listener(failure);
  }
}
class MockTimers implements ConnectionTimerPort {
  lastTimeoutMs: number = 0;
  private handler: (() => void) | null = null;
  nowMs(): number { return 0; }
  schedule(handler: () => void, timeoutMs: number): number {
    this.handler = handler;
    this.lastTimeoutMs = timeoutMs;
    return 1;
  }
  cancel(timerId: number): void { if (timerId === 1) this.handler = null; }
  fire(): void { const handler = this.handler; this.handler = null; if (handler !== null) handler(); }
}
class Deferred {
  private resolve: (() => void) | null = null;
  private reject: ((reason?: Object) => void) | null = null;
  wait(): Promise<void> {
    return new Promise<void>((resolve: () => void,
      reject: (reason?: Object) => void): void => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
  complete(): void {
    const resolve = this.resolve; this.resolve = null; if (resolve !== null) resolve();
  }
  fail(): void {
    const reject = this.reject; this.reject = null;
    if (reject !== null) reject(new Error('Synthetic late connect failure'));
  }
}
function createTransport(peer: MockTcpSocket, maximumReceiveBytes: number): PostgresTcpTransport {
  return new PostgresTcpTransport(new MockTcpSocketFactory(peer),
    maximumReceiveBytes, new MockTimers());
}
async function failure(operation: () => Promise<void>): Promise<ArkDbError> {
  let failure: ArkDbError | null = null;
  try {
    await operation();
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  return failure!;
}
function assertValidation(action: () => void): void {
  let failure: ArkDbError | null = null;
  try {
    action();
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
}
function syncFailure(action: () => void): ArkDbError {
  let terminal: ArkDbError | null = null;
  try {
    action();
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  return terminal!;
}
function verifiedTls(): PostgresSslConfig {
  const config = new PostgresSslConfig();
  config.mode = PostgresSslMode.VERIFY_FULL;
  return config;
}
function assertBytes(actual: Uint8Array | null, expected: number[]): void {
  expect(actual !== null).assertTrue();
  expect(actual!.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual![index]).assertEqual(expected[index]);
  }
}
async function nextTask(): Promise<void> { await Promise.resolve(); }
