import assert from 'node:assert/strict';
import test from 'node:test';
import { requireCleanSource, requireConsumerEvidence } from './check-release.mjs';

const identity = { sha256: 'artifact', sourceFingerprint: 'source' };
const consumer = {
  schemaVersion: 1, artifactSha256: 'artifact', sourceFingerprint: 'source', sampleFingerprint: 'example',
  check: 'isolated-release-hap-and-local-tests', sampleHapCompiled: true, localTestsExecuted: true,
  documentedExamples: 8, localSampleCases: 6
};

test('accepts a compiled sample and guide bound to the exact candidate', () => {
  assert.doesNotThrow(() => requireConsumerEvidence(identity, consumer, 'example', 8));
});

test('stale examples, changed archives, and compile-only records cannot pass release preparation', () => {
  for (const overrides of [
    { artifactSha256: 'other' }, { sourceFingerprint: 'other' }, { sampleFingerprint: 'other' },
    { check: 'isolated-release-har-compilation' }, { check: 'isolated-release-hap-compilation' }, { documentedExamples: 7 },
    { localSampleCases: 0 }, { sampleHapCompiled: false }, { localTestsExecuted: false },
    { dependencyArtifacts: [{ id: 'unexpected' }] }
  ]) {
    assert.throws(() => requireConsumerEvidence(identity, { ...consumer, ...overrides }, 'example', 8), /stale/);
  }
});

test('a clean checkout cannot retroactively bless an artifact built from uncommitted source', () => {
  assert.doesNotThrow(() => requireCleanSource({ sourceClean: true, sourceCommit: 'reviewed' }, true, 'reviewed'));
  assert.throws(() => requireCleanSource({ sourceClean: false, sourceCommit: null }, true, 'reviewed'), /Build the HAR/);
  assert.throws(() => requireCleanSource({ sourceClean: true, sourceCommit: 'older' }, true, 'reviewed'), /Build the HAR/);
  assert.throws(() => requireCleanSource({ sourceClean: true, sourceCommit: 'reviewed' }, false, 'reviewed'), /Build the HAR/);
});
