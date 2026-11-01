import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { extract } from 'tar';
import { readReleaseBundle } from './prepare-har-release.mjs';
import { verifyHarConsumer } from './test-consumer.mjs';

test('reads the immutable mysql-v1.0.1 bundle without schema-3 HAP evidence', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'arkdb-legacy-release-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await extract({
    cwd: directory,
    file: join(import.meta.dirname, 'test-fixtures', 'mysql-v1.0.1-release.tar.gz'),
    strict: true
  });
  const bundle = await readReleaseBundle(directory);
  assert.equal(bundle.releaseSet.tag, 'mysql-v1.0.1');
  assert.equal(bundle.releaseSet.sourceCommit, '27d4095575ca56ff4f1b9d38221e610034f3a049');
  assert.equal(bundle.releaseSet.verification.schemaVersion, undefined);
  assert.equal(bundle.releaseSet.verification.sampleHapSha256, undefined);
  assert.equal(bundle.releaseSet.verification.sampleHapByteLength, undefined);
  assert.equal(bundle.releaseSet.verification.sampleHapContentSha256, undefined);
  assert.equal(bundle.assets.get('arkdb-mysql-1.0.1.har').length, 114127);
});

test('verifies the immutable schema-1 HAR with only its published API surface', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'arkdb-legacy-consumer-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await extract({
    cwd: directory,
    file: join(import.meta.dirname, 'test-fixtures', 'mysql-v1.0.1-release.tar.gz'),
    strict: true
  });
  const bundle = await readReleaseBundle(directory);
  const artifact = bundle.releaseSet.assets.find((entry) => entry.name === 'arkdb-mysql-1.0.1.har');
  const available = new Set(bundle.releaseSet.verification.publicExports);
  const workspace = join(process.cwd(), 'build', `legacy-schema-1-${randomUUID()}`);
  const record = await verifyHarConsumer({
    root: process.cwd(),
    driver: 'mysql',
    artifactPath: join(directory, artifact.name),
    manifestPath: join(directory, 'arkdb-mysql-1.0.1.manifest.json'),
    expectedSha256: artifact.sha256,
    workspaceDirectory: workspace,
    consumerProfile: 'legacy-schema-1'
  }, {
    runOhpm() {
      return { status: 0, output: 'install completed' };
    },
    runHvigor(args, { cwd }) {
      if (args.includes('assembleHap')) {
        const buildProfile = JSON.parse(readFileSync(
          join(cwd, 'entry', 'build-profile.json5'), 'utf8'));
        assert.deepEqual(buildProfile.buildOption?.sourceOption?.workers ?? [], []);
        assertOnlyPublishedImports(cwd, available);
        const hap = join(cwd, 'entry', 'build', 'default', 'outputs', 'default',
          'entry-default-unsigned.hap');
        mkdirSync(dirname(hap), { recursive: true });
        writeFileSync(hap, 'Legacy schema-1 synthetic HAP output');
        const module = join(cwd, 'entry', 'build', 'default', 'intermediates',
          'merge_profile', 'default', 'module.json');
        mkdirSync(dirname(module), { recursive: true });
        writeFileSync(module,
          '{"module":{"requestPermissions":[{"name":"ohos.permission.INTERNET"}]}}');
      } else if (args.includes('test')) {
        const report = join(cwd, 'entry', '.test', 'default', 'intermediates',
          'test', 'coverage_data', 'test_result.txt');
        mkdirSync(dirname(report), { recursive: true });
        writeFileSync(report, 'class=LegacyReleaseConsumer\n' +
          'test=legacyReleasePublicSurfaceCompiles\nresult=Success\n' +
          'Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0\n');
      } else {
        assert.fail(`Unexpected compiler task: ${args.join(' ')}`);
      }
      return { status: 0, output: 'BUILD SUCCESSFUL' };
    },
    hapContentFingerprint() {
      return 'a'.repeat(64);
    }
  });

  assert.equal(record.consumerProfile, 'legacy-schema-1');
  assert.equal(record.version, '1.0.1');
  assert.equal(record.localSampleCases, 1);
  assert.equal(record.localTestsExecuted, true);
});

function assertOnlyPublishedImports(workspace, available) {
  const source = join(workspace, 'entry', 'src');
  for (const entry of readdirSync(source, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.ets')) continue;
    const text = readFileSync(join(entry.parentPath, entry.name), 'utf8');
    for (const match of text.matchAll(
      /import\s*\{([^}]*)\}\s*from\s*['"]@arkdb\/mysql['"]/g
    )) {
      for (const imported of match[1].split(',')) {
        const name = imported.trim().replace(/^type\s+/, '').split(/\s+as\s+/)[0];
        if (name.length > 0) {
          assert.equal(available.has(name), true,
            `Legacy consumer imported unpublished @arkdb/mysql symbol: ${name}`);
        }
      }
    }
  }
}
