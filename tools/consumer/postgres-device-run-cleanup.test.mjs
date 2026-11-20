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
  cleanup.register({ state: 'closed', async close() { closed.push('second'); } });
  assert.equal(await cleanup.settlement, null);
  assert.deepEqual(closed, ['first', 'second']);
});

test('closes connections registered during and after a stalled operation timeout', async () => {
  let finishOperation;
  const operation = new Promise((resolve) => { finishOperation = resolve; });
  const close = closeDeviceConnections([]);
  const pending = cleanupDeviceRun(close, operation);
  await new Promise(setImmediate);
  const first = { state: 'ready', async close() { this.state = 'closed'; } };
  close.register(first);
  await close.settlements[0];
  assert.equal(first.state, 'closed');
  const timeout = await pending;
  assert.match(timeout.message, /timed out/);
  const second = { state: 'ready', async close() { this.state = 'closed'; } };
  close.register(second);
  await timeout.closeSettlements[1];
  assert.equal(second.state, 'closed');
  finishOperation(null);
  await timeout.operationSettlement;
});

test('waits for a registered close added while another close is pending', async () => {
  let releaseFirst;
  let releaseSecond;
  const first = { state: 'ready', close: () => new Promise((resolve) => {
    releaseFirst = () => { first.state = 'closed'; resolve(); };
  }) };
  const second = { state: 'ready', close: () => new Promise((resolve) => {
    releaseSecond = () => { second.state = 'closed'; resolve(); };
  }) };
  const close = closeDeviceConnections([first]);
  const pending = cleanupDeviceRun(close, Promise.resolve(null));
  const observed = observeSettlement(pending);
  await new Promise(setImmediate);
  close.register(second);
  releaseFirst();
  await new Promise(setImmediate);
  assert.equal(observed.settled, false);
  releaseSecond();
  assert.equal(await pending, null);
});

test('waits for a registered close added during case query settlement', async () => {
  let finishQuery;
  let finishClose;
  const query = new Promise((resolve) => { finishQuery = resolve; });
  const failure = new DeviceCaseCleanupError(new Error('cancel failed'), new Error('close failed'),
    query, Promise.resolve(null));
  const close = closeDeviceConnections([]);
  const pending = cleanupDeviceRun(close, Promise.resolve(failure));
  const observed = observeSettlement(pending);
  await new Promise(setImmediate);
  const connection = { state: 'ready', close: () => new Promise((resolve) => {
    finishClose = () => { connection.state = 'closed'; resolve(); };
  }) };
  close.register(connection);
  finishQuery(null);
  await new Promise(setImmediate);
  assert.equal(observed.settled, false);
  finishClose();
  assert.equal(await pending, failure);
});

test('waits for a close registered at the final drain boundary', async () => {
  let release;
  const close = closeDeviceConnections([]);
  const pending = cleanupDeviceRun(close, Promise.resolve(null));
  const observed = observeSettlement(pending);
  let chain = Promise.resolve();
  for (let i = 0; i < 4; i++) chain = chain.then(() => {});
  await chain.then(() => {
    const connection = { state: 'ready', close: () => new Promise((resolve) => {
      release = () => { connection.state = 'closed'; resolve(); };
    }) };
    close.register(connection);
  });
  await new Promise(setImmediate);
  assert.equal(observed.settled, false);
  release();
  assert.equal(await pending, null);
});

test('closes connections registered asynchronously by an in-flight operation', async () => {
  let release;
  const close = closeDeviceConnections([]);
  const connection = { state: 'ready', async close() { this.state = 'closed'; } };
  const operation = (async () => {
    await new Promise((resolve) => { release = resolve; });
    close.register(connection);
    return null;
  })();
  const cleanup = cleanupDeviceRun(close, operation);
  await new Promise(setImmediate);
  release();
  assert.equal(await cleanup, null);
  assert.equal(connection.state, 'closed');
});

test('retains a late connection close error after the initial scan', async () => {
  let release;
  const close = closeDeviceConnections([]);
  const closeError = new Error('late close failed');
  const operation = (async () => {
    await new Promise((resolve) => { release = resolve; });
    close.register({ state: 'ready', async close() { throw closeError; } });
    return null;
  })();
  const cleanup = cleanupDeviceRun(close, operation);
  await new Promise(setImmediate);
  release();
  assert.equal(await cleanup, closeError);
});

test('drains a connection registered after cleanup has timed out', async () => {
  let release;
  const close = closeDeviceConnections([]);
  const connection = { state: 'ready', async close() { this.state = 'closed'; } };
  const operation = (async () => {
    await new Promise((resolve) => { release = resolve; });
    close.register(connection);
    return null;
  })();
  const timeout = await cleanupDeviceRun(close, operation);
  assert.match(timeout.message, /timed out/);
  release();
  await timeout.operationSettlement;
  await new Promise(setImmediate);
  assert.equal(connection.state, 'closed');
  assert.equal(timeout.closeSettlements.length, 1);
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

test('concurrent cleanup calls share one deadline and can retry after settlement', async () => {
  let release;
  const connection = { state: 'ready', close: () => new Promise((resolve) => {
    release = () => { connection.state = 'closed'; resolve(); };
  }) };
  const close = closeDeviceConnections([connection]);
  const operation = Promise.resolve(null);
  const first = cleanupDeviceRun(close, operation);
  await new Promise(setImmediate);
  const second = cleanupDeviceRun(close, operation);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /cannot change the active operation/);
  release();
  assert.equal(first, second);
  assert.equal(await first, null);
  assert.notEqual(cleanupDeviceRun(close, operation), first);
});

test('a retry cannot replace an operation still pending after timeout', async () => {
  let finish;
  const close = closeDeviceConnections([]);
  const operation = new Promise((resolve) => { finish = resolve; });
  let subscriptions = 0;
  const then = operation.then;
  operation.then = function (...args) {
    subscriptions++;
    return then.apply(this, args);
  };
  const first = cleanupDeviceRun(close, operation);
  const timeout = await first;
  assert.match(timeout.message, /timed out/);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /cannot change the active operation/);
  const beforeRetries = subscriptions;
  for (let i = 0; i < 20; i++) assert.equal(cleanupDeviceRun(close, operation), first);
  assert.equal(subscriptions, beforeRetries);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /cannot change the active operation/);
  const failure = new Error('late operation failed');
  finish(failure);
  assert.equal(await timeout.operationSettlement, failure);
  await new Promise(setImmediate);
  assert.equal(await cleanupDeviceRun(close, operation), failure);
});

test('a case timeout keeps its operation until query and cleanup settle', async () => {
  let finishQuery;
  let finishCleanup;
  const query = new Promise((resolve) => { finishQuery = resolve; });
  const cleanup = new Promise((resolve) => { finishCleanup = resolve; });
  const failure = new DeviceCaseCleanupError(new Error('cancel failed'), new DeviceCaseCleanupTimeoutError(),
    query, cleanup);
  const close = closeDeviceConnections([]);
  const operation = Promise.resolve(failure);
  const result = await cleanupDeviceRun(close, operation);
  assert.match(result.message, /timed out/);
  await new Promise(setImmediate);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /cannot change the active operation/);
  finishQuery(null);
  await new Promise(setImmediate);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /cannot change the active operation/);
  finishCleanup(null);
  await new Promise(setImmediate);
  assert.equal(await cleanupDeviceRun(close, Promise.resolve(null)), null);
});

test('case timeout keeps its operation until a later registered close settles', async () => {
  let finishQuery;
  let finishClose;
  const query = new Promise((resolve) => { finishQuery = resolve; });
  const failure = new DeviceCaseCleanupError(new Error('cancel failed'), new DeviceCaseCleanupTimeoutError(),
    query, Promise.resolve(null));
  const close = closeDeviceConnections([]);
  await cleanupDeviceRun(close, Promise.resolve(failure));
  await new Promise(setImmediate);
  const connection = { state: 'ready', close: () => new Promise((resolve) => {
    finishClose = () => { connection.state = 'closed'; resolve(); };
  }) };
  close.register(connection);
  finishQuery(null);
  await new Promise(setImmediate);
  assert.throws(() => cleanupDeviceRun(close, Promise.resolve(null)), /cannot change the active operation/);
  finishClose();
  await new Promise(setImmediate);
  assert.equal(await cleanupDeviceRun(close, Promise.resolve(null)), null);
});

test('a late registration reestablishes ownership after a timeout settles', async () => {
  let finishOperation;
  let finishClose;
  const operation = new Promise((resolve) => { finishOperation = resolve; });
  const close = closeDeviceConnections([]);
  await cleanupDeviceRun(close, operation);
  finishOperation(null);
  await new Promise(setImmediate);
  const closeError = new Error('late close failed');
  close.register({ state: 'ready', close: () => new Promise((_, reject) => {
    finishClose = () => reject(closeError);
  }) });
  const different = Promise.resolve(null);
  assert.throws(() => cleanupDeviceRun(close, different), /cannot change the active operation/);
  finishClose();
  await new Promise(setImmediate);
  assert.equal(await cleanupDeviceRun(close, different), closeError);
});

test('retries share one retention of a timed-out case', async () => {
  let finishQuery;
  const query = new Promise((resolve) => { finishQuery = resolve; });
  let subscriptions = 0;
  const then = query.then;
  query.then = function (...args) {
    subscriptions++;
    return then.apply(this, args);
  };
  const failure = new DeviceCaseCleanupError(new Error('cancel failed'), new DeviceCaseCleanupTimeoutError(),
    query, Promise.resolve(null));
  const close = closeDeviceConnections([]);
  const operation = Promise.resolve(failure);
  for (let i = 0; i < 20; i++) {
    assert.match((await cleanupDeviceRun(close, operation)).message, /timed out/);
  }
  assert.equal(subscriptions, 1);
  finishQuery(null);
});
