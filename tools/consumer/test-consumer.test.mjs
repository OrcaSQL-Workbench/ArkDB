import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { join } from 'node:path';
import test from 'node:test';
import { consumerArguments, consumerMode, REGISTRY, registryIdentity } from '../test-consumer.mjs';
import * as consumerTools from '../test-consumer.mjs';
import { sha256 } from '../lib/hash.mjs';
import { releaseFixture } from '../test-fixtures/har-release.mjs';

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

test('dual-HAR verification has a dedicated CLI mode that cannot be mixed with one-driver flags', () => {
  assert.deepEqual(consumerArguments(['--dual']), { driver: 'mysql', mode: '--dual' });
  assert.throws(() => consumerArguments(['--dual', '--registry']), /Usage/);
  assert.throws(() => consumerArguments(['--driver', 'pgsql', '--dual']), /Usage/);
});

test('dual-HAR candidate validation requires the exact self-contained driver pair', () => {
  const mysql = dualArtifact('mysql', '@arkdb/mysql', 'a');
  const postgres = dualArtifact('pgsql', '@arkdb/postgres', 'b');
  assert.equal(typeof consumerTools.assertDualHarArtifacts, 'function');
  assert.deepEqual(consumerTools.assertDualHarArtifacts([postgres, mysql]), [mysql, postgres]);
  assert.throws(() => consumerTools.assertDualHarArtifacts([mysql]), /exact MySQL and PostgreSQL HAR pair/);
  assert.throws(() => consumerTools.assertDualHarArtifacts([mysql, {
    ...postgres, identity: { ...postgres.identity, delivery: 'dependency-set' }
  }]), /self-contained/);
  assert.throws(() => consumerTools.assertDualHarArtifacts([mysql, {
    ...postgres, identity: { ...postgres.identity, dependencies: { '@arkdb/core': '1.0.0' } }
  }]), /external runtime dependencies/);
  assert.throws(() => consumerTools.assertDualHarArtifacts([mysql, {
    ...postgres, manifest: { ...postgres.manifest, name: '@arkdb/mysql' }
  }]), /package identity/);
});

test('dual-HAR verification stages both exact archives and removes its temporary project', async (t) => {
  const fixture = await releaseFixture(t);
  const artifacts = [];
  for (const [driver, packageName, content] of [
    ['mysql', '@arkdb/mysql', 'exact mysql bytes'],
    ['pgsql', '@arkdb/postgres', 'exact postgres bytes']
  ]) {
    const artifact = join(fixture.root, 'build', `${driver}.har`);
    const bytes = Buffer.from(content);
    await writeFile(artifact, bytes);
    artifacts.push({
      artifact, driver: { id: driver },
      manifest: { name: packageName, version: '1.0.0' },
      identity: {
        driver, packageName, version: '1.0.0', delivery: 'self-contained',
        dependencies: {}, dependencyArtifacts: [], sha256: sha256(bytes), byteLength: bytes.length
      }
    });
  }
  let workspace;
  const restored = [];
  const copiedArchives = new Map();
  let reportText = 'class=Dual standalone HAR identity boundaries\n' +
    'test=keepsFactoryResultAndErrorIdentityPackageLocal\nresult=Success\n' +
    'Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0\n';
  assert.equal(typeof consumerTools.verifyDualHarConsumer, 'function');
  const dependencies = {
    verifiedArtifact: async (_root, id) => artifacts.find((entry) => entry.driver.id === id),
    runOhpm(args, options) {
      restored.push(args);
      const dependencies = JSON.parse(readFileSync(join(options.cwd, 'entry', 'oh-package.json5'), 'utf8'))
        .dependencies;
      assert.equal(dependencies['@arkdb/mysql'], 'file:../dependency/mysql.har');
      assert.equal(dependencies['@arkdb/postgres'], 'file:../dependency/pgsql.har');
      for (const driver of ['mysql', 'pgsql']) {
        copiedArchives.set(driver, readFileSync(join(options.cwd, 'dependency', `${driver}.har`)));
      }
      if (workspace === undefined) workspace = options.cwd;
      return { status: 0, output: 'install completed' };
    },
    runHvigor(args, options) {
      workspace = options.cwd;
      if (args.includes('assembleHap')) {
        const hap = join(options.cwd, 'entry', 'build', 'default', 'outputs',
          'default', 'entry-default-unsigned.hap');
        mkdirSync(dirname(hap), { recursive: true });
        writeFileSync(hap, 'dual-HAR test HAP');
        const module = join(options.cwd, 'entry', 'build', 'default', 'intermediates',
          'merge_profile', 'default', 'module.json');
        mkdirSync(dirname(module), { recursive: true });
        writeFileSync(module, '{"module":{"requestPermissions":[{"name":"ohos.permission.INTERNET"}]}}');
        const profile = JSON.parse(readFileSync(join(options.cwd, 'entry', 'build-profile.json5'), 'utf8'));
        assert.deepEqual(profile.buildOption?.sourceOption?.workers, [
          './src/main/ets/workers/mysql.worker.ets',
          './src/main/ets/workers/postgres.worker.ets'
        ]);
      } else {
        const report = join(options.cwd, 'entry', '.test', 'default', 'intermediates',
          'test', 'coverage_data', 'test_result.txt');
        mkdirSync(dirname(report), { recursive: true });
        writeFileSync(report, reportText);
      }
      return { status: 0, output: 'BUILD SUCCESSFUL' };
    }
  };
  const record = await consumerTools.verifyDualHarConsumer({ root: fixture.root }, dependencies);
  assert.equal(record.localCases, 1);
  assert.equal(record.workerRuntimeVerified, false);
  assert.equal(await readFile(record.applicationHap, 'utf8'), 'dual-HAR test HAP');
  assert.deepEqual(restored[0].slice(0, 3), ['install', '--all', '--cache']);
  assert.equal(restored[0].at(-1), 'http://127.0.0.1:9');
  assert.equal(restored[1].at(-1), REGISTRY);
  for (const artifact of artifacts) {
    assert.deepEqual(copiedArchives.get(artifact.driver.id), await readFile(artifact.artifact));
  }
  await assert.rejects(readdir(workspace), { code: 'ENOENT' });
  await t.test('rejects unrelated passing cases in real Hypium report format', async () => {
    reportText = reportText.replace('keepsFactoryResultAndErrorIdentityPackageLocal', 'unrelatedSmokeTest');
    await assert.rejects(consumerTools.verifyDualHarConsumer({ root: fixture.root }, dependencies), /identity case/i);
  });
  await t.test('rejects extra passing cases alongside the required identity case', async () => {
    reportText = reportText.replace('unrelatedSmokeTest', 'keepsFactoryResultAndErrorIdentityPackageLocal');
    reportText = reportText.replace(
      'Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0',
      'test=unrelatedSmokeTest\nresult=Success\n' +
      'Tests run: 2, Failure: 0, Error: 0, Pass: 2, Ignore: 0'
    );
    await assert.rejects(consumerTools.verifyDualHarConsumer({ root: fixture.root }, dependencies), /identity case/i);
    reportText = reportText.replace(
      'test=unrelatedSmokeTest\nresult=Success\n' +
      'Tests run: 2, Failure: 0, Error: 0, Pass: 2, Ignore: 0',
      'Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0'
    );
  });
  await t.test('only successful runs return unique byte-bound HAPs', async () => {
    const second = await consumerTools.verifyDualHarConsumer({ root: fixture.root }, dependencies);
    assert.notEqual(record.applicationHap, second.applicationHap);
    assert.equal(second.applicationHapSha256, sha256(await readFile(second.applicationHap)));
    const before = await readdir(join(fixture.root, 'build'));
    reportText = reportText.replace('result=Success', 'result=Error');
    await assert.rejects(consumerTools.verifyDualHarConsumer({ root: fixture.root }, dependencies));
    assert.deepEqual(await readdir(join(fixture.root, 'build')), before);
  });
});

test('merged INTERNET permission must match the driver verification declaration', () => {
  assert.equal(typeof consumerTools.assertInternetPermission, 'function');
  const check = consumerTools.assertInternetPermission;
  assert.doesNotThrow(() => check({}, false));
  assert.doesNotThrow(() => check({
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }]
  }, true));
  assert.throws(() => check({}, true), /missing INTERNET/);
  assert.throws(() => check({
    requestPermissions: [{ name: 'ohos.permission.INTERNET' }]
  }, false), /unexpectedly includes INTERNET/);
});

function dualArtifact(driver, packageName, digest) {
  return {
    driver: { id: driver },
    manifest: { name: packageName, version: '1.0.0' },
    identity: {
      driver, packageName, version: '1.0.0', delivery: 'self-contained',
      dependencies: {}, dependencyArtifacts: [], sha256: digest.repeat(64), byteLength: 10
    }
  };
}

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
