import { worker } from '@kit.ArkTS';
import { ArkDbError as MySqlError, QueryResult as MySqlResult } from '@arkdb/mysql';
import { ArkDbError as PostgresError, QueryResult as PostgresResult } from '@arkdb/postgres';

let workerIsolationRetryBlocked: boolean = false;

export function isWorkerIsolationRetryBlocked(): boolean {
  return workerIsolationRetryBlocked;
}

class Probe {
  readonly instance: worker.ThreadWorker;
  readonly exit: Promise<void>;
  shutdownAcknowledged: boolean = false;
  finished: boolean = false;
  failure: string = '';
  stopPromise: Promise<void> | null = null;

  constructor(path: string) {
    this.instance = new worker.ThreadWorker(path);
    this.instance.onerror = (): void => { this.failure = 'Worker execution failed.'; };
    this.exit = new Promise<void>((resolve) => {
      this.instance.onexit = (code: number): void => {
        this.finished = true;
        if ((!this.shutdownAcknowledged || code !== 0) && this.failure.length === 0) {
          this.failure = 'Unexpected Worker exit: ' + code;
        }
        resolve();
      };
    });
  }
}

function exchange(probe: Probe, expected: string): Promise<void> {
  const instance = probe.instance;
  if (probe.failure.length > 0) return Promise.reject(new Error(probe.failure));
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout((): void => {
      reject(new Error('Worker round trip timed out: ' + expected));
    }, 5000);
    instance.onmessage = (event): void => {
      clearTimeout(timer);
      if (event.data === expected) resolve();
      else {
        if (probe.failure.length === 0) {
          probe.failure = 'Unexpected Worker response: ' + String(event.data);
        }
        reject(new Error(probe.failure));
      }
    };
    instance.onerror = (): void => {
      probe.failure = 'Worker execution failed: ' + expected;
      clearTimeout(timer);
      reject(new Error(probe.failure));
    };
    instance.onmessageerror = (): void => {
      probe.failure = 'Worker message decoding failed: ' + expected;
      clearTimeout(timer);
      reject(new Error(probe.failure));
    };
    try { instance.postMessage('offline-probe'); } catch (error) {
      clearTimeout(timer);
      reject(error);
    }
  });
}

function stop(probe: Probe): Promise<void> {
  if (probe.stopPromise !== null) return probe.stopPromise;
  probe.stopPromise = new Promise<void>((resolve, reject) => {
    const abort = (reason: Error): void => {
      if (probe.failure.length === 0) probe.failure = reason.message;
      if (probe.finished) {
        reject(new Error(probe.failure));
        return;
      }
      try {
        probe.instance.terminate();
      } catch (error) {
        workerIsolationRetryBlocked = true;
        reject(new Error(probe.failure + '; Worker termination failed: ' + String(error) +
          '; Worker exit remains unconfirmed.'));
        return;
      }
      const terminationTimer = setTimeout((): void => {
        workerIsolationRetryBlocked = true;
        reject(new Error(probe.failure + '; Worker exit was not confirmed after termination.'));
      }, 5000);
      probe.exit.then((): void => {
        clearTimeout(terminationTimer);
        reject(new Error(probe.failure));
      });
    };
    const timer = setTimeout((): void => abort(new Error('Worker exit was not confirmed.')), 5000);
    probe.exit.then((): void => {
      clearTimeout(timer);
      if (probe.failure.length > 0) reject(new Error(probe.failure));
      else resolve();
    });
    if (!probe.finished) {
      probe.instance.onmessage = (event): void => {
        if (event.data === 'shutdown-complete' && !probe.finished) probe.shutdownAcknowledged = true;
        else if (probe.failure.length === 0) {
          probe.failure = 'Unexpected Worker shutdown response: ' + String(event.data);
        }
      };
      probe.instance.onmessageerror = (): void => {
        if (probe.failure.length === 0) probe.failure = 'Worker shutdown message decoding failed.';
      };
      try { probe.instance.postMessage('shutdown'); } catch (error) {
        clearTimeout(timer);
        abort(new Error('Worker shutdown request failed: ' + String(error)));
      }
    }
  });
  return probe.stopPromise;
}

export async function verifyWorkerIsolation(): Promise<void> {
  if (workerIsolationRetryBlocked) {
    throw new Error('A previous Worker exit is unconfirmed. Restart the app before retrying.');
  }
  if (new MySqlResult() instanceof PostgresResult || new PostgresResult() instanceof MySqlResult ||
    MySqlError.server('identity probe') instanceof PostgresError ||
    PostgresError.server('identity probe') instanceof MySqlError) {
    throw new Error('Standalone HARs unexpectedly share constructor identity.');
  }
  const active: Probe[] = [];
  try {
    const mysql = new Probe('entry/ets/workers/mysql.worker.ets');
    active.push(mysql);
    const postgres = new Probe('entry/ets/workers/postgres.worker.ets');
    active.push(postgres);
    await Promise.all([
      exchange(mysql, 'mysql:local-error:1'),
      exchange(postgres, 'pgsql:local-error:1')
    ]);
    await exchange(mysql, 'mysql:local-error:2');
    await stop(mysql);
    active.shift();
    const replacement = new Probe('entry/ets/workers/mysql.worker.ets');
    active.push(replacement);
    await Promise.all([
      exchange(replacement, 'mysql:local-error:1'),
      exchange(postgres, 'pgsql:local-error:2')
    ]);
  } finally {
    const cleanupFailures: string[] = [];
    await Promise.all(active.map(async (probe: Probe): Promise<void> => {
      try { await stop(probe); } catch (error) { cleanupFailures.push(String(error)); }
    }));
    if (cleanupFailures.length > 0) throw new Error(cleanupFailures.join('; '));
  }
}
