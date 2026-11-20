import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';
const source = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/DeviceAcceptanceReceipt.ets',
  import.meta.url);

function loadReceipt() {
  const compiled = ts.transpileModule(readFileSync(source, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports });
  return exports;
}

test('receipt binds case outcomes and operator run data to challenge and platform identity', () => {
  const { DeviceCaseResult, DeviceReceiptRun, createDeviceReceipt } = loadReceipt();
  const binding = {
    challengeId: 'challenge', sourceCommit: 'commit', artifactSha256: 'har',
    consumerFingerprint: 'consumer', acceptanceFingerprint: 'acceptance',
    createdAt: 'issued', expiresAt: 'expires'
  };
  const platform = { sdkApiVersion: 24, deviceType: 'tablet' };
  const run = Object.assign(new DeviceReceiptRun(), {
    profile: 'P17', signedHapSha256: 'hap', operatorEvidenceId: 'operator',
    startedAt: 'started', completedAt: 'completed', serverVersion: '17.6',
    authPlugin: 'scram-sha-256'
  });
  const result = Object.assign(new DeviceCaseResult('cancellation'), {
    status: 'fail', durationMs: 42, errorKind: 'device-cleanup'
  });
  const passing = Object.assign(new DeviceCaseResult('tls_identity'), {
    status: 'pass', durationMs: 12
  });
  const payload = JSON.parse(JSON.stringify(createDeviceReceipt(binding, platform, run, [passing, result])));
  assert.deepEqual(payload, {
    schemaVersion: 2, profile: 'P17', features: [], runId: 'challenge',
    sourceCommit: 'commit', sourceClean: true, harSha256: 'har',
    consumerFingerprint: 'consumer', acceptanceFingerprint: 'acceptance',
    hapSha256: 'hap', apiVersion: 24, deviceClass: 'tablet',
    serverVersion: '17.6', tlsMode: 'verify_full', authPlugin: 'scram-sha-256',
    challengeIssuedAt: 'issued', challengeExpiresAt: 'expires',
    startedAt: 'started', completedAt: 'completed', operatorEvidenceId: 'operator',
    cases: [
      { id: 'tls_identity', status: 'pass', durationMs: 12 },
      { id: 'cancellation', status: 'fail', durationMs: 42, errorKind: 'device-cleanup' }
    ]
  });
});
