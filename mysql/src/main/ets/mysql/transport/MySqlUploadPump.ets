import { ArkDbError, ConnectionTimerPort } from '@arkdb/core';
import { MySqlByteSource } from '../model/MySqlByteSource';

export interface MySqlUploadChunkWriter {
  write(sourceIndex: number, chunk: Uint8Array, timeoutMs: number): Promise<void>;
  retire(error: ArkDbError): Promise<void>;
}

export interface MySqlUploadAbortSignal {
  subscribe(listener: (error: ArkDbError) => void): void;
}

export class MySqlPromiseUploadAbortSignal implements MySqlUploadAbortSignal {
  private abort: Promise<ArkDbError>;

  constructor(abort: Promise<ArkDbError>) {
    this.abort = abort;
  }

  subscribe(listener: (error: ArkDbError) => void): void {
    this.abort.then(listener);
  }
}

export class MySqlUploadFailure extends ArkDbError {
  readonly primary: ArkDbError;
  readonly cleanupErrors: ArkDbError[];
  readonly writeUncertain: boolean;
  readonly originalCause?: Object;

  constructor(primary: ArkDbError, cleanupErrors: ArkDbError[],
    writeUncertain: boolean, originalCause?: Object) {
    super(primary.kind, primary.message + (cleanupErrors.length > 0 ? ' Upload cleanup failed.' : ''),
      primary.nativeCode, primary.sqlState);
    this.name = 'MySqlUploadFailure';
    this.code = primary.code;
    this.primary = primary;
    this.cleanupErrors = cleanupErrors.slice();
    this.writeUncertain = writeUncertain;
    this.originalCause = originalCause;
  }
}

export class MySqlUploadPump {
  private timers: ConnectionTimerPort;

  constructor(timers: ConnectionTimerPort) {
    this.timers = timers;
  }

  async upload(sources: MySqlByteSource[], chunkBytes: number, maxTotalBytes: number,
    timeoutMs: number, writer: MySqlUploadChunkWriter,
    abort: MySqlUploadAbortSignal | null = null,
    cleanupTimeoutMs: number = timeoutMs): Promise<number> {
    const captured: UploadSourceState[] = sources.slice()
      .map((source: MySqlByteSource): UploadSourceState => new UploadSourceState(source));
    const deadline = new UploadDeadline(timeoutMs, this.timers, abort);
    let totalBytes = 0;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      for (let sourceIndex = 0; sourceIndex < captured.length; sourceIndex += 1) {
        const source = captured[sourceIndex];
        while (true) {
          const chunk = await readUploadSource(source, chunkBytes, deadline);
          if (chunk === null) break;
          if (!(chunk instanceof Uint8Array)) {
            throw ArkDbError.validation('MySqlByteSource must return Uint8Array chunks or null.');
          }
          if (chunk.length === 0) {
            throw ArkDbError.validation('MySqlByteSource returned an empty non-EOF chunk.');
          }
          if (chunk.length > chunkBytes) {
            throw ArkDbError.validation('MySqlByteSource returned more bytes than requested.');
          }
          if (chunk.length > maxTotalBytes - totalBytes) {
            throw ArkDbError.validation('MySQL upload exceeds maxTotalBytes.');
          }
          await deadline.write(
            (remainingMs: number): Promise<void> =>
              writer.write(sourceIndex, chunk.slice(), remainingMs),
            (error: ArkDbError): Promise<void> => writer.retire(error));
          totalBytes += chunk.length;
        }
        await deadline.wait<void>((): Promise<void> => captured[sourceIndex].close());
      }
    } catch (error) {
      primary = error as Object;
    }
    if (primary === null) return totalBytes;
    const cleanupDeadline = new UploadDeadline(cleanupTimeoutMs, this.timers, null);
    const closeObservations: UploadObservation[] = [];
    const readObservations: UploadObservation<Uint8Array | null>[] = [];
    for (let sourceIndex = 0; sourceIndex < captured.length; sourceIndex += 1) {
      closeObservations.push(new UploadObservation(captured[sourceIndex].close()));
      const activeRead = captured[sourceIndex].activeRead;
      if (activeRead !== null) readObservations.push(activeRead);
    }
    const allClosed = settleUploadObservations(closeObservations);
    try {
      await cleanupDeadline.wait<void>((): Promise<void> => allClosed);
    } catch (error) {
      appendUploadCleanup(cleanup, error as Object, primary);
    }
    await allClosed;
    await settleUploadObservations(readObservations);
    for (const observation of closeObservations) {
      if (observation.failure !== null) {
        appendUploadCleanup(cleanup, observation.failure, primary);
      }
    }
    for (const observation of readObservations) {
      if (observation.failure !== null) {
        appendUploadCleanup(cleanup, observation.failure, primary);
      }
    }
    throw uploadFailure(primary, cleanup);
  }
}

class UploadSourceState {
  readonly source: MySqlByteSource;
  private closeTask: Promise<void> | null = null;
  private pendingRead: UploadObservation<Uint8Array | null> | null = null;

  constructor(source: MySqlByteSource) {
    this.source = source;
  }

  close(): Promise<void> {
    if (this.closeTask !== null) return this.closeTask;
    try {
      this.closeTask = normalizeUploadPromise(this.source.close());
    } catch (error) {
      this.closeTask = Promise.reject<void>(uploadRejection(error as Object));
    }
    return this.closeTask;
  }

  startRead(maxBytes: number): UploadObservation<Uint8Array | null> {
    if (this.pendingRead !== null) {
      throw ArkDbError.protocol('MySqlByteSource already has a pending read.');
    }
    let task: Promise<Uint8Array | null>;
    try {
      task = this.source.read(maxBytes);
    } catch (error) {
      task = Promise.reject<Uint8Array | null>(error as Object);
    }
    this.pendingRead = new UploadObservation<Uint8Array | null>(task);
    return this.pendingRead;
  }

  finishRead(observation: UploadObservation<Uint8Array | null>): void {
    if (this.pendingRead === observation) this.pendingRead = null;
  }

  get activeRead(): UploadObservation<Uint8Array | null> | null {
    return this.pendingRead;
  }
}

class UploadDeadline {
  private expiresAtMs: number;
  private timers: ConnectionTimerPort;
  private abortError: ArkDbError | null = null;
  private activeAbort: ((error: ArkDbError) => void) | null = null;

  constructor(timeoutMs: number, timers: ConnectionTimerPort,
    abort: MySqlUploadAbortSignal | null) {
    this.timers = timers;
    const now = this.nowMs();
    this.expiresAtMs = timeoutMs > Number.MAX_SAFE_INTEGER - now ?
      Number.MAX_SAFE_INTEGER : now + timeoutMs;
    if (abort !== null) {
      abort.subscribe((error: ArkDbError): void => {
        if (this.abortError !== null) return;
        this.abortError = error;
        const active = this.activeAbort;
        if (active !== null) active(error);
      });
    }
  }

  wait<T>(operation: (remainingMs: number) => Promise<T>): Promise<T> {
    if (this.abortError !== null) {
      return Promise.reject<T>(this.abortError);
    }
    let remaining = this.expiresAtMs - this.nowMs();
    if (remaining <= 0) {
      return Promise.reject<T>(ArkDbError.timeout('MySQL upload timed out.'));
    }
    return new Promise<T>((resolve: (value: T | PromiseLike<T>) => void,
      reject: (reason?: Object) => void): void => {
      let settled = false;
      const timerId = this.timers.schedule((): void => {
        if (settled) return;
        settled = true;
        if (this.activeAbort === abortWaiter) this.activeAbort = null;
        reject(ArkDbError.timeout('MySQL upload timed out.'));
      }, remaining);
      const abortWaiter = (error: ArkDbError): void => {
        if (settled) return;
        settled = true;
        if (this.activeAbort === abortWaiter) this.activeAbort = null;
        this.timers.cancel(timerId);
        reject(error);
      };
      this.activeAbort = abortWaiter;
      if (this.abortError !== null) {
        abortWaiter(this.abortError);
      }
      if (settled) return;
      let task: Promise<T>;
      try {
        task = operation(remaining);
      } catch (error) {
        if (settled) return;
        settled = true;
        if (this.activeAbort === abortWaiter) this.activeAbort = null;
        this.timers.cancel(timerId);
        reject(uploadRejection(error as Object));
        return;
      }
      task.then((value: T): void => {
        if (settled) return;
        const interruption = this.currentInterruption();
        settled = true;
        if (this.activeAbort === abortWaiter) this.activeAbort = null;
        this.timers.cancel(timerId);
        if (interruption !== null) reject(interruption);
        else resolve(value);
      }, (error: Object): void => {
        if (settled) return;
        const interruption = this.currentInterruption();
        settled = true;
        if (this.activeAbort === abortWaiter) this.activeAbort = null;
        this.timers.cancel(timerId);
        if (interruption !== null) {
          reject(uploadFailure(interruption, [uploadCleanup(error)]));
        } else {
          reject(uploadRejection(error));
        }
      });
    });
  }

  async write(operation: (remainingMs: number) => Promise<void>,
    retire: (error: ArkDbError) => Promise<void>): Promise<void> {
    let observation: UploadObservation | null = null;
    let interruption: Object | null = null;
    try {
      await this.wait<void>((remainingMs: number): Promise<void> => {
        let task: Promise<void>;
        try {
          task = operation(remainingMs);
        } catch (error) {
          task = Promise.reject<void>(error as Object);
        }
        observation = new UploadObservation(task);
        return observation.settled;
      });
    } catch (error) {
      interruption = error as Object;
    }
    if (observation === null) {
      throw uploadFailure(interruption!, [], false);
    }
    const observed = observation as UploadObservation;
    if (interruption === null && observed.failure === null) return;
    const primary: Object = interruption === null ?
      observed.failure! : interruption;
    const cleanup: ArkDbError[] = [];
    try {
      await retire(uploadError(primary));
    } catch (error) {
      cleanup.push(uploadCleanup(error as Object));
    }
    await observed.settled;
    if (observed.failure !== null) {
      if (!containsUploadCause(primary, observed.failure)) {
        cleanup.push(uploadCleanup(observed.failure));
      }
    }
    throw uploadFailure(primary, cleanup, true);
  }

  private nowMs(): number {
    const now = this.timers.nowMs();
    if (!Number.isSafeInteger(now) || now < 0) {
      throw ArkDbError.protocol('MySQL upload clock is unavailable.');
    }
    return now;
  }

  private currentInterruption(): ArkDbError | null {
    if (this.abortError !== null) return this.abortError;
    return this.expiresAtMs <= this.nowMs() ?
      ArkDbError.timeout('MySQL upload timed out.') : null;
  }
}

class UploadObservation<T = void> {
  readonly settled: Promise<void>;
  value: T | undefined = undefined;
  failure: Object | null = null;
  settledNow: boolean = false;

  constructor(task: Promise<T>) {
    this.settled = task.then((value: T): void => {
      this.value = value;
      this.settledNow = true;
    }, (error: Object): void => {
      this.failure = uploadRejection(error);
      this.settledNow = true;
    });
  }
}

function uploadFailure(error: Object, cleanup: ArkDbError[],
  writeUncertain: boolean = false): MySqlUploadFailure {
  if (error instanceof MySqlUploadFailure) {
    return new MySqlUploadFailure(error.primary,
      mergeUploadCleanup(error.cleanupErrors, cleanup),
      error.writeUncertain || writeUncertain, error.originalCause);
  }
  const primary = uploadError(error);
  return new MySqlUploadFailure(primary, mergeUploadCleanup([], cleanup),
    writeUncertain,
    error instanceof ArkDbError ? undefined : error);
}

function uploadCleanup(error: Object): ArkDbError {
  return error instanceof ArkDbError ? error :
    uploadFailure(error, []);
}

function uploadError(error: Object): ArkDbError {
  return error instanceof ArkDbError ? error :
    ArkDbError.protocol('Unexpected MySQL upload failure.');
}

function uploadRejection(error: Object): Object {
  return error === null ?
    ArkDbError.protocol('MySQL upload operation rejected with null.') : error;
}

function normalizeUploadPromise<T>(task: Promise<T>): Promise<T> {
  return task.then((value: T): T => value,
    (error: Object): Promise<T> => Promise.reject<T>(uploadRejection(error)));
}

async function settleUploadObservations<T>(observations: UploadObservation<T>[]): Promise<void> {
  for (const observation of observations) await observation.settled;
}

function appendUploadCleanup(cleanup: ArkDbError[], error: Object,
  primary: Object): void {
  if (containsUploadCause(primary, error)) return;
  const failure = uploadCleanup(error);
  for (const existing of cleanup) {
    if (sameUploadEvidence(existing, failure)) return;
  }
  cleanup.push(failure);
}

function mergeUploadCleanup(existing: ArkDbError[],
  additions: ArkDbError[]): ArkDbError[] {
  const merged = existing.slice();
  for (const addition of additions) {
    let found = false;
    for (const current of merged) {
      if (sameUploadEvidence(current, addition)) {
        found = true;
        break;
      }
    }
    if (!found) merged.push(addition);
  }
  return merged;
}

async function readUploadSource(source: UploadSourceState, maxBytes: number,
  deadline: UploadDeadline): Promise<Uint8Array | null> {
  let observation: UploadObservation<Uint8Array | null> | null = null;
  let interruption: MySqlUploadFailure | null = null;
  try {
    await deadline.wait<void>((): Promise<void> => {
      observation = source.startRead(maxBytes);
      return observation.settled;
    });
  } catch (error) {
    interruption = uploadFailure(error as Object, []);
  }
  if (observation === null) {
    throw interruption === null ?
      ArkDbError.protocol('MySqlByteSource read was not started.') : interruption;
  }
  const observed = observation as UploadObservation<Uint8Array | null>;
  if (observed.settledNow) source.finishRead(observed);
  if (interruption !== null) {
    if (observed.settledNow && observed.failure !== null) {
      throw uploadFailure(interruption, [uploadCleanup(observed.failure)]);
    }
    throw interruption;
  }
  if (observed.failure !== null) throw uploadFailure(observed.failure, []);
  return observed.value!;
}

function containsUploadCause(container: Object, target: Object): boolean {
  if (container === target) return true;
  if (!(container instanceof MySqlUploadFailure)) return false;
  if (container.originalCause === target) return true;
  if (containsUploadCause(container.primary, target)) return true;
  for (const cleanup of container.cleanupErrors) {
    if (containsUploadCause(cleanup, target)) return true;
  }
  return false;
}

function sameUploadEvidence(first: Object, second: Object): boolean {
  if (first === second) return true;
  if (first instanceof MySqlUploadFailure &&
    second instanceof MySqlUploadFailure &&
    first.originalCause !== undefined &&
    first.originalCause === second.originalCause) return true;
  return false;
}
