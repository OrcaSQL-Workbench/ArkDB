import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionTimerPort
} from '@arkdb/core';
import {
  PostgresTcpSocket, PostgresTcpSocketFactory, PostgresTcpTransport
} from '../../../main/ets/pgsql/transport/PostgresTcpTransport';

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
    it('cleansPartiallyRegisteredListenersWhenConnectSetupThrows', 0, async () => {
      const peer = new MockTcpSocket();
      peer.listenFailure = new Error('Synthetic listener registration failure');
      const transport = createTransport(peer, 8);
      const terminal = await failure((): Promise<void> =>
        transport.connect('db.invalid', 5432, 1000));
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Network);
      expect(terminal.message).assertEqual(
        'PostgreSQL TCP connect failed: Synthetic listener registration failure');
      expect(await failure(async (): Promise<void> => {
        await transport.read(1);
      })).assertEqual(terminal);
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
      await transport.close();
      expect(peer.closeCalls).assertEqual(1);
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
  });
}

class MockTcpSocketFactory implements PostgresTcpSocketFactory {
  private readonly peer: PostgresTcpSocket;
  constructor(peer: PostgresTcpSocket) {
    this.peer = peer;
  }
  create(): PostgresTcpSocket {
    return this.peer;
  }
}

class MockTcpSocket implements PostgresTcpSocket {
  closeCalls: number = 0;
  sendCalls: number = 0;
  connectFailure: Error | null = null;
  listenFailure: Error | null = null;
  sendFailure: Error | null = null;
  closeResult: Promise<void> | null = null;
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
  }
  async connect(host: string, port: number, timeoutMs: number): Promise<void> {
    if (this.connectFailure !== null) throw this.connectFailure;
  }
  async send(data: Uint8Array): Promise<void> {
    this.sendCalls += 1;
    if (this.sendFailure !== null) throw this.sendFailure;
    this.lastWrite = data.slice();
  }
  close(): Promise<void> {
    this.closeCalls += 1;
    return this.closeResult === null ? Promise.resolve() : this.closeResult;
  }
  get listenerCount(): number {
    return (this.messageListener === null ? 0 : 1) +
      (this.closeListener === null ? 0 : 1) +
      (this.errorListener === null ? 0 : 1);
  }
  emitMessage(data: Uint8Array, late: boolean = false): void {
    const listener = late ? this.lastMessageListener : this.messageListener;
    if (listener !== null) listener(data.slice());
  }

  emitClose(): void {
    if (this.closeListener !== null) this.closeListener();
  }

  emitError(late: boolean = false): void {
    const listener = late ? this.lastErrorListener : this.errorListener;
    if (listener !== null) listener(new Error('Synthetic socket failure'));
  }
}

class MockTimers implements ConnectionTimerPort {
  lastTimeoutMs: number = 0;
  private handler: (() => void) | null = null;

  nowMs(): number {
    return 0;
  }

  schedule(handler: () => void, timeoutMs: number): number {
    this.handler = handler;
    this.lastTimeoutMs = timeoutMs;
    return 1;
  }

  cancel(timerId: number): void {
    if (timerId === 1) this.handler = null;
  }

  fire(): void {
    const handler = this.handler;
    this.handler = null;
    if (handler !== null) handler();
  }
}

class Deferred {
  private resolve: (() => void) | null = null;

  wait(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.resolve = resolve;
    });
  }

  complete(): void {
    const resolve = this.resolve;
    this.resolve = null;
    if (resolve !== null) resolve();
  }
}

function createTransport(peer: MockTcpSocket, maximumReceiveBytes: number): PostgresTcpTransport {
  return new PostgresTcpTransport(
    new MockTcpSocketFactory(peer), maximumReceiveBytes, new MockTimers());
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

function assertBytes(actual: Uint8Array | null, expected: number[]): void {
  expect(actual !== null).assertTrue();
  expect(actual!.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual![index]).assertEqual(expected[index]);
  }
}

async function nextTask(): Promise<void> {
  await Promise.resolve();
}
