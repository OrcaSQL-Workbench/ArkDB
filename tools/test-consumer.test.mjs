import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import { consumerMode, REGISTRY, registryIdentity } from './test-consumer.mjs';
import { releaseFixture } from './test-fixtures/har-release.mjs';

const integrity = `sha512-${Buffer.alloc(64, 1).toString('base64')}`;

function lock(overrides = {}) {
  return { packages: { '@arkdb/mysql@1.0.0': {
    name: '@arkdb/mysql', version: '1.0.0', registryType: 'ohpm',
    resolved: `${REGISTRY}@arkdb/mysql/-/mysql-1.0.0.har`, integrity, ...overrides
  } } };
}

test('records registry-resolved package integrity and exact version', () => {
  const identity = registryIdentity(lock(), '@arkdb/mysql', '1.0.0');
  assert.equal(identity.version, '1.0.0');
  assert.equal(identity.integrity, integrity);
});

test('local, unpinned, or different-registry dependencies cannot establish publication', () => {
  for (const overrides of [
    { version: '2.0.0' }, { registryType: 'local' }, { resolved: 'file:../mysql.har' },
    { resolved: 'https://other.invalid/mysql.har' }, { integrity: '' },
    { integrity: 'sha512-YWJj' }, { resolved: `${REGISTRY}@arkdb/mysql.har?token=not-allowed` },
    { resolved: `${REGISTRY}../../mysql.har` }
  ]) {
    assert.throws(() => registryIdentity(lock(overrides), '@arkdb/mysql', '1.0.0'), /Registry/);
  }
});

test('compile-only hosted checks are explicit and cannot be mixed with registry/runtime modes', () => {
  assert.equal(consumerMode([]), '--verify');
  assert.equal(consumerMode(['--compile-only']), '--compile-only');
  assert.throws(() => consumerMode(['--compile-only', '--registry']), /Usage/);
  assert.throws(() => consumerMode(['--no-tests']), /Usage/);
});

test('device acceptance UI changes do not change the ordinary consumer fingerprint', async (t) => {
  const consumerTools = await import('./test-consumer.mjs');
  assert.equal(typeof consumerTools.deviceSampleFingerprint, 'function');
  const fixture = await releaseFixture(t);
  const ordinaryBefore = consumerTools.sampleFingerprint(fixture.root, 'mysql');
  const acceptanceBefore = consumerTools.deviceSampleFingerprint(fixture.root, 'mysql');
  const page = join(fixture.root, 'examples', 'mysql-device-acceptance', 'entry', 'src',
    'main', 'ets', 'pages', 'Index.ets');
  await writeFile(page, `${await readFile(page, 'utf8')}\n// Synthetic acceptance-only UI change.\n`);
  assert.equal(consumerTools.sampleFingerprint(fixture.root, 'mysql'), ordinaryBefore);
  assert.notEqual(consumerTools.deviceSampleFingerprint(fixture.root, 'mysql'), acceptanceBefore);
});
