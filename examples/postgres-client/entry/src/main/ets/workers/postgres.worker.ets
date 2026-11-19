import { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { SampleRequest } from '../sample/Messages';
import { SampleRunner } from '../sample/SampleRunner';

const port: ThreadWorkerGlobalScope = worker.workerPort;
const runner = new SampleRunner();

function closePortSafely(): void {
  try { port.close(); } catch {}
}

port.onmessage = async (event: MessageEvents): Promise<void> => {
  const payload = event.data as Object;
  if (!(payload instanceof SampleRequest)) { closePortSafely(); return; }
  if (payload.operation === 'stop') {
    payload.password = '';
    try { await runner.stop(); } catch { console.error('ArkDB PostgreSQL worker stop cleanup failed.'); }
    return;
  }
  try {
    port.postMessageWithSharedSendable(await runner.run(payload));
  } catch {
    console.error('ArkDB PostgreSQL worker response dispatch failed.');
  } finally {
    closePortSafely();
  }
};

port.onmessageerror = (_event: MessageEvents): void => {
  console.error('ArkDB PostgreSQL worker received an unserializable message.');
  closePortSafely();
};

port.onerror = (_event: ErrorEvent): void => {
  console.error('ArkDB PostgreSQL worker unhandled error.');
  closePortSafely();
};
