const CLEANUP_TIMEOUT_MS: number = 2000;

export class DeviceOperationCleanupError extends Error {
  operationError: Error;
  cleanupError: Error;

  constructor(operationError: Error, cleanupError: Error) {
    super('Device operation and connection cleanup both failed.');
    this.operationError = operationError;
    this.cleanupError = cleanupError;
  }
}

export class DeviceCleanupTimeoutError extends Error {
  operationError: Error | null;
  cleanupError: Error | null;

  constructor(operationError: Error | null, cleanupError: Error | null) {
    super('Connection cleanup timed out.');
    this.operationError = operationError;
    this.cleanupError = cleanupError;
  }
}

export async function waitDeviceCleanup(close: Promise<Error | null>,
  settlement: Promise<Error | null>): Promise<Error | null> {
  let closeError: Error | null = null;
  let operationError: Error | null = null;
  const observedClose = close.then((error): Error | null => {
    closeError = error;
    return error;
  });
  const observedSettlement = settlement.then((error): Error | null => {
    operationError = error;
    return error;
  });
  let timer: number = 0;
  const timeout = new Promise<Error>((resolve): void => {
    timer = setTimeout((): void => resolve(new DeviceCleanupTimeoutError(operationError, closeError)),
      CLEANUP_TIMEOUT_MS);
  });
  const cleanup = Promise.all([observedClose, observedSettlement]).then((errors): Error | null => {
    if (errors[0] !== null && errors[1] !== null) {
      return new DeviceOperationCleanupError(errors[1], errors[0]);
    }
    return errors[1] ?? errors[0];
  });
  const result = await Promise.race<Error | null>([cleanup, timeout]);
  clearTimeout(timer);
  return result;
}

export class DeviceRunOperation<T> {
  result: Promise<T>;
  settlement: Promise<Error | null>;

  constructor(operation: () => Promise<T>, interrupted: Promise<void>, requireActive: () => void,
    observeError: (error: Object) => void) {
    const observed = Promise.resolve().then((): Promise<T> => {
      requireActive();
      return operation();
    }).catch((error: Object): T => {
      observeError(error);
      if (error instanceof Error) throw error;
      throw new Error('The device operation failed with a non-error value.');
    });
    this.settlement = observed.then(
      (): Error | null => null,
      (error: Error): Error | null => error
    );
    this.result = Promise.race<T>([
      observed,
      interrupted.then((): T => { throw new Error('The device run was interrupted.'); })
    ]).then((value: T): T => {
      requireActive();
      return value;
    });
  }
}
