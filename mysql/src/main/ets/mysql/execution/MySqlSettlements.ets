import {
  ArkDbError, ConnectionTimerPort, QueryCancellationResult
} from '@arkdb/core';
import { MySqlCommandScope } from './MySqlCommandGate';

const MAX_MYSQL_DEADLINE_TIMER_DELAY_MS: number = 2147483647;

export class PreparedCommandSettlement {
  readonly scope: MySqlCommandScope;
  readonly cancellations: Promise<QueryCancellationResult>[] = [];
  readonly closeRequested: Promise<ArkDbError>;
  joinedCancellations: number = 0;
  closeResult: Promise<void> | null = null;
  closeJoined: boolean = false;
  private resolveClose: (error: ArkDbError) => void =
    (_error: ArkDbError): void => {};
  private closeSignalled: boolean = false;

  constructor(scope: MySqlCommandScope) {
    this.scope = scope;
    this.closeRequested = new Promise<ArkDbError>(
      (resolve: (error: ArkDbError) => void): void => {
        this.resolveClose = resolve;
      });
  }

  signalClose(error: ArkDbError): void {
    if (this.closeSignalled) return;
    this.closeSignalled = true;
    this.resolveClose(error);
  }
}

export class CommandCloseSettlement {
  readonly scope: MySqlCommandScope;
  closeResult: Promise<void> | null = null;
  closeJoin: Promise<ArkDbError | null> | null = null;

  constructor(scope: MySqlCommandScope) {
    this.scope = scope;
  }
}

export class OrdinaryCommandSettlement extends CommandCloseSettlement {
  dispatched: boolean = false;
}

export class DeadlineObservation<T> {
  readonly settled: Promise<void>;
  value: T | undefined = undefined;
  failure: Object | null = null;
  settledNow: boolean = false;

  constructor(task: Promise<T>) {
    this.settled = task.then(
      (value: T): void => {
        this.value = value;
        this.settledNow = true;
      },
      (error: Object): void => {
        this.failure = error;
        this.settledNow = true;
      });
  }
}

export class DeadlineCancellationSettlement {
  readonly scope: MySqlCommandScope;
  readonly attempts: Promise<QueryCancellationResult>[] = [];
  readonly failures: ArkDbError[] = [];
  joined: number = 0;
  unknown: boolean = false;

  constructor(scope: MySqlCommandScope) {
    this.scope = scope;
  }

  add(task: Promise<QueryCancellationResult>): void {
    for (const attempt of this.attempts) {
      if (attempt === task) return;
    }
    this.attempts.push(task);
  }

  addFailure(failure: ArkDbError): void {
    for (const existing of this.failures) {
      if (existing === failure) return;
    }
    this.failures.push(failure);
  }
}

export class MySqlDeadlineTimer {
  private timers: ConnectionTimerPort;
  private expiresAtMs: number;
  private callback: () => void;
  private timerId: number = 0;
  private generation: number = 0;
  private active: boolean = true;

  constructor(timeoutMs: number, timers: ConnectionTimerPort, callback: () => void) {
    this.timers = timers;
    this.callback = callback;
    const now = this.nowMs();
    this.expiresAtMs = timeoutMs > Number.MAX_SAFE_INTEGER - now ?
      Number.MAX_SAFE_INTEGER : now + timeoutMs;
    this.arm();
  }

  cancel(): void {
    if (!this.active) return;
    this.active = false;
    this.generation += 1;
    if (this.timerId !== 0) this.timers.cancel(this.timerId);
    this.timerId = 0;
  }

  isExpired(): boolean {
    return this.expiresAtMs <= this.nowMs();
  }

  private arm(): void {
    if (!this.active) return;
    const remaining = Math.max(0, this.expiresAtMs - this.nowMs());
    const delay = Math.min(remaining, MAX_MYSQL_DEADLINE_TIMER_DELAY_MS);
    const generation = this.generation + 1;
    this.generation = generation;
    this.timerId = this.timers.schedule((): void => {
      if (!this.active || this.generation !== generation) return;
      this.timerId = 0;
      if (this.expiresAtMs > this.nowMs()) {
        this.arm();
        return;
      }
      this.active = false;
      this.callback();
    }, delay);
  }

  private nowMs(): number {
    const now = this.timers.nowMs();
    if (!Number.isSafeInteger(now) || now < 0) {
      throw ArkDbError.protocol('Connection clock is unavailable.');
    }
    return now;
  }
}
