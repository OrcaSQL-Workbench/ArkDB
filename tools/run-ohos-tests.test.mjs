import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
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
  const root = await mkdtemp(join(tmpdir(), 'arkdb-missing-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const executable = join(root, 'missing-hvigorw');
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

async function createHvigorFixture(t, output, status, report) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-hvigor-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const reporter = join(root, 'reporter.mjs');
  await writeFile(reporter, `
    import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
    import { dirname, join } from 'node:path';
    if (existsSync(join(process.cwd(), 'mysql', '.test', 'default', 'cache', 'package-identity.json'))) {
      console.error('hvigor ERROR: stale unit package identity');
      process.exit(1);
    }
    const report = ${JSON.stringify(report) ?? 'undefined'};
    if (report !== undefined) {
      const path = join(process.cwd(), 'mysql', '.test', 'default', 'intermediates',
        'test', 'coverage_data', 'test_result.txt');
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, report);
    }
    console.log(${JSON.stringify(output)});
    process.exitCode = ${status};
  `);

  if (process.platform === 'win32') {
    const executable = join(root, 'hvigorw.cmd');
    await writeFile(executable, `@echo off\r\n"${process.execPath}" "${reporter}"\r\n`);
    return executable;
  }

  const executable = join(root, 'hvigorw');
  await writeFile(executable, `#!/bin/sh\nexec "${process.execPath}" "${reporter}"\n`);
  await chmod(executable, 0o755);
  return executable;
}
