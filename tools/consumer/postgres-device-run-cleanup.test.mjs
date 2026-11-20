import assert from 'node:assert/strict';
import test from 'node:test';
import ts from 'typescript';
import { createSampleLoader, observeSettlement } from './postgres-device-test-loader.mjs';

const samples = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/', import.meta.url);
const modules = new Map([['@arkdb/postgres', { ConnectionState: { Closed: 'closed' } }]]);
const load = createSampleLoader(samples, modules, ts);
const { closeDeviceConnections, settleDeviceCase, cleanupDeviceRun } = load('./DeviceRunCleanup');
const { DeviceCaseCleanupError, DeviceCaseCleanupTimeoutError } = load('./DeviceAcceptanceCases');

test('closing multiple connections waits for all and reports a failure', async () => {
  let release;
  const closeError = new Error('close failed');
  const pending = closeDeviceConnections([
    { state: 'ready', async close() { throw closeError; } },
    { state: 'closed', close: () => new Promise((resolve) => { release = resolve; }) }
  ]);
  const observed = observeSettlement(pending.settlement);
  await new Promise(setImmediate);
  assert.equal(observed.settled, false);
  release();
  assert.equal(await pending.settlement, closeError);
  const notClosed = closeDeviceConnections([{ state: 'ready', async close() {} }]);
  assert.match((await notClosed.settlement).message, /did not close/);
});

test('includes connections registered synchronously after reentrant stop', async () => {
  const closed = [];
  const connections = [{ state: 'closed', async close() { closed.push('first'); } }];
  const cleanup = closeDeviceConnections(connections);
  connections.push({ state: 'closed', async close() { closed.push('second'); } });
  assert.equal(await cleanup.settlement, null);
  assert.deepEqual(closed, ['first', 'second']);
});

test('settling a failed case waits for the query and retains both errors', async () => {
  const operationError = new Error('cancel failed');
  const cleanupError = new Error('close failed');
  const queryError = new Error('query failed');
  let finishQuery;
  const query = new Promise((resolve) => { finishQuery = resolve; });
  const failure = new DeviceCaseCleanupError(operationError, cleanupError, query, Promise.resolve(cleanupError));
  const pending = settleDeviceCase(failure);
  let done = false;
  pending.then(() => { done = true; });
  await new Promise(setImmediate);
  assert.equal(done, false);
  finishQuery(queryError);
  const result = await pending;
  assert.equal(result.caseError, failure);
  assert.equal(result.queryError, queryError);
});

test('an already timed-out cleanup preserves its handles without waiting again', async () => {
  const failure = new DeviceCaseCleanupError(new Error('cancel failed'), new DeviceCaseCleanupTimeoutError(),
    new Promise(() => {}), new Promise(() => {}));
  assert.equal(await settleDeviceCase(failure), failure);
});

test('a later query timeout still exposes the case failure and its settlement handle', async () => {
  let finishQuery;
  const closeError = new Error('close failed');
  const queryError = new Error('late query failed');
  const query = new Promise((resolve) => { finishQuery = resolve; });
  const failure = new DeviceCaseCleanupError(new Error('cancel failed'), closeError,
    query, Promise.resolve(closeError));
  const timeout = await cleanupDeviceRun(closeDeviceConnections([
    { state: 'ready', async close() { throw closeError; } }
  ]), Promise.resolve(failure));
  assert.match(timeout.message, /timed out/);
  assert.equal(timeout.operationError, failure);
  assert.equal(timeout.cleanupError, closeError);
  finishQuery(queryError);
  assert.equal(await timeout.operationError.querySettlement, queryError);
});

test('preserves every connection failure and outstanding close settlement', async () => {
  let releaseClose;
  const first = new Error('first close failed');
  const second = new Error('second close failed');
  const closing = closeDeviceConnections([
    { state: 'ready', async close() { throw first; } },
    { state: 'ready', close: () => new Promise((_, reject) => { releaseClose = () => reject(second); }) }
  ]);
  const timeout = await cleanupDeviceRun(closing, Promise.resolve(null));
  assert.match(timeout.message, /timed out/);
  assert.deepEqual(Array.from(timeout.cleanupErrors), [first]);
  releaseClose();
  assert.equal(await timeout.closeSettlements[1], second);
  const aggregate = await closing.settlement;
  assert.deepEqual(Array.from(aggregate.errors), [first, second]);
});

test('exposes an operation that fails after the cleanup timeout', async () => {
  let finish;
  const operation = new Promise((resolve) => { finish = resolve; });
  const timeout = await cleanupDeviceRun(closeDeviceConnections([]), operation);
  assert.match(timeout.message, /timed out/);
  const late = new Error('late operation failed');
  finish(late);
  assert.equal(await timeout.operationSettlement, late);
});

test('case timeout does not wait a second time for a stalled connection', async () => {
  const close = closeDeviceConnections([{ state: 'ready', close: () => new Promise(() => {}) }]);
  const failure = new DeviceCaseCleanupError(new Error('cancel failed'), new DeviceCaseCleanupTimeoutError(),
    new Promise(() => {}), new Promise(() => {}));
  let timer;
  const result = await Promise.race([
    cleanupDeviceRun(close, Promise.resolve(failure)),
    new Promise((resolve) => { timer = setTimeout(() => resolve(null), 300); })
  ]);
  clearTimeout(timer);
  assert.notEqual(result, null);
  assert.equal(result.operationError, failure);
  assert.equal(typeof result.closeSettlements[0].then, 'function');
});
