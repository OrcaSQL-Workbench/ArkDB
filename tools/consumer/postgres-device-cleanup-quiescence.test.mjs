import assert from 'node:assert/strict';
import test from 'node:test';
import ts from 'typescript';
import { createSampleLoader, observeSettlement } from './postgres-device-test-loader.mjs';

const samples = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/', import.meta.url);
const load = createSampleLoader(samples,
  new Map([['@arkdb/postgres', { ConnectionState: { Closed: 'closed' } }]]), ts);
const { closeDeviceConnections, cleanupDeviceRun } = load('./DeviceRunCleanup');
const { DeviceCaseCleanupError, DeviceCaseCleanupTimeoutError } = load('./DeviceAcceptanceCases');

test('quiescence remains pending after a bounded timeout until all owned work settles', async () => {
  let finishQuery, finishCaseClose, finishConnectionClose;
  const query = new Promise((resolve) => { finishQuery = resolve; });
  const caseClose = new Promise((resolve) => { finishCaseClose = resolve; });
  const caseFailure = new DeviceCaseCleanupError(new Error('cancel failed'),
    new DeviceCaseCleanupTimeoutError(), query, caseClose);
  const close = closeDeviceConnections([]);
  const timeout = await cleanupDeviceRun(close, Promise.resolve(caseFailure));
  assert.match(timeout.message, /timed out/);
  const quiescence = observeSettlement(close.quiescence);
  finishQuery(new Error('late query failed'));
  const caseCloseError = new Error('late case close failed');
  finishCaseClose(caseCloseError);
  await new Promise(setImmediate);
  assert.equal(quiescence.settled, false, 'registration remains open after producers settle');
  close.register({ state: 'ready', close: () => new Promise((_, reject) => {
    finishConnectionClose = () => reject(new Error('late connection close failed'));
  }) });
  close.sealRegistration();
  await new Promise(setImmediate);
  assert.equal(quiescence.settled, false);
  finishConnectionClose();
  const result = await quiescence.result;
  assert.equal(result.operationError.caseError, caseFailure);
  assert.equal(result.operationError.queryError.message, 'late query failed');
  assert.equal(await result.operationError.caseError.cleanupSettlement, caseCloseError);
  assert.equal(result.cleanupError.message, 'late connection close failed');
});

test('quiescence also reports ordinary completed cleanup failures', async () => {
  const failure = new Error('ordinary close failed');
  const close = closeDeviceConnections([{ state: 'ready', async close() { throw failure; } }]);
  assert.equal(await cleanupDeviceRun(close, Promise.resolve(null)), failure);
  close.sealRegistration();
  assert.equal(await close.quiescence, failure);
});

test('quiescence includes registration after a successful bounded cleanup but before the seal', async () => {
  const close = closeDeviceConnections([]);
  await cleanupDeviceRun(close, Promise.resolve(null));
  const quiescence = observeSettlement(close.quiescence);
  let release;
  const connection = { state: 'ready', close: () => new Promise((resolve) => {
    release = () => { connection.state = 'closed'; resolve(); };
  }) };
  close.register(connection);
  close.sealRegistration();
  await new Promise(setImmediate);
  assert.equal(quiescence.settled, false);
  release();
  assert.equal(await quiescence.result, null);
});

test('a late registration is rejected visibly and its connection is still closed', async () => {
  const close = closeDeviceConnections([]);
  await cleanupDeviceRun(close, Promise.resolve(null));
  close.sealRegistration();
  await close.quiescence;
  const connection = { state: 'ready', async close() { this.state = 'closed'; } };
  assert.throws(() => close.register(connection), /registration.*sealed/i);
  await close.settlements[0];
  assert.equal(connection.state, 'closed');
});

test('one quiescence handle covers each operation accepted before the seal', async () => {
  const close = closeDeviceConnections([]);
  await cleanupDeviceRun(close, Promise.resolve(null));
  const quiescence = observeSettlement(close.quiescence);
  let finish;
  const secondOperation = new Promise((resolve) => { finish = resolve; });
  const second = cleanupDeviceRun(close, secondOperation);
  close.sealRegistration();
  assert.equal(cleanupDeviceRun(close, secondOperation), second);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /sealed/i);
  await new Promise(setImmediate);
  assert.equal(quiescence.settled, false);
  const lateFailure = new Error('second operation failed');
  finish(lateFailure);
  assert.equal(await second, lateFailure);
  assert.equal(await quiescence.result, lateFailure);
  assert.equal(await cleanupDeviceRun(close, secondOperation), lateFailure);
  assert.equal(await close.quiescence, lateFailure);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /sealed/i);
});

test('quiescence preserves failures from multiple completed operations', async () => {
  const close = closeDeviceConnections([]);
  const first = new Error('first failed');
  const second = new Error('second failed');
  await cleanupDeviceRun(close, Promise.resolve(first));
  await cleanupDeviceRun(close, Promise.resolve(second));
  close.sealRegistration();
  const result = await close.quiescence;
  assert.equal(result.errors[0], first);
  assert.equal(result.errors[1], second);
});

test('sealing without an operation rejects later cleanup requests', async () => {
  const close = closeDeviceConnections([]);
  close.sealRegistration();
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /sealed/i);
  assert.equal(await close.quiescence, null);
});
