import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import ts from 'typescript';
import { deviceRunnerFixture, validDeviceRunnerRequest, State } from './postgres-device-runner-fixtures.mjs';

class DeviceAcceptanceRequest {
  constructor(operation) { this.operation = operation; }
}
class DeviceAcceptanceResponse {}
class DeviceShutdownResponse {}
const source = readFileSync(new URL(
  '../../examples/postgres-device-acceptance/entry/src/main/ets/workers/device.worker.ets', import.meta.url), 'utf8');
const output = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
}).outputText;

function fixture(stopError = false, failResponse = false, failShutdown = false, failRejection = false) {
  let releaseRun;
  let releaseQuiescence;
  let failQuiescence;
  let stopCalls = 0;
  const run = new Promise((resolve) => { releaseRun = resolve; });
  const quiescence = new Promise((resolve, reject) => {
    releaseQuiescence = resolve;
    failQuiescence = reject;
  });
  class DeviceAcceptanceRunner {
    async run() { return run; }
    async stop() {
      stopCalls++;
      if (stopError) throw new Error('secret shutdown error');
    }
    async waitForQuiescence() { await quiescence; }
  }
  const port = {
    closed: false,
    messages: [],
    postMessageWithSharedSendable(value) {
      if (failRejection && value instanceof DeviceAcceptanceResponse) {
        failRejection = false;
        throw new Error('secret rejection transport error');
      }
      if (failResponse && !(value instanceof DeviceShutdownResponse)) throw new Error('secret post error');
      if (failShutdown && value instanceof DeviceShutdownResponse) throw new Error('secret shutdown post error');
      this.messages.push(value);
    },
    close() { this.closed = true; }
  };
  const modules = {
    '@kit.ArkTS': { worker: { workerPort: port } },
    '../sample/Messages': { DeviceAcceptanceRequest, DeviceAcceptanceResponse, DeviceShutdownResponse },
    '../sample/DeviceAcceptanceRunner': { DeviceAcceptanceRunner }
  };
  vm.compileFunction(output, ['exports', 'require'])({}, (name) => {
    if (!(name in modules)) throw new Error(`Unknown module: ${name}`);
    return modules[name];
  });
  return { port, releaseRun, releaseQuiescence, failQuiescence, stopCalls: () => stopCalls };
}

test('completed run does not close before host-requested shutdown', async () => {
  const { port, releaseRun } = fixture();
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  releaseRun({ ok: true });
  await new Promise(setImmediate);
  assert.equal(port.closed, false);
});

test('interrupted run remains open until cleanup is quiescent', async () => {
  const { port, releaseRun, releaseQuiescence } = fixture();
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  releaseRun({ ok: false });
  await new Promise(setImmediate);
  assert.equal(port.closed, false);
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.closed, true);
});

test('duplicate stop is idempotent and acknowledges only after quiescence', async () => {
  const { port, releaseRun, releaseQuiescence, stopCalls } = fixture();
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  releaseRun({ ok: true });
  await new Promise(setImmediate);
  assert.equal(stopCalls(), 1);
  assert.equal(port.messages.some((message) => message instanceof DeviceShutdownResponse), false);
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.messages.at(-1) instanceof DeviceShutdownResponse, true);
  assert.equal(port.messages.at(-1).ok, true);
});

test('a failed acceptance result remains distinct from successful cleanup', async () => {
  const { port, releaseRun, releaseQuiescence } = fixture();
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  releaseRun({ ok: false });
  await new Promise(setImmediate);
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.messages[0].ok, false);
  assert.equal(port.messages.at(-1).ok, true);
});

for (const failure of ['stop', 'quiescence']) {
  test(`${failure} failure is not acknowledged as successful shutdown`, async () => {
    const { port, releaseRun, releaseQuiescence, failQuiescence } = fixture(failure === 'stop');
    port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
    port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
    releaseRun({ ok: false });
    await new Promise(setImmediate);
    if (failure === 'stop') releaseQuiescence();
    else failQuiescence(new Error('secret quiescence error'));
    await new Promise(setImmediate);
    assert.equal(port.messages.at(-1) instanceof DeviceShutdownResponse, true);
    assert.equal(port.messages.at(-1).ok, false);
    assert.equal(JSON.stringify(port.messages).includes('secret'), false);
  });
}

test('response delivery failure still drains cleanup and reports shutdown failure', async () => {
  const { port, releaseRun, releaseQuiescence } = fixture(false, true);
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  releaseRun({ ok: true });
  await new Promise(setImmediate);
  assert.equal(port.closed, false);
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.messages.at(-1) instanceof DeviceShutdownResponse, true);
  assert.equal(port.messages.at(-1).ok, false);
  assert.equal(port.closed, true);
});

test('shutdown delivery failure still closes the Worker port', async () => {
  const { port, releaseRun, releaseQuiescence } = fixture(false, false, true);
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  releaseRun({ ok: true });
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.closed, true);
});

test('overlapping requests discard passwords without replacing the active run', async () => {
  const { port, releaseRun, releaseQuiescence, stopCalls } = fixture();
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  const duplicate = Object.assign(new DeviceAcceptanceRequest('acceptance'), { password: 'secret' });
  port.onmessage({ data: duplicate });
  assert.equal(duplicate.password, '');
  assert.equal(JSON.stringify(port.messages).includes('secret'), false);
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  releaseRun({ ok: true });
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(stopCalls(), 1);
  assert.equal(port.messages.at(-1).ok, true);
});

test('stop and invalid-operation requests erase their typed request passwords', async () => {
  const { port, releaseQuiescence } = fixture();
  const invalid = Object.assign(new DeviceAcceptanceRequest('invalid'), { password: 'secret' });
  const stop = Object.assign(new DeviceAcceptanceRequest('stop'), { password: 'secret' });
  const duplicate = Object.assign(new DeviceAcceptanceRequest('stop'), { password: 'secret' });
  port.onmessage({ data: invalid });
  port.onmessage({ data: stop });
  port.onmessage({ data: duplicate });
  assert.equal(invalid.password, '');
  assert.equal(stop.password, '');
  assert.equal(duplicate.password, '');
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.closed, true);
});

test('a rejected request whose error response cannot be sent makes shutdown fail', async () => {
  const { port, releaseRun, releaseQuiescence } = fixture(false, false, false, true);
  port.onmessage({ data: new DeviceAcceptanceRequest('acceptance') });
  const duplicate = Object.assign(new DeviceAcceptanceRequest('acceptance'), { password: 'secret' });
  assert.doesNotThrow(() => port.onmessage({ data: duplicate }));
  assert.equal(duplicate.password, '');
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  releaseRun({ ok: true });
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.messages.at(-1) instanceof DeviceShutdownResponse, true);
  assert.equal(port.messages.at(-1).ok, false);
  assert.equal(port.closed, true);
});

test('a rejection delivery failure during quiescence makes shutdown fail', async () => {
  const { port, releaseQuiescence } = fixture(false, false, false, true);
  port.onmessage({ data: new DeviceAcceptanceRequest('stop') });
  await new Promise(setImmediate);
  const request = Object.assign(new DeviceAcceptanceRequest('invalid'), { password: 'secret' });
  port.onmessage({ data: request });
  assert.equal(request.password, '');
  releaseQuiescence();
  await new Promise(setImmediate);
  assert.equal(port.messages.at(-1) instanceof DeviceShutdownResponse, true);
  assert.equal(port.messages.at(-1).ok, false);
  assert.equal(port.closed, true);
});

test('Worker waits for the real runner to settle an interrupted connection before shutdown',
  { timeout: 7000 }, async () => {
    const runtime = deviceRunnerFixture(Date.now(), Date, () => 1);
    const { DeviceAcceptanceRunner, DeviceAcceptanceRequest, DeviceAcceptanceResponse, binding, sha } = runtime;
    let startConnection;
    const started = new Promise((resolve) => { startConnection = resolve; });
    let releaseConnection;
    const pending = new Promise((resolve) => { releaseConnection = resolve; });
    const factory = {
      createConnection() {
        return {
          state: State.Closed,
          async connect() { startConnection(); await pending; },
          async close() { this.state = State.Closed; }
        };
      }
    };
    class WiredRunner extends DeviceAcceptanceRunner {
      constructor() {
        super(factory, binding,
          { read: () => ({ deviceType: 'tablet', sdkApiVersion: 24, osFullName: 'HarmonyOS' }) },
          { wait: async () => {} }, { sign: async () => { throw new Error('unexpected signing'); } });
      }
    }
    let finish;
    const closed = new Promise((resolve) => { finish = resolve; });
    const port = {
      messages: [],
      closed: false,
      postMessageWithSharedSendable(value) { this.messages.push(value); },
      close() { this.closed = true; finish(); }
    };
    const modules = {
      '@kit.ArkTS': { worker: { workerPort: port } },
      '../sample/Messages': { DeviceAcceptanceRequest, DeviceAcceptanceResponse, DeviceShutdownResponse },
      '../sample/DeviceAcceptanceRunner': { DeviceAcceptanceRunner: WiredRunner }
    };
    vm.compileFunction(output, ['exports', 'require'])({}, (name) => {
      if (!(name in modules)) throw new Error(`Unknown module: ${name}`);
      return modules[name];
    });

    const request = validDeviceRunnerRequest(DeviceAcceptanceRequest, sha, 'worker-test-secret');
    port.onmessage({ data: request });
    await started;
    port.onmessage({ data: Object.assign(new DeviceAcceptanceRequest(), { operation: 'stop' }) });
    await new Promise((resolve) => setTimeout(resolve, 2200));
    assert.equal(request.password, '');
    assert.equal(port.closed, false, 'Worker closed before the late connection settled');
    assert.equal(port.messages.some((value) => value instanceof DeviceShutdownResponse), false);
    releaseConnection();
    await closed;
    assert.equal(port.messages.length, 2);
    assert.ok(port.messages[0] instanceof DeviceAcceptanceResponse);
    assert.equal(port.messages[0].receiptJson, '');
    assert.ok(port.messages[1] instanceof DeviceShutdownResponse);
    assert.equal(port.messages[1].ok, false, 'a cleanup timeout must not be acknowledged as successful');
    assert.equal(JSON.stringify(port.messages).includes('worker-test-secret'), false);
  });
