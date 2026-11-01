import assert from 'node:assert/strict';
import test from 'node:test';
import { requireCleanSource, requireConsumerEvidence } from './check-release.mjs';

const identity = { sha256: 'artifact', sourceFingerprint: 'source' };
const consumer = {
  schemaVersion: 3, artifactSha256: 'artifact', sourceFingerprint: 'source', sampleFingerprint: 'example',
  consumerProfile: 'current',
  check: 'isolated-release-hap-and-local-tests', sampleHapCompiled: true, localTestsExecuted: true,
  documentedExamples: 8, localSampleCases: 6, sampleHapSha256: 'f'.repeat(64),
  sampleHapByteLength: 12345, sampleHapContentSha256: 'e'.repeat(64)
};

test('accepts a compiled sample and guide bound to the exact candidate', () => {
  assert.doesNotThrow(() => requireConsumerEvidence(identity, consumer, 'example', 8));
});

test('stale examples, changed archives, and compile-only records cannot pass release preparation', () => {
  for (const overrides of [
    { artifactSha256: 'other' }, { sourceFingerprint: 'other' }, { sampleFingerprint: 'other' },
    { schemaVersion: 1 }, { consumerProfile: 'legacy-schema-1' }, { consumerProfile: undefined },
    { check: 'isolated-release-har-compilation' }, { check: 'isolated-release-hap-compilation' }, { documentedExamples: 7 },
    { localSampleCases: 0 }, { sampleHapCompiled: false }, { localTestsExecuted: false },
    { sampleHapSha256: undefined }, { sampleHapSha256: '0'.repeat(63) },
    { sampleHapContentSha256: undefined }, { sampleHapContentSha256: '0'.repeat(63) },
    { sampleHapByteLength: 0 }, { sampleHapByteLength: undefined },
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
