import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { SampleRequest } from '../sample/Messages';
import { SampleRunner } from '../sample/SampleRunner';

const port: ThreadWorkerGlobalScope = worker.workerPort;
const runner = new SampleRunner();

port.onmessage = (event: MessageEvents): void => {
  const request: Object = event.data;
  if (request instanceof SampleRequest && request.operation === 'stop') {
    void stop();
  } else if (request instanceof SampleRequest && request.operation === 'read') {
    void read(request);
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

async function stop(): Promise<void> {
  await runner.stop();
}
