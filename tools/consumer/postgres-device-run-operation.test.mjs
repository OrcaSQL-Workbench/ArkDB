import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

const source = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/DeviceRunOperation.ets',
  import.meta.url);

function loadOperation() {
  const compiled = ts.transpileModule(readFileSync(source, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, Error, setTimeout, clearTimeout });
  return exports;
}

test('interruption returns promptly but preserves a reentrantly dispatched operation', async () => {
  const { DeviceRunOperation: Operation } = loadOperation();
  let interrupt;
  let rejectWork;
  let operation;
  const interrupted = new Promise((resolve) => { interrupt = resolve; });
  const failures = [];
  operation = new Operation(() => {
    assert.equal(typeof operation.settlement.then, 'function');
    interrupt();
    return new Promise((_, reject) => { rejectWork = reject; });
  }, interrupted, () => {}, (error) => failures.push(error));
  await assert.rejects(operation.result, /interrupted/);
  let settled = false;
  operation.settlement.then(() => { settled = true; });
  await new Promise(setImmediate);
  assert.equal(settled, false);
  const error = new Error('late operation failure');
  rejectWork(error);
  assert.equal(await operation.settlement, error);
  assert.deepEqual(failures, [error]);
});

test('guard blocks work after interruption and is rechecked after success', async () => {
  const { DeviceRunOperation: Operation } = loadOperation();
  let active = false;
  let calls = 0;
  const guard = () => { if (!active) throw new Error('inactive'); };
  const pending = new Promise(() => {});
  const rejected = new Operation(async () => { calls++; }, pending, guard, () => {});
  await assert.rejects(rejected.result, /inactive/);
  assert.match((await rejected.settlement).message, /inactive/);
  assert.equal(calls, 0);

  active = true;
  const expired = new Operation(async () => { active = false; return 42; }, pending, guard, () => {});
  await assert.rejects(expired.result, /inactive/);
  assert.equal(await expired.settlement, null);
});

test('non-error operation rejection is retained as an explicit error', async () => {
  const { DeviceRunOperation: Operation } = loadOperation();
  let observed;
  const operation = new Operation(async () => { throw 'unexpected'; }, new Promise(() => {}),
    () => {}, (error) => { observed = error; });
  await assert.rejects(operation.result, /non-error value/);
  assert.equal(observed, 'unexpected');
  assert.match((await operation.settlement).message, /non-error value/);
});

test('cleanup waits for settlement, preserves both failures and times out if either stalls', async () => {
  const { waitDeviceCleanup } = loadOperation();
  const closeError = new Error('close failed');
  const operationError = new Error('operation failed');
  const combined = await waitDeviceCleanup(Promise.resolve(closeError), Promise.resolve(operationError));
  assert.equal(combined.cleanupError, closeError);
  assert.equal(combined.operationError, operationError);
  assert.equal(await waitDeviceCleanup(Promise.resolve(null), Promise.resolve(operationError)), operationError);
  const timeout = await waitDeviceCleanup(Promise.resolve(null), new Promise(() => {}));
  assert.match(timeout.message, /timed out/);
  const pendingOperation = await waitDeviceCleanup(Promise.resolve(closeError), new Promise(() => {}));
  assert.match(pendingOperation.message, /timed out/);
  assert.equal(pendingOperation.cleanupError, closeError);
  assert.equal(pendingOperation.operationError, null);
  const pendingClose = await waitDeviceCleanup(new Promise(() => {}), Promise.resolve(operationError));
  assert.match(pendingClose.message, /timed out/);
  assert.equal(pendingClose.operationError, operationError);
  assert.equal(pendingClose.cleanupError, null);
});
