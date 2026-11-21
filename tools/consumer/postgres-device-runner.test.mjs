import assert from 'node:assert/strict';
import test from 'node:test';
import { observeSettlement } from './postgres-device-test-loader.mjs';
import { ArkDbError, Kind, State, deviceRunnerFixture, deviceRunnerRuntime,
  deviceRunnerPreparedFeatures, validDeviceRunnerRequest, stallRunnerClose,
  assertDeviceRunnerReceipt } from './postgres-device-runner-fixtures.mjs';

test('unbound source refuses a connection and erases the supplied password', async () => {
  const { DeviceAcceptanceRunner, DeviceAcceptanceRequest, DeviceEvidenceIdentity } = deviceRunnerRuntime();
  const runner = new DeviceAcceptanceRunner({
    createConnection() { assert.fail('unbound runner must not create a connection'); }
  }, new DeviceEvidenceIdentity());
  const request = Object.assign(new DeviceAcceptanceRequest(), { password: 'not-for-a-receipt' });
  const result = await runner.run(request);
  assert.equal(result.errorKind, 'validation');
  assert.equal(result.receiptJson, '');
  assert.equal(request.password, '');
});

test('signs fixed acceptance results only within the active run', async (t) => {
  const now = Date.UTC(2026, 10, 20);
  let time = now;
  let uptime = 0;
  const { DeviceAcceptanceRunner, DeviceAcceptanceRequest, Ed25519DeviceReceiptSigner,
    publicKey, spki, pkcs8, sha, manifest, binding } = deviceRunnerFixture(now,
    class extends Date { constructor(value = time) { super(value); } }, () => uptime
  );
  for (const scenario of [
    'success', 'normalized probe password', 'cleanup failure', 'expired', 'not issued', 'expires during run',
    'expires during platform read', 'expires between connections', 'request changes during run',
    'schema changes before use', 'expires during signing', 'clock reverses during signing',
    'expires during mismatch', 'valid mismatch host', 'mismatch authentication failure',
    'signing overlap and stop', 'late signing failure after stop',
    'stop after signer settlement before receipt publication',
    'signing expires while pending',
    'stalled context at expiry',
    'stalled context after clock jump', 'late query cleanup failure after stop', 'stalled cleanup',
    'second factory fails', 'stalled context after rollback', 'stalled cancellation cleanup',
    'late settlement failure after stop', 'unsettled cancellation after stop', 'reentrant stop during dispatch',
    'failed cancellation close with pending query', 'reentrant stop during first factory',
    'reentrant stop during second factory', 'reentrant run during platform read',
    'reentrant same request during platform read',
    'platform read failure', 'invalid platform'
  ]) {
    await t.test(scenario, async () => {
    const failCleanup = scenario === 'cleanup failure';
    const expiry = Date.parse(binding.expiresAt);
    uptime = 0;
    time = scenario === 'stalled context at expiry' || scenario === 'stalled context after rollback' ? expiry - 100 :
      scenario === 'expired' ? expiry + 1 : scenario === 'not issued' ? now - 1 :
      scenario === 'clock reverses during signing' ? now + 1_000 : now;
    const closed = [];
    const created = [];
    const passwords = [];
    const connected = [];
    let contextChanges = 0;
    const signingWaiters = [];
    let notifySigning;
    const signingStarted = new Promise((resolve) => { notifySigning = resolve; });
    const request = validDeviceRunnerRequest(DeviceAcceptanceRequest, sha,
      scenario === 'normalized probe password' ? 'arkdb\u00ad-tls-probe' : 'not-for-a-receipt');
    let rejectQuery;
    let rejectContext;
    let resolveClose;
    let rejectCancellation;
    let notifyCancellation;
    let resolveConnect;
    let stoppingDuringConnect;
    let stopAfterSigning;
    let stoppedDuringConnect = false;
    let reentered = false;
    let reentrantRun;
    let reentrantRequest;
    let platformReads = 0;
    const cancellationStarted = new Promise((resolve) => { notifyCancellation = resolve; });
    const signer = new Ed25519DeviceReceiptSigner(spki, pkcs8);
    const runner = new DeviceAcceptanceRunner({ createConnection(config, password) {
      created.push(config.host);
      passwords.push(password);
      assert.equal(config.ssl.mode, 'verify_full');
      if (scenario === 'reentrant run during platform read' ||
        scenario === 'reentrant same request during platform read') {
        return { state: State.Closed, async connect() { throw new Error('injected failure'); }, async close() {} };
      }
      if ((scenario === 'reentrant stop during first factory' && config.host === 'db.test') ||
        (scenario === 'reentrant stop during second factory' && config.host === 'wrong.test')) {
        stoppingDuringConnect = runner.stop();
      }
      if (scenario === 'second factory fails' && config.host === 'wrong.test') {
        throw new Error('Second connection creation failed');
      }
      return {
        state: State.Closed, serverInfo: { productName: 'PostgreSQL', version: '17.6',
          tlsActive: true, authPlugin: 'scram-sha-256' },
        postgresFeatures: deviceRunnerPreparedFeatures(sha),
        async connect() {
          connected.push(config.host);
          if (scenario === 'reentrant stop during dispatch' && config.host === 'db.test') {
            stoppingDuringConnect = runner.stop().then(() => { stoppedDuringConnect = true; });
            await new Promise((resolve) => { resolveConnect = resolve; });
            return;
          }
          if (config.host === 'wrong.test') {
            if (scenario === 'expires during mismatch') time = expiry + 1;
            if (scenario === 'valid mismatch host') { this.state = State.Ready; return; }
            if (scenario === 'mismatch authentication failure') throw new ArkDbError('auth', '28P01');
            throw new ArkDbError(Kind.Tls, 'TLS_HOSTNAME_MISMATCH');
          }
          this.state = State.Ready;
          if (scenario === 'expires between connections') time = expiry + 1;
          if (scenario === 'schema changes before use') request.schema = 'changed';
        },
        async close() {
          closed.push(config.host);
          if (rejectContext) { rejectContext(new Error('closed')); rejectContext = undefined; }
          if (scenario === 'expires during run') time = expiry + 1;
          if (config.host === 'db.test' && (scenario === 'stalled cleanup' ||
            (scenario === 'stalled cancellation cleanup' && !resolveClose))) {
            return stallRunnerClose(this, (resolve) => { resolveClose = resolve; });
          }
          if ((scenario === 'late query cleanup failure after stop' ||
            scenario === 'failed cancellation close with pending query') && config.host === 'db.test') {
            throw new Error('cleanup failed');
          }
          if (failCleanup && config.host === 'db.test') throw new Error('Sensitive cleanup detail');
          this.state = State.Closed;
        },
        async changeContext(context) {
          contextChanges++;
          assert.equal(context.schema, 'authorized');
          if (scenario === 'stalled context at expiry' || scenario === 'stalled context after clock jump' ||
            scenario === 'stalled context after rollback') {
            return new Promise((_, reject) => { rejectContext = reject; });
          }
          if (scenario === 'request changes during run') {
            request.profile = 'P15';
            request.signedHapSha256 = 'f'.repeat(64);
            request.operatorEvidenceId = 'changed';
          }
        },
        async query(sql) {
          if (sql.includes('pg_sleep')) return new Promise((_, reject) => { rejectQuery = reject; });
          if (sql === 'SET statement_timeout = 0') return { rows: [] };
          throw new ArkDbError(Kind.Server, '42P01');
        },
        async cancel() {
          if (scenario === 'stalled cancellation cleanup' || scenario === 'failed cancellation close with pending query') {
            notifyCancellation();
            throw new Error('cancel failed');
          }
          if (scenario === 'late query cleanup failure after stop' || scenario === 'late settlement failure after stop' ||
            scenario === 'unsettled cancellation after stop') {
            notifyCancellation();
            return new Promise((_, reject) => { rejectCancellation = reject; });
          }
          rejectQuery(new ArkDbError(Kind.Server, '57014'));
          return { outcome: 'requested' };
        },
        isInterruptionError: (error) => error.sqlState === '57014',
        async ping() {}
      };
    } }, binding, { read: () => {
      platformReads++;
      if (scenario === 'platform read failure' && platformReads === 1) throw new Error('injected');
      if (scenario === 'invalid platform' && platformReads === 1) {
        return { deviceType: 'invalid', sdkApiVersion: 24, osFullName: 'HarmonyOS' };
      }
      if (scenario === 'expires during platform read') time = expiry + 1;
      if ((scenario === 'reentrant run during platform read' ||
        scenario === 'reentrant same request during platform read') && !reentered) {
        reentered = true;
        reentrantRequest = scenario === 'reentrant same request during platform read' ?
          request : Object.assign(new DeviceAcceptanceRequest(), request);
        reentrantRun = runner.run(reentrantRequest);
      }
      return { deviceType: 'tablet', sdkApiVersion: 24, osFullName: 'HarmonyOS' };
    } },
    { wait: async () => {} }, {
      async sign(payload) {
        const envelope = await signer.sign(payload);
        if (scenario === 'stop after signer settlement before receipt publication') {
          runner.activeOperation.then(() => {
            queueMicrotask(() => queueMicrotask(() => { stopAfterSigning = runner.stop(); }));
          });
        }
        if (scenario === 'signing overlap and stop' || scenario === 'late signing failure after stop' ||
          scenario === 'signing expires while pending') {
          notifySigning();
          await new Promise((resolve, reject) => {
            signingWaiters.push(scenario === 'late signing failure after stop' ?
              () => reject(new Error('late signing failure')) : resolve);
          });
        }
        if (scenario === 'expires during signing') time = expiry + 1;
        if (scenario === 'clock reverses during signing') time = now + 999;
        return envelope;
      }
    });
    const running = runner.run(request);
    if (scenario === 'platform read failure' || scenario === 'invalid platform') {
      const first = await running;
      assert.equal(first.errorKind, 'validation');
      assert.equal(request.password, '');
      const retry = Object.assign(new DeviceAcceptanceRequest(), request, { password: 'retry-secret' });
      assert.equal((await runner.run(retry)).ok, true);
      assert.deepEqual(created, ['db.test', 'wrong.test']);
      return;
    }
    if (scenario === 'reentrant run during platform read' ||
      scenario === 'reentrant same request during platform read') {
      const [result, reentrant] = await Promise.all([running, reentrantRun]);
      assert.equal(result.ok, false);
      assert.equal(reentrant.errorKind, 'validation');
      assert.equal(reentrantRequest.password, '');
      assert.deepEqual(created, ['db.test', 'wrong.test']);
      assert.equal(passwords[0], 'not-for-a-receipt');
      assert.notEqual(passwords[1], passwords[0]);
      return;
    }
    if (scenario === 'reentrant stop during first factory' || scenario === 'reentrant stop during second factory') {
      const result = await running;
      await stoppingDuringConnect;
      assert.equal(result.receiptJson, '');
      assert.deepEqual(closed, created);
      return;
    }
    if (scenario === 'reentrant stop during dispatch') {
      await new Promise(setImmediate);
      const premature = stoppedDuringConnect;
      resolveConnect();
      const [result] = await Promise.all([running, stoppingDuringConnect]);
      assert.equal(premature, false, 'stop must observe an operation from its dispatch');
      assert.equal(result.receiptJson, '');
      return;
    }
    if (scenario === 'stalled cancellation cleanup') {
      let timeout;
      const result = await Promise.race([running,
        new Promise((resolve) => { timeout = setTimeout(() => resolve(null), 2300); })]);
      clearTimeout(timeout);
      if (result === null) {
        const stopping = runner.stop().catch((error) => error);
        resolveClose();
        rejectQuery(new Error('query failed'));
        await Promise.all([running, stopping]);
      } else {
        resolveClose();
        rejectQuery(new Error('query failed'));
        await new Promise(setImmediate);
      }
      assert.notEqual(result, null, 'cancellation cleanup must have a bounded deadline');
      assert.equal(result.receiptJson, '');
      return;
    }
    if (scenario === 'late settlement failure after stop') {
      await cancellationStarted;
      const stopping = observeSettlement(runner.stop());
      await new Promise(setImmediate);
      const premature = stopping.settled;
      rejectCancellation(new Error('cancel failed'));
      rejectQuery(new Error('query failed'));
      const [result, error] = await Promise.all([running, stopping.result]);
      assert.equal(result.receiptJson, '');
      assert.equal(premature, false, 'stop must not discard an unsettled cancellation');
      assert.equal(error?.operationError?.message, 'cancel failed');
      assert.equal(error?.queryError?.message, 'query failed');
      return;
    }
    if (scenario === 'failed cancellation close with pending query') {
      await cancellationStarted;
      const stopping = observeSettlement(runner.stop());
      await new Promise(setImmediate);
      const premature = stopping.settled;
      rejectQuery(new Error('late query failure'));
      const [result, error] = await Promise.all([running, stopping.result]);
      assert.equal(result.receiptJson, '');
      assert.equal(premature, false, 'stop must wait for the pending cancellation query');
      assert.equal(error?.operationError?.queryError?.message, 'late query failure');
      assert.equal(error?.operationError?.caseError?.cleanupError?.message, 'cleanup failed');
      return;
    }
    if (scenario === 'unsettled cancellation after stop') {
      await cancellationStarted;
      const stopping = runner.stop().catch((error) => error);
      const [result, error] = await Promise.all([running, stopping]);
      assert.equal(result.receiptJson, '');
      assert.match(error.message, /timed out/);
      rejectCancellation(new Error('late cancellation failure'));
      rejectQuery(new Error('late query failure'));
      const late = await runner.activeOperation;
      assert.equal(late.operationError.message, 'late cancellation failure');
      assert.equal(late.queryError.message, 'late query failure');
      return;
    }
    if (scenario === 'second factory fails') {
      const result = await running;
      assert.equal(result.ok, false);
      assert.equal(result.receiptJson, '');
      assert.deepEqual(created, ['db.test', 'wrong.test']);
      assert.deepEqual(closed, ['db.test'], 'the first connection must be closed');
      assert.deepEqual(connected, []);
      return;
    }
    if (scenario === 'stalled cleanup') {
      const result = await running;
      assert.equal(result.ok, false);
      assert.equal(result.receiptJson, '');
      assert.equal(result.errorKind, 'device-cleanup');
      const later = await runner.run(Object.assign(new DeviceAcceptanceRequest(), request));
      assert.equal(later.errorKind, 'validation');
      resolveClose();
      await assert.rejects(runner.stop(), /timed out/);
      await new Promise(setImmediate);
      await runner.stop();
      return;
    }
    if (scenario === 'late query cleanup failure after stop') {
      await cancellationStarted;
      const stopping = runner.stop().catch((error) => error);
      const result = await running;
      assert.equal(result.receiptJson, '');
      assert.ok(await stopping instanceof Error);
      rejectCancellation(new Error('cancel failed'));
      await new Promise(setImmediate);
      assert.equal(typeof runner.querySettlement?.then, 'function',
        'late cleanup failures must retain the outstanding query settlement');
      assert.equal(typeof runner.cleanupSettlement?.then, 'function',
        'late cleanup failures must retain the connection cleanup settlement');
      assert.equal((await runner.cleanupSettlement).message, 'cleanup failed');
      rejectQuery(new Error('query failed'));
      assert.equal((await runner.querySettlement).message, 'query failed');
      return;
    }
    if (scenario === 'stalled context at expiry' || scenario === 'stalled context after clock jump' ||
      scenario === 'stalled context after rollback') {
      const advance = setTimeout(() => {
        time = scenario === 'stalled context after rollback' ? expiry - 3_600_000 : expiry + 1;
        uptime = 200;
      }, 25);
      let timeout;
      const result = await Promise.race([
        running,
        new Promise((resolve) => { timeout = setTimeout(() => resolve(null), 1500); })
      ]);
      clearTimeout(advance);
      clearTimeout(timeout);
      if (result === null) {
        rejectContext(new Error('test released stalled operation'));
        await running;
      }
      assert.notEqual(result, null, 'expiry must interrupt stalled operations and clean up');
      assert.equal(result.receiptJson, '');
      assert.deepEqual(closed, ['db.test', 'wrong.test']);
      return;
    }
    if (scenario === 'signing overlap and stop') {
      await signingStarted;
      const another = Object.assign(new DeviceAcceptanceRequest(), request, { password: 'another-password' });
      const overlapping = runner.run(another);
      await new Promise(setImmediate);
      const stopping = observeSettlement(runner.stop());
      await new Promise(setImmediate);
      const prematurelyStopped = stopping.settled;
      for (const resolve of signingWaiters) resolve();
      await stopping.result;
      const [first, second] = await Promise.all([running, overlapping]);
      assert.equal(prematurelyStopped, false, 'stop must retain the pending signing operation');
      assert.equal(created.length, 2, 'a second run must not create connections during signing');
      assert.equal(second.errorKind, 'validation');
      assert.equal(another.password, '');
      assert.equal(first.receiptJson, '', 'stop must suppress a still-pending receipt');
      return;
    }
    if (scenario === 'stop after signer settlement before receipt publication') {
      const result = await running;
      await assert.doesNotReject(stopAfterSigning);
      assert.equal(result.receiptJson, '', 'stop must suppress a receipt not yet published');
      assert.equal(result.ok, false);
      return;
    }
    if (scenario === 'late signing failure after stop') {
      await signingStarted;
      const stopping = runner.stop().catch((error) => error);
      const result = await running;
      assert.equal(result.receiptJson, '');
      assert.match((await stopping).message, /timed out/);
      const cleanup = runner.closeTask;
      assert.ok(cleanup, 'the timed-out signing operation must retain its cleanup owner');
      cleanup.sealRegistration();
      const quiescence = observeSettlement(cleanup.quiescence);
      await new Promise(setImmediate);
      assert.equal(quiescence.settled, false);
      for (const resolve of signingWaiters) resolve();
      assert.equal((await quiescence.result).message, 'late signing failure');
      return;
    }
    if (scenario === 'signing expires while pending') {
      await signingStarted;
      time = expiry + 1;
      const result = await running;
      assert.equal(result.receiptJson, '');
      const cleanup = runner.closeTask;
      assert.ok(cleanup);
      cleanup.sealRegistration();
      const quiescence = observeSettlement(cleanup.quiescence);
      await new Promise(setImmediate);
      const premature = quiescence.settled;
      for (const resolve of signingWaiters) resolve();
      assert.equal(premature, false, 'expiry must track the pending signer');
      assert.equal(await quiescence.result, null);
      return;
    }
    const result = await running;
    if (scenario === 'success' || scenario === 'normalized probe password') {
      assert.equal(passwords[1], '', 'negative TLS probe must use the empty probe password');
    }
    if (scenario === 'expires during mismatch') {
      assert.equal(contextChanges, 0, 'expired challenge must not start more database operations');
    }
    const invalidAtStart = scenario === 'expired' || scenario === 'not issued';
    const invalidBeforeCreation = invalidAtStart || scenario === 'expires during platform read';
    assert.deepEqual(created, invalidBeforeCreation ? [] : ['db.test', 'wrong.test'], scenario);
    assert.deepEqual(closed, invalidBeforeCreation ? [] : ['db.test', 'wrong.test'], scenario);
    assert.deepEqual(connected, invalidBeforeCreation ? [] :
      scenario === 'expires between connections' ? ['db.test'] : ['db.test', 'wrong.test'], scenario);
    if (failCleanup || invalidBeforeCreation || scenario === 'expires during run' ||
      scenario === 'expires between connections' || scenario === 'expires during signing' ||
      scenario === 'clock reverses during signing' || scenario === 'expires during mismatch') {
      assert.equal(result.ok, false, scenario);
      assert.equal(result.receiptJson, '', scenario);
      return;
    }
    const mismatchFailed = scenario === 'valid mismatch host' || scenario === 'mismatch authentication failure';
    assertDeviceRunnerReceipt(result, { publicKey, spki, pkcs8, password: passwords[0], sha, manifest, mismatchFailed });
    });
  }
});
