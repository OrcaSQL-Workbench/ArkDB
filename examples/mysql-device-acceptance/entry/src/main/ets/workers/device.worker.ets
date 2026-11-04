import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { DeviceAcceptanceRequest } from '../sample/Messages';
import { DeviceAcceptanceRunner } from '../sample/DeviceAcceptanceRunner';

const port: ThreadWorkerGlobalScope = worker.workerPort;
const runner = new DeviceAcceptanceRunner();

port.onmessage = (event: MessageEvents): void => {
  const request: Object = event.data;
  if (request instanceof DeviceAcceptanceRequest && request.operation === 'stop') {
    void stop();
  } else if (request instanceof DeviceAcceptanceRequest && request.operation === 'acceptance') {
    void accept(request);
  } else {
    throw new Error('Invalid or unknown device acceptance operation.');
  }
};

async function accept(request: DeviceAcceptanceRequest): Promise<void> {
  try {
    port.postMessage(await runner.run(request));
  } finally {
    port.close();
  }
}

async function stop(): Promise<void> {
  await runner.stop();
}
