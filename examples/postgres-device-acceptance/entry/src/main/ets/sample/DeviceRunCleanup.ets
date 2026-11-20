import { ConnectionState } from '@arkdb/postgres';
import {
  DeviceAcceptanceConnection, DeviceCaseCleanupError, DeviceCaseCleanupTimeoutError
} from './DeviceAcceptanceCases';
import { DeviceCleanupTimeoutError, DeviceOperationCleanupError } from './DeviceRunOperation';

const CLEANUP_TIMEOUT_MS: number = 2000;

export class DeviceQueryCleanupError extends Error {
  caseError: DeviceCaseCleanupError;
  queryError: Error;

  constructor(caseError: DeviceCaseCleanupError, queryError: Error) {
    super('Cancellation cleanup and query settlement both failed.');
    this.caseError = caseError;
    this.queryError = queryError;
  }
}

export class DeviceConnectionCleanupError extends Error {
  errors: Error[];

  constructor(errors: Error[]) {
    super('Multiple connections failed to close.');
    this.errors = errors;
  }
}

export class DeviceOperationsCleanupError extends Error {
  errors: Error[];

  constructor(errors: Error[]) {
    super('Multiple device operations failed during cleanup.');
    this.errors = errors;
  }
}

export class DeviceConnectionCleanup {
  errors: Error[] = [];
  settlements: Promise<Error | null>[] = [];
  settlement: Promise<Error | null>;
  cleanupTask: Promise<Error | null> | null = null;
  cleanupOperation: Promise<Error | null> | null = null;
  lastOperation: Promise<Error | null> | null = null;
  readonly quiescence: Promise<Error | null>;
  readonly registrationDone: Promise<void>;
  drainedCount: number = 0;
  private connections: DeviceAcceptanceConnection[];
  private scanned: number = 0;
  private pendingCloses: number = 0;
  private registrationSealed: boolean = false;
  private finishRegistration: (() => void) | null = null;
  private operations: Promise<Error | null>[] = [];
  private operationSettlements: Promise<Error | null>[] = [];

  constructor(connections: DeviceAcceptanceConnection[]) {
    // Take ownership of a snapshot; later additions must use register().
    this.connections = connections.slice();
    this.registrationDone = new Promise<void>((resolve): void => {
      this.finishRegistration = (): void => resolve();
    });
    this.settlement = Promise.resolve().then((): Promise<Error | null> => this.drain());
    this.quiescence = this.registrationDone.then(async (): Promise<Error | null> => {
      const results = await Promise.all(this.operationSettlements);
      const errors: Error[] = [];
      for (const result of results) {
        if (result !== null) errors.push(result);
      }
      const operationError = combineOperationErrors(errors);
      const closeError = await this.drain();
      if (operationError !== null && closeError !== null) {
        return new DeviceOperationCleanupError(operationError, closeError);
      }
      return operationError ?? closeError;
    });
  }

  // All connections created after cleanup starts must be registered before the seal.
  register(connection: DeviceAcceptanceConnection): void {
    this.connections.push(connection);
    this.startClosing();
    if (this.registrationSealed) throw new Error('Connection registration is sealed.');
  }

  sealRegistration(): void {
    if (this.registrationSealed) return;
    this.registrationSealed = true;
    if (this.finishRegistration !== null) this.finishRegistration();
  }

  isRegistrationSealed(): boolean {
    return this.registrationSealed;
  }

  hasTrackedOperation(operation: Promise<Error | null>): boolean {
    return this.operations.includes(operation);
  }

  trackOperation(operation: Promise<Error | null>, settlement: Promise<Error | null>): void {
    if (this.hasTrackedOperation(operation)) return;
    this.operations.push(operation);
    this.operationSettlements.push(settlement);
  }

  hasPendingCloses(): boolean {
    return this.pendingCloses > 0;
  }

  private startClosing(): void {
    while (this.scanned < this.connections.length) {
      const connection = this.connections[this.scanned++];
      this.pendingCloses++;
      const settlement = (async (): Promise<Error | null> => {
        try {
          await connection.close();
          return connection.state === ConnectionState.Closed ? null : new Error('Connection did not close.');
        } catch (error) {
          return error instanceof Error ? error : new Error('Connection cleanup failed with a non-error value.');
        }
      })().then((error): Error | null => {
        this.pendingCloses--;
        if (error !== null) this.errors.push(error);
        return error;
      });
      this.settlements.push(settlement);
    }
  }

  async drain(): Promise<Error | null> {
    let awaited: number = 0;
    do {
      this.startClosing();
      awaited = this.settlements.length;
      await Promise.all(this.settlements);
    } while (this.scanned < this.connections.length || awaited !== this.settlements.length);
    this.drainedCount = awaited;
    if (this.errors.length === 0) return null;
    if (this.errors.length === 1) return this.errors[0];
    return new DeviceConnectionCleanupError(this.errors.slice());
  }
}

function combineOperationErrors(errors: Error[]): Error | null {
  if (errors.length === 0) return null;
  if (errors.length === 1) return errors[0];
  return new DeviceOperationsCleanupError(errors);
}

export class DeviceRunCleanupTimeoutError extends DeviceCleanupTimeoutError {
  cleanupErrors: Error[];
  closeSettlements: Promise<Error | null>[];
  operationSettlement: Promise<Error | null>;

  constructor(operationError: Error | null, close: DeviceConnectionCleanup,
    operation: Promise<Error | null>) {
    super(operationError, close.errors[0] ?? null);
    this.cleanupErrors = close.errors.slice();
    this.closeSettlements = close.settlements;
    this.operationSettlement = operation;
  }
}

export function closeDeviceConnections(connections: DeviceAcceptanceConnection[]): DeviceConnectionCleanup {
  return new DeviceConnectionCleanup(connections);
}

export async function settleDeviceCase(error: Error | null): Promise<Error | null> {
  if (!(error instanceof DeviceCaseCleanupError)) return error;
  const failure: DeviceCaseCleanupError = error;
  if (failure.cleanupError instanceof DeviceCaseCleanupTimeoutError) return failure;
  const results = await Promise.all([failure.querySettlement, failure.cleanupSettlement]);
  const queryError = results[0];
  if (queryError === null) return failure;
  return new DeviceQueryCleanupError(failure, queryError);
}

async function settleRetainedCase(error: Error | null): Promise<Error | null> {
  if (!(error instanceof DeviceCaseCleanupError)) return error;
  const failure: DeviceCaseCleanupError = error;
  const results = await Promise.all([failure.querySettlement, failure.cleanupSettlement]);
  if (results[0] === null) return failure;
  return new DeviceQueryCleanupError(failure, results[0]);
}

export function cleanupDeviceRun(close: DeviceConnectionCleanup,
  operation: Promise<Error | null>): Promise<Error | null> {
  if (close.isRegistrationSealed() && !close.hasTrackedOperation(operation)) {
    throw new Error('Cleanup operation registration is sealed.');
  }
  if ((close.cleanupOperation !== null && close.cleanupOperation !== operation) ||
    (close.hasPendingCloses() && close.lastOperation !== null && close.lastOperation !== operation)) {
    throw new Error('Concurrent cleanup cannot change the active operation.');
  }
  if (close.cleanupTask !== null) return close.cleanupTask;
  close.cleanupOperation = operation;
  close.lastOperation = operation;
  const task = waitForDeviceRunCleanup(close, operation);
  close.cleanupTask = task;
  const clearOperation = (): void => {
    if (close.cleanupTask === task) {
      close.cleanupTask = null;
      close.cleanupOperation = null;
    }
  };
  const settled = task.then(async (result: Error | null): Promise<Error | null> => {
    if (!(result instanceof DeviceRunCleanupTimeoutError)) {
      clearOperation();
      return settleRetainedCase(await operation);
    }
    const settledOperation = await settleRetainedCase(await operation);
    do {
      await close.drain();
    } while (close.drainedCount !== close.settlements.length);
    clearOperation();
    return settledOperation;
  }, (error: Object): Error => {
    clearOperation();
    return error instanceof Error ? error : new Error('Device cleanup failed with a non-error value.');
  });
  close.trackOperation(operation, settled);
  return task;
}

async function waitForDeviceRunCleanup(close: DeviceConnectionCleanup,
  operation: Promise<Error | null>): Promise<Error | null> {
  let observedOperationError: Error | null = null;
  const expiredCase = new Promise<Error>((resolve): void => {
    operation.then((error: Error | null): void => {
      observedOperationError = error;
      if (error instanceof DeviceCaseCleanupError && error.cleanupError instanceof DeviceCaseCleanupTimeoutError) {
        resolve(new DeviceRunCleanupTimeoutError(observedOperationError, close, operation));
      }
    });
  });
  const settlement = operation.then(settleDeviceCase);
  let observedSettlement: Error | null = null;
  let drainedCount: number = -1;
  const finalClose = settlement.then((): Promise<Error | null> => close.drain());
  const cleanup = Promise.all([close.settlement, finalClose, settlement]).then((errors): Error | null => {
    observedSettlement = errors[2];
    drainedCount = close.drainedCount;
    if (errors[1] !== null && errors[2] !== null) {
      return new DeviceOperationCleanupError(errors[2], errors[1]);
    }
    return errors[2] ?? errors[1];
  });
  let timer: number = 0;
  const timeout = new Promise<Error>((resolve): void => {
    timer = setTimeout((): void => resolve(new DeviceRunCleanupTimeoutError(observedOperationError, close, operation)),
      CLEANUP_TIMEOUT_MS);
  });
  let result = await Promise.race<Error | null>([cleanup, timeout, expiredCase]);
  while (drainedCount >= 0 && close.settlements.length > drainedCount &&
    !(result instanceof DeviceRunCleanupTimeoutError)) {
    const lateClose = close.drain().then((error): Error | null => {
      drainedCount = close.drainedCount;
      if (error !== null && observedSettlement !== null) {
        return new DeviceOperationCleanupError(observedSettlement, error);
      }
      return observedSettlement ?? error;
    });
    result = await Promise.race<Error | null>([lateClose, timeout, expiredCase]);
  }
  clearTimeout(timer);
  return result;
}
