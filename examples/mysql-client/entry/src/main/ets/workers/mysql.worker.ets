import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { DeviceAcceptanceRequest, SampleRequest } from '../sample/Messages';
import { DeviceAcceptanceRunner } from '../sample/DeviceAcceptanceRunner';
import { SampleRunner } from '../sample/SampleRunner';

const port: ThreadWorkerGlobalScope = worker.workerPort;
const runner = new SampleRunner();
const deviceRunner = new DeviceAcceptanceRunner();

port.onmessage = (event: MessageEvents): void => {
  const request: Object = event.data;
  if (request instanceof SampleRequest && request.operation === 'stop') {
    void stop();
  } else if (request instanceof SampleRequest && request.operation === 'read') {
    void read(request);
  } else if (request instanceof DeviceAcceptanceRequest && request.operation === 'acceptance') {
    void accept(request);
  } else {
    throw new Error('Invalid or unknown sample operation.');
  }
};

async function read(request: SampleRequest): Promise<void> {
  try {
    port.postMessage(await runner.run(request));
  } finally {
    port.close();
  }
}

async function accept(request: DeviceAcceptanceRequest): Promise<void> {
  try {
    port.postMessage(await deviceRunner.run(request));
  } finally {
    port.close();
  }
}

async function stop(): Promise<void> {
  await runner.stop();
  await deviceRunner.stop();
}
