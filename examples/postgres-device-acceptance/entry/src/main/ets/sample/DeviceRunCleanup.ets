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

export class DeviceConnectionCleanup {
  errors: Error[] = [];
  settlements: Promise<Error | null>[] = [];
  settlement: Promise<Error | null>;

  constructor(connections: DeviceAcceptanceConnection[]) {
    // Include a connection returned synchronously after a reentrant stop.
    this.settlement = Promise.resolve().then(async (): Promise<Error | null> => {
      for (const connection of connections) {
        const settlement = (async (): Promise<Error | null> => {
          try {
            await connection.close();
            return connection.state === ConnectionState.Closed ? null : new Error('Connection did not close.');
          } catch (error) {
            return error instanceof Error ? error : new Error('Connection cleanup failed with a non-error value.');
          }
        })().then((error): Error | null => {
          if (error !== null) this.errors.push(error);
          return error;
        });
        this.settlements.push(settlement);
      }
      await Promise.all(this.settlements);
      if (this.errors.length === 0) return null;
      if (this.errors.length === 1) return this.errors[0];
      return new DeviceConnectionCleanupError(this.errors.slice());
    });
  }
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

export async function cleanupDeviceRun(close: DeviceConnectionCleanup,
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
  const cleanup = Promise.all([close.settlement, settlement]).then((errors): Error | null => {
    if (errors[0] !== null && errors[1] !== null) {
      return new DeviceOperationCleanupError(errors[1], errors[0]);
    }
    return errors[1] ?? errors[0];
  });
  let timer: number = 0;
  const timeout = new Promise<Error>((resolve): void => {
    timer = setTimeout((): void => resolve(new DeviceRunCleanupTimeoutError(observedOperationError, close, operation)),
      CLEANUP_TIMEOUT_MS);
  });
  const result = await Promise.race<Error | null>([cleanup, timeout, expiredCase]);
  clearTimeout(timer);
  return result;
}
