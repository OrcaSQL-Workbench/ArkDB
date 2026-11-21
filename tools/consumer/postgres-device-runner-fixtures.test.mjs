import assert from 'node:assert/strict';
import { createPrivateKey, sign, verify } from 'node:crypto';
import test from 'node:test';
import { observeSettlement } from './postgres-device-test-loader.mjs';
import {
  ArkDbError, Kind, State, deviceRuntime, deviceSampleLoader, deviceRunnerFixture, signingKeys,
  deviceRunnerPreparedFeatures, validDeviceRunnerRequest, stallRunnerClose, assertDeviceRunnerReceipt
} from './postgres-device-runner-fixtures.mjs';

const samples = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/', import.meta.url);

test('fixture signs a real receipt payload verifiable with its generated public key', async () => {
  const { publicKey, spki, pkcs8 } = signingKeys();
  const { Ed25519DeviceReceiptSigner } = deviceSampleLoader(samples)('./DeviceReceiptSigner');
  const payload = '{"message":"fixture"}';
  const envelope = JSON.parse(await new Ed25519DeviceReceiptSigner(spki, pkcs8).sign(payload));
  assert.equal(envelope.payload, payload);
  assert.equal(envelope.signature.publicKeySpkiBase64, spki);
  assert.equal(verify(null, Buffer.from(payload), publicKey, Buffer.from(envelope.signature.valueBase64, 'base64')),
    true);
});

test('fixture rejects malformed and mismatched signing keys', async () => {
  const { spki, pkcs8 } = signingKeys();
  const other = signingKeys();
  const { Ed25519DeviceReceiptSigner } = deviceSampleLoader(samples)('./DeviceReceiptSigner');
  await assert.rejects(new Ed25519DeviceReceiptSigner('YWJjZA==', pkcs8).sign('{}'), /unavailable/);
  await assert.rejects(new Ed25519DeviceReceiptSigner(spki, other.pkcs8).sign('{}'), /unavailable/);
});

test('fixture native errors are recognized by acceptance cases', async () => {
  const { DeviceAcceptanceCases } = deviceSampleLoader(samples)('./DeviceAcceptanceCases');
  const cases = new DeviceAcceptanceCases('', '', { wait: async () => {} }, () => {});
  const connection = { async query() { throw new ArkDbError(Kind.Server, '42P01'); } };
  assert.equal(await cases.verifyServerError(connection), true);
});

test('fixture loads the requested sample modules', () => {
  const runtime = deviceRuntime(samples, ['./Messages', './DeviceReceiptSigner']);
  assert.equal(typeof runtime.DeviceAcceptanceRequest, 'function');
  assert.equal(typeof runtime.Ed25519DeviceReceiptSigner, 'function');
});

test('fixture uses real connection validation for invalid ports and users', () => {
  const { DeviceAcceptanceRequestSnapshot } = deviceSampleLoader(samples)('./DeviceAcceptanceRequestSnapshot');
  const request = {
    host: 'db.test', mismatchHost: 'wrong.test', port: 0, user: '',
    database: '', caCertPath: '', schema: 'authorized', profile: 'P17',
    signedHapSha256: 'a'.repeat(64), operatorEvidenceId: 'operator'
  };
  assert.equal(new DeviceAcceptanceRequestSnapshot(request).valid(), false);
  request.port = 5432;
  assert.equal(new DeviceAcceptanceRequestSnapshot(request).valid(), false);
  request.user = 'operator';
  assert.equal(new DeviceAcceptanceRequestSnapshot(request).valid(), true);
});

test('fixture preserves real prepared parameter types', async () => {
  const { DeviceAcceptanceCases } = deviceSampleLoader(samples)('./DeviceAcceptanceCases');
  const cases = new DeviceAcceptanceCases('', '', { wait: async () => {} }, () => {});
  const connection = { postgresFeatures: { prepared: { async execute(_sql, parameters) {
    assert.deepEqual(Array.from(parameters, (parameter) => parameter.type), ['int8', 'numeric', 'bytea']);
    return { rows: [[9007199254740993n, '12.34', new Uint8Array([0, 127, 255])]] };
  } } } };
  assert.equal(await cases.verifyPreparedValues(connection), true);
});

test('fixture preserves built-in errors across sample modules', async () => {
  const { DeviceAcceptanceRequestSnapshot, DeviceRunOperation } = deviceRuntime(samples,
    ['./DeviceAcceptanceRequestSnapshot', './DeviceRunOperation']);
  let observed;
  const operation = new DeviceRunOperation(
    async () => new DeviceAcceptanceRequestSnapshot({ host: null }),
    new Promise(() => {}), () => {}, (error) => { observed = error; }
  );
  await assert.rejects(operation.result, (error) => error === observed && error instanceof TypeError);
  assert.equal(await operation.settlement, observed);
});

test('runner fixture creates a valid bound identity and matching signing keys', () => {
  const now = Date.UTC(2026, 10, 20);
  const fixture = deviceRunnerFixture(now);
  assert.equal(fixture.validBinding(fixture.binding), true);
  assert.equal(fixture.binding.suiteId, fixture.manifest.suiteId);
  assert.equal(Date.parse(fixture.binding.expiresAt) - Date.parse(fixture.binding.createdAt), 86_400_000);
  const signature = sign(null, Buffer.from('receipt'), createPrivateKey({
    key: Buffer.from(fixture.pkcs8, 'base64'), type: 'pkcs8', format: 'der'
  }));
  assert.equal(verify(null, Buffer.from('receipt'), fixture.publicKey, signature), true);
});

test('runner fixture builds a valid request and prepared results', async () => {
  const { DeviceAcceptanceRequest, sha } = deviceRunnerFixture(Date.UTC(2026, 10, 20));
  const { DeviceAcceptanceRequestSnapshot } = deviceSampleLoader(samples)('./DeviceAcceptanceRequestSnapshot');
  const request = validDeviceRunnerRequest(DeviceAcceptanceRequest, sha, 'secret');
  assert.equal(new DeviceAcceptanceRequestSnapshot(request).valid(), true);
  assert.equal(request.password, 'secret');
  const prepared = deviceRunnerPreparedFeatures(sha).prepared;
  assert.deepEqual((await prepared.execute('', [{}])).rows, [[sha]]);
  assert.deepEqual((await prepared.execute('', [{}, {}, {}])).rows,
    [[9007199254740993n, '12.34', new Uint8Array([0, 127, 255])]]);
});

test('runner fixture lets a pending close settle explicitly', async () => {
  const connection = { state: State.Ready };
  let release;
  const close = stallRunnerClose(connection, (callback) => { release = callback; });
  const observation = observeSettlement(close);
  await new Promise(setImmediate);
  assert.equal(observation.settled, false);
  assert.equal(connection.state, State.Ready);
  release();
  await close;
  assert.equal(connection.state, State.Closed);
});

test('receipt assertion checks signature, case verdicts, metadata and secrecy', async () => {
  const { publicKey, spki, pkcs8, binding, manifest, sha, createDeviceReceipt, DeviceReceiptRun,
    Ed25519DeviceReceiptSigner } = deviceRunnerFixture(Date.UTC(2026, 10, 20), Date, () => 1,
    ['./DeviceAcceptanceReceipt', './DeviceReceiptSigner', './DeviceEvidenceIdentity']);
  const key = createPrivateKey({ key: Buffer.from(pkcs8, 'base64'), type: 'pkcs8', format: 'der' });
  const password = 'actual-"test-password';
  const expected = { publicKey, spki, pkcs8, password, sha, manifest, mismatchFailed: false };
  const run = Object.assign(new DeviceReceiptRun(), { authPlugin: 'scram-sha-256', profile: 'P17',
    signedHapSha256: sha, operatorEvidenceId: 'operator-1' });
  const payload = createDeviceReceipt(binding, { sdkApiVersion: 24, deviceType: 'tablet' }, run,
    manifest.caseIds.map((id) => ({ id, status: 'pass' })));
  const resultFor = (value) => {
    const text = JSON.stringify(value);
    return { ok: true, receiptJson: JSON.stringify({
      schemaVersion: 1, kind: 'arkdb-device-acceptance-envelope', payload: text,
      signature: { algorithm: 'Ed25519', publicKeySpkiBase64: spki,
        valueBase64: sign(null, Buffer.from(text), key).toString('base64') }
    }) };
  };
  const valid = { ok: true, receiptJson: await new Ed25519DeviceReceiptSigner(spki, pkcs8)
    .sign(JSON.stringify(payload)) };
  assert.doesNotThrow(() => assertDeviceRunnerReceipt(valid, expected));
  const failedMismatch = resultFor({ ...payload,
    cases: payload.cases.map((entry) => entry.id === 'tls_hostname_mismatch' ? { ...entry, status: 'fail' } : entry) });
  failedMismatch.ok = false;
  assert.doesNotThrow(() => assertDeviceRunnerReceipt(failedMismatch, { ...expected, mismatchFailed: true }));
  assert.throws(() => assertDeviceRunnerReceipt({ ...valid, ok: false }, expected));
  const badSignature = JSON.parse(valid.receiptJson);
  badSignature.payload += ' ';
  assert.throws(() => assertDeviceRunnerReceipt({ ...valid, receiptJson: JSON.stringify(badSignature) }, expected));
  const badKey = JSON.parse(valid.receiptJson);
  badKey.signature.publicKeySpkiBase64 = 'wrong-key';
  assert.throws(() => assertDeviceRunnerReceipt({ ...valid, receiptJson: JSON.stringify(badKey) }, expected));
  const badKind = JSON.parse(valid.receiptJson);
  badKind.kind = 'other-envelope';
  assert.throws(() => assertDeviceRunnerReceipt({ ...valid, receiptJson: JSON.stringify(badKind) }, expected));
  for (const change of [{ schemaVersion: 99 }, { signature: { ...badKind.signature, algorithm: 'RSA' } }]) {
    assert.throws(() => assertDeviceRunnerReceipt(
      { ...valid, receiptJson: JSON.stringify({ ...JSON.parse(valid.receiptJson), ...change }) }, expected));
  }
  for (const id of manifest.caseIds) {
    assert.throws(() => assertDeviceRunnerReceipt(resultFor({ ...payload,
      cases: payload.cases.map((entry) => entry.id === id ? { ...entry, status: 'fail' } : entry) }), expected));
  }
  const mismatchAndCleanupFailed = resultFor({ ...payload, cases: payload.cases.map((entry) =>
    ['tls_hostname_mismatch', 'cleanup'].includes(entry.id) ? { ...entry, status: 'fail' } : entry) });
  mismatchAndCleanupFailed.ok = false;
  assert.throws(() => assertDeviceRunnerReceipt(mismatchAndCleanupFailed, { ...expected, mismatchFailed: true }));
  for (const invalid of [
    { ...payload, profile: 'P18' },
    { ...payload, authPlugin: 'md5' },
    { ...payload, hapSha256: 'b'.repeat(64) },
    { ...payload, operatorEvidenceId: 'other' },
    { ...payload, cases: payload.cases.slice().reverse() },
    { ...payload, extra: password },
    { ...payload, extra: pkcs8 },
    { ...payload, extra: 'not-for-a-receipt' },
    { ...payload, extra: 'Sensitive' }
  ]) {
    assert.throws(() => assertDeviceRunnerReceipt(resultFor(invalid), expected));
  }
});
