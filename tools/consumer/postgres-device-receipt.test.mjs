import assert from 'node:assert/strict';
import { createPrivateKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';
import { renderDeviceEvidenceBinding } from '../device/harness.mjs';

const source = readFileSync(new URL(
  '../../examples/postgres-device-acceptance/entry/src/main/ets/sample/DeviceReceiptSigner.ets',
  import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
}).outputText;
const modules = new Map([
  ['@kit.ArkTS', { buffer: Buffer, util: {
    Base64Helper: class { decodeSync(value) { return Buffer.from(value, 'base64'); } }
  } }],
  ['@kit.CryptoArchitectureKit', { cryptoFramework: {
    createAsyKeyGenerator: () => ({
      convertKeySync: (_, key) => ({
        priKey: createPrivateKey({ key: key.data, type: 'pkcs8', format: 'der' })
      })
    }),
    createSign: () => ({
      initSync(key) { this.key = key; },
      signSync({ data }) { return { data: sign(null, data, this.key) }; }
    })
  } }]
]);
const exports = {};
vm.runInNewContext(compiled, { exports, require: (name) => {
  assert.ok(modules.has(name), `unexpected import: ${name}`);
  return modules.get(name);
}, Uint8Array });

test('signs the exact UTF-8 receipt payload with the bound Ed25519 key', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const spki = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');
  const signer = new exports.Ed25519DeviceReceiptSigner(spki, pkcs8);
  const payload = JSON.stringify({ message: 'PostgreSQL \u2713' });
  const envelope = JSON.parse(await signer.sign(payload));
  assert.equal(envelope.schemaVersion, 1);
  assert.equal(envelope.kind, 'arkdb-device-acceptance-envelope');
  assert.equal(envelope.payload, payload);
  assert.equal(envelope.signature.algorithm, 'Ed25519');
  assert.equal(envelope.signature.publicKeySpkiBase64, spki);
  const signature = Buffer.from(envelope.signature.valueBase64, 'base64');
  assert.equal(signature.length, 64);
  assert.ok(verify(null, Buffer.from(payload, 'utf8'), publicKey, signature));
  assert.equal(verify(null, Buffer.from(`${payload}!`, 'utf8'), publicKey, signature), false);
});

test('reports signing failure without including private key or runtime details', async () => {
  const signer = new exports.Ed25519DeviceReceiptSigner('cHVibGlj', 'cHJpdmF0ZQ==');
  await assert.rejects(signer.sign('{}'), (error) => {
    assert.equal(error.message, 'HarmonyOS Ed25519 signing is unavailable in this runtime.');
    assert.doesNotMatch(error.message, /cHJpdmF0ZQ|private/i);
    return true;
  });
});

test('source binding is disabled and the generated binding preserves challenge identity', () => {
  const samples = new URL(
    '../../examples/postgres-device-acceptance/entry/src/main/ets/sample/', import.meta.url);
  const identitySource = readFileSync(new URL('DeviceEvidenceIdentity.ets', samples), 'utf8');
  const bindingSource = readFileSync(new URL('DeviceEvidenceBinding.ets', samples), 'utf8');
  function load(source, require) {
    const result = {};
    const js = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
    }).outputText;
    vm.runInNewContext(js, { exports: result, require });
    return result;
  }
  const identity = load(identitySource, () => assert.fail('unexpected identity import'));
  const loadBinding = (source) => load(source, (name) => {
    assert.equal(name, './DeviceEvidenceIdentity');
    return identity;
  }).currentDeviceEvidenceBinding();
  const unbound = loadBinding(bindingSource);
  assert.equal(unbound.enabled, false);
  assert.equal(unbound.privateKeyPkcs8Base64, '');

  const fields = {
    challengeId: 'challenge', receiptNonce: 'nonce', schemaChallenge: 'schema',
    createdAt: 'issued', expiresAt: 'expires', suiteId: 'suite',
    caseManifestSha256: 'cases', releaseSetSha256: 'release', repository: 'repository',
    driver: 'pgsql', packageName: 'package', version: 'version', sourceCommit: 'commit',
    artifactSha256: 'artifact', artifactByteLength: 123, consumerFingerprint: 'consumer',
    acceptanceFingerprint: 'acceptance', publicKeySpkiBase64: 'public',
    publicKeySpkiSha256: 'public-hash', privateKeyPkcs8Base64: 'private'
  };
  const platform = {
    format: 'bytecode-har', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
    useNormalizedOHMUrl: true, buildMode: 'release'
  };
  const defaults = new identity.DeviceEvidenceIdentity();
  for (const [name, value] of Object.entries({ ...fields, ...platform })) {
    assert.ok(Object.hasOwn(defaults, name), `missing identity field: ${name}`);
    assert.equal(typeof defaults[name], typeof value, name);
  }
  const generated = loadBinding(renderDeviceEvidenceBinding({ ...fields, platform }));
  assert.equal(generated.enabled, true);
  for (const [name, value] of Object.entries({ ...fields, ...platform })) {
    assert.equal(generated[name], value, name);
  }
});
