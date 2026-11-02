import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionTimerPort } from '@arkdb/core';
import { MySqlByteSource } from '../../../main/ets/mysql/model/MySqlByteSource';
import { MySqlOperationError } from '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlPromiseUploadAbortSignal, MySqlUploadAbortSignal,
  MySqlUploadChunkWriter, MySqlUploadFailure, MySqlUploadPump
} from '../../../main/ets/mysql/transport/MySqlUploadPump';

class UploadTimers implements ConnectionTimerPort {
  private nextId: number = 0;
  private currentMs: number = 0;
  private scheduled: ScheduledUploadTimer[] = [];

  nowMs(): number { return this.currentMs; }

  schedule(handler: () => void, timeoutMs: number): number {
    const timer = new ScheduledUploadTimer(++this.nextId,
      this.currentMs + timeoutMs, handler);
    this.scheduled.push(timer);
    return timer.id;
  }

  cancel(timerId: number): void {
    for (const timer of this.scheduled) {
      if (timer.id === timerId) timer.cancelled = true;
    }
  }

  advance(milliseconds: number): void {
    this.currentMs += milliseconds;
    for (const timer of this.scheduled) {
      if (!timer.cancelled && !timer.fired && timer.dueAtMs <= this.currentMs) {
        timer.fired = true;
        timer.handler();
      }
    }
  }

  elapseWithoutFiring(milliseconds: number): void {
    this.currentMs += milliseconds;
  }

  fireNextDue(): boolean {
    for (const timer of this.scheduled) {
      if (!timer.cancelled && !timer.fired && timer.dueAtMs <= this.currentMs) {
        timer.fired = true;
        timer.handler();
        return true;
      }
    }
    return false;
  }
}

class ScheduledUploadTimer {
  readonly id: number;
  readonly dueAtMs: number;
  readonly handler: () => void;
  cancelled: boolean = false;
  fired: boolean = false;

  constructor(id: number, dueAtMs: number, handler: () => void) {
    this.id = id;
    this.dueAtMs = dueAtMs;
    this.handler = handler;
  }
}

class RecordingSource implements MySqlByteSource {
  readCount: number = 0;
  closeCount: number = 0;
  readFailure: ArkDbError | null = null;
  closeFailure: ArkDbError | null = null;
  onRead: (() => void) | null = null;
  onClose: (() => void) | null = null;
  private chunks: Array<Uint8Array | null>;

  constructor(chunks: Array<Uint8Array | null>) {
    this.chunks = chunks;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readCount += 1;
    if (this.onRead !== null) this.onRead();
    if (this.readFailure !== null) throw this.readFailure;
    return this.chunks.length === 0 ? null : this.chunks.shift()!;
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    if (this.onClose !== null) this.onClose();
    if (this.closeFailure !== null) throw this.closeFailure;
  }
}

class RecordingWriter implements MySqlUploadChunkWriter {
  chunks: Uint8Array[] = [];
  sourceIndexes: number[] = [];
  onWrite: (() => void) | null = null;

  async write(sourceIndex: number, chunk: Uint8Array, _timeoutMs: number): Promise<void> {
    if (this.onWrite !== null) this.onWrite();
    this.sourceIndexes.push(sourceIndex);
    this.chunks.push(chunk);
  }

  async retire(_error: ArkDbError): Promise<void> {}
}

class PendingCloseSource implements MySqlByteSource {
  closeCount: number = 0;
  private failClose: (reason?: Object) => void = (_reason?: Object): void => {};

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    return null;
  }

  close(): Promise<void> {
    this.closeCount += 1;
    return new Promise<void>((_resolve: () => void,
      reject: (reason?: Object) => void): void => {
      this.failClose = reject;
    });
  }

  rejectClose(error: ArkDbError): void {
    this.failClose(error);
  }
}

class ControlledCloseSource implements MySqlByteSource {
  readCount: number = 0;
  closeCount: number = 0;
  readFailure: ArkDbError | null;
  private completeClose: () => void = (): void => {};
  private failClose: (reason?: Object) => void = (_reason?: Object): void => {};

  constructor(readFailure: ArkDbError | null = null) {
    this.readFailure = readFailure;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readCount += 1;
    if (this.readFailure !== null) throw this.readFailure;
    return null;
  }

  close(): Promise<void> {
    this.closeCount += 1;
    return new Promise<void>((resolve: () => void,
      reject: (reason?: Object) => void): void => {
      this.completeClose = resolve;
      this.failClose = reject;
    });
  }

  resolveClose(): void {
    this.completeClose();
  }

  rejectClose(error: ArkDbError): void {
    this.failClose(error);
  }
}

class CountingAbortSignal implements MySqlUploadAbortSignal {
  subscriptions: number = 0;
  private listener: (error: ArkDbError) => void =
    (_error: ArkDbError): void => {};

  subscribe(listener: (error: ArkDbError) => void): void {
    this.subscriptions += 1;
    this.listener = listener;
  }

  abort(error: ArkDbError): void {
    this.listener(error);
  }
}

class PendingWriteWriter implements MySqlUploadChunkWriter {
  writeCount: number = 0;
  retireCount: number = 0;
  private failWrite: (reason?: Object) => void = (_reason?: Object): void => {};

  write(_sourceIndex: number, _chunk: Uint8Array, _timeoutMs: number): Promise<void> {
    this.writeCount += 1;
    return new Promise<void>((_resolve: () => void,
      reject: (reason?: Object) => void): void => {
      this.failWrite = reject;
    });
  }

  async retire(_error: ArkDbError): Promise<void> {
    this.retireCount += 1;
  }

  rejectWrite(error: ArkDbError): void {
    this.failWrite(error);
  }
}

class EqualDeadlineWriter implements MySqlUploadChunkWriter {
  writeCount: number = 0;
  retireCount: number = 0;
  readonly transportFailure: ArkDbError;
  private timers: UploadTimers;

  constructor(timers: UploadTimers, transportFailure: ArkDbError) {
    this.timers = timers;
    this.transportFailure = transportFailure;
  }

  write(_sourceIndex: number, _chunk: Uint8Array, timeoutMs: number): Promise<void> {
    this.writeCount += 1;
    return new Promise<void>((_resolve: () => void,
      reject: (reason?: Object) => void): void => {
      this.timers.schedule((): void => {
        reject(this.transportFailure);
      }, timeoutMs);
    });
  }

  async retire(_error: ArkDbError): Promise<void> {
    this.retireCount += 1;
  }
}

class OrdinaryFailureWriter implements MySqlUploadChunkWriter {
  retireCount: number = 0;
  private failure: Error;

  constructor(failure: Error) {
    this.failure = failure;
  }

  async write(_sourceIndex: number, _chunk: Uint8Array,
    _timeoutMs: number): Promise<void> {
    throw this.failure;
  }

  async retire(_error: ArkDbError): Promise<void> {
    this.retireCount += 1;
  }
}

class CloseSettlesReadSource implements MySqlByteSource {
  readCount: number = 0;
  closeCount: number = 0;
  private readTask: Promise<Uint8Array | null> | null = null;
  private completeRead: (value: Uint8Array | null) => void =
    (_value: Uint8Array | null): void => {};
  private failRead: (reason?: Object) => void = (_reason?: Object): void => {};

  read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readCount += 1;
    this.readTask = new Promise<Uint8Array | null>(
      (resolve: (value: Uint8Array | null) => void,
        reject: (reason?: Object) => void): void => {
        this.completeRead = resolve;
        this.failRead = reject;
      });
    return this.readTask;
  }

  close(): Promise<void> {
    this.closeCount += 1;
    if (this.readTask === null) return Promise.resolve();
    return this.readTask.then((): void => {}, (_error: Object): void => {});
  }

  resolveRead(value: Uint8Array | null): void {
    this.completeRead(value);
  }

  rejectRead(error: ArkDbError): void {
    this.failRead(error);
  }
}

export default function mySqlUploadPumpTest(): void {
  describe('MySQL bounded upload pump', () => {
    it('closesAcceptedSourcesExactlyOnceAndStopsReadingLaterSources', 0, async () => {
      const first = new RecordingSource([null]);
      first.closeFailure = ArkDbError.network('Synthetic first source close failure.');
      const second = new RecordingSource([new Uint8Array([9]), null]);
      const writer = new RecordingWriter();
      const failure = await uploadFailure(new MySqlUploadPump(new UploadTimers())
        .upload([first, second], 4, 8, 100, writer));

      expect(failure !== null).assertTrue();
      expect(first.readCount).assertEqual(1);
      expect(first.closeCount).assertEqual(1);
      expect(second.readCount).assertEqual(0);
      expect(second.closeCount).assertEqual(1);
      expect(writer.chunks.length).assertEqual(0);
    });

    it('rejectsOversizedOrEmptyNonEofChunk', 0, async () => {
      const empty = new RecordingSource([new Uint8Array(0)]);
      const oversized = new RecordingSource([new Uint8Array([1, 2, 3])]);
      const emptyWriter = new RecordingWriter();
      const oversizedWriter = new RecordingWriter();

      const emptyFailure = await uploadFailure(new MySqlUploadPump(new UploadTimers())
        .upload([empty], 2, 8, 100, emptyWriter));
      const oversizedFailure = await uploadFailure(new MySqlUploadPump(new UploadTimers())
        .upload([oversized], 2, 8, 100, oversizedWriter));

      expect(emptyFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(oversizedFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(emptyWriter.chunks.length).assertEqual(0);
      expect(oversizedWriter.chunks.length).assertEqual(0);
      expect(empty.closeCount).assertEqual(1);
      expect(oversized.closeCount).assertEqual(1);
    });

    it('stopsBeforeWritingChunkThatExceedsTotalBudget', 0, async () => {
      const source = new RecordingSource([
        new Uint8Array([1, 2, 3]), new Uint8Array([4, 5]), null
      ]);
      const writer = new RecordingWriter();
      const failure = await uploadFailure(new MySqlUploadPump(new UploadTimers())
        .upload([source], 3, 4, 100, writer));

      expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(writer.chunks.length).assertEqual(1);
      expect(writer.chunks[0].join(',')).assertEqual('1,2,3');
      expect(source.closeCount).assertEqual(1);
    });

    it('acceptsExactTotalLimitOnlyWhenNextReadIsEof', 0, async () => {
      const source = new RecordingSource([
        new Uint8Array([1, 2]), new Uint8Array([3, 4]), null
      ]);
      const writer = new RecordingWriter();
      const uploaded = await new MySqlUploadPump(new UploadTimers())
        .upload([source], 2, 4, 100, writer);

      expect(uploaded).assertEqual(4);
      expect(source.readCount).assertEqual(3);
      expect(source.closeCount).assertEqual(1);
      expect(writer.chunks.length).assertEqual(2);
    });

    it('usesOneAbsoluteTimeoutAcrossReadWriteAndClose', 0, async () => {
      const timers = new UploadTimers();
      const source = new RecordingSource([new Uint8Array([1]), null]);
      const writer = new RecordingWriter();
      source.onRead = (): void => { timers.advance(2); };
      writer.onWrite = (): void => { timers.advance(3); };
      source.onClose = (): void => { timers.advance(6); };

      const failure = await uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, writer));

      expect(failure!.kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(writer.chunks.length).assertEqual(1);
      expect(source.closeCount).assertEqual(1);
    });

    it('preservesPrimaryAndCloseFailures', 0, async () => {
      const source = new RecordingSource([]);
      source.readFailure = ArkDbError.network('Synthetic source read failure.');
      source.closeFailure = ArkDbError.protocol('Synthetic source close failure.');
      const failure = await uploadFailure(new MySqlUploadPump(new UploadTimers())
        .upload([source], 4, 8, 100, new RecordingWriter()));

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      expect(failure instanceof MySqlOperationError).assertFalse();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary === source.readFailure).assertTrue();
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0] === source.closeFailure).assertTrue();
        expect(failure.writeUncertain).assertFalse();
      }
      expect(source.closeCount).assertEqual(1);
    });

    it('abortDuringSourceCloseJoinsTheSameCloseTask', 0, async () => {
      let abortUpload: (error: ArkDbError) => void =
        (_error: ArkDbError): void => {};
      const abort = new Promise<ArkDbError>(
        (resolve: (error: ArkDbError) => void): void => {
          abortUpload = resolve;
        });
      const source = new PendingCloseSource();
      const closeFailure = ArkDbError.network('Synthetic pending source close failure.');
      let settled = false;
      const running = uploadFailure(new MySqlUploadPump(new UploadTimers())
        .upload([source], 4, 8, 100, new RecordingWriter(),
          new MySqlPromiseUploadAbortSignal(abort)))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          settled = true;
          return failure;
        });

      await flushUpload();
      abortUpload(ArkDbError.cancelled('Synthetic upload abort.'));
      await flushUpload();
      expect(settled).assertFalse();
      expect(source.closeCount).assertEqual(1);
      source.rejectClose(closeFailure);
      const failure = await running;

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      expect(failure instanceof MySqlOperationError).assertFalse();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Cancelled);
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0] === closeFailure).assertTrue();
        expect(failure.writeUncertain).assertFalse();
      }
      expect(source.closeCount).assertEqual(1);
    });

    it('subscribesToAbortOncePerUpload', 0, async () => {
      const abort = new CountingAbortSignal();
      const source = new RecordingSource([
        new Uint8Array([1]), new Uint8Array([2]), new Uint8Array([3]), null
      ]);
      const uploaded = await new MySqlUploadPump(new UploadTimers())
        .upload([source], 1, 4, 100, new RecordingWriter(), abort);

      expect(uploaded).assertEqual(3);
      expect(abort.subscriptions).assertEqual(1);
    });

    it('writeTimeoutRetiresAndJoinsTheInFlightWrite', 0, async () => {
      const timers = new UploadTimers();
      const writer = new PendingWriteWriter();
      const source = new RecordingSource([new Uint8Array([1]), null]);
      let settled = false;
      const running = uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, writer))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          settled = true;
          return failure;
        });

      await waitForUpload((): boolean => writer.writeCount === 1,
        'Expected timed-out writer dispatch.');
      timers.advance(10);
      await waitForUpload((): boolean => writer.retireCount === 1,
        'Expected timed-out writer retirement.');
      expect(settled).assertFalse();
      const writeFailure = ArkDbError.network('Synthetic late packet write failure.');
      writer.rejectWrite(writeFailure);
      const failure = await running;

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0] === writeFailure).assertTrue();
        expect(failure.writeUncertain).assertTrue();
      }
      expect(source.closeCount).assertEqual(1);
    });

    it('timeoutCleanupUsesExplicitBudgetAndPreservesCloseFailure', 0, async () => {
      const timers = new UploadTimers();
      const source = new RecordingSource([null]);
      const closeFailure = ArkDbError.network('Synthetic bounded cleanup close failure.');
      source.onRead = (): void => { timers.advance(10); };
      source.onClose = (): void => { timers.advance(5); };
      source.closeFailure = closeFailure;

      const failure = await uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, new RecordingWriter(), null, 20));

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0] === closeFailure).assertTrue();
      }
      expect(source.closeCount).assertEqual(1);
    });

    it('pumpDeadlineWinsEqualTransportDeadline', 0, async () => {
      const timers = new UploadTimers();
      const transportFailure = ArkDbError.protocol(
        'Truncated result exceeded synchronization drain time budget');
      const writer = new EqualDeadlineWriter(timers, transportFailure);
      const source = new RecordingSource([new Uint8Array([1]), null]);
      let uploadSettled = false;
      const running = uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, writer))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          uploadSettled = true;
          return failure;
        });

      await waitForUpload((): boolean => writer.writeCount === 1,
        'Expected equal-deadline writer dispatch.');
      timers.elapseWithoutFiring(10);
      const firstTimerFired = timers.fireNextDue();
      await flushUpload();
      const remainedPendingForTransport = !uploadSettled;
      const secondTimerFired = timers.fireNextDue();
      if (secondTimerFired) {
        await flushUpload();
      }
      const failure = await running;

      expect(firstTimerFired).assertTrue();
      expect(remainedPendingForTransport).assertTrue();
      expect(secondTimerFired).assertTrue();
      expect(failure instanceof MySqlUploadFailure).assertTrue();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0] === transportFailure).assertTrue();
        expect(failure.writeUncertain).assertTrue();
      }
      expect(writer.retireCount).assertEqual(1);
      expect(source.closeCount).assertEqual(1);
    });

    it('lateReadSuccessCannotBypassAbsoluteExpiry', 0, async () => {
      const timers = new UploadTimers();
      const source = new CloseSettlesReadSource();
      const writer = new RecordingWriter();
      const running = uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, writer));

      await waitForUpload((): boolean => source.readCount === 1,
        'Expected retained read dispatch.');
      timers.elapseWithoutFiring(10);
      source.resolveRead(new Uint8Array([1]));
      const failure = await running;

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
      }
      expect(timers.fireNextDue()).assertFalse();
      expect(writer.chunks.length).assertEqual(0);
      expect(source.closeCount).assertEqual(1);
    });

    it('lateWriteFailureCannotBypassAbsoluteExpiry', 0, async () => {
      const timers = new UploadTimers();
      const writer = new PendingWriteWriter();
      const source = new RecordingSource([new Uint8Array([1]), null]);
      const writeFailure = ArkDbError.network(
        'Synthetic write failure after absolute upload expiry.');
      const running = uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, writer));

      await waitForUpload((): boolean => writer.writeCount === 1,
        'Expected late-failure writer dispatch.');
      timers.elapseWithoutFiring(10);
      writer.rejectWrite(writeFailure);
      const failure = await running;

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0] === writeFailure).assertTrue();
        expect(failure.writeUncertain).assertTrue();
      }
      expect(timers.fireNextDue()).assertFalse();
      expect(writer.retireCount).assertEqual(1);
      expect(source.closeCount).assertEqual(1);
    });

    it('preservesOrdinaryWriterFailureIdentity', 0, async () => {
      const writerFailure = new Error('Synthetic ordinary writer failure.');
      const writer = new OrdinaryFailureWriter(writerFailure);
      const source = new RecordingSource([new Uint8Array([1]), null]);
      const failure = await uploadFailure(new MySqlUploadPump(new UploadTimers())
        .upload([source], 1, 4, 100, writer));

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.originalCause === writerFailure).assertTrue();
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(failure.writeUncertain).assertTrue();
      }
      expect(writer.retireCount).assertEqual(1);
      expect(source.closeCount).assertEqual(1);
    });

    it('lateCloseFailureCannotBypassAbsoluteExpiry', 0, async () => {
      const timers = new UploadTimers();
      const source = new PendingCloseSource();
      const closeFailure =
        ArkDbError.network('Synthetic close failure after absolute upload expiry.');
      const running = uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, new RecordingWriter()));

      await waitForUpload((): boolean => source.closeCount === 1,
        'Expected pending source close.');
      timers.elapseWithoutFiring(10);
      source.rejectClose(closeFailure);
      const failure = await running;

      expect(failure instanceof MySqlUploadFailure).assertTrue();
      if (failure instanceof MySqlUploadFailure) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0] === closeFailure).assertTrue();
      }
      expect(timers.fireNextDue()).assertFalse();
      expect(source.closeCount).assertEqual(1);
    });

    it('timeoutClosesAndJoinsTheExactPendingRead', 0, async () => {
      const timers = new UploadTimers();
      const source = new CloseSettlesReadSource();
      const writer = new RecordingWriter();
      const lateReadFailure =
        ArkDbError.network('Synthetic pending read failure after upload timeout.');
      let uploadSettled = false;
      let readSettled = false;
      const running = uploadFailure(new MySqlUploadPump(timers)
        .upload([source], 1, 4, 10, writer, null, 20))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          uploadSettled = true;
          return failure;
        });

      try {
        await flushUpload();
        timers.advance(10);
        await flushUpload();
        expect(source.closeCount).assertEqual(1);
        expect(uploadSettled).assertFalse();
        expect(writer.chunks.length).assertEqual(0);

        source.rejectRead(lateReadFailure);
        readSettled = true;
        const failure = await running;
        expect(failure instanceof MySqlUploadFailure).assertTrue();
        if (failure instanceof MySqlUploadFailure) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0] === lateReadFailure).assertTrue();
        }
        expect(source.closeCount).assertEqual(1);
        expect(writer.chunks.length).assertEqual(0);
      } finally {
        if (!readSettled) source.rejectRead(lateReadFailure);
        await running;
      }
    });

    it('initiatesEveryCloseBeforeTimeoutAndJoinsLateFailures', 0, async () => {
      const timers = new UploadTimers();
      const primary = ArkDbError.network('Synthetic multi-source read failure.');
      const first = new ControlledCloseSource(primary);
      const second = new ControlledCloseSource();
      const lateCloseFailure =
        ArkDbError.protocol('Synthetic late unread-source close failure.');
      let firstSettled = false;
      let secondSettled = false;
      let uploadSettled = false;
      const running = uploadFailure(new MySqlUploadPump(timers)
        .upload([first, second], 1, 4, 100, new RecordingWriter(), null, 10))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          uploadSettled = true;
          return failure;
        });

      await waitForUpload((): boolean =>
        first.closeCount === 1 && second.closeCount === 1,
      'Expected every source close to start.');
      const allClosesStartedBeforeTimeout =
        first.closeCount === 1 && second.closeCount === 1;
      timers.advance(10);
      await flushUpload();
      const remainedPendingAfterTimeout = !uploadSettled;

      first.resolveClose();
      firstSettled = true;
      await flushUpload();
      const remainedPendingAfterFirstClose = !uploadSettled;
      if (second.closeCount > 0) {
        second.rejectClose(lateCloseFailure);
        secondSettled = true;
      }
      const failure = await running;
      try {
        expect(allClosesStartedBeforeTimeout).assertTrue();
        expect(second.readCount).assertEqual(0);
        expect(remainedPendingAfterTimeout).assertTrue();
        expect(remainedPendingAfterFirstClose).assertTrue();
        expect(failure instanceof MySqlUploadFailure).assertTrue();
        if (failure instanceof MySqlUploadFailure) {
          expect(failure.primary === primary).assertTrue();
          let foundTimeout = false;
          let foundLateClose = false;
          for (const cleanup of failure.cleanupErrors) {
            if (cleanup.kind === ArkDbErrorKind.Timeout) foundTimeout = true;
            if (cleanup === lateCloseFailure) foundLateClose = true;
          }
          expect(foundTimeout).assertTrue();
          expect(foundLateClose).assertTrue();
        }
        expect(first.closeCount).assertEqual(1);
        expect(second.closeCount).assertEqual(1);
      } finally {
        if (!firstSettled) first.resolveClose();
        if (!secondSettled && second.closeCount > 0) second.rejectClose(lateCloseFailure);
        await running;
      }
    });
  });
}

function uploadFailure(task: Promise<number>): Promise<ArkDbError | null> {
  return task.then((): ArkDbError | null => null,
    (error: Object): ArkDbError | null => {
      if (!(error instanceof ArkDbError)) throw error as Error;
      return error;
    });
}

async function flushUpload(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

async function waitForUpload(predicate: () => boolean, message: string): Promise<void> {
  for (let turn = 0; turn < 32; turn += 1) {
    if (predicate()) return;
    await flushUpload();
  }
  throw new Error(message);
}
