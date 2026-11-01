import assert from 'node:assert/strict';
import { mkdir, readFile, readdir, rm, rmdir, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import { prepareHarRelease, readReleaseBundle, verifyLocally } from './prepare-har-release.mjs';
import { releaseFixture, LOCAL_STEM, STEM, TAG, COMMIT, TAG_OBJECT } from './test-fixtures/har-release.mjs';

test('prepares only exact verified assets and binds them to the clean annotated tag', async (t) => {
  const fixture = await releaseFixture(t);
  await writeFile(join(fixture.evidence, `${LOCAL_STEM}.compile.json`), '{"stale":true}');
  await writeFile(join(fixture.dist, 'private-signing.p12'), 'Must never be distributed');
  const prepared = await prepareHarRelease(fixture.options, fixture.dependencies);
  assert.equal(prepared.releaseSet.sourceCommit, COMMIT);
  assert.equal(prepared.releaseSet.tagObject, TAG_OBJECT);
  assert.equal(prepared.releaseSet.verification.driverTestsPassed, 183);
  assert.equal(prepared.releaseSet.verification.realDeviceVerified, false);
  assert.equal(prepared.releaseSet.verification.schemaVersion, 3);
  assert.equal(prepared.releaseSet.verification.consumerProfile, 'current');
  assert.equal(prepared.releaseSet.verification.sampleHapSha256, fixture.consumer.sampleHapSha256);
  assert.equal(prepared.releaseSet.verification.sampleHapByteLength, fixture.consumer.sampleHapByteLength);
  assert.equal(prepared.releaseSet.verification.sampleHapContentSha256,
    fixture.consumer.sampleHapContentSha256);
  assert.deepEqual((await readdir(prepared.bundleDirectory)).sort(), [
    `${STEM}.consumer.json`, `${STEM}.har`, `${STEM}.har.sha256`,
    `${STEM}.manifest.json`, `${STEM}.readiness.json`, 'release-set.json'
  ].sort());
  const loaded = await readReleaseBundle(prepared.bundleDirectory);
  assert.deepEqual(loaded.releaseSet, prepared.releaseSet);
  assert.equal(loaded.assets.get(`${STEM}.har`).length, fixture.identity.byteLength);
});

test('unimplemented drivers and tag/version mistakes fail before any build', async (t) => {
  const fixture = await releaseFixture(t);
  const dependencies = { ...fixture.dependencies, verify: () => assert.fail('No verification may run') };
  await assert.rejects(prepareHarRelease({ ...fixture.options, driver: 'pgsql' }, dependencies), /not implemented/);
  for (const tag of ['mysql-v2.0.0', 'v1.0.0', '../escape', 'mysql;echo injected']) {
    await assert.rejects(prepareHarRelease({ ...fixture.options, tag }, dependencies), /tag|match/i);
  }
});

test('dirty source, lightweight tags and tags pointing elsewhere cannot start a release build', async (t) => {
  for (const change of [{ dirty: true }, { tagType: 'commit' }, { tagCommit: 'c'.repeat(40) }]) {
    const fixture = await releaseFixture(t);
    Object.assign(fixture.state, change);
    await assert.rejects(prepareHarRelease(fixture.options, {
      ...fixture.dependencies, verify: () => assert.fail('No build is permitted')
    }), /clean|annotated|commit/i);
  }
});

test('rejects source or tag changes that happen while verification runs', async (t) => {
  const fixture = await releaseFixture(t);
  await assert.rejects(prepareHarRelease(fixture.options, {
    ...fixture.dependencies,
    verify: async () => {
      await writeFile(join(fixture.root, 'mysql', 'README.md'), 'Changed after the source pin.');
      return { driverTestsPassed: 183 };
    }
  }), /changed|stale/i);
  const second = await releaseFixture(t);
  await assert.rejects(prepareHarRelease(second.options, {
    ...second.dependencies,
    verify: async () => { second.state.tagObject = 'd'.repeat(40); return { driverTestsPassed: 183 }; }
  }), /changed/i);
});

test('requires successful current runtime evidence, not compile-only or stale reports', async (t) => {
  for (const [name, overrides] of [
    ['consumer', { artifactSha256: '0'.repeat(64) }],
    ['consumer', { consumerProfile: 'legacy-schema-1' }],
    ['consumer', { localTestsExecuted: false }],
    ['consumer', { sampleHapSha256: undefined }],
    ['consumer', { sampleHapContentSha256: undefined }],
    ['consumer', { sampleHapByteLength: 0 }],
    ['consumer', { check: 'isolated-release-hap-compilation' }],
    ['consumer', { packageName: '@arkdb/other' }],
    ['readiness', { sourceCommit: 'c'.repeat(40) }],
    ['readiness', { consumerProfile: 'legacy-schema-1' }],
    ['readiness', { sampleHapSha256: '0'.repeat(64) }],
    ['readiness', { sampleHapContentSha256: '0'.repeat(64) }],
    ['readiness', { sampleHapByteLength: 12346 }],
    ['readiness', { ohpmPrepublishPassed: false }],
    ['manifest', { sourceClean: false, sourceCommit: null }]
  ]) {
    const fixture = await releaseFixture(t);
    await fixture.changeRecord(name, overrides);
    await assert.rejects(prepareHarRelease(fixture.options, fixture.dependencies), /evidence|identity|source|verification/i);
  }
  const fixture = await releaseFixture(t);
  await assert.rejects(prepareHarRelease(fixture.options, {
    ...fixture.dependencies, verify: async () => ({ driverTestsPassed: 0 })
  }), /verification|tests/i);
});

test('refuses mismatched checksums, absent required assets and existing output without overwriting it', async (t) => {
  const fixture = await releaseFixture(t);
  await writeFile(join(fixture.dist, `${LOCAL_STEM}.har.sha256`), `${'0'.repeat(64)}  ${LOCAL_STEM}.har\n`);
  await assert.rejects(prepareHarRelease(fixture.options, fixture.dependencies), /checksum/i);
  const second = await releaseFixture(t);
  await rm(join(second.evidence, `${LOCAL_STEM}.readiness.json`));
  await assert.rejects(prepareHarRelease(second.options, second.dependencies), /ENOENT|missing/i);
  const third = await releaseFixture(t);
  const target = join(third.root, 'dist', TAG);
  await mkdir(target, { recursive: true });
  await writeFile(join(target, 'owner-file'), 'keep');
  await assert.rejects(prepareHarRelease(third.options, third.dependencies), /exists|occupied/i);
  assert.equal(await readFile(join(target, 'owner-file'), 'utf8'), 'keep');
});

test('does not write through linked output parents or arbitrary destinations', async (t) => {
  const fixture = await releaseFixture(t);
  const outside = join(fixture.root, 'outside');
  await mkdir(outside);
  await rmdir(join(fixture.root, 'dist'));
  await symlink(outside, join(fixture.root, 'dist'), process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(prepareHarRelease(fixture.options, fixture.dependencies), /link|directory/i);
  assert.deepEqual(await readdir(outside), []);
  const second = await releaseFixture(t);
  await assert.rejects(prepareHarRelease({ ...second.options, destination: join(second.root, '..', 'escape') },
    second.dependencies), /destination|release directory/i);
});

test('a modified bundle file or an extra secret invalidates the sealed release set', async (t) => {
  const fixture = await releaseFixture(t);
  const prepared = await prepareHarRelease(fixture.options, fixture.dependencies);
  await writeFile(join(prepared.bundleDirectory, `${STEM}.har`), 'modified');
  await assert.rejects(readReleaseBundle(prepared.bundleDirectory), /digest|size|identity/i);
  const second = await releaseFixture(t);
  const other = await prepareHarRelease(second.options, second.dependencies);
  await writeFile(join(other.bundleDirectory, 'secret.txt'), 'not allowed');
  await assert.rejects(readReleaseBundle(other.bundleDirectory), /unexpected|allowlist/i);
});

test('verification binds the declared driver to checked native verdicts without rereading cleaned reports', async (t) => {
  const f = await releaseFixture(t);
  const verdict = await verifyLocally(f.root, 'mysql', {
    npm: process.execPath,
    output: { write() {} },
    spawnSync(command, args, options) {
      assert.equal(command, process.execPath);
      assert.deepEqual(args.slice(1), ['run', 'verify', '--', '--driver', 'mysql']);
      assert.equal(options.cwd, f.root);
      return { status: 0, stdout: 'PASSED mysql (1 native cases)\n', stderr: '' };
    }
  });
  assert.equal(verdict.driverTestsPassed, 1);
  assert.deepEqual(verdict.nativeModules, [{ module: 'mysql', passed: 1 }]);
  await assert.rejects(readFile(join(f.root, 'mysql', '.test', 'default', 'intermediates',
    'test', 'coverage_data', 'test_result.txt')), /ENOENT/);
});

test('a zero-exit verifier without a unique checked module verdict is rejected', async (t) => {
  const f = await releaseFixture(t);
  for (const stdout of ['', 'PASSED mysql (1 native cases)\nPASSED mysql (1 native cases)\n']) {
    await assert.rejects(verifyLocally(f.root, 'mysql', {
      npm: process.execPath, output: { write() {} }, spawnSync: () => ({ status: 0, stdout, stderr: '' })
    }), /native.*verdict|driver.*verification/i);
  }
});
