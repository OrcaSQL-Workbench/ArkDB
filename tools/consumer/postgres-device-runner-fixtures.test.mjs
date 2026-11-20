import assert from 'node:assert/strict';
import { createPrivateKey, sign, verify } from 'node:crypto';
import test from 'node:test';
import {
  ArkDbError, Kind, deviceRuntime, deviceSampleLoader, deviceRunnerFixture, signingKeys
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
