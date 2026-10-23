import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { delimiter, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { resolveHvigor, resolveOhpm, runHvigor, runOhpm } from './run-hvigor.mjs';

const repoRoot = fileURLToPath(new URL('..', import.meta.url));
const runtimeRoot = join(repoRoot, 'tools', '.tmp-run-hvigor');
const wrapperPath = join(repoRoot, 'tools', 'run-hvigor.mjs');

test('resolves OHPM from an explicit path, environment override, then DevEco', () => {
  assert.equal(resolveOhpm({
    ohpm: 'explicit-ohpm',
    env: { HARMONYOS_OHPM: 'environment-ohpm', DEVECO_HOME: 'deveco' }
  }), 'explicit-ohpm');
  assert.equal(resolveOhpm({ env: { HARMONYOS_OHPM: 'environment-ohpm' } }), 'environment-ohpm');
  assert.equal(resolveOhpm({ env: { DEVECO_HOME: 'deveco' }, platform: 'win32' }),
    join('deveco', 'tools', 'ohpm', 'bin', 'ohpm.bat'));
});

test('OHPM forwards the isolated working directory and preserves failure status', () => {
  let invocation;
  const result = runOhpm(['install', '--all'], {
    ohpm: process.execPath, cwd: runtimeRoot, env: {}, platform: 'linux',
    spawnSync(command, args, options) {
      invocation = { command, args, options };
      return { status: 9, stdout: '', stderr: 'restore failed' };
    },
    output: { write() {} }
  });
  assert.equal(invocation.options.cwd, runtimeRoot);
  assert.deepEqual(invocation.args, ['install', '--all']);
  assert.equal(result.status, 9);
  assert.equal(result.output, 'restore failed');
});

test('prefers explicit hvigor path over HARMONYOS_HVIGORW and DEVECO_HOME', () => {
  const explicit = join(runtimeRoot, 'explicit', 'hvigorw');
  assert.equal(resolveHvigor({
    hvigorw: explicit,
    env: {
      HARMONYOS_HVIGORW: join(runtimeRoot, 'environment', 'hvigorw'),
      DEVECO_HOME: join(runtimeRoot, 'deveco')
    },
    platform: 'linux'
  }), explicit);
});

test('prefers HARMONYOS_HVIGORW over DEVECO_HOME', () => {
  const environment = join(runtimeRoot, 'environment', 'hvigorw');
  assert.equal(resolveHvigor({
    env: {
      HARMONYOS_HVIGORW: environment,
      DEVECO_HOME: join(runtimeRoot, 'deveco')
    },
    platform: 'linux'
  }), environment);
});

test('derives hvigorw.bat from DEVECO_HOME on Windows', () => {
  const devecoHome = join(runtimeRoot, 'DevEco Studio');
  assert.equal(resolveHvigor({
    env: { DEVECO_HOME: devecoHome },
    platform: 'win32'
  }), join(devecoHome, 'tools', 'hvigor', 'bin', 'hvigorw.bat'));
});

test('forwards arguments without shell interpolation', async (t) => {
  const executable = await createExecutableFixture(t, 'forwarding');
  const expectedArgs = ['--mode', 'module', '-p', 'module=mysql@default'];
  let invocation;

  runHvigor(expectedArgs, {
    hvigorw: executable,
    env: {},
    platform: 'linux',
    spawnSync(command, args, options) {
      invocation = { command, args, options };
      return { status: 0, stdout: '', stderr: '' };
    },
    output: { write() {} }
  });

  assert.equal(invocation.command, executable);
  assert.deepEqual(invocation.args, expectedArgs);
  assert.equal(invocation.options.shell, false);
});

test('returns combined normalized output and exit status', async (t) => {
  const executable = await createExecutableFixture(t, 'output');
  let streamed = '';

  const result = runHvigor([], {
    hvigorw: executable,
    env: {},
    platform: 'linux',
    spawnSync() {
      return {
        status: 7,
        stdout: '\u001B[31mstdout\u001B[0m\r\n',
        stderr: 'stderr\r'
      };
    },
    output: {
      write(value) {
        streamed += value;
      }
    }
  });

  assert.equal(result.status, 7);
  assert.equal(result.output, 'stdout\nstderr\n');
  assert.equal(streamed, result.output);
});

test('fails when the executable does not exist', () => {
  assert.throws(() => runHvigor([], {
    hvigorw: join(runtimeRoot, 'missing', 'hvigorw'),
    env: {},
    platform: 'linux',
    output: { write() {} }
  }), /hvigorw not found/);
});

test('derives SDK home and prepends the bundled Node directory only when it exists', async (t) => {
  const devecoHome = join(runtimeRoot, 'environment');
  const executable = join(devecoHome, 'hvigorw');
  const bundledNode = join(devecoHome, 'tools', 'node');
  await rm(devecoHome, { recursive: true, force: true });
  await mkdir(bundledNode, { recursive: true });
  await writeFile(executable, '');
  t.after(() => rm(devecoHome, { recursive: true, force: true }));
  let childEnv;

  runHvigor([], {
    hvigorw: executable,
    env: { DEVECO_HOME: devecoHome, PATH: 'original-path' },
    platform: 'linux',
    spawnSync(command, args, options) {
      childEnv = options.env;
      return { status: 0, stdout: '', stderr: '' };
    },
    output: { write() {} }
  });

  assert.equal(childEnv.DEVECO_SDK_HOME, join(devecoHome, 'sdk'));
  assert.equal(childEnv.PATH, `${bundledNode}${delimiter}original-path`);

  runHvigor([], {
    hvigorw: executable,
    env: { DEVECO_HOME: devecoHome },
    platform: 'linux',
    spawnSync(command, args, options) {
      childEnv = options.env;
      return { status: 0, stdout: '', stderr: '' };
    },
    output: { write() {} }
  });
  assert.equal(childEnv.PATH, bundledNode);

  await rm(bundledNode, { recursive: true, force: true });
  runHvigor([], {
    hvigorw: executable,
    env: { DEVECO_HOME: devecoHome, PATH: 'original-path' },
    platform: 'linux',
    spawnSync(command, args, options) {
      childEnv = options.env;
      return { status: 0, stdout: '', stderr: '' };
    },
    output: { write() {} }
  });
  assert.equal(childEnv.PATH, 'original-path');
});

test('CLI forwards explicit executable arguments and exits with the child status', async (t) => {
  const root = join(runtimeRoot, 'cli');
  await rm(root, { recursive: true, force: true });
  await mkdir(root, { recursive: true });
  t.after(() => rm(root, { recursive: true, force: true }));
  const fixture = join(root, 'fixture.mjs');
  await writeFile(fixture,
    "process.stdout.write(JSON.stringify(process.argv.slice(2)) + '\\r\\n');\n" +
    "process.stderr.write('\\u001B[31mstderr\\u001B[0m\\r\\n');\n" +
    'process.exitCode = 7;\n');

  const result = spawnSync(process.execPath, [
    wrapperPath,
    '--hvigorw', process.execPath,
    '--', fixture, 'argument with spaces'
  ], { encoding: 'utf8' });

  assert.equal(result.status, 7);
  assert.equal(result.stdout, '["argument with spaces"]\nstderr\n');
  assert.equal(result.stderr, '');
});

test('CLI requires the Hvigor argument separator', () => {
  const result = spawnSync(process.execPath, [wrapperPath], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Expected -- before Hvigor arguments/);
});

test('Windows batch execution preserves shell metacharacters in arguments', {
  skip: process.platform !== 'win32'
}, async (t) => {
  const root = join(runtimeRoot, 'windows-arguments');
  await rm(root, { recursive: true, force: true });
  await mkdir(root, { recursive: true });
  t.after(() => rm(root, { recursive: true, force: true }));
  const reporter = join(root, 'reporter.mjs');
  const executable = join(root, 'hvigorw.cmd');
  await writeFile(reporter, 'process.stdout.write(JSON.stringify(process.argv.slice(2)));\n');
  await writeFile(executable, `@echo off\r\n"${process.execPath}" "${reporter}" %*\r\n`);
  const expected = [
    'argument with spaces',
    'literal&echo injected',
    'literal|more',
    'literal>output',
    'literal^caret',
    'literal%PATH%',
    'literal!value!',
    'literal(paren)',
    'literal"quote',
    'before\\"quote',
    'trailing\\',
    ''
  ];
  let output = '';

  const result = runHvigor(expected, {
    hvigorw: executable,
    env: { ...process.env, DEVECO_HOME: '' },
    platform: 'win32',
    output: {
      write(value) {
        output += value;
      }
    }
  });

  assert.equal(result.status, 0, output);
  assert.deepEqual(JSON.parse(output), expected);
});

test('Windows child environments supply OS without changing the caller environment', async (t) => {
  const executable = await createExecutableFixture(t, 'windows-os');
  const env = { PATH: 'restricted-path', DEVECO_HOME: '' };
  let childEnv;
  runHvigor([], {
    hvigorw: executable,
    env,
    platform: 'win32',
    spawnSync(command, args, options) {
      childEnv = options.env;
      return { status: 0, stdout: '', stderr: '' };
    },
    output: { write() {} }
  });
  assert.equal(childEnv.OS, 'Windows_NT');
  assert.deepEqual(env, { PATH: 'restricted-path', DEVECO_HOME: '' });
});

test('restricted Windows batch launches enable OS-dependent delayed expansion', {
  skip: process.platform !== 'win32'
}, async (t) => {
  const root = join(runtimeRoot, 'windows-delayed-expansion');
  await mkdir(root, { recursive: true });
  t.after(() => rm(root, { recursive: true, force: true }));
  const executable = join(root, 'fixture.cmd');
  await writeFile(executable, [
    '@echo off',
    'if "%OS%"=="Windows_NT" setlocal enabledelayedexpansion',
    'set "ARKDB_FIXTURE_STATE=ready"',
    'if "!ARKDB_FIXTURE_STATE!"=="ready" (',
    '  echo delayed-expansion-ready',
    '  exit /b 0',
    ')',
    'echo delayed-expansion-unavailable',
    'exit /b 17',
    ''
  ].join('\r\n'));
  const result = runHvigor([], {
    hvigorw: executable,
    env: { SystemRoot: process.env.SystemRoot, ComSpec: process.env.ComSpec, DEVECO_HOME: '' },
    platform: 'win32',
    output: { write() {} }
  });
  assert.equal(result.status, 0, result.output);
  assert.equal(result.output, 'delayed-expansion-ready\n');
});

async function createExecutableFixture(t, name) {
  const root = join(runtimeRoot, name);
  await rm(root, { recursive: true, force: true });
  await mkdir(root, { recursive: true });
  t.after(() => rm(root, { recursive: true, force: true }));
  const executable = join(root, 'hvigorw');
  await writeFile(executable, '');
  return executable;
}
