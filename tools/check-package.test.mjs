import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { copyFile, cp, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import test from 'node:test';
import JSON5 from 'json5';
import { checkPackage, exportedNames, importSpecifiers, ROOT } from './check-package.mjs';

test('discovers the current standalone interface and registered suites', () => {
  const result = checkPackage();
  assert.equal(result.manifest.name, '@arkdb/mysql');
  assert.ok(result.testSuites > 0);
  assert.ok(result.sourceFiles > 0);
  assert.deepEqual(result.exports, exportedNames(readFileSync(join(ROOT, 'mysql', 'Index.ets'), 'utf8')));
  assert.ok(result.exports.includes('ArkDbError'));
  assert.ok(result.exports.includes('ArkDbErrorKind'));
  assert.ok(!result.exports.some((name) => name.startsWith('OrcaSql')));
});

test('allows additional registered modules without freezing the workspace layout', async (t) => {
  const root = await workspaceFixture(t);
  const profile = JSON5.parse(readFileSync(join(root, 'build-profile.json5'), 'utf8'));
  profile.modules.push({ name: 'another_driver', srcPath: './another_driver' });
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify(profile));
  assert.equal(checkPackage(root).manifest.name, '@arkdb/mysql');
});

test('requires the MySQL module to be registered at its actual source path', async (t) => {
  const root = await workspaceFixture(t);
  const profile = JSON5.parse(readFileSync(join(root, 'build-profile.json5'), 'utf8'));
  profile.modules[0].srcPath = './different-module';
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
  await mkdir(join(root, 'drivers'), { recursive: true });
  await cp(join(root, 'mysql'), join(root, 'drivers', 'pgsql'), { recursive: true });
  const profile = JSON5.parse(readFileSync(join(root, 'build-profile.json5'), 'utf8'));
  profile.modules.push({ name: 'pgsql', srcPath: './drivers/pgsql' });
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify(profile));
  const definitionPath = join(root, 'drivers', 'pgsql', 'src', 'main', 'module.json5');
  const definition = JSON5.parse(readFileSync(definitionPath, 'utf8'));
  definition.module.name = 'pgsql';
  await writeFile(definitionPath, JSON.stringify(definition));
  const manifestPath = join(root, 'drivers', 'pgsql', 'oh-package.json5');
  const manifest = JSON5.parse(readFileSync(manifestPath, 'utf8'));
  manifest.name = '@arkdb/postgres';
  await writeFile(manifestPath, JSON.stringify(manifest));
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
  await cp(join(ROOT, 'mysql'), join(root, 'mysql'), {
    recursive: true,
    filter: (file) => !generated.has(basename(file))
  });
  await copyFile(join(ROOT, 'LICENSE'), join(root, 'LICENSE'));
  await copyFile(join(ROOT, 'build-profile.json5'), join(root, 'build-profile.json5'));
  return root;
}

test('import scanning covers both concrete and type-only seams', () => {
  assert.deepEqual(importSpecifiers(`
    import BuildProfile from '../../BuildProfile';
    import { socket } from '@kit.NetworkKit';
    export type { Connection } from './Connection';
  `), ['../../BuildProfile', '@kit.NetworkKit', './Connection']);
});
