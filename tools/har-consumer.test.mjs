import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { verifyHarConsumer } from './test-consumer.mjs';
import { releaseFixture, STEM } from './test-fixtures/har-release.mjs';

function fakeCompiler() {
  let copiedHar;
  return {
    get copiedHar() { return copiedHar; },
    runOhpm(args, { cwd }) {
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
    }
  };
}

test('consumer uses only the supplied archive and its packaged README, not current driver source/dist', async (t) => {
  const fixture = await releaseFixture(t);
  const manifest = join(fixture.dist, `${STEM}.manifest.json`);
  const artifact = join(fixture.dist, `${STEM}.har`);
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
  assert.equal(record.artifactSha256, fixture.identity.sha256);
  assert.equal(record.liveNetworkingVerified, false);
});

test('wrong archive identity fails before dependency restore or compiler execution', async (t) => {
  const fixture = await releaseFixture(t);
  await assert.rejects(verifyHarConsumer({
    root: fixture.root, driver: 'mysql', artifactPath: join(fixture.dist, `${STEM}.har`),
    manifestPath: join(fixture.dist, `${STEM}.manifest.json`), expectedSha256: '0'.repeat(64)
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
    root: fixture.root, driver: 'mysql', artifactPath: join(fixture.dist, `${STEM}.har`),
    manifestPath: join(fixture.dist, `${STEM}.manifest.json`), expectedSha256: fixture.identity.sha256,
    workspaceDirectory: workspace
  }, fakeCompiler()), /exists|occupied/i);
  assert.deepEqual(await readdir(workspace), ['owner.txt']);
});
