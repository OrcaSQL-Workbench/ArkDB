import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { DeviceAcceptanceRequest, DeviceAcceptanceResponse, DeviceShutdownResponse } from '../sample/Messages';
import { DeviceAcceptanceRunner } from '../sample/DeviceAcceptanceRunner';

const port: ThreadWorkerGlobalScope = worker.workerPort;
const runner = new DeviceAcceptanceRunner();
let runTask: Promise<void> | null = null;
let shuttingDown: boolean = false;
let executionFailed: boolean = false;

port.onmessage = (event: MessageEvents): void => {
  const request: Object = event.data;
  if (!(request instanceof DeviceAcceptanceRequest)) {
    sendError('Invalid Worker request.');
  } else if (request.operation === 'stop') {
    request.password = '';
    if (!shuttingDown) {
      shuttingDown = true;
      void stop().catch((): void => {
        console.error('Device acceptance Worker shutdown could not be completed.');
      });
    }
  } else if (request.operation === 'acceptance' && runTask === null && !shuttingDown) {
    runTask = accept(request);
  } else {
    request.password = '';
    sendError('Invalid or overlapping Worker request.');
  }
};

async function accept(request: DeviceAcceptanceRequest): Promise<void> {
  try {
    port.postMessageWithSharedSendable(await runner.run(request));
  } catch (_error) {
    executionFailed = true;
    request.password = '';
    sendError('Worker execution failed. The outcome is unknown.');
  }
}

async function stop(): Promise<void> {
  let success = true;
  try {
    await runner.stop();
  } catch (_error) {
    success = false;
  }
  if (runTask !== null) await runTask;
  try {
    await runner.waitForQuiescence();
  } catch (_error) {
    success = false;
  }
  if (executionFailed) success = false;
  const response = new DeviceShutdownResponse();
  response.ok = success;
  try {
    port.postMessageWithSharedSendable(response);
  } finally {
    port.close();
  }
}

function sendError(text: string): void {
  const response = new DeviceAcceptanceResponse();
  response.errorKind = 'worker';
  response.text = text;
  try {
    port.postMessageWithSharedSendable(response);
  } catch (_error) {
    executionFailed = true;
    console.error('Device acceptance Worker could not deliver its result.');
  }
}
