import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { parseHypiumResults } from './run-ohos-tests.mjs';

const runnerPath = fileURLToPath(new URL('./run-ohos-tests.mjs', import.meta.url));
const successfulReport = 'class=Example\ntest=example\nresult=Success\n' +
  'Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0\n';

test('fails on hvigor ERROR output when Hvigor exits zero', async (t) => {
  const executable = await createHvigorFixture(t, 'hvigor ERROR: simulated assertion failure', 0);
  const result = runStrictRunner(executable);
  const output = `${result.stdout}${result.stderr}`;

  assert.equal(result.status, 1);
  assert.match(output, /FAILED mysql \(exit 0, 1 error lines\)/);
  assert.match(output, /hvigor ERROR: simulated assertion failure/);
  assert.match(output, /ArkTS unit tests failed/);
});

test('fails on a non-zero Hvigor exit without assertion output', async (t) => {
  const executable = await createHvigorFixture(t, 'simulated build failure', 9);
  const result = runStrictRunner(executable);
  const output = `${result.stdout}${result.stderr}`;

  assert.equal(result.status, 1);
  assert.match(output, /FAILED mysql \(exit 9, 0 error lines\)/);
  assert.match(output, /simulated build failure/);
});

test('reports Hvigor invocation errors without an uncaught stack', async (t) => {
  const fixture = await createHvigorFixture(t, '', 0);
  const executable = join(dirname(fixture), 'missing-hvigorw');
  const result = runStrictRunner(executable);
  const output = `${result.stdout}${result.stderr}`;

  assert.equal(result.status, 1);
  assert.match(output, /FAILED mysql \(Hvigor invocation failed\)/);
  assert.match(output, /hvigorw not found/);
  assert.match(output, /ArkTS unit tests failed/);
  assert.doesNotMatch(output, /\s+at runHvigor /);
});

test('requires a fresh native verdict rather than trusting BUILD SUCCESSFUL', async (t) => {
  const executable = await createHvigorFixture(t, 'BUILD SUCCESSFUL', 0);
  const report = join(dirname(executable), 'mysql', '.test', 'default', 'intermediates',
    'test', 'coverage_data', 'test_result.txt');
  await mkdir(dirname(report), { recursive: true });
  await writeFile(report, successfulReport);
  const result = runStrictRunner(executable);
  assert.equal(result.status, 1);
  assert.match(`${result.stdout}${result.stderr}`, /native verdict unavailable/);
});

test('accepts actual case results with a matching successful native summary', async (t) => {
  const executable = await createHvigorFixture(t, 'BUILD SUCCESSFUL', 0, successfulReport);
  const result = runStrictRunner(executable);
  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /PASSED mysql \(1 native cases\)/);
});

test('invalidates generated unit artifacts after a package identity change', async (t) => {
  const executable = await createHvigorFixture(t, 'BUILD SUCCESSFUL', 0, successfulReport);
  const stale = join(dirname(executable), 'mysql', '.test', 'default', 'cache', 'package-identity.json');
  await mkdir(dirname(stale), { recursive: true });
  await writeFile(stale, '{"packageVersion":"0.1.0"}');
  const result = runStrictRunner(executable);
  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /PASSED mysql \(1 native cases\)/);
});

test('uses the registered module source path for fresh native reports and cleanup', async (t) => {
  const sourcePath = join('drivers', 'mysql');
  const executable = await createHvigorFixture(t, 'BUILD SUCCESSFUL', 0, successfulReport, sourcePath);
  const root = dirname(executable);
  const stale = join(root, sourcePath, '.test', 'default', 'cache', 'package-identity.json');
  await mkdir(dirname(stale), { recursive: true });
  await writeFile(stale, '{"packageVersion":"0.1.0"}');
  const unrelated = join(root, 'mysql', '.test', 'keep.txt');
  await mkdir(dirname(unrelated), { recursive: true });
  await writeFile(unrelated, 'Not the registered module cache.');

  const result = runStrictRunner(executable);

  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /PASSED mysql \(1 native cases\)/);
  assert.equal(await readFile(unrelated, 'utf8'), 'Not the registered module cache.');
});

test('regenerates the HAR BuildProfile before native unit compilation', async (t) => {
  const executable = await createHvigorFixture(t, 'BUILD SUCCESSFUL', 0, successfulReport, 'mysql', true);
  await writeFile(join(dirname(executable), 'mysql', 'BuildProfile.ets'), 'Stale release profile.');

  const result = runStrictRunner(executable);

  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /PASSED mysql \(1 native cases\)/);
});

test('rejects skipped, failed, zero-case and inconsistent native verdicts', () => {
  assert.deepEqual(parseHypiumResults(successfulReport), { total: 1, passed: 1 });
  for (const report of [
    '', successfulReport.replace('result=Success', 'result=Failure'),
    successfulReport.replace('Pass: 1', 'Pass: 0'),
    successfulReport.replace('Ignore: 0', 'Ignore: 1'),
    successfulReport.replace('result=Success\n', ''),
    successfulReport.replace('result=Success\n', 'result=Success\nresult=Success\n'),
    'Tests run: 0, Failure: 0, Error: 0, Pass: 0, Ignore: 0\n'
  ]) {
    assert.throws(() => parseHypiumResults(report), /Native Hypium/);
  }
});

test('counts completed native verdicts rather than repeated SDK case-name markers', () => {
  const report = successfulReport.replace('test=example\n', 'test=example\ntest=example-\n');
  assert.deepEqual(parseHypiumResults(report), { total: 1, passed: 1 });
});

function runStrictRunner(executable) {
  return spawnSync(process.execPath, [runnerPath, 'mysql'], {
    cwd: dirname(executable),
    encoding: 'utf8',
    env: {
      ...process.env,
      HARMONYOS_HVIGORW: executable,
      DEVECO_HOME: ''
    }
  });
}

async function createHvigorFixture(t, output, status, report, sourcePath = 'mysql', requireProfile = false) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-hvigor-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const moduleRoot = join(root, sourcePath);
  await mkdir(join(moduleRoot, 'src', 'main'), { recursive: true });
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify({
    modules: [{ name: 'mysql', srcPath: `./${sourcePath.replaceAll('\\', '/')}` }]
  }));
  await writeFile(join(moduleRoot, 'src', 'main', 'module.json5'),
    '{"module":{"name":"mysql","type":"har"}}');
  await writeFile(join(moduleRoot, 'oh-package.json5'), '{"name":"@arkdb/mysql","version":"1.0.0"}');
  await writeFile(join(moduleRoot, 'arkdb-package.json'), '{"kind":"driver"}');
  const reporter = join(root, 'reporter.mjs');
  await writeFile(reporter, `
    import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
    import { dirname, join } from 'node:path';
    const moduleRoot = join(process.cwd(), ${JSON.stringify(sourcePath)});
    const profile = join(moduleRoot, 'BuildProfile.ets');
    if (process.argv.includes('GenerateBuildProfile')) {
      writeFileSync(profile, 'Current generated profile.');
      console.log('BUILD SUCCESSFUL');
      process.exit(0);
    }
    if (${requireProfile} &&
      (!existsSync(profile) || readFileSync(profile, 'utf8') !== 'Current generated profile.')) {
      console.error('hvigor ERROR: HAR BuildProfile is missing or stale');
      process.exit(1);
    }
    if (existsSync(join(moduleRoot, '.test', 'default', 'cache', 'package-identity.json'))) {
      console.error('hvigor ERROR: stale unit package identity');
      process.exit(1);
    }
    const report = ${JSON.stringify(report) ?? 'undefined'};
    if (report !== undefined) {
      const path = join(moduleRoot, '.test', 'default', 'intermediates',
        'test', 'coverage_data', 'test_result.txt');
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, report);
    }
    console.log(${JSON.stringify(output)});
    process.exitCode = ${status};
  `);

  if (process.platform === 'win32') {
    const executable = join(root, 'hvigorw.cmd');
    await writeFile(executable, `@echo off\r\n"${process.execPath}" "${reporter}" %*\r\n`);
    return executable;
  }

  const executable = join(root, 'hvigorw');
  await writeFile(executable, `#!/bin/sh\nexec "${process.execPath}" "${reporter}" "$@"\n`);
  await chmod(executable, 0o755);
  return executable;
}
