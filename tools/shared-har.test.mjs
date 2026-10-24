import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { verifiedArtifactSet } from './package-har.mjs';
import { releaseAssetNames, releaseDependencyReferences, validateReleaseSet } from './har-release.mjs';
import { prepareHarRelease, readReleaseBundle, verifyLocally } from './prepare-har-release.mjs';
import { verifyHarConsumer } from './test-consumer.mjs';
import { publishHarRelease } from './publish-har.mjs';
import { verifyDownloadedHar } from './verify-download.mjs';
import { sharedReleaseFixture, LOCAL_STEM, TAG } from './test-fixtures/har-release.mjs';
import { fakeGitHub } from './test-fixtures/github-release.mjs';

test('the exact shared-plus-driver set verifies without embedding or treating core as a driver', async (t) => {
  const f = await sharedReleaseFixture(t);
  const sources = await verifiedArtifactSet(f.root);
  assert.deepEqual(sources.map((source) => [source.driver.id, source.driver.kind]),
    [['core', 'shared'], ['mysql', 'driver']]);
  assert.deepEqual(sources[1].identity.dependencyArtifacts, f.identity.dependencyArtifacts);
  await writeFile(f.archives[0].artifactPath, 'Changed synthetic core bytes.');
  await assert.rejects(verifiedArtifactSet(f.root), /identity|stale|inconsistent/);
});

test('consumer receives both exact archives and project-level transitive dependency overrides', async (t) => {
  const f = await sharedReleaseFixture(t);
  const record = await verifyHarConsumer(supplied(f), fakeCompiler(f));
  assert.deepEqual(record.dependencyArtifacts, f.identity.dependencyArtifacts);
  assert.equal(record.documentedExamples, 8);
  assert.equal(record.localSampleCases, 1);
  assert.equal(record.liveNetworkingVerified, false);
  assert.deepEqual(await readdir(join(f.root, 'build', 'mysql-v1.0.0', 'work')), []);
});

test('missing, changed or extra dependency archives fail before restore or any compiler seam', async (t) => {
  const f = await sharedReleaseFixture(t);
  const fail = { runOhpm() { assert.fail('No restore is allowed'); }, runHvigor() { assert.fail('No compiler is allowed'); } };
  await assert.rejects(verifyHarConsumer({ ...supplied(f), dependencyArtifacts: [] }, fail), /dependency HAR set/);
  await assert.rejects(verifyHarConsumer({ ...supplied(f),
    dependencyArtifacts: [{ ...f.archives[0], expectedSha256: '0'.repeat(64) }] }, fail), /digest|identity/);
  await assert.rejects(verifyHarConsumer({ ...supplied(f),
    dependencyArtifacts: [f.archives[0], f.archives[0]] }, fail), /identity/);
});

test('the sealed release includes one immutable core identity and both checksums', async (t) => {
  const f = await sharedReleaseFixture(t);
  const bundle = await prepareHarRelease(f.options, f.dependencies);
  const set = bundle.releaseSet;
  assert.equal(set.schemaVersion, 2);
  assert.deepEqual(set.dependencies.map((entry) => entry.packageName), ['@arkdb/core']);
  assert.deepEqual(releaseDependencyReferences(set),
    [{ ...f.identity.dependencyArtifacts[0], file: 'arkdb-core-1.0.0.har' }]);
  assert.equal(releaseAssetNames(set).length, 8);
  assert.equal((await readdir(bundle.bundleDirectory)).length, 9);
  assert.equal((await readReleaseBundle(bundle.bundleDirectory)).assets.size, 8);
  const bad = structuredClone(set);
  bad.dependencies[0].version = '2.0.0';
  assert.throws(() => validateReleaseSet(bad), /dependency|allowlist/);
  const sealed = await readReleaseBundle(bundle.bundleDirectory);
  for (const suffix of ['manifest.json', 'consumer.json', 'readiness.json']) {
    const record = JSON.parse(sealed.assets.get(`arkdb-mysql-1.0.0.${suffix}`).toString('utf8'));
    assert.equal(record.dependencyArtifacts[0].file, 'arkdb-core-1.0.0.har');
  }
  assert.equal(JSON.parse(await readFile(f.archives[1].manifestPath, 'utf8'))
    .dependencyArtifacts[0].file, 'arkdb-core-1.0.0-local.har');
  await writeFile(join(bundle.bundleDirectory, 'arkdb-core-1.0.0.har'), 'Changed after sealing.');
  await assert.rejects(readReleaseBundle(bundle.bundleDirectory), /digest|size/);
});

test('missing dependency consumer evidence cannot be sealed as a successful shared release', async (t) => {
  const f = await sharedReleaseFixture(t);
  await f.changeRecord('consumer', { dependencyArtifacts: [] });
  await assert.rejects(prepareHarRelease(f.options, f.dependencies), /evidence|verification/);
});

test('native verification dispatch requires checked verdicts for every declared dependency module', async (t) => {
  const f = await sharedReleaseFixture(t);
  const fake = (stdout) => ({
    npm: process.execPath,
    output: { write() {} },
    spawnSync: () => ({ status: 0, stdout, stderr: '' })
  });
  const record = await verifyLocally(f.root, 'mysql', fake('PASSED core (5 native cases)\nPASSED mysql (7 native cases)\n'));
  assert.equal(record.driverTestsPassed, 12);
  await assert.rejects(verifyLocally(f.root, 'mysql', fake('PASSED mysql (7 native cases)\n')), /core/);
});

test('mock publication and download preserve all core bytes without rebuilding or local fallback', async (t) => {
  const f = await sharedReleaseFixture(t);
  const bundle = await prepareHarRelease(f.options, f.dependencies);
  const github = fakeGitHub(bundle);
  const receipt = await publishHarRelease({
    root: f.root, bundleDirectory: bundle.bundleDirectory, confirmPublish: true
  }, { git: f.git, github });
  assert.equal(receipt.assets.length, 9);
  const bytes = new Map();
  for (const asset of receipt.assets) bytes.set(asset.name, await readFile(join(bundle.bundleDirectory, asset.name)));
  github.state.writes.length = 0;
  const download = await verifyDownloadedHar({ root: f.root, driver: 'mysql', tag: TAG }, {
    github,
    fetch: async (url, options) => {
      assert.equal(options.headers.Authorization, undefined);
      const data = bytes.get(new URL(url).pathname.split('/').at(-1));
      return new Response(data, { status: 200, headers: { 'Content-Length': String(data.length) } });
    },
    consumer: async (options) => {
      assert.notEqual(options.artifactPath, join(f.dist, `${LOCAL_STEM}.har`));
      assert.equal(options.dependencyArtifacts.length, 1);
      const core = options.dependencyArtifacts[0];
      assert.notEqual(core.artifactPath, f.archives[0].artifactPath);
      assert.deepEqual(await readFile(core.artifactPath), bytes.get('arkdb-core-1.0.0.har'));
      return { ...f.consumer,
        dependencyArtifacts: [{ ...f.identity.dependencyArtifacts[0], file: 'arkdb-core-1.0.0.har' }] };
    }
  });
  assert.equal(download.downloadVerified, true);
  assert.deepEqual(download.consumer.dependencyArtifacts,
    [{ ...f.identity.dependencyArtifacts[0], file: 'arkdb-core-1.0.0.har' }]);
  assert.equal(github.state.writes.length, 0);
});

function supplied(fixture) {
  return {
    root: fixture.root, driver: 'mysql', ...fixture.archives[1],
    dependencyArtifacts: [fixture.archives[0]]
  };
}

function fakeCompiler(fixture) {
  return {
    runOhpm(args, { cwd }) {
      assert.deepEqual(args, ['install', '--all']);
      const manifest = JSON.parse(readFileSync(join(cwd, 'entry', 'oh-package.json5'), 'utf8'));
      const project = JSON.parse(readFileSync(join(cwd, 'oh-package.json5'), 'utf8'));
      for (const archive of fixture.archives) {
        assert.equal(manifest.dependencies[archive.identity.packageName], `file:../dependency/${archive.id}.har`);
        assert.equal(project.overrides[archive.identity.packageName], `file:./dependency/${archive.id}.har`);
        assert.deepEqual(readFileSync(join(cwd, 'dependency', `${archive.id}.har`)), readFileSync(archive.artifactPath));
      }
      return { status: 0, output: 'Synthetic restore only' };
    },
    runHvigor(args, { cwd }) {
      const path = args.includes('assembleHap')
        ? join(cwd, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap')
        : join(cwd, 'entry', '.test', 'default', 'intermediates', 'test', 'coverage_data', 'test_result.txt');
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, args.includes('assembleHap') ? 'Synthetic output, never executable.' :
        'result=Success\nTests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0\n');
      if (args.includes('assembleHap')) {
        const definition = join(cwd, 'entry', 'build', 'default', 'intermediates', 'merge_profile', 'default', 'module.json');
        mkdirSync(dirname(definition), { recursive: true });
        writeFileSync(definition, '{"module":{"requestPermissions":[{"name":"ohos.permission.INTERNET"}]}}');
      }
      return { status: 0, output: 'BUILD SUCCESSFUL' };
    }
  };
}
