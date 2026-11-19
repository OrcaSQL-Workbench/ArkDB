import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import {
  ArkDbError as MySqlArkDbError, ConnectionConfig, MySqlDriverFactory
} from '@arkdb/mysql';

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
  const config = new ConnectionConfig();
  config.host = '127.0.0.1';
  config.user = 'arkdb';
  config.port = 1;
  const connection = new MySqlDriverFactory().createConnection(config, '');
  let outcome: string = 'mysql:unexpected-success';
  try {
    await connection.query('SELECT 1');
  } catch (error) {
    outcome = error instanceof MySqlArkDbError
      ? 'mysql:local-error'
      : 'mysql:foreign-error';
  }
  await connection.close();
  probes++;
  outcome += ':' + probes;
  port.postMessage(outcome);
};
