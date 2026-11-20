import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

function createIsolationRuntime({
  selfExitAfter, noShutdownAck = false, shutdownReply = 'shutdown-complete',
  exitCode = 0, failPost = false, failTerminate = false, shutdownMessageError = false,
  shutdownReplies, failPostFor, failTerminateFor, noShutdownAckFor, lateProbeReplyAfterValid = false,
  terminateDelayMs = 0
} = {}) {
  const workers = [];
  let resolveTermination;
  const terminationRequested = new Promise((resolve) => { resolveTermination = resolve; });
  class ThreadWorker {
    constructor(path) {
      this.path = path;
      this.messages = [];
      this.probes = 0;
      this.terminationCalls = 0;
      this.exited = false;
      workers.push(this);
    }

    emitExit(code) {
      this.exited = true;
      this.onexit(code);
    }

    postMessage(message) {
      if (message === 'shutdown' &&
        (failPost || (failPostFor && this.path.includes(failPostFor)))) throw new Error('post failed');
      this.messages.push(message);
      if (message === 'shutdown') {
        if (noShutdownAck || (noShutdownAckFor && this.path.includes(noShutdownAckFor))) return;
        queueMicrotask(() => {
          if (shutdownMessageError) this.onmessageerror({});
          for (const reply of shutdownReplies ?? [shutdownReply]) this.onmessage({ data: reply });
          this.emitExit(exitCode);
        });
        return;
      }

      this.probes++;
      const driver = this.path.includes('mysql') ? 'mysql' : 'pgsql';
      queueMicrotask(() => {
        this.onmessage({ data: `${driver}:local-error:${this.probes}` });
        if (lateProbeReplyAfterValid) this.onmessage({ data: 'unexpected-late-reply' });
        if (selfExitAfter?.path === driver && selfExitAfter.probes === this.probes) {
          queueMicrotask(() => this.emitExit(0));
        }
      });
    }

    terminate() {
      this.terminationCalls++;
      resolveTermination();
      if (failTerminate || (failTerminateFor && this.path.includes(failTerminateFor))) {
        throw new Error('terminate failed');
      }
      if (terminateDelayMs > 0) setTimeout(() => this.emitExit(exitCode), terminateDelayMs);
      else queueMicrotask(() => this.emitExit(exitCode));
    }
  }
  class MySqlResult {}
  class PostgresResult {}
  class MySqlError { static server() { return new MySqlError(); } }
  class PostgresError { static server() { return new PostgresError(); } }

  const file = new URL('../../examples/dual-har-client/entry/src/main/ets/WorkerIsolation.ets', import.meta.url);
  const source = readFileSync(file, 'utf8')
    .replace(/import\s*\{[^}]*\}\s*from\s*['"][^'"]+['"];?/g, '') +
    '\nexport { isWorkerIsolationRetryBlocked, verifyWorkerIsolation };';
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS }
  }).outputText;
  const api = {};
  vm.runInNewContext(compiled, {
    exports: api,
    worker: { ThreadWorker },
    MySqlError,
    MySqlResult,
    PostgresError,
    PostgresResult,
    Error,
    Promise,
    setTimeout: (callback) => setTimeout(callback, 30),
    clearTimeout,
    queueMicrotask
  });
  return {
    workers,
    isWorkerIsolationRetryBlocked: api.isWorkerIsolationRetryBlocked,
    terminationRequested,
    verifyWorkerIsolation: api.verifyWorkerIsolation
  };
}

test('Workers keep package-local responses and state, and acknowledge host shutdown', async () => {
  const runtime = createIsolationRuntime();
  await runtime.verifyWorkerIsolation();

  assert.deepEqual(runtime.workers.map((worker) => worker.path), [
    'entry/ets/workers/mysql.worker.ets',
    'entry/ets/workers/postgres.worker.ets',
    'entry/ets/workers/mysql.worker.ets'
  ]);
  assert.deepEqual(runtime.workers.map((worker) => worker.messages), [
    ['offline-probe', 'offline-probe', 'shutdown'],
    ['offline-probe', 'offline-probe', 'shutdown'],
    ['offline-probe', 'shutdown']
  ]);
});

test('a queued zero exit after the final response cannot acknowledge shutdown', async () => {
  const runtime = createIsolationRuntime({
    selfExitAfter: { path: 'mysql', probes: 2 }
  });

  await assert.rejects(runtime.verifyWorkerIsolation(), /Unexpected Worker exit/);
});

test('shutdown accepts only its acknowledgement followed by a zero-code exit', async () => {
  const abnormal = createIsolationRuntime({ exitCode: 1 });
  await assert.rejects(abnormal.verifyWorkerIsolation(), /Unexpected Worker exit/);

  const wrongReply = createIsolationRuntime({ shutdownReply: 'incorrect' });
  await assert.rejects(wrongReply.verifyWorkerIsolation(), /Unexpected Worker shutdown response/);
});

test('shutdown decoding errors cannot be cleared by a later acknowledgement', async () => {
  const runtime = createIsolationRuntime({ shutdownMessageError: true });

  await assert.rejects(runtime.verifyWorkerIsolation(), /message decoding failed/i);
});

test('an unexpected shutdown reply cannot be cleared by a later acknowledgement', async () => {
  const runtime = createIsolationRuntime({
    shutdownReplies: ['incorrect', 'shutdown-complete']
  });

  await assert.rejects(runtime.verifyWorkerIsolation(), /Unexpected Worker shutdown response/i);
});

test('a late invalid probe reply after a valid response remains fatal', async () => {
  const runtime = createIsolationRuntime({ lateProbeReplyAfterValid: true });

  await assert.rejects(runtime.verifyWorkerIsolation(), /Unexpected Worker response/i);
});

test('a stalled shutdown terminates the Worker and reports failure', async () => {
  const runtime = createIsolationRuntime({ noShutdownAck: true, terminateDelayMs: 10 });

  await assert.rejects(runtime.verifyWorkerIsolation(), /exit/i);
  assert.equal(runtime.workers[0].terminationCalls, 1);
  assert.ok(runtime.workers.every((worker) => worker.exited));
});

test('an unconfirmed forced exit blocks another Worker verification', async () => {
  const runtime = createIsolationRuntime({ noShutdownAck: true, terminateDelayMs: 100 });
  const verification = runtime.verifyWorkerIsolation();
  let settled = false;
  verification.catch(() => { settled = true; });

  await runtime.terminationRequested;
  assert.equal(settled, false);
  await assert.rejects(verification, /exit was not confirmed after termination/i);
  assert.equal(runtime.isWorkerIsolationRetryBlocked(), true);

  const workerCount = runtime.workers.length;
  await assert.rejects(runtime.verifyWorkerIsolation(), /restart the app before retrying/i);
  assert.equal(runtime.workers.length, workerCount);
});

test('failed shutdown request reports request and termination failures', async () => {
  const runtime = createIsolationRuntime({ failPost: true, failTerminate: true });

  await assert.rejects(runtime.verifyWorkerIsolation(), /post failed.*termination failed.*terminate failed/i);
});

test('cleanup waits for every Worker stop attempt before reporting failures', async () => {
  const runtime = createIsolationRuntime({
    failPostFor: 'mysql',
    failTerminateFor: 'mysql',
    noShutdownAckFor: 'postgres'
  });
  const verification = runtime.verifyWorkerIsolation();
  let settled = false;
  verification.catch(() => { settled = true; });

  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(settled, false);
  await assert.rejects(verification, /post failed.*termination failed.*terminate failed/i);
  assert.equal(runtime.workers[1].terminationCalls, 1);
});
