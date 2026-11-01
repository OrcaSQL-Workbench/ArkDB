import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { verifyHarConsumer } from './test-consumer.mjs';
import { verifiedArtifact } from './package-har.mjs';
import { releaseFixture, LOCAL_STEM, STEM } from './test-fixtures/har-release.mjs';

function fakeCompiler() {
  let copiedHar;
  let workspace;
  return {
    get copiedHar() { return copiedHar; },
    get workspace() { return workspace; },
    runOhpm(args, { cwd }) {
      workspace = cwd;
      assert.deepEqual(args, ['install', '--all']);
      const dependency = JSON.parse(readFileSync(join(cwd, 'entry', 'oh-package.json5'), 'utf8')).dependencies;
      assert.equal(dependency['@arkdb/mysql'], 'file:../dependency/mysql.har');
      copiedHar = readFileSync(join(cwd, 'dependency', 'mysql.har'));
      return { status: 0, output: 'install completed' };
    },
    runHvigor(args, { cwd }) {
      if (args.includes('assembleHap')) {
        const hap = join(cwd, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
        mkdirSync(dirname(hap), { recursive: true });
        writeFileSync(hap, 'Synthetic HAP output');
        const module = join(cwd, 'entry', 'build', 'default', 'intermediates', 'merge_profile', 'default', 'module.json');
        mkdirSync(dirname(module), { recursive: true });
        writeFileSync(module, '{"module":{"requestPermissions":[{"name":"ohos.permission.INTERNET"}]}}');
        const example = readFileSync(join(cwd, 'entry', 'src', 'main', 'ets', 'readme-check', 'quickstart.ets'), 'utf8');
        assert.match(example, /from '@arkdb\/mysql'/);
      } else if (args.includes('test')) {
        const report = join(cwd, 'entry', '.test', 'default', 'intermediates', 'test', 'coverage_data', 'test_result.txt');
        mkdirSync(dirname(report), { recursive: true });
        writeFileSync(report, 'class=Synthetic\ntest=cleanup\nresult=Success\n' +
          'Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0\n');
      } else assert.fail(`Unexpected compiler task: ${args.join(' ')}`);
      return { status: 0, output: 'BUILD SUCCESSFUL' };
    },
    hapContentFingerprint() { return 'a'.repeat(64); }
  };
}

test('local artifacts are versioned outside dist and never fall back to loose dist files', async (t) => {
  const fixture = await releaseFixture(t);
  const directory = join(fixture.root, 'build', 'mysql-v1.0.0');
  const legacy = join(fixture.root, 'dist');
  await mkdir(legacy, { recursive: true });
  await writeFile(join(legacy, `${STEM}.har`), 'Stale loose output must not be selected.');

  const source = await verifiedArtifact(fixture.root, 'mysql');

  assert.equal(source.artifact, join(directory, `${LOCAL_STEM}.har`));
  assert.equal(source.evidenceDirectory,
    join(directory, 'evidence'));
  await rm(source.artifact);
  await assert.rejects(verifiedArtifact(fixture.root, 'mysql'), { code: 'ENOENT' });
});

test('consumer workspaces are grouped by driver and version and cleaned after verification', async (t) => {
  const fixture = await releaseFixture(t);
  const compiler = fakeCompiler();
  await verifyHarConsumer({
    root: fixture.root, driver: 'mysql', artifactPath: join(fixture.dist, `${LOCAL_STEM}.har`),
    manifestPath: join(fixture.dist, `${LOCAL_STEM}.manifest.json`), expectedSha256: fixture.identity.sha256
  }, compiler);

  assert.equal(dirname(compiler.workspace),
    join(fixture.root, 'build', 'mysql-v1.0.0', 'work'));
  await assert.rejects(readdir(compiler.workspace), { code: 'ENOENT' });
});

test('consumer uses only the supplied archive and its packaged README, not current driver source/dist', async (t) => {
  const fixture = await releaseFixture(t);
  const manifest = join(fixture.dist, `${LOCAL_STEM}.manifest.json`);
  const artifact = join(fixture.dist, `${LOCAL_STEM}.har`);
  await writeFile(join(fixture.root, 'mysql', 'README.md'), 'Local guide deliberately differs from the downloaded version.');
  const compiler = fakeCompiler();
  const record = await verifyHarConsumer({
    root: fixture.root, driver: 'mysql', artifactPath: artifact,
    manifestPath: manifest, expectedSha256: fixture.identity.sha256
  }, compiler);
  assert.deepEqual(compiler.copiedHar, await readFile(artifact));
  assert.equal(record.documentedExamples, 8);
  assert.equal(record.localSampleCases, 1);
  assert.equal(record.localTestsExecuted, true);
  assert.equal(record.sampleHapSha256, '1db6978eba3c2118be09fa9ff32f4e14d4956b79b8014a8012b7fd65fc9b463f');
  assert.equal(record.sampleHapByteLength, 20);
  assert.equal(record.sampleHapContentSha256, 'a'.repeat(64));
  assert.equal(record.artifactSha256, fixture.identity.sha256);
  assert.equal(record.liveNetworkingVerified, false);
});

test('wrong archive identity fails before dependency restore or compiler execution', async (t) => {
  const fixture = await releaseFixture(t);
  await assert.rejects(verifyHarConsumer({
    root: fixture.root, driver: 'mysql', artifactPath: join(fixture.dist, `${LOCAL_STEM}.har`),
    manifestPath: join(fixture.dist, `${LOCAL_STEM}.manifest.json`), expectedSha256: '0'.repeat(64)
  }, {
    runOhpm() { assert.fail('No package restore is permitted'); },
    runHvigor() { assert.fail('No compiler invocation is permitted'); }
  }), /identity|digest/i);
});

test('caller-owned existing workspace is never overwritten or cleaned up', async (t) => {
  const fixture = await releaseFixture(t);
  const workspace = join(fixture.root, 'build', 'existing-consumer');
  await mkdir(workspace, { recursive: true });
  await writeFile(join(workspace, 'owner.txt'), 'keep');
  await assert.rejects(verifyHarConsumer({
    root: fixture.root, driver: 'mysql', artifactPath: join(fixture.dist, `${LOCAL_STEM}.har`),
    manifestPath: join(fixture.dist, `${LOCAL_STEM}.manifest.json`), expectedSha256: fixture.identity.sha256,
    workspaceDirectory: workspace
  }, fakeCompiler()), /exists|occupied/i);
  assert.deepEqual(await readdir(workspace), ['owner.txt']);
});
