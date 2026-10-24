import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { verifiedArtifactSet } from './package-har.mjs';
import { prepareHarRelease, readReleaseBundle } from './prepare-har-release.mjs';
import { requireConsumerEvidence } from './check-release.mjs';
import { sourceFingerprint } from './package-har.mjs';
import { sampleFingerprint } from './test-consumer.mjs';
import { verifyHarConsumer } from './test-consumer.mjs';
import { publishHarRelease } from './publish-har.mjs';
import { fakeGitHub } from './test-fixtures/github-release.mjs';
import { standaloneReleaseFixture, LOCAL_STEM, STEM } from './test-fixtures/har-release.mjs';

test('a self-contained driver uses one archive while source identity still includes the shared core', async (t) => {
  const fixture = await standaloneReleaseFixture(t);
  await writeFile(fixture.coreArtifact, 'A separate core HAR must not be used.');
  const sources = await verifiedArtifactSet(fixture.root, 'mysql');

  assert.deepEqual(sources.map((entry) => entry.driver.id), ['mysql']);
  assert.deepEqual(sources[0].identity.dependencies, {});
  assert.equal(sources[0].identity.embeddedPackages[0].packageName, '@arkdb/core');
});

test('changed embedded source identity or a fabricated external dependency invalidates a standalone artifact', async (t) => {
  const fixture = await standaloneReleaseFixture(t);
  const manifest = join(fixture.dist, `${LOCAL_STEM}.manifest.json`);
  await writeFile(manifest, JSON.stringify({
    ...fixture.identity, embeddedPackages: [{ ...fixture.identity.embeddedPackages[0], sourceFingerprint: '0'.repeat(64) }]
  }));
  await assert.rejects(verifiedArtifactSet(fixture.root), /embedded|source|identity|stale/i);
  await writeFile(manifest, JSON.stringify({ ...fixture.identity, dependencies: { '@arkdb/core': '1.0.0' } }));
  await assert.rejects(verifiedArtifactSet(fixture.root), /dependenc|identity|stale/i);
  await writeFile(manifest, JSON.stringify(fixture.identity));
  const file = join(fixture.root, 'core', 'src', 'main', 'ets', 'model', 'ArkDbError.ets');
  await writeFile(file, (await readFile(file, 'utf8')) + '\n// Changed embedded source.\n');
  assert.notEqual(sourceFingerprint(fixture.root), fixture.identity.sourceFingerprint);
  await assert.rejects(verifiedArtifactSet(fixture.root), /source|identity|stale/i);
});

test('standalone release preparation seals only one HAR and keeps source dependency provenance', async (t) => {
  const fixture = await standaloneReleaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);

  assert.deepEqual(bundle.releaseSet.assets.filter((entry) => entry.name.endsWith('.har'))
    .map((entry) => entry.name), [`${STEM}.har`]);
  assert.equal(bundle.releaseSet.dependencies?.length ?? 0, 0);
  const sealed = await readReleaseBundle(bundle.bundleDirectory);
  const identity = JSON.parse(sealed.assets.get(`${STEM}.manifest.json`).toString('utf8'));
  assert.equal(identity.embeddedPackages[0].packageName, '@arkdb/core');
  assert.deepEqual(identity.sourceDependencies, { '@arkdb/core': '1.0.0' });
});

test('publication validates the assembled standalone package and uploads its exact sealed bytes', async (t) => {
  const fixture = await standaloneReleaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const github = fakeGitHub(bundle);
  const receipt = await publishHarRelease({
    root: fixture.root, bundleDirectory: bundle.bundleDirectory, confirmPublish: true
  }, { git: fixture.git, github });

  assert.deepEqual(receipt.assets.filter((entry) => entry.name.endsWith('.har'))
    .map((entry) => entry.name), [`${STEM}.har`]);
  assert.equal(receipt.assets.length, 6);
  const upload = github.state.writes.find((entry) => entry.method === 'POST' &&
    new URL(entry.path, 'https://api.github.com').searchParams.get('name') === `${STEM}.har`);
  assert.deepEqual(upload.body, await readFile(join(bundle.bundleDirectory, `${STEM}.har`)));
  assert.equal(github.state.release.draft, false);
});

test('compile success without registry-independent standalone verification cannot establish readiness', async (t) => {
  const fixture = await standaloneReleaseFixture(t);
  assert.throws(() => requireConsumerEvidence(fixture.identity, {
    ...fixture.consumer, selfContainedRuntimeVerified: false
  }, sampleFingerprint(fixture.root), 8), /standalone|self-contained|isolat|evidence/i);
});

test('one-HAR consumption proves runtime isolation before restoring the test framework', async (t) => {
  const fixture = await standaloneReleaseFixture(t);
  const stages = [];
  const record = await verifyHarConsumer({
    root: fixture.root, driver: 'mysql', artifactPath: join(fixture.dist, `${LOCAL_STEM}.har`),
    manifestPath: join(fixture.dist, `${LOCAL_STEM}.manifest.json`), expectedSha256: fixture.identity.sha256
  }, {
    runOhpm(args, { cwd }) {
      const project = JSON.parse(readFileSync(join(cwd, 'oh-package.json5'), 'utf8'));
      const module = JSON.parse(readFileSync(join(cwd, 'entry', 'oh-package.json5'), 'utf8'));
      assert.deepEqual(module.dependencies, { '@arkdb/mysql': 'file:../dependency/mysql.har' });
      assert.equal(project.overrides, undefined);
      if (stages.length === 0) {
        assert.equal(project.devDependencies, undefined);
        assert.equal(module.devDependencies, undefined);
        assert.equal(args[args.indexOf('--registry') + 1], 'http://127.0.0.1:9');
        stages.push('runtime');
      } else {
        assert.deepEqual(stages, ['runtime', 'hap']);
        assert.ok(project.devDependencies['@ohos/hypium']);
        assert.equal(args[args.indexOf('--registry') + 1], 'https://ohpm.openharmony.cn/ohpm/');
        stages.push('framework');
      }
      return { status: 0, output: 'Synthetic dependency restore.' };
    },
    runHvigor(args, { cwd }) {
      if (args.includes('assembleHap')) {
        assert.deepEqual(stages, ['runtime']);
        const hap = join(cwd, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
        mkdirSync(dirname(hap), { recursive: true });
        writeFileSync(hap, 'Synthetic application.');
        const metadata = join(cwd, 'entry', 'build', 'default', 'intermediates', 'merge_profile', 'default', 'module.json');
        mkdirSync(dirname(metadata), { recursive: true });
        writeFileSync(metadata, '{"module":{"requestPermissions":[{"name":"ohos.permission.INTERNET"}]}}');
        stages.push('hap');
      } else {
        assert.ok(args.includes('test'));
        assert.deepEqual(stages, ['runtime', 'hap', 'framework']);
        const report = join(cwd, 'entry', '.test', 'default', 'intermediates', 'test', 'coverage_data', 'test_result.txt');
        mkdirSync(dirname(report), { recursive: true });
        writeFileSync(report, 'result=Success\nTests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0\n');
        stages.push('tests');
      }
      return { status: 0, output: 'BUILD SUCCESSFUL' };
    }
  });
  assert.deepEqual(stages, ['runtime', 'hap', 'framework', 'tests']);
  assert.equal(record.selfContainedRuntimeVerified, true);
  assert.deepEqual(record.dependencyArtifacts, []);
});

test('a failed isolated runtime restore cannot invoke a compiler or claim standalone readiness', async (t) => {
  const fixture = await standaloneReleaseFixture(t);
  await assert.rejects(verifyHarConsumer({
    root: fixture.root, driver: 'mysql', artifactPath: join(fixture.dist, `${LOCAL_STEM}.har`),
    manifestPath: join(fixture.dist, `${LOCAL_STEM}.manifest.json`), expectedSha256: fixture.identity.sha256
  }, {
    runOhpm() { return { status: 1, output: 'ohpm ERROR: external runtime dependency.' }; },
    runHvigor() { assert.fail('No compiler can run before isolated runtime restore succeeds.'); }
  }), /restore/i);
});
