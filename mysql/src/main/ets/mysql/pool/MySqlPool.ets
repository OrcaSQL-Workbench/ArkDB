import {
  ArkDbError, ConnectionTimerPort, SystemConnectionTimerPort
} from '@arkdb/core';
import { MySqlConnectionExtensions } from '../driver/MySqlConnectionExtensions';
import { MySqlConnectionOptions } from '../driver/MySqlConnectionOptions';
import { MySqlDriverFactory } from '../driver/MySqlDriverFactory';
import { MySqlExecutionOutcome, MySqlOperationError } from '../model/MySqlOperationError';
import { MySqlPoolOptions } from '../model/MySqlPoolOptions';
import {
  MySqlConnectionLease, MySqlLeaseContext, MySqlPoolConnection,
  MySqlPoolConnectionAdapter, PooledMySqlConnectionLease
} from './MySqlConnectionLease';

export interface MySqlPool {
  acquire(): Promise<MySqlConnectionLease>;
  close(): Promise<void>;
}

export interface MySqlPoolRuntime {
  readonly timers: ConnectionTimerPort;
  createConnection(options: MySqlConnectionOptions): MySqlPoolConnection;
}

enum MySqlPoolState {
  Open = 'open',
  Closing = 'closing',
  Closed = 'closed'
}

enum MySqlPoolSlotState {
  Creating = 'creating',
  Idle = 'idle',
  Leased = 'leased',
  Releasing = 'releasing',
  Destroying = 'destroying'
}

class DefaultMySqlPoolRuntime implements MySqlPoolRuntime {
  readonly timers: ConnectionTimerPort = new SystemConnectionTimerPort();
  private factory: MySqlDriverFactory = new MySqlDriverFactory();

  createConnection(options: MySqlConnectionOptions): MySqlPoolConnection {
    return new MySqlPoolConnectionAdapter(this.factory.create(options));
  }
}

class MySqlPoolWaiter {
  readonly promise: Promise<MySqlConnectionLease>;
  active: boolean = true;
  timerId: number = 0;
  private resolvePromise:
    (lease: MySqlConnectionLease | PromiseLike<MySqlConnectionLease>) => void =
    (_lease: MySqlConnectionLease | PromiseLike<MySqlConnectionLease>): void => {};
  private rejectPromise: (error: Object) => void = (_error: Object): void => {};

  constructor() {
    this.promise = new Promise<MySqlConnectionLease>(
      (resolve: (lease: MySqlConnectionLease | PromiseLike<MySqlConnectionLease>) => void,
        reject: (error: Object) => void): void => {
        this.resolvePromise = resolve;
        this.rejectPromise = reject;
      });
  }

  succeed(lease: MySqlConnectionLease): void {
    if (!this.active) return;
    this.active = false;
    this.resolvePromise(lease);
  }

  fail(error: Object): void {
    if (!this.active) return;
    this.active = false;
    this.rejectPromise(error);
  }
}

class MySqlPoolSlot {
  state: MySqlPoolSlotState = MySqlPoolSlotState.Creating;
  connection: MySqlPoolConnection | null = null;
  demandCreation: boolean;
  lease: MySqlLeaseContext | null = null;
  idleTimerId: number = 0;
  opening: Promise<void> | null = null;
  closing: Promise<void> | null = null;

  constructor(demandCreation: boolean) {
    this.demandCreation = demandCreation;
  }
}

class MySqlPoolBudget {
  private timers: ConnectionTimerPort;
  private timerId: number = 0;
  private failure: ArkDbError | null = null;
  private waiters: Array<(error: Object) => void> = [];

  constructor(timers: ConnectionTimerPort, timeoutMs: number, message: string) {
    this.timers = timers;
    try {
      this.timerId = this.timers.schedule((): void => {
        this.timerId = 0;
        this.expire(ArkDbError.timeout(message));
      }, timeoutMs);
    } catch (error) {
      this.expire(poolArkDbError(error as Object));
    }
  }

  wait<T>(operation: Promise<T>): Promise<T> {
    return new Promise<T>((resolve: (value: T | PromiseLike<T>) => void,
      reject: (error: Object) => void): void => {
      let settled = false;
      const fail = (error: Object): void => {
        if (settled) return;
        settled = true;
        this.remove(fail);
        reject(this.failure === null ? error : this.failure);
      };
      if (this.failure !== null) {
        fail(this.failure);
        return;
      }
      this.waiters.push(fail);
      operation.then((value: T): void => {
        if (settled) return;
        settled = true;
        this.remove(fail);
        resolve(value);
      }, fail);
    });
  }

  dispose(): void {
    if (this.timerId !== 0) this.timers.cancel(this.timerId);
    this.timerId = 0;
  }

  cancel(error: ArkDbError): void {
    this.expire(error);
  }

  private expire(error: ArkDbError): void {
    if (this.failure !== null) return;
    this.failure = error;
    const waiters = this.waiters;
    this.waiters = [];
    for (const fail of waiters) fail(error);
  }

  private remove(waiter: (error: Object) => void): void {
    const index = this.waiters.indexOf(waiter);
    if (index >= 0) this.waiters.splice(index, 1);
  }
}

class MySqlPoolVoidTask {
  readonly promise: Promise<void>;
  private resolvePromise: () => void = (): void => {};
  private rejectPromise: (error: Object) => void = (_error: Object): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve: () => void,
      reject: (error: Object) => void): void => {
      this.resolvePromise = resolve;
      this.rejectPromise = reject;
    });
  }

  follow(start: () => Promise<void>): void {
    let task: Promise<void>;
    try {
      task = start();
    } catch (error) {
      this.rejectPromise(error as Object);
      return;
    }
    task.then(
      (): void => this.resolvePromise(),
      (error: Object): void => this.rejectPromise(error));
  }
}

class FifoMySqlPool implements MySqlPool {
  private connectionOptions: MySqlConnectionOptions;
  private options: MySqlPoolOptions;
  private runtime: MySqlPoolRuntime;
  private state: MySqlPoolState = MySqlPoolState.Open;
  private slots: MySqlPoolSlot[] = [];
  private idle: MySqlPoolSlot[] = [];
  private waiters: MySqlPoolWaiter[] = [];
  private emptyWaiters: Array<() => void> = [];
  private closeTask: Promise<void> | null = null;
  private backgroundErrors: Object[] = [];

  constructor(connectionOptions: MySqlConnectionOptions,
    poolOptions: MySqlPoolOptions, runtime: MySqlPoolRuntime) {
    this.connectionOptions = snapshotConnectionOptions(connectionOptions);
    this.options = poolOptions.clone();
    this.runtime = runtime;
    this.dispatch(true);
  }

  acquire(): Promise<MySqlConnectionLease> {
    if (this.state !== MySqlPoolState.Open) {
      return Promise.reject(ArkDbError.cancelled('The MySQL pool is closing or closed.'));
    }
    if (this.projectedQueuedWaiterCount() > this.options.maxQueueSize) {
      return Promise.reject(ArkDbError.validation('The MySQL pool acquire queue is full.'));
    }

    const waiter = new MySqlPoolWaiter();
    try {
      waiter.timerId = this.runtime.timers.schedule(
        (): void => this.timeoutWaiter(waiter), this.options.acquireTimeoutMs);
    } catch (error) {
      waiter.fail(poolArkDbError(error as Object));
      return waiter.promise;
    }
    this.waiters.push(waiter);
    this.dispatch(true);
    return waiter.promise;
  }

  close(): Promise<void> {
    if (this.closeTask !== null) return this.closeTask;
    this.state = MySqlPoolState.Closing;
    const published = new MySqlPoolVoidTask();
    this.closeTask = published.promise;
    this.closeTask.catch((_error: Object): void => {});
    published.follow((): Promise<void> => this.closeCore());
    return published.promise;
  }

  private async closeCore(): Promise<void> {
    const failures: Object[] = this.backgroundErrors.slice();
    this.backgroundErrors = [];
    this.rejectAllWaiters();

    const idle = this.idle.slice();
    for (const slot of idle) this.destroyIdleSlot(slot);

    const budget = new MySqlPoolBudget(
      this.runtime.timers, this.options.closeTimeoutMs,
      'MySQL pool close timed out waiting for active leases.');
    let timedOut = false;
    let closeTimeout: ArkDbError | null = null;
    try {
      await budget.wait(this.waitForEmpty());
    } catch (error) {
      timedOut = true;
      closeTimeout = poolArkDbError(error as Object);
      appendPoolFailure(failures, closeTimeout);
    }

    if (timedOut) {
      const slots = this.slots.slice();
      for (const slot of slots) {
        if (slot.lease !== null && closeTimeout !== null) {
          slot.lease.forceFinish(closeTimeout);
        } else if (slot.state === MySqlPoolSlotState.Creating &&
          slot.connection !== null) {
          this.ensurePhysicalClose(slot).catch(
            (error: Object): void => {
              this.backgroundErrors.push(error);
            });
        }
      }
      await this.waitForEmpty();
    }
    budget.dispose();

    for (const error of this.backgroundErrors) appendPoolFailure(failures, error);
    this.backgroundErrors = [];
    this.state = MySqlPoolState.Closed;
    if (failures.length > 0) throw poolOperationFailure(failures);
  }

  private rejectAllWaiters(): void {
    const queued = this.waiters;
    this.waiters = [];
    for (const waiter of queued) {
      this.cancelWaiterTimer(waiter);
      waiter.fail(ArkDbError.cancelled('The MySQL pool is closing.'));
    }
    for (const slot of this.slots) {
      this.cancelIdleTimer(slot);
    }
  }

  private dispatch(allowWarmup: boolean): void {
    if (this.state !== MySqlPoolState.Open) return;

    while (this.idle.length > 0) {
      const slot = this.idle.shift();
      if (slot === undefined) break;
      const waiter = this.takeNextWaiter();
      if (waiter === null) {
        this.idle.unshift(slot);
        break;
      }
      this.issueLease(slot, waiter);
    }

    while (this.slots.length < this.options.maxSize &&
      this.activeWaiterCount() > this.demandCreationCount()) {
      this.startCreation(true);
    }

    if (!allowWarmup ||
      this.activeWaiterCount() > this.demandCreationCount()) return;
    while (this.slots.length < this.options.maxSize &&
      this.availableIdleTarget() < this.options.minIdle) {
      this.startCreation(false);
    }
  }

  private availableIdleTarget(): number {
    let target = this.idle.length;
    for (const slot of this.slots) {
      if (slot.state === MySqlPoolSlotState.Creating &&
        !slot.demandCreation) target++;
    }
    return target;
  }

  private startCreation(demandCreation: boolean): void {
    const slot = new MySqlPoolSlot(demandCreation);
    this.slots.push(slot);
    slot.opening = this.openSlot(slot);
    slot.opening.catch((_error: Object): void => {});
  }

  private async openSlot(slot: MySqlPoolSlot): Promise<void> {
    let failure: Object | null = null;
    try {
      const connection = this.runtime.createConnection(this.nextConnectionOptions());
      slot.connection = connection;
      await connection.connect();
    } catch (error) {
      failure = error as Object;
    }

    if (failure !== null) {
      const demandCreation = slot.demandCreation;
      slot.demandCreation = false;
      const waiter = demandCreation && this.state === MySqlPoolState.Open ?
        this.takeNextWaiter() : null;
      if (waiter !== null) this.cancelWaiterTimer(waiter);
      if (slot.connection !== null) {
        try {
          await this.ensurePhysicalClose(slot);
        } catch (closeError) {
          failure = poolOperationFailure([failure, closeError as Object]);
        }
      }
      this.removeSlot(slot);
      if (waiter !== null && waiter.active) {
        waiter.fail(failure);
      } else {
        appendPoolFailure(this.backgroundErrors, failure);
      }
      this.dispatch(demandCreation);
      return;
    }

    slot.demandCreation = false;
    if (this.state !== MySqlPoolState.Open) {
      try {
        await this.ensurePhysicalClose(slot);
      } catch (error) {
        this.backgroundErrors.push(error as Object);
      }
      this.removeSlot(slot);
      return;
    }

    const waiter = this.takeNextWaiter();
    if (waiter !== null) {
      this.issueLease(slot, waiter);
      return;
    }
    this.makeIdle(slot);
  }

  private issueLease(slot: MySqlPoolSlot, waiter: MySqlPoolWaiter): void {
    this.cancelIdleTimer(slot);
    removeItem(this.idle, slot);
    slot.state = MySqlPoolSlotState.Leased;
    const connection = slot.connection;
    if (connection === null) {
      this.cancelWaiterTimer(waiter);
      waiter.fail(ArkDbError.protocol('The MySQL pool slot has no physical connection.'));
      this.removeSlot(slot);
      this.dispatch(true);
      return;
    }
    const context = new MySqlLeaseContext(connection,
      (lease: MySqlLeaseContext): Promise<void> =>
        this.finishLease(slot, lease));
    slot.lease = context;
    this.cancelWaiterTimer(waiter);
    waiter.succeed(new PooledMySqlConnectionLease(context));
    this.dispatch(true);
  }

  private async finishLease(slot: MySqlPoolSlot,
    context: MySqlLeaseContext): Promise<void> {
    if (slot.lease !== context) {
      throw ArkDbError.validation('The MySQL pool lease does not own this slot.');
    }
    slot.state = MySqlPoolSlotState.Releasing;
    const failures: Object[] = [];
    let settlementTimedOut = false;
    let cursorSettlement: Promise<Object[]> | null = null;
    let statementSettlement: Promise<Object[]> | null = null;
    let resetSettlement: Promise<Object | null> | null = null;
    const forcedFailure = context.forcedFailure;
    if (forcedFailure !== null) {
      settlementTimedOut = true;
      appendPoolFailure(failures, forcedFailure);
    } else {
      const budget = new MySqlPoolBudget(
        this.runtime.timers, this.options.releaseTimeoutMs,
        'MySQL lease release timed out.');
      context.onForce((error: ArkDbError): void => budget.cancel(error));
      try {
        try {
          const operationFailures = await budget.wait(context.waitForOperations());
          for (const failure of operationFailures) appendPoolFailure(failures, failure);
        } catch (error) {
          settlementTimedOut = true;
          appendPoolFailure(failures, error as Object);
        }

        if (!settlementTimedOut) {
          cursorSettlement = context.closeCursors();
          try {
            const cursorFailures = await budget.wait(cursorSettlement);
            for (const failure of cursorFailures) appendPoolFailure(failures, failure);
          } catch (error) {
            settlementTimedOut = true;
            appendPoolFailure(failures, error as Object);
          }
        }

        if (!settlementTimedOut) {
          statementSettlement = context.closeStatements();
          try {
            const resourceFailures = await budget.wait(statementSettlement);
            for (const failure of resourceFailures) appendPoolFailure(failures, failure);
          } catch (error) {
            settlementTimedOut = true;
            appendPoolFailure(failures, error as Object);
          }
        }

        const reusable = !settlementTimedOut && failures.length === 0 &&
          !context.destroyRequested && this.state === MySqlPoolState.Open;
        if (reusable) {
          const reset = context.connection.mysqlFeatures?.session;
          if (reset === undefined) {
            appendPoolFailure(failures,
              ArkDbError.unsupported('This MySQL connection does not support session reset.'));
          } else {
            resetSettlement = observePoolSettlement(
              (): Promise<void> => reset.reset());
            try {
              const resetFailure = await budget.wait(resetSettlement);
              if (resetFailure !== null) appendPoolFailure(failures, resetFailure);
            } catch (error) {
              settlementTimedOut = true;
              appendPoolFailure(failures, error as Object);
            }
          }
        }
      } finally {
        budget.dispose();
      }
    }

    if (failures.length === 0 && !context.destroyRequested &&
      this.state === MySqlPoolState.Open) {
      slot.lease = null;
      this.makeIdle(slot);
      return;
    }

    if (settlementTimedOut) {
      const closing = this.ensurePhysicalClose(slot);
      try {
        await closing;
      } catch (error) {
        appendPoolFailure(failures, error as Object);
      }
      if (cursorSettlement !== null) {
        try {
          const lateCursorFailures = await cursorSettlement;
          for (const failure of lateCursorFailures) {
            appendPoolFailure(failures, failure);
          }
        } catch (error) {
          appendPoolFailure(failures, error as Object);
        }
      }
      if (statementSettlement !== null) {
        try {
          const lateStatementFailures = await statementSettlement;
          for (const failure of lateStatementFailures) {
            appendPoolFailure(failures, failure);
          }
        } catch (error) {
          appendPoolFailure(failures, error as Object);
        }
      }
      if (resetSettlement !== null) {
        try {
          const lateResetFailure = await resetSettlement;
          if (lateResetFailure !== null) appendPoolFailure(failures, lateResetFailure);
        } catch (error) {
          appendPoolFailure(failures, error as Object);
        }
      }
    } else {
      try {
        await this.ensurePhysicalClose(slot);
      } catch (error) {
        appendPoolFailure(failures, error as Object);
      }
    }

    slot.lease = null;
    this.removeSlot(slot);
    this.dispatch(true);
    if (this.state === MySqlPoolState.Closing) {
      for (const failure of failures) appendPoolFailure(this.backgroundErrors, failure);
    }
    if (failures.length > 0) throw poolOperationFailure(failures);
  }

  private makeIdle(slot: MySqlPoolSlot): void {
    slot.state = MySqlPoolSlotState.Idle;
    slot.lease = null;
    this.idle.push(slot);
    this.dispatch(true);
    if (slot.state === MySqlPoolSlotState.Idle &&
      this.options.idleTimeoutMs > 0) {
      try {
        slot.idleTimerId = this.runtime.timers.schedule(
          (): void => this.expireIdle(slot), this.options.idleTimeoutMs);
      } catch (error) {
        this.backgroundErrors.push(error as Object);
        this.destroyIdleSlot(slot);
      }
    }
  }

  private expireIdle(slot: MySqlPoolSlot): void {
    slot.idleTimerId = 0;
    if (this.state !== MySqlPoolState.Open ||
      slot.state !== MySqlPoolSlotState.Idle ||
      this.idle.length <= this.options.minIdle) return;
    this.destroyIdleSlot(slot);
  }

  private destroyIdleSlot(slot: MySqlPoolSlot): void {
    if (slot.state !== MySqlPoolSlotState.Idle) return;
    this.cancelIdleTimer(slot);
    removeItem(this.idle, slot);
    slot.state = MySqlPoolSlotState.Destroying;
    this.ensurePhysicalClose(slot).then((): void => {
      this.removeSlot(slot);
      this.dispatch(true);
    }, (error: Object): void => {
      this.backgroundErrors.push(error);
      this.removeSlot(slot);
      this.dispatch(true);
    });
  }

  private ensurePhysicalClose(slot: MySqlPoolSlot): Promise<void> {
    if (slot.closing !== null) return slot.closing;
    if (slot.connection === null) return Promise.resolve();
    slot.state = MySqlPoolSlotState.Destroying;
    slot.closing = slot.connection.close();
    slot.closing.catch((_error: Object): void => {});
    return slot.closing;
  }

  private timeoutWaiter(waiter: MySqlPoolWaiter): void {
    if (!waiter.active) return;
    waiter.timerId = 0;
    removeItem(this.waiters, waiter);
    waiter.fail(ArkDbError.timeout('MySQL pool acquire timed out.'));
    this.dispatch(true);
  }

  private takeNextWaiter(): MySqlPoolWaiter | null {
    while (this.waiters.length > 0) {
      const waiter = this.waiters.shift();
      if (waiter !== undefined && waiter.active) return waiter;
    }
    return null;
  }

  private activeWaiterCount(): number {
    let count = 0;
    for (const waiter of this.waiters) {
      if (waiter.active) count++;
    }
    return count;
  }

  private demandCreationCount(): number {
    let count = 0;
    for (const slot of this.slots) {
      if (slot.demandCreation) count++;
    }
    return count;
  }

  private projectedQueuedWaiterCount(): number {
    const availableSlots = Math.max(0, this.options.maxSize - this.slots.length);
    return Math.max(0, this.activeWaiterCount() + 1 -
      this.creatingSlotCount() - this.idle.length - availableSlots);
  }

  private creatingSlotCount(): number {
    let count = 0;
    for (const slot of this.slots) {
      if (slot.state === MySqlPoolSlotState.Creating) count++;
    }
    return count;
  }

  private cancelWaiterTimer(waiter: MySqlPoolWaiter): void {
    if (waiter.timerId !== 0) this.runtime.timers.cancel(waiter.timerId);
    waiter.timerId = 0;
  }

  private cancelIdleTimer(slot: MySqlPoolSlot): void {
    if (slot.idleTimerId !== 0) this.runtime.timers.cancel(slot.idleTimerId);
    slot.idleTimerId = 0;
  }

  private removeSlot(slot: MySqlPoolSlot): void {
    this.cancelIdleTimer(slot);
    removeItem(this.idle, slot);
    removeItem(this.slots, slot);
    if (this.slots.length === 0) {
      const waiters = this.emptyWaiters;
      this.emptyWaiters = [];
      for (const complete of waiters) complete();
    }
  }

  private waitForEmpty(): Promise<void> {
    if (this.slots.length === 0) return Promise.resolve();
    return new Promise<void>((resolve: () => void): void => {
      this.emptyWaiters.push(resolve);
    });
  }

  private nextConnectionOptions(): MySqlConnectionOptions {
    const extensions = this.connectionOptions.extensions;
    return new MySqlConnectionOptions(
      this.connectionOptions.config.clone(),
      this.connectionOptions.password,
      extensions === undefined ? undefined :
        new MySqlConnectionExtensions(extensions.executionObserver));
  }
}

export function createMySqlPool(options: MySqlConnectionOptions,
  poolOptions?: MySqlPoolOptions): MySqlPool {
  return createMySqlPoolInternal(
    options, poolOptions === undefined ? new MySqlPoolOptions() : poolOptions,
    new DefaultMySqlPoolRuntime());
}

export function createMySqlPoolInternal(options: MySqlConnectionOptions,
  poolOptions: MySqlPoolOptions, runtime: MySqlPoolRuntime): MySqlPool {
  const snapshot = poolOptions.clone();
  const errors = snapshot.validate();
  if (errors.length > 0) throw errors[0];
  return new FifoMySqlPool(options, snapshot, runtime);
}

let poolCloseReentryTarget: FifoMySqlPool | null = null;
let poolCloseOuterTask: Promise<void> | null = null;
let poolCloseRepeatedTask: Promise<void> | null = null;
let poolCloseStartCount: number = 0;

export function setupPoolCloseReentryTest(options: MySqlConnectionOptions,
  poolOptions: MySqlPoolOptions, runtime: MySqlPoolRuntime): void {
  clearPoolCloseReentryTest();
  const snapshot = poolOptions.clone();
  const errors = snapshot.validate();
  if (errors.length > 0) throw errors[0];
  poolCloseReentryTarget = new FifoMySqlPool(options, snapshot, runtime);
}

export function startPoolCloseReentryTest(): void {
  const target = poolCloseReentryTarget;
  if (target === null) throw new Error('Pool close reentry test is not set up.');
  const startIndex = poolCloseStartCount++;
  const task = target.close();
  if (startIndex === 0) {
    poolCloseOuterTask = task;
  } else if (startIndex === 1) {
    poolCloseRepeatedTask = task;
  }
}

export function poolCloseReentryTaskForTest(repeated: boolean): Promise<void> | null {
  return repeated ? poolCloseRepeatedTask : poolCloseOuterTask;
}

export function clearPoolCloseReentryTest(): void {
  poolCloseReentryTarget = null;
  poolCloseOuterTask = null;
  poolCloseRepeatedTask = null;
  poolCloseStartCount = 0;
}

function snapshotConnectionOptions(options: MySqlConnectionOptions): MySqlConnectionOptions {
  const extensions = options.extensions;
  return new MySqlConnectionOptions(
    options.config.clone(), options.password,
    extensions === undefined ? undefined :
      new MySqlConnectionExtensions(extensions.executionObserver));
}

function removeItem<T>(items: T[], value: T): void {
  const index = items.indexOf(value);
  if (index >= 0) items.splice(index, 1);
}

function appendPoolFailure(failures: Object[], error: Object): void {
  const existing: Object[] = [];
  for (const failure of failures) appendPoolFailureLeaves(existing, failure);
  const incoming: Object[] = [];
  appendPoolFailureLeaves(incoming, error);
  for (const leaf of incoming) {
    if (!containsPoolFailureLeaf(existing, leaf)) {
      failures.push(error);
      return;
    }
  }
}

function appendPoolFailureLeaves(leaves: Object[], error: Object): void {
  if (error instanceof MySqlOperationError) {
    appendPoolFailureLeaves(leaves, error.primary);
    for (const cleanup of error.cleanupErrors) {
      appendPoolFailureLeaves(leaves, cleanup);
    }
    return;
  }
  if (!containsPoolFailureLeaf(leaves, error)) leaves.push(error);
}

function containsPoolFailureLeaf(leaves: Object[], expected: Object): boolean {
  for (const leaf of leaves) {
    if (leaf === expected) return true;
  }
  return false;
}

function poolOperationFailure(failures: Object[]): MySqlOperationError {
  const leaves: Object[] = [];
  for (const failure of failures) appendPoolFailureLeaves(leaves, failure);
  const first = failures[0];
  const cleanup: ArkDbError[] = [];
  const primary = poolArkDbError(leaves[0]);
  let outcome = MySqlExecutionOutcome.Unknown;
  let originalCause: Object | undefined;
  if (first instanceof MySqlOperationError) {
    outcome = first.outcome;
    originalCause = first.originalCause;
  } else if (!(first instanceof ArkDbError)) {
    originalCause = first;
  }
  for (let index = 1; index < leaves.length; index++) {
    cleanup.push(poolArkDbError(leaves[index]));
  }
  return new MySqlOperationError(primary, cleanup, outcome, originalCause);
}

function observePoolSettlement(start: () => Promise<void>): Promise<Object | null> {
  return new Promise<Object | null>((resolve: (failure: Object | null) => void): void => {
    let task: Promise<void>;
    try {
      task = start();
    } catch (error) {
      resolve(error as Object);
      return;
    }
    task.then(
      (): void => resolve(null),
      (error: Object): void => resolve(error));
  });
}

function poolArkDbError(error: Object): ArkDbError {
  if (error instanceof ArkDbError) return error;
  if (error instanceof Error && error.message.length > 0) {
    return ArkDbError.network(error.message);
  }
  return ArkDbError.network('MySQL pool operation failed.');
}
