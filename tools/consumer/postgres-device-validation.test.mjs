import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

const samples = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/', import.meta.url);

function load(clock = Date) {
  const modules = new Map();
  function require(name) {
    if (!modules.has(name)) {
      const source = readFileSync(new URL(`${name}.ets`, samples), 'utf8');
      const compiled = ts.transpileModule(source, {
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
      }).outputText;
      const exports = {};
      vm.runInNewContext(compiled, { exports, require, Date: clock });
      modules.set(name, exports);
    }
    return modules.get(name);
  }
  return require('./DeviceAcceptanceValidation');
}

function binding() {
  const sha = 'a'.repeat(64);
  return {
    enabled: true, challengeId: 'b'.repeat(32), receiptNonce: sha, schemaChallenge: sha,
    createdAt: '2026-11-20T00:00:00.000Z', expiresAt: '2026-11-21T00:00:00.000Z',
    suiteId: 'arkdb.postgresql.device-acceptance', caseManifestSha256: sha, releaseSetSha256: sha,
    repository: 'OrcaSQL-Workbench/ArkDB', driver: 'pgsql', packageName: '@arkdb/postgres',
    version: '1.0.0', sourceCommit: 'c'.repeat(40), artifactSha256: sha, artifactByteLength: 1,
    consumerFingerprint: sha, acceptanceFingerprint: sha, publicKeySpkiBase64: 'YWJjZA==',
    publicKeySpkiSha256: sha, privateKeyPkcs8Base64: 'ZWZnaA==', format: 'bytecode-har',
    compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS', useNormalizedOHMUrl: true,
    buildMode: 'release'
  };
}

test('binding rejects missing or altered provenance and malformed challenge periods', () => {
  const { validBinding } = load();
  const good = binding();
  assert.equal(validBinding(good), true);
  for (const [field, value] of [
    ['enabled', false], ['schemaChallenge', 'short'], ['receiptNonce', ''], ['sourceCommit', 'x'],
    ['artifactByteLength', 0], ['packageName', '@arkdb/mysql'], ['repository', 'other/repository'],
    ['createdAt', 'invalid'], ['expiresAt', '2026-11-21T00:00:01.000Z'],
    ['caseManifestSha256', ''], ['releaseSetSha256', ''], ['privateKeyPkcs8Base64', ''],
    ['compatibleSdkVersion', 23], ['useNormalizedOHMUrl', false], ['buildMode', 'debug']
  ]) {
    assert.equal(validBinding({ ...good, [field]: value }), false, field);
  }
});

test('challenge active interval includes only issued, unexpired time', () => {
  let time = Date.parse(binding().createdAt);
  const clock = class extends Date { constructor(value = time) { super(value); } };
  const { challengeIsActive } = load(clock);
  assert.equal(challengeIsActive(binding()), true);
  time = Date.parse(binding().expiresAt);
  assert.equal(challengeIsActive(binding()), true);
  time++;
  assert.equal(challengeIsActive(binding()), false);
  time = Date.parse(binding().createdAt) - 1;
  assert.equal(challengeIsActive(binding()), false);
});

test('platform and server profile validation reject incompatible runtime metadata', () => {
  const { validPlatform, safePublicLabel, serverVersionMatchesProfile } = load();
  const platform = { deviceType: 'tablet', sdkApiVersion: 24, osFullName: 'HarmonyOS 6.1' };
  assert.equal(validPlatform(platform), true);
  assert.equal(validPlatform({ ...platform, sdkApiVersion: 23 }), false);
  assert.equal(validPlatform({ ...platform, sdkApiVersion: 24.5 }), false);
  assert.equal(validPlatform({ ...platform, deviceType: 'phone' }), false);
  assert.equal(validPlatform({ ...platform, osFullName: 'bad\nlabel' }), false);
  assert.equal(safePublicLabel('17.12 (Debian)'), true);
  assert.equal(safePublicLabel('17.12\nsecret'), false);
  assert.equal(serverVersionMatchesProfile('17.12', 'P17'), true);
  assert.equal(serverVersionMatchesProfile('17.12', 'P15'), false);
  assert.equal(serverVersionMatchesProfile('170.1', 'P17'), false);
  assert.equal(serverVersionMatchesProfile('17.12', 'X17'), false);
  assert.equal(serverVersionMatchesProfile('17.12', 'P.*'), false);
  assert.equal(serverVersionMatchesProfile('17.12', 'P('), false);
});
