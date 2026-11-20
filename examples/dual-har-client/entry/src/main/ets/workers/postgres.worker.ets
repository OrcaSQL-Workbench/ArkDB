import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import {
  ArkDbError as PostgresArkDbError, PostgresConnectionConfig,
  PostgresConnectionOptions, PostgresDriverFactory
} from '@arkdb/postgres';

const port: ThreadWorkerGlobalScope = worker.workerPort;
let probes: number = 0;

port.onmessage = async (event: MessageEvents): Promise<void> => {
  if (event.data === 'shutdown') {
    port.postMessage('shutdown-complete');
    port.close();
    return;
  }
  if (event.data !== 'offline-probe') {
    port.close();
    return;
  }
  const config = new PostgresConnectionConfig();
  config.host = '127.0.0.1';
  config.user = 'arkdb';
  config.port = 1;
  const connection = new PostgresDriverFactory().create(new PostgresConnectionOptions(config, ''));
  let outcome: string = 'pgsql:unexpected-success';
  try {
    await connection.query('SELECT 1');
  } catch (error) {
    outcome = error instanceof PostgresArkDbError
      ? 'pgsql:local-error'
      : 'pgsql:foreign-error';
  }
  await connection.close();
  probes++;
  outcome += ':' + probes;
  port.postMessage(outcome);
};
