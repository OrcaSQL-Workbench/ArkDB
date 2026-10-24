import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import { inspectHar, verifiedArtifact } from './package-har.mjs';
import { prepareHarRelease, readReleaseBundle } from './prepare-har-release.mjs';
import { validateEvidence } from './har-release.mjs';
import { releaseFixture, sharedReleaseFixture, STEM } from './test-fixtures/har-release.mjs';

test('local build labels change filenames but not the numeric package version', async (t) => {
  const fixture = await releaseFixture(t);
  const source = await verifiedArtifact(fixture.root, 'mysql');
  const inspected = await inspectHar(source.artifact, {
    name: '@arkdb/mysql', version: '1.0.0', license: 'Apache-2.0', dependencies: {}
  });

  assert.equal(source.artifact, join(fixture.root, 'build', 'mysql-v1.0.0', `${STEM}-local.har`));
  assert.equal(source.evidenceDirectory, join(fixture.root, 'build', 'mysql-v1.0.0', 'evidence'));
  assert.equal(source.identity.file, `${STEM}-local.har`);
  assert.equal(inspected.manifest.version, '1.0.0');
});

test('release preparation removes only the local artifact label and preserves verified HAR bytes', async (t) => {
  const fixture = await releaseFixture(t);
  const bytes = await readFile(join(fixture.dist, `${fixture.localStem}.har`));
  const prepared = await prepareHarRelease(fixture.options, fixture.dependencies);
  const bundle = await readReleaseBundle(prepared.bundleDirectory);

  assert.equal(prepared.bundleDirectory, join(fixture.root, 'dist', 'mysql-v1.0.0'));
  assert.deepEqual(bundle.assets.get(`${STEM}.har`), bytes);
  const ready = JSON.parse(bundle.assets.get(`${STEM}.manifest.json`).toString('utf8'));
  assert.equal(ready.version, '1.0.0');
  assert.equal(ready.file, `${STEM}.har`);
  assert.equal(ready.artifactChannel, 'release');
  assert.equal(bundle.assets.get(`${STEM}.har.sha256`).toString('utf8'),
    `${fixture.identity.sha256}  ${STEM}.har\n`);
  assert.equal(JSON.parse(await readFile(join(fixture.dist, `${fixture.localStem}.manifest.json`),
    'utf8')).artifactChannel, 'local');
});

test('sealed evidence rejects a local-channel dependency but still reads historical unlabelled identities', async (t) => {
  const fixture = await sharedReleaseFixture(t);
  const prepared = await prepareHarRelease(fixture.options, fixture.dependencies);
  const bundle = await readReleaseBundle(prepared.bundleDirectory);
  const name = 'arkdb-core-1.0.0.manifest.json';
  const identity = JSON.parse(bundle.assets.get(name).toString('utf8'));
  const assets = new Map(bundle.assets);
  assets.set(name, Buffer.from(JSON.stringify({ ...identity, artifactChannel: 'local' })));
  assert.throws(() => validateEvidence(bundle.releaseSet, assets), /channel|dependency|evidence/i);

  delete identity.artifactChannel;
  assets.set(name, Buffer.from(JSON.stringify(identity)));
  assert.doesNotThrow(() => validateEvidence(bundle.releaseSet, assets));
});
