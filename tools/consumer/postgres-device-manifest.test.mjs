import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';
import { readCaseManifest } from '../device/contracts.mjs';

test('device runner manifest matches the verifier case contract', () => {
  const root = new URL('../../examples/postgres-device-acceptance/', import.meta.url);
  const bytes = readFileSync(new URL('device-acceptance-cases.json', root));
  const manifest = readCaseManifest(bytes, {
    suiteId: 'arkdb.postgresql.device-acceptance',
    serverFamilies: ['PostgreSQL']
  });
  assert.deepEqual(manifest.caseIds, [
    'tls_identity', 'tls_hostname_mismatch', 'server_error', 'prepared_values',
    'authorized_schema', 'cancellation', 'cleanup'
  ]);
  assert.equal(manifest.runtime.minimumSdkApiVersion, 24);
  const source = readFileSync(new URL('entry/src/main/ets/sample/DeviceAcceptanceManifest.ets', root), 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports });
  assert.equal(exports.DEVICE_ACCEPTANCE_SUITE_ID, manifest.suiteId);
  assert.deepEqual(Array.from(exports.DEVICE_ACCEPTANCE_CASE_IDS), manifest.caseIds);
  assert.deepEqual(Array.from(exports.DEVICE_ACCEPTANCE_DEVICE_TYPES), manifest.runtime.deviceTypes);
  assert.equal(exports.DEVICE_ACCEPTANCE_MINIMUM_SDK, manifest.runtime.minimumSdkApiVersion);
});
