import { ArkDbError } from '../model/ArkDbError';
import { monotonicNowMs } from '../time/MonotonicClock';

export interface ConnectionTimerPort {
  nowMs(): number;
  schedule(handler: () => void, timeoutMs: number): number;
  cancel(timerId: number): void;
}

export class SystemConnectionTimerPort implements ConnectionTimerPort {
  nowMs(): number {
    return monotonicNowMs();
  }

  schedule(handler: () => void, timeoutMs: number): number {
    return setTimeout(handler, timeoutMs);
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}

/** One elapsed-time budget, including waits between adapter opening stages. */
export class ConnectionDeadline {
  readonly expiresAtMs: number;
  private timers: ConnectionTimerPort;
  private timerId: number = 0;
  private failure: ArkDbError | null = null;
  private waiters: Array<(error: Object) => void> = [];

  constructor(timeoutMs: number, timers: ConnectionTimerPort = new SystemConnectionTimerPort(),
    expiresAtMs: number = 0) {
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
      throw ArkDbError.validation('Connect timeout must be a positive integer');
    }
    if (!Number.isSafeInteger(expiresAtMs) || expiresAtMs < 0) {
      throw ArkDbError.validation('Connection opening deadline must be a non-negative integer');
    }
    this.timers = timers;
    const now = this.nowMs();
    const configuredExpiry = Math.min(Number.MAX_SAFE_INTEGER, now + timeoutMs);
    this.expiresAtMs = expiresAtMs > 0 ? Math.min(configuredExpiry, expiresAtMs) : configuredExpiry;
    try {
      this.arm();
    } catch (error) {
      this.cancel(error as ArkDbError);
    }
  }

  remainingMs(): number {
    if (this.failure !== null) throw this.failure;
    const remaining = this.expiresAtMs - this.nowMs();
    if (remaining <= 0) {
      this.cancel(ArkDbError.timeout('Connection opening timed out.'));
      throw this.failure!;
    }
    return remaining;
  }

  wait<T>(operation: () => Promise<T>): Promise<T> {
    return new Promise<T>((resolve: (value: T | PromiseLike<T>) => void,
      reject: (error: Object) => void): void => {
      let settled = false;
      const fail = (error: Object): void => {
        if (settled) return;
        settled = true;
        this.remove(fail);
        reject(this.failure !== null ? this.failure : error);
      };
      try {
        this.remainingMs();
        this.waiters.push(fail);
        operation().then((value: T): void => {
          if (settled) return;
          try {
            this.remainingMs();
            settled = true;
            this.remove(fail);
            resolve(value);
          } catch (error) {
            fail(error as Object);
          }
        }, fail);
      } catch (error) {
        fail(error as Object);
      }
    });
  }

  cancel(error: ArkDbError = ArkDbError.timeout('Connection opening timed out.')): void {
    if (this.failure !== null) return;
    this.failure = error;
    if (this.timerId !== 0) this.timers.cancel(this.timerId);
    this.timerId = 0;
    const waiters = this.waiters;
    this.waiters = [];
    for (const fail of waiters) fail(error);
  }

  dispose(): void {
    this.cancel(ArkDbError.cancelled('Connection opening is no longer active.'));
  }

  private arm(): void {
    const remaining = this.remainingMs();
    const delay = Math.min(remaining, 2147483647);
    this.timerId = this.timers.schedule((): void => {
      this.timerId = 0;
      if (delay === remaining) {
        this.cancel();
      } else {
        try {
          this.arm();
        } catch (error) {
          this.cancel(error as ArkDbError);
        }
      }
    }, delay);
  }

  private nowMs(): number {
    const now = this.timers.nowMs();
    if (!Number.isSafeInteger(now) || now < 0) {
      throw ArkDbError.protocol('Connection clock is unavailable.');
    }
    return now;
  }

  private remove(waiter: (error: Object) => void): void {
    const index = this.waiters.indexOf(waiter);
    if (index >= 0) this.waiters.splice(index, 1);
  }
}

export function connectionCleanupError(primary: Object): ArkDbError {
  if (primary instanceof ArkDbError) {
    return new ArkDbError(primary.kind, primary.message + ' Connection cleanup failed.',
      primary.code, primary.sqlState);
  }
  return ArkDbError.network('Connection opening failed. Connection cleanup failed.');
}
