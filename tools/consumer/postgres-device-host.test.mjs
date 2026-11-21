import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import ts from 'typescript';

class DeviceAcceptanceRequest {
  constructor() { this.operation = 'acceptance'; this.password = ''; }
}
class DeviceAcceptanceResponse {
  constructor() { this.receiptJson = 'signed-receipt'; }
}
class DeviceShutdownResponse {
  constructor(ok) { this.ok = ok; }
}

function compile(path) {
  const source = readFileSync(new URL(path, import.meta.url), 'utf8');
  return ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
}

const hostSource = compile('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/DeviceWorkerHost.ets');
const workerSource = compile('../../examples/postgres-device-acceptance/entry/src/main/ets/workers/device.worker.ets');
const messages = { DeviceAcceptanceRequest, DeviceAcceptanceResponse, DeviceShutdownResponse };

function load(source, modules, globals = []) {
  const exports = {};
  vm.compileFunction(source, ['exports', 'require', ...globals.map(([name]) => name)])(
    exports, (name) => {
      if (!(name in modules)) throw new Error(`Unknown module: ${name}`);
      return modules[name];
    }, ...globals.map(([, value]) => value));
  return exports;
}

function fixture(options = {}) {
  const timers = new Map();
  const instances = [];
  let nextTimer = 1;
  class ThreadWorker {
    constructor() {
      if (options.failConstruction) throw new Error('secret constructor error');
      this.messages = [];
      instances.push(this);
    }
    postMessageWithSharedSendable(value) {
      this.messages.push(value);
      if (options.failDelivery && value.operation === 'acceptance') throw new Error('secret delivery error');
      if (options.reentrant && value.operation === 'stop') {
        this.onmessage({ data: new DeviceShutdownResponse(true) });
        this.onexit(0);
      }
    }
    terminate() {
      this.terminated = true;
      if (options.failTermination) throw new Error('secret termination error');
    }
  }
  const host = load(hostSource, { '@kit.ArkTS': { worker: { ThreadWorker } }, './Messages': messages }, [
    ['setTimeout', (callback, ms) => { const id = nextTimer++; timers.set(id, { callback, ms }); return id; }],
    ['clearTimeout', (id) => timers.delete(id)]
  ]);
  return {
    ...host, instances,
    timerDelays() { return [...timers.values()].map(({ ms }) => ms); },
    fireTimers() { for (const [id, { callback }] of [...timers]) { timers.delete(id); callback(); } }
  };
}

const flush = () => new Promise(setImmediate);
function observe(promise) {
  const state = { settled: false };
  state.promise = promise.then(
    (value) => { state.settled = true; return { value }; },
    (error) => { state.settled = true; return { error }; }
  );
  return state;
}

test('receipt is withheld until successful shutdown acknowledgement and exit', async () => {
  const f = fixture();
  const result = observe(new f.DeviceWorkerHost().run(new DeviceAcceptanceRequest()));
  const instance = f.instances[0];
  assert.ok(instance, 'host must create a Worker');
  instance.onmessage({ data: new DeviceAcceptanceResponse() });
  await flush();
  assert.equal(instance.messages.at(-1).operation, 'stop');
  instance.onmessage({ data: new DeviceShutdownResponse(true) });
  await flush();
  assert.equal(result.settled, false);
  instance.onexit(0);
  assert.equal((await result.promise).value.receiptJson, 'signed-receipt');
});

test('host copies request and clears caller password without changing the sent snapshot', async () => {
  const f = fixture();
  const request = Object.assign(new DeviceAcceptanceRequest(), {
    host: 'db.example', port: 5433, user: 'user', password: 'secret', database: 'db', schema: 's',
    caCertPath: '/ca', mismatchHost: 'wrong.example', profile: 'P18',
    signedHapSha256: 'hash', operatorEvidenceId: 'operator'
  });
  const expected = { ...request };
  const result = observe(new f.DeviceWorkerHost().run(request));
  const instance = f.instances[0];
  const sent = instance.messages[0];
  assert.notEqual(sent, request);
  assert.deepEqual({ ...sent }, expected);
  assert.equal(request.password, '');
  request.host = 'changed.example';
  assert.equal(sent.host, 'db.example');
  instance.onmessage({ data: new DeviceAcceptanceResponse() });
  await flush();
  instance.onmessage({ data: new DeviceShutdownResponse(true) });
  instance.onexit(0);
  assert.equal((await result.promise).error, undefined);
  assert.equal(sent.password, '');
});

test('delivery failure erases passwords, hides details and still shuts down', async () => {
  const f = fixture({ failDelivery: true });
  const request = Object.assign(new DeviceAcceptanceRequest(), { password: 'secret' });
  const result = observe(new f.DeviceWorkerHost().run(request));
  const instance = f.instances[0];
  assert.equal(request.password, '');
  assert.equal(instance.messages[0].password, '');
  await flush();
  instance.onmessage({ data: new DeviceShutdownResponse(true) });
  instance.onexit(0);
  assert.doesNotMatch((await result.promise).error.message, /secret/);
});

test('overlapping request and request after early exit erase their passwords', async () => {
  const f = fixture();
  const host = new f.DeviceWorkerHost();
  const result = observe(host.run(new DeviceAcceptanceRequest()));
  const duplicate = Object.assign(new DeviceAcceptanceRequest(), { password: 'secret' });
  await assert.rejects(host.run(duplicate));
  assert.equal(duplicate.password, '');
  f.instances[0].onexit(1);
  assert.ok((await result.promise).error);
  const later = Object.assign(new DeviceAcceptanceRequest(), { password: 'secret' });
  await assert.rejects(host.run(later));
  assert.equal(later.password, '');
});

test('unsolicited response cannot become a subsequent run result', async () => {
  const f = fixture();
  const host = new f.DeviceWorkerHost();
  f.instances[0].onmessage({ data: new DeviceAcceptanceResponse() });
  const request = Object.assign(new DeviceAcceptanceRequest(), { password: 'secret' });
  await assert.rejects(host.run(request));
  assert.equal(request.password, '');
  await flush();
  f.instances[0].onmessage({ data: new DeviceShutdownResponse(true) });
  f.instances[0].onexit(0);
});

test('reentrant shutdown acknowledgement and exit succeed', async () => {
  const f = fixture({ reentrant: true });
  const result = observe(new f.DeviceWorkerHost().run(new DeviceAcceptanceRequest()));
  f.instances[0].onmessage({ data: new DeviceAcceptanceResponse() });
  assert.equal((await result.promise).value.receiptJson, 'signed-receipt');
});

test('acknowledgement before stop, early exit and failed cleanup never publish receipt', async () => {
  for (const mode of ['early-ack', 'early-exit', 'cleanup-failure']) {
    const f = fixture();
    const result = observe(new f.DeviceWorkerHost().run(new DeviceAcceptanceRequest()));
    const instance = f.instances[0];
    if (mode !== 'early-exit') instance.onmessage({ data: new DeviceAcceptanceResponse() });
    if (mode === 'early-ack') {
      await Promise.resolve();
      instance.onmessage({ data: new DeviceShutdownResponse(true) });
    }
    if (mode === 'cleanup-failure') {
      await flush();
      instance.onmessage({ data: new DeviceShutdownResponse(false) });
    }
    instance.onexit(0);
    assert.ok((await result.promise).error, mode);
  }
});

test('worker onerror is sanitized and shutdown is requested', async () => {
  const f = fixture();
  const result = observe(new f.DeviceWorkerHost().run(new DeviceAcceptanceRequest()));
  const instance = f.instances[0];
  assert.equal(typeof instance.onerror, 'function');
  instance.onerror({ message: 'secret error detail' });
  await flush();
  assert.equal(instance.messages.at(-1).operation, 'stop');
  instance.onmessage({ data: new DeviceShutdownResponse(true) });
  instance.onexit(0);
  assert.doesNotMatch((await result.promise).error.message, /secret/);
});

test('silent Worker triggers bounded shutdown and cannot publish a late receipt', async () => {
  const f = fixture();
  const result = observe(new f.DeviceWorkerHost().run(new DeviceAcceptanceRequest()));
  const instance = f.instances[0];
  assert.deepEqual(f.timerDelays(), [86400000]);
  f.fireTimers();
  await flush();
  assert.equal(instance.messages.at(-1).operation, 'stop');
  instance.onmessage({ data: new DeviceAcceptanceResponse() });
  instance.onmessage({ data: new DeviceShutdownResponse(true) });
  instance.onexit(0);
  assert.ok((await result.promise).error);
});

test('unconfirmed Worker termination erases the shared request password', async () => {
  for (const failTermination of [false, true]) {
    const f = fixture({ failTermination });
    const request = Object.assign(new DeviceAcceptanceRequest(), { password: 'secret' });
    const host = new f.DeviceWorkerHost();
    const result = observe(host.run(request));
    const stopped = observe(host.stop());
    await flush();
    const sent = f.instances[0].messages[0];
    f.fireTimers();
    if (!failTermination) f.fireTimers();
    assert.ok((await result.promise).error);
    assert.ok((await stopped.promise).error);
    assert.equal(sent.password, '');
    assert.throws(() => new f.DeviceWorkerHost(), /unconfirmed|restart/i);
  }
});

test('stopping an unstarted worker and worker ownership remain safe', async () => {
  const f = fixture();
  const host = new f.DeviceWorkerHost();
  assert.throws(() => new f.DeviceWorkerHost());
  const stopped = observe(host.stop());
  await flush();
  const instance = f.instances[0];
  instance.onmessage({ data: new DeviceShutdownResponse(true) });
  instance.onexit(0);
  assert.equal((await stopped.promise).error, undefined);
  assert.doesNotThrow(() => new f.DeviceWorkerHost());
  instance.onexit(0);
  assert.throws(() => new f.DeviceWorkerHost());
});

test('failed Worker construction releases ownership and sanitizes the error', () => {
  const f = fixture({ failConstruction: true });
  assert.throws(() => new f.DeviceWorkerHost(), (error) => !/secret/.test(error.message));
});

test('stop during execution suppresses a late receipt', async () => {
  const f = fixture();
  const host = new f.DeviceWorkerHost();
  const result = observe(host.run(new DeviceAcceptanceRequest()));
  const stopped = observe(host.stop());
  await flush();
  const instance = f.instances[0];
  instance.onmessage({ data: new DeviceAcceptanceResponse() });
  instance.onmessage({ data: new DeviceShutdownResponse(true) });
  instance.onexit(0);
  assert.ok((await result.promise).error);
  assert.equal((await stopped.promise).error, undefined);
});

test('unconfirmed termination blocks subsequent attempts', async () => {
  const f = fixture();
  const host = new f.DeviceWorkerHost();
  const result = observe(host.run(new DeviceAcceptanceRequest()));
  const stopped = observe(host.stop());
  await flush();
  f.fireTimers();
  assert.equal(f.instances[0].terminated, true);
  f.fireTimers();
  assert.ok((await result.promise).error);
  assert.ok((await stopped.promise).error);
  assert.throws(() => new f.DeviceWorkerHost(), /unconfirmed|restart/i);
});

test('actual Worker and host wait for quiescence and suppress interrupted receipts', async () => {
  for (const interrupted of [false, true]) {
    let releaseRun;
    let releaseQuiescence;
    let stopCalls = 0;
    const run = new Promise((resolve) => { releaseRun = resolve; });
    const quiescence = new Promise((resolve) => { releaseQuiescence = resolve; });
    class DeviceAcceptanceRunner {
      async run() { return run; }
      async stop() { stopCalls++; }
      async waitForQuiescence() { return quiescence; }
    }
    class ThreadWorker {
      constructor() {
        const instance = this;
        const port = {
          postMessageWithSharedSendable(value) { queueMicrotask(() => instance.onmessage({ data: value })); },
          close() { queueMicrotask(() => instance.onexit(0)); }
        };
        load(workerSource, {
          '@kit.ArkTS': { worker: { workerPort: port } },
          '../sample/Messages': messages,
          '../sample/DeviceAcceptanceRunner': { DeviceAcceptanceRunner }
        });
        this.port = port;
      }
      postMessageWithSharedSendable(value) { queueMicrotask(() => this.port.onmessage({ data: value })); }
      terminate() { queueMicrotask(() => this.onexit(1)); }
    }
    const { DeviceWorkerHost } = load(hostSource,
      { '@kit.ArkTS': { worker: { ThreadWorker } }, './Messages': messages },
      [['setTimeout', setTimeout], ['clearTimeout', clearTimeout]]);
    const host = new DeviceWorkerHost();
    const result = observe(host.run(new DeviceAcceptanceRequest()));
    const stopped = interrupted ? observe(host.stop()) : null;
    releaseRun(new DeviceAcceptanceResponse());
    await flush();
    assert.equal(stopCalls, 1);
    assert.equal(result.settled, false);
    if (stopped) assert.equal(stopped.settled, false);
    releaseQuiescence();
    const outcome = await result.promise;
    if (interrupted) assert.ok(outcome.error);
    else assert.equal(outcome.value.receiptJson, 'signed-receipt');
    if (stopped) assert.equal((await stopped.promise).error, undefined);
  }
});
