import { describe, expect, it } from '@ohos/hypium';
import { cert } from '@kit.DeviceCertificateKit';
import {
  ConnectionDeadline, ConnectionTimerPort, ConnectionState, ArkDbError, ArkDbErrorKind
} from '@arkdb/core';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import { MAX_RECEIVE_BUFFER_BYTES, TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { MySqlConnection } from '../../../main/ets/mysql/MySqlConnection';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';

class TimerTask {
  at: number;
  handler: () => void;

  constructor(at: number, handler: () => void) {
    this.at = at;
    this.handler = handler;
  }
}

class OpeningTimers implements ConnectionTimerPort {
  now: number = 1000;
  private nextId: number = 1;
  private tasks: Map<number, TimerTask> = new Map();

  nowMs(): number {
    return this.now;
  }

  schedule(handler: () => void, timeoutMs: number): number {
    const id = this.nextId++;
    this.tasks.set(id, new TimerTask(this.now + timeoutMs, handler));
    return id;
  }

  cancel(timerId: number): void {
    this.tasks.delete(timerId);
  }

  advance(ms: number): void {
    this.now += ms;
    const due: number[] = [];
    this.tasks.forEach((task: TimerTask, id: number): void => {
      if (task.at <= this.now) due.push(id);
    });
    for (const id of due) {
      const task = this.tasks.get(id);
      this.tasks.delete(id);
      if (task !== undefined) task.handler();
    }
  }

  get size(): number {
    return this.tasks.size;
  }
}

class Deferred {
  readonly promise: Promise<void>;
  private complete: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => { this.complete = resolve; });
  }

  resolve(): void {
    this.complete();
  }
}

class OpeningSocket extends MockSocket {
  sends: number = 0;

  send(options: Object): Promise<void> {
    this.sends++;
    return super.send(options);
  }
}

class Outcome {
  settled: boolean = false;
  error: ArkDbError | null = null;

  observe(operation: Promise<void>): Promise<void> {
    return operation.then((): void => { this.settled = true; }, (error: Object): void => {
      this.settled = true;
      this.error = error as ArkDbError;
    });
  }
}

class OpeningFixture {
  readonly timers: OpeningTimers = new OpeningTimers();
  readonly peer: OpeningSocket = new OpeningSocket();
  readonly outcome: Outcome = new Outcome();
  readonly config: ConnectionConfig = new ConnectionConfig();
  connection: MySqlConnection | null = null;
  finished: Promise<void> = Promise.resolve();

  constructor() {
    this.config.host = 'synthetic.invalid';
    this.config.connectTimeoutMs = 25;
    this.config.ssl.mode = SslMode.DISABLED;
  }

  start(): void {
    socket.nextTcp = this.peer;
    this.connection = new MySqlConnection(this.config, '',
      new TcpTransport(null, MAX_RECEIVE_BUFFER_BYTES, this.timers), this.timers);
    this.finished = this.outcome.observe(this.connection.connect());
  }

  async expire(): Promise<void> {
    this.timers.advance(25);
    await flush();
  }

  assertTimeout(): void {
    expect(this.outcome.settled).assertTrue();
    expect(this.outcome.error !== null).assertTrue();
    expect(this.outcome.error!.kind).assertEqual(ArkDbErrorKind.Timeout);
    expect(this.connection!.state).assertEqual(ConnectionState.Error);
  }
}

export default function connectionOpeningTest(): void {
  describe('connection opening deadlines', () => {
    it('preservesLongPositiveTimeoutsWithoutOverflowingThePlatformTimer', 0, async () => {
      const timers = new OpeningTimers();
      const deadline = new ConnectionDeadline(2147483672, timers);
      const gate = new Deferred();
      const outcome = new Outcome();
      const waiting = outcome.observe(deadline.wait((): Promise<void> => gate.promise));
      timers.advance(2147483647);
      await flush();
      expect(outcome.settled).assertFalse();
      timers.advance(25);
      await waiting;
      expect(outcome.error!.kind).assertEqual(ArkDbErrorKind.Timeout);
      gate.resolve();
      deadline.dispose();
      expect(timers.size).assertEqual(0);
    });

    it('boundsAStalledInitialHandshakeAndDetachesLateDeliveries', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.start();
      await flush();
      expect(fixture.peer.listenerCount).assertEqual(3);
      await fixture.expire();
      fixture.assertTimeout();
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.listenerCount).assertEqual(0);
      fixture.peer.emitMessage(handshake(), true);
      await fixture.finished;
      expect(fixture.peer.sends).assertEqual(0);
      expect(fixture.timers.size).assertEqual(0);
    });

    it('rejectsLateTcpConnectResolutionWithoutStartingAuthentication', 0, async () => {
      const fixture = new OpeningFixture();
      const gate = new Deferred();
      fixture.peer.connectResult = gate.promise;
      fixture.start();
      await fixture.expire();
      fixture.assertTimeout();
      gate.resolve();
      fixture.peer.emitMessage(handshake(), true);
      await flush();
      expect(fixture.peer.sends).assertEqual(0);
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.connection!.state).assertEqual(ConnectionState.Error);
    });

    it('boundsInitialAuthSwitchFastAuthAndFullAuthRepliesWithOneBudget', 0, async () => {
      for (let stage = 0; stage < 4; stage++) {
        const fixture = new OpeningFixture();
        fixture.start();
        fixture.peer.emitMessage(handshake(stage >= 2 ? 'caching_sha2_password' : 'mysql_native_password'));
        await flush();
        expect(fixture.peer.sends).assertEqual(1);
        fixture.timers.advance(15);
        if (stage === 1) {
          fixture.peer.emitMessage(frame(2, new PacketWriter().writeUInt8(0xfe)
            .writeNulString('mysql_native_password').writeBytes(new Uint8Array(20))
            .writeUInt8(0).toUint8Array()));
        } else if (stage >= 2) {
          fixture.peer.emitMessage(frame(2, new Uint8Array([1, stage === 2 ? 3 : 4])));
        }
        await flush();
        expect(fixture.peer.sends).assertEqual(stage === 1 || stage === 3 ? 2 : 1);
        fixture.timers.advance(10);
        await flush();
        fixture.assertTimeout();
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.timers.size).assertEqual(0);
      }
    });

    it('boundsTlsNegotiationAndRejectsItsLateSuccessBeforeCredentials', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.config.ssl.mode = SslMode.REQUIRED;
      const tls = new OpeningSocket();
      const gate = new Deferred();
      tls.connectResult = gate.promise;
      socket.nextTls = tls;
      fixture.start();
      fixture.peer.emitMessage(handshake('mysql_native_password', true));
      await flush();
      expect(fixture.peer.sends).assertEqual(1);
      expect(tls.sends).assertEqual(0);
      await fixture.expire();
      fixture.assertTimeout();
      expect(tls.closeCalls).assertEqual(1);
      expect(fixture.peer.closeCalls).assertEqual(0);
      gate.resolve();
      await flush();
      expect(tls.sends).assertEqual(0);
      expect(fixture.connection!.serverInfo.tlsActive).assertFalse();
    });

    it('boundsAuthenticationWritesAndRejectsTheirDelayedContinuations', 0, async () => {
      const fixture = new OpeningFixture();
      const send = new Deferred();
      fixture.peer.sendResult = send.promise;
      fixture.start();
      fixture.peer.emitMessage(handshake());
      await flush();
      expect(fixture.peer.sends).assertEqual(1);
      await fixture.expire();
      fixture.assertTimeout();
      send.resolve();
      fixture.peer.emitMessage(ok(2), true);
      await flush();
      expect(fixture.peer.sends).assertEqual(1);
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.connection!.state).assertEqual(ConnectionState.Error);
    });

    it('boundsIdentityVerificationWithoutDowngradingSslMode', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.config.ssl.mode = SslMode.VERIFY_IDENTITY;
      const tls = new OpeningSocket();
      tls.remoteCertificateResult = new Promise<cert.EncodingBlob>(
        (resolve: (value: cert.EncodingBlob) => void): void => {});
      socket.nextTls = tls;
      fixture.start();
      fixture.peer.emitMessage(handshake('mysql_native_password', true));
      await flush();
      expect(tls.remoteCertificateCalls).assertEqual(1);
      await fixture.expire();
      fixture.assertTimeout();
      expect(tls.sends).assertEqual(0);
      expect(tls.closeCalls).assertEqual(1);
    });

    it('boundsTheFinalFullAuthReplyInsideTls', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.config.ssl.mode = SslMode.REQUIRED;
      const tls = new OpeningSocket();
      socket.nextTls = tls;
      fixture.start();
      fixture.peer.emitMessage(handshake('caching_sha2_password', true));
      await flush();
      expect(tls.sends).assertEqual(1);
      tls.emitMessage(frame(3, new Uint8Array([1, 4])));
      await flush();
      expect(tls.sends).assertEqual(2);
      await fixture.expire();
      fixture.assertTimeout();
      expect(tls.closeCalls).assertEqual(1);
    });

    it('includesInitialAutocommitSetupBeforeBecomingReady', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.config.autocommit = false;
      fixture.start();
      fixture.peer.emitMessage(handshake());
      await flush();
      fixture.peer.emitMessage(ok(2));
      await flush();
      expect(fixture.peer.sends).assertEqual(2);
      expect(fixture.connection!.state).assertEqual(ConnectionState.Authenticating);
      await fixture.expire();
      fixture.assertTimeout();
      expect(fixture.peer.closeCalls).assertEqual(1);
    });

    it('rejectsSuccessAtTheElapsedDeadlineBeforeTheTimerCallbackRuns', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.start();
      fixture.peer.emitMessage(handshake());
      await flush();
      fixture.peer.emitMessage(ok(2));
      fixture.timers.now += 25;
      await flush();
      fixture.assertTimeout();
      expect(fixture.peer.closeCalls).assertEqual(1);
    });

    it('disarmsSuccessfulOpeningsAndLeavesLaterCommandsUsable', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.start();
      fixture.peer.emitMessage(handshake());
      await flush();
      fixture.peer.emitMessage(ok(2));
      await fixture.finished;
      expect(fixture.outcome.error === null).assertTrue();
      expect(fixture.connection!.state).assertEqual(ConnectionState.Ready);
      fixture.timers.advance(1000);
      expect(fixture.peer.closeCalls).assertEqual(0);
      const ping = fixture.connection!.ping();
      await flush();
      fixture.peer.emitMessage(ok(1));
      await ping;
      expect(fixture.timers.size).assertEqual(0);
      await fixture.connection!.close();
      expect(fixture.peer.closeCalls).assertEqual(1);
    });

    it('reportsTimeoutAndCleanupFailureWhenNativeCloseRejects', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.peer.closeFailure = new Error('Synthetic close rejection');
      fixture.start();
      await fixture.expire();
      fixture.assertTimeout();
      expect(fixture.outcome.error!.message.indexOf('cleanup failed') >= 0).assertTrue();
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.listenerCount).assertEqual(0);
    });

    it('boundsTheQuitWriteBeforeJoiningSocketCleanup', 0, async () => {
      const fixture = new OpeningFixture();
      fixture.start();
      fixture.peer.emitMessage(handshake());
      await flush();
      fixture.peer.emitMessage(ok(2));
      await fixture.finished;
      const send = new Deferred();
      fixture.peer.sendResult = send.promise;
      const closing = fixture.connection!.close();
      await flush();
      fixture.timers.advance(1000);
      await closing;
      expect(fixture.connection!.state).assertEqual(ConnectionState.Closed);
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.listenerCount).assertEqual(0);
      send.resolve();
      await flush();
      expect(fixture.peer.closeCalls).assertEqual(1);
    });

    it('boundsNonSettlingNativeCleanupAndIgnoresItsLateResolution', 0, async () => {
      const fixture = new OpeningFixture();
      const close = new Deferred();
      fixture.peer.closeResult = close.promise;
      fixture.start();
      await fixture.expire();
      expect(fixture.outcome.settled).assertFalse();
      expect(fixture.peer.listenerCount).assertEqual(0);
      fixture.timers.advance(1000);
      await flush();
      fixture.assertTimeout();
      expect(fixture.outcome.error!.message.indexOf('cleanup failed') >= 0).assertTrue();
      const failure = fixture.outcome.error;
      close.resolve();
      await flush();
      expect(fixture.outcome.error === failure).assertTrue();
      expect(fixture.peer.closeCalls).assertEqual(1);
    });

    it('doesNotReviveAnOpeningAfterExplicitClose', 0, async () => {
      const fixture = new OpeningFixture();
      const gate = new Deferred();
      fixture.peer.connectResult = gate.promise;
      fixture.start();
      await fixture.connection!.close();
      await fixture.finished;
      expect(fixture.outcome.error!.kind).assertEqual(ArkDbErrorKind.Cancelled);
      gate.resolve();
      fixture.peer.emitMessage(handshake(), true);
      await flush();
      expect(fixture.connection!.state).assertEqual(ConnectionState.Closed);
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.sends).assertEqual(0);
    });
  });
}

function handshake(plugin: string = 'mysql_native_password', tls: boolean = false): Uint8Array {
  let capabilities = Capabilities.PROTOCOL_41 | Capabilities.SECURE_CONNECTION |
    Capabilities.PLUGIN_AUTH | Capabilities.TRANSACTIONS;
  if (tls) capabilities |= Capabilities.SSL;
  const payload = new PacketWriter().writeUInt8(10).writeNulString('8.0.44').writeUInt32(42)
    .writeBytes(new Uint8Array(8)).writeUInt8(0).writeUInt16(capabilities & 0xffff)
    .writeUInt8(45).writeUInt16(2).writeUInt16(capabilities >>> 16).writeUInt8(21)
    .writeBytes(new Uint8Array(10)).writeBytes(new Uint8Array(12)).writeUInt8(0)
    .writeNulString(plugin).toUint8Array();
  return frame(0, payload);
}

function ok(sequence: number): Uint8Array {
  return frame(sequence, new Uint8Array([0, 0, 0, 2, 0, 0, 0]));
}

function frame(sequence: number, payload: Uint8Array): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence)
    .writeBytes(payload).toUint8Array();
}

async function flush(): Promise<void> {
  for (let turn = 0; turn < 80; turn++) await Promise.resolve();
}
