import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { copyFile, cp, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import test from 'node:test';
import JSON5 from 'json5';
import {
  checkArkTsTests, checkPackage, exportedNames, importSpecifiers, ROOT
} from './check-package.mjs';

test('discovers the current standalone interface and registered suites', () => {
  const result = checkPackage();
  assert.equal(result.manifest.name, '@arkdb/mysql');
  assert.equal(result.testSuites, 58);
  assert.equal(result.testCases, 815);
  assert.ok(result.sourceFiles > 0);
  assert.deepEqual(result.testOwners, [
    'auth',
    'command',
    'connection',
    'diagnostics',
    'execution',
    'features/batch',
    'features/cursor',
    'features/insert',
    'features/longdata',
    'features/metadata',
    'features/metrics',
    'features/named',
    'features/prepared',
    'features/procedure',
    'features/session',
    'features/transaction',
    'model',
    'protocol',
    'public',
    'transport',
    'value'
  ]);
  assert.deepEqual(result.exports, exportedNames(readFileSync(join(ROOT, 'mysql', 'Index.ets'), 'utf8')));
  assert.ok(result.exports.includes('ArkDbError'));
  assert.ok(result.exports.includes('ArkDbErrorKind'));
  assert.ok(!result.exports.some((name) => name.startsWith('OrcaSql')));
});

test('preserves exact core, consumer and acceptance suite registrations', () => {
  const core = checkPackage(ROOT, 'core');
  const consumer = checkArkTsTests(
    ROOT, 'examples/mysql-client/entry/src/test', 'mysql-client');
  const acceptance = checkArkTsTests(
    ROOT, 'examples/mysql-device-acceptance/entry/src/test',
    'mysql-device-acceptance');

  assert.deepEqual(
    [core.testSuites, core.testCases, core.testOwners],
    [1, 13, ['.']]
  );
  assert.deepEqual(
    [consumer.testSuites, consumer.testCases, consumer.testOwners],
    [3, 20, ['consumer', 'sample']]
  );
  assert.deepEqual(
    [acceptance.testSuites, acceptance.testCases, acceptance.testOwners],
    [3, 14, ['acceptance', 'evidence']]
  );
});

test('rejects duplicate executable suite registrations', async (t) => {
  const root = await workspaceFixture(t);
  const list = join(root, 'mysql', 'src', 'test', 'List.test.ets');
  await writeFile(list,
    "import first from './public/PublicInterface.test';\n" +
    "import duplicate from './public/PublicInterface.test';\n" +
    'export default function tests(): void { first(); duplicate(); }\n');

  assert.throws(() => checkPackage(root),
    /registered more than once.*PublicInterface\.test\.ets/i);
});

test('rejects shared fixture exports from executable suites', async (t) => {
  const root = await workspaceFixture(t);
  const suite = join(root, 'mysql', 'src', 'test', 'Probe.test.ets');
  await writeFile(suite,
    'export class SharedFixture {}\n' +
    'export default function suite(): void {}\n');

  assert.throws(() => checkPackage(root), /Executable ArkTS suite must not export shared fixtures/i);
});

test('requires support sources to use explicit fixture ownership', async (t) => {
  const root = await workspaceFixture(t);
  await writeFile(join(root, 'mysql', 'src', 'test', 'SharedFixture.ets'),
    'export class SharedFixture {}\n');

  assert.throws(() => checkPackage(root), /Test support source must live under a fixtures directory/i);
});

test('rejects stale relative imports in ArkTS test sources', async (t) => {
  const root = await workspaceFixture(t);
  const suite = join(root, 'mysql', 'src', 'test', 'public',
    'PublicInterface.test.ets');
  await writeFile(suite, readFileSync(suite, 'utf8') +
    "\nimport { MissingFixture } from '../fixtures/MissingFixture';\n");

  assert.throws(() => checkPackage(root), /Unresolved ArkTS test import.*MissingFixture/i);
});

test('allows additional registered modules without freezing the workspace layout', async (t) => {
  const root = await workspaceFixture(t);
  await independentModule(root, 'another_driver', 'another_driver', '@arkdb/another-driver');
  const profile = JSON5.parse(readFileSync(join(root, 'build-profile.json5'), 'utf8'));
  profile.modules.push({ name: 'another_driver', srcPath: './another_driver' });
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify(profile));
  assert.equal(checkPackage(root).manifest.name, '@arkdb/mysql');
});

test('requires the MySQL module to be registered at its actual source path', async (t) => {
  const root = await workspaceFixture(t);
  const profile = JSON5.parse(readFileSync(join(root, 'build-profile.json5'), 'utf8'));
  profile.modules.find((entry) => entry.name === 'mysql').srcPath = './different-module';
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify(profile));
  assert.throws(() => checkPackage(root), /register the mysql HAR/);
});

test('rejects an empty public entry without freezing a historical export list', async (t) => {
  const root = await workspaceFixture(t);
  await writeFile(join(root, 'mysql', 'Index.ets'), '// No public exports.\n');
  assert.throws(() => checkPackage(root), /Public entry must expose named exports/);
});

test('validates a synthetic second driver without forcing the MySQL package or directory name', async (t) => {
  const root = await workspaceFixture(t);
  await independentModule(root, 'drivers\\pgsql', 'pgsql', '@arkdb/postgres');
  const profile = JSON5.parse(readFileSync(join(root, 'build-profile.json5'), 'utf8'));
  profile.modules.push({ name: 'pgsql', srcPath: './drivers/pgsql' });
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify(profile));
  const result = checkPackage(root, 'pgsql');
  assert.equal(result.manifest.name, '@arkdb/postgres');
  assert.equal(result.driver.sourcePath, 'drivers/pgsql');
});

test('public export parsing handles type-only exports, multiline groups and aliases', () => {
  assert.deepEqual(exportedNames(`
    export type { Connection } from './Connection';
    export { Config,
      Driver as MyDriver } from './Driver';
  `), ['Config', 'Connection', 'MyDriver']);
});

test('rejects duplicate public symbols', () => {
  assert.throws(() => exportedNames(`
    export { Driver } from './a';
    export { Driver } from './b';
  `), /Duplicate public export/);
});

async function workspaceFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-package-check-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const generated = new Set(['build', '.test', 'oh_modules', 'BuildProfile.ets', 'oh-package-lock.json5']);
  for (const name of ['core', 'mysql']) {
    await cp(join(ROOT, name), join(root, name), {
      recursive: true, filter: (file) => !generated.has(basename(file))
    });
  }
  await copyFile(join(ROOT, 'LICENSE'), join(root, 'LICENSE'));
  await copyFile(join(ROOT, 'build-profile.json5'), join(root, 'build-profile.json5'));
  await copyFile(join(ROOT, 'oh-package.json5'), join(root, 'oh-package.json5'));
  return root;
}

async function independentModule(root, directory, id, name) {
  const target = join(root, ...directory.split('\\'));
  await mkdir(join(target, 'src', 'main', 'ets'), { recursive: true });
  await mkdir(join(target, 'src', 'test'), { recursive: true });
  for (const file of ['LICENSE', 'README.md', 'CHANGELOG.md', 'README.OpenSource']) {
    await writeFile(join(target, file), file === 'LICENSE' ? readFileSync(join(ROOT, 'LICENSE')) : 'Test-only independent module.\n');
  }
  await writeFile(join(target, 'oh-package.json5'), JSON.stringify({
    name, version: '1.0.0', main: 'Index.ets', license: 'Apache-2.0', author: 'Synthetic fixture',
    dependencies: { '@arkdb/core': '1.0.0' }
  }));
  await writeFile(join(target, 'arkdb-package.json'), '{"kind":"driver"}');
  await writeFile(join(target, 'src', 'main', 'module.json5'), JSON.stringify({ module: { name: id, type: 'har' } }));
  await writeFile(join(target, 'Index.ets'), "export { Probe } from './src/main/ets/Probe';\n");
  await writeFile(join(target, 'src', 'main', 'ets', 'Probe.ets'),
    "import { ArkDbError } from '@arkdb/core';\nexport class Probe { fail(): void { throw ArkDbError.unsupported('Test only.'); } }\n");
  await writeFile(join(target, 'src', 'test', 'List.test.ets'),
    "import suite from './Probe.test';\nexport default function tests(): void { suite(); }\n");
  await writeFile(join(target, 'src', 'test', 'Probe.test.ets'), 'export default function suite(): void {}\n');
}

test('import scanning covers both concrete and type-only seams', () => {
  assert.deepEqual(importSpecifiers(`
    import BuildProfile from '../../BuildProfile';
    import { socket } from '@kit.NetworkKit';
    export type { Connection } from './Connection';
  `), ['../../BuildProfile', '@kit.NetworkKit', './Connection']);
});
