import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { copyFile, cp, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import test from 'node:test';
import JSON5 from 'json5';
import {
  checkArkTsTests, checkPackage, exportedNames, importSpecifiers,
  requiresCanonicalTestOwners, ROOT
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

test('canonical packages cannot disable test ownership enforcement', async (t) => {
  assert.throws(() => requiresCanonicalTestOwners(ROOT, {
    testOwnership: 'fixture'
  }), /Canonical packages cannot disable test ownership enforcement/);

  const root = await workspaceFixture(t);
  assert.equal(requiresCanonicalTestOwners(root, {
    testOwnership: 'fixture'
  }), false);
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

test('rejects unowned core fixture directories', async (t) => {
  for (const owner of ['rogue', 'mysql']) {
    const root = await workspaceFixture(t);
    const fixture = join(root, 'core', 'src', 'test', owner, 'fixtures',
      'Helper.ets');
    await mkdir(join(fixture, '..'), { recursive: true });
    await writeFile(fixture, 'export class Helper {}\n');

    assert.throws(() => checkPackage(root, 'core'),
      new RegExp(`Core tests must use canonical ownership.*unexpected owners: ${owner}`));
  }
});

test('rejects TSX and JSX package test sources', async (t) => {
  for (const suffix of ['tsx', 'jsx']) {
    const root = await workspaceFixture(t);
    const source = join(root, 'core', 'src', 'test', 'fixtures',
      `Helper.${suffix}`);
    await mkdir(join(source, '..'), { recursive: true });
    await writeFile(source, 'export class Helper {}\n');

    assert.throws(() => checkPackage(root, 'core'),
      /must use the exact lowercase \.ets suffix/);
  }
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

test('rejects linked package test roots', async (t) => {
  const root = await workspaceFixture(t);
  const testRoot = join(root, 'mysql', 'src', 'test');
  await rm(testRoot, { recursive: true, force: true });
  await symlink(join(root, 'core', 'src', 'test'), testRoot,
    process.platform === 'win32' ? 'junction' : 'dir');

  assert.throws(() => checkPackage(root),
    /Source links are not supported/);
});

test('allows an executable suite exported through a default assignment', async (t) => {
  const root = await workspaceFixture(t);
  const suite = join(root, 'mysql', 'src', 'test', 'public',
    'PublicInterface.test.ets');
  await writeFile(suite,
    'function publicInterfaceTest(): void {}\n' +
    'export default publicInterfaceTest;\n');

  assert.doesNotThrow(() => checkPackage(root));
});

test('rejects an executable suite exported through export equals', async (t) => {
  const root = await workspaceFixture(t);
  const suite = join(root, 'mysql', 'src', 'test', 'public',
    'PublicInterface.test.ets');
  await writeFile(suite,
    'function publicInterfaceTest(): void {}\n' +
    'export = publicInterfaceTest;\n');

  assert.throws(() => checkPackage(root),
    /Executable ArkTS suite must not export shared fixtures/i);
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

test('rejects a directory as a resolved ArkTS test import', async (t) => {
  const root = await workspaceFixture(t);
  const fixtures = join(root, 'mysql', 'src', 'test', 'fixtures');
  await mkdir(fixtures, { recursive: true });
  const suite = join(root, 'mysql', 'src', 'test', 'public',
    'PublicInterface.test.ets');
  await writeFile(suite, readFileSync(suite, 'utf8') +
    "\nimport { MissingFixture } from '../fixtures';\n");

  assert.throws(() => checkPackage(root), /Unresolved ArkTS test import.*fixtures/i);
});

test('resolves explicitly suffixed production declaration references', async (t) => {
  const root = await workspaceFixture(t);
  const directory = join(root, 'mysql', 'src', 'main', 'ets', 'mysql',
  'model');
  await writeFile(join(directory, 'Types.d.ets'),
  'export interface FixtureTypes {}\n');
  const source = join(directory, 'MySqlServerInfo.ets');
  await writeFile(source,
  "/// <reference path='Types.d.ets' />\n" +
  readFileSync(source, 'utf8'));

  assert.doesNotThrow(() => checkPackage(root, 'mysql'));
});

test('rejects unowned MySQL test directories', async (t) => {
  const root = await workspaceFixture(t);
  const suite = join(root, 'mysql', 'src', 'test', 'mysql', 'features',
  'rogue', 'Rogue.test.ets');
  await mkdir(join(suite, '..'), { recursive: true });
  await writeFile(suite, 'export default function rogueTest(): void {}\n');
  const list = join(root, 'mysql', 'src', 'test', 'List.test.ets');
  await writeFile(list, readFileSync(list, 'utf8')
  .replace(
    "import publicInterfaceTest from './public/PublicInterface.test';",
    "import publicInterfaceTest from './public/PublicInterface.test';\n" +
    "import rogueTest from './mysql/features/rogue/Rogue.test';")
  .replace('  publicInterfaceTest();', '  publicInterfaceTest();\n  rogueTest();'));

  assert.throws(() => checkPackage(root, 'mysql'),
  /MySQL tests must mirror production ownership.*unexpected owners: features\/rogue/);
});

test('rejects fixtures under unowned MySQL test directories', async (t) => {
  const root = await workspaceFixture(t);
  const fixture = join(root, 'mysql', 'src', 'test', 'mysql', 'features',
  'rogue', 'fixtures', 'Helper.ets');
  await mkdir(join(fixture, '..'), { recursive: true });
  await writeFile(fixture, 'export class Helper {}\n');

  assert.throws(() => checkPackage(root, 'mysql'),
  /MySQL tests must mirror production ownership.*unexpected owners: features\/rogue/);
});

test('rejects non-ArkTS package test support sources', async (t) => {
  const root = await workspaceFixture(t);
  const fixture = join(root, 'mysql', 'src', 'test', 'mysql', 'features',
    'cursor', 'fixtures', 'Helper.ts');
  await writeFile(fixture, 'export class Helper {}\n');

  assert.throws(() => checkPackage(root, 'mysql'),
    /ArkDB package test source.*Helper\.ts.*lowercase \.ets/);
});

test('requires an executable suite for every canonical MySQL owner', async (t) => {
  const root = await workspaceFixture(t);
  const cursor = join(root, 'mysql', 'src', 'test', 'mysql', 'features',
    'cursor');
  for (const name of [
    'MySqlCursorFetch.test.ets',
    'MySqlCursorLifecycle.test.ets',
    'MySqlCursorOpen.test.ets'
  ]) {
    await rm(join(cursor, name));
  }
  const list = join(root, 'mysql', 'src', 'test', 'mysql', 'List.test.ets');
  await writeFile(list, readFileSync(list, 'utf8')
    .replace("import mySqlCursorFetchTest from './features/cursor/MySqlCursorFetch.test';\n", '')
    .replace(
      "import mySqlCursorLifecycleTest from\n  './features/cursor/MySqlCursorLifecycle.test';\n",
      '')
    .replace("import mySqlCursorOpenTest from './features/cursor/MySqlCursorOpen.test';\n", '')
    .replace('  mySqlCursorFetchTest();\n', '')
    .replace('  mySqlCursorLifecycleTest();\n', '')
    .replace('  mySqlCursorOpenTest();\n', ''));

  assert.throws(() => checkPackage(root, 'mysql'),
    /MySQL tests must mirror production ownership.*missing owners: features\/cursor/);
});

test('rejects executable cases hidden inside nested suite registries', async (t) => {
  const root = await workspaceFixture(t);
  const nested = join(root, 'mysql', 'src', 'test', 'mysql', 'features',
    'cursor', 'List.test.ets');
  await writeFile(nested,
    "import { it } from '@ohos/hypium';\n" +
    "export default function hiddenRegistry(): void {\n" +
    "  it('hiddenNestedRegistryCase', 0, () => {});\n" +
    "}\n");
  const list = join(root, 'mysql', 'src', 'test', 'mysql', 'List.test.ets');
  await writeFile(list, readFileSync(list, 'utf8')
    .replace(
      "import mySqlCursorFetchTest from './features/cursor/MySqlCursorFetch.test';",
      "import hiddenRegistry from './features/cursor/List.test';\n" +
      "import mySqlCursorFetchTest from './features/cursor/MySqlCursorFetch.test';")
    .replace('  mySqlCursorFetchTest();',
      '  hiddenRegistry();\n  mySqlCursorFetchTest();'));

  assert.throws(() => checkPackage(root, 'mysql'),
    /ArkTS suite registries must not declare test cases|Unexpected ArkTS suite registry/);
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
    import './side-effect';
    import BuildProfile from '../../BuildProfile';
    import { socket } from '@kit.NetworkKit';
    export type { Connection } from './Connection';
    type Runtime = import('./Runtime').Runtime;
    void import('./dynamic');
  `), [
    './side-effect',
    '../../BuildProfile',
    '@kit.NetworkKit',
    './Connection',
    './Runtime',
    './dynamic'
  ]);
});

test('strict import scanning rejects mutated and destructured loader aliases', () => {
  for (const source of [
    `
      let key = '';
      key ||= 'constructor';
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const key = '' || 'constructor';
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const [key] = ['constructor'];
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      let key;
      [key] = ['constructor'];
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const names = ['constructor'];
      let key;
      [key] = names;
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const override = { key: 'constructor' };
      const { key } = { key: 'safe', ...override };
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const [api] = ['setDependenciesOpt'];
      project[api]({});
    `,
    `
      let api;
      ({ api } = { api: 'setDependenciesOpt' });
      project[api]({});
    `,
    `
      function load(key) {
        return ({})[key][key]("return import('./hidden.mjs')")();
      }
      load('constructor');
    `,
    `
      function load(key = 'safe') {
        return ({})[key][key]("return import('./hidden.mjs')")();
      }
      load('constructor');
    `,
    `
      function load(key = 'safe') {
        const Loader = ({})[key][key];
        return Loader("return import('./hidden.mjs')")();
      }
      load('constructor');
    `,
    `
      function load(key) {
        const proto = ({})[key];
        const Loader = proto[key];
        return Loader("return import('./hidden.mjs')")();
      }
      load('constructor');
    `,
    `
      function load(key) {
        const Loader = ((async function () {})[key] as any);
        return Loader("return import('./hidden.mjs')")();
      }
      load('constructor');
    `,
    `
      function apply(name) {
        project[name].call(project, {});
      }
      apply('setDependenciesOpt');
    `,
    `
      const get = (name) => project[name];
      get('setDependenciesOpt')({});
    `,
    `
      function invoke(value) {
        return value;
      }
      function apply(name) {
        invoke(project[name]);
      }
      apply('setDependenciesOpt');
    `,
    `
      let name = false;
      name = name || 'setDependenciesOpt';
      project[name]({});
    `,
    `
      function apply(name) {
        const mutate = project[name];
        mutate.call(project, {});
      }
      apply('setDependenciesOpt');
    `,
    `
      const key = 'constructor';
      function load(alias = key) {
        var key = 'safe';
        return ({})[alias][alias]("return import('./hidden.mjs')")();
      }
      load();
    `,
    `
      const { 'setDependenciesOpt': mutate } = project;
      mutate({});
    `,
    `
      const { 'constructor': Loader } =
        Object.getPrototypeOf(async function () {});
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const key = 'constructor';
      const { [key]: Loader } =
        Object.getPrototypeOf(async function () {});
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const key = 'constructor';
      let Loader;
      ({ [key]: Loader } =
        Object.getPrototypeOf(async function () {}));
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const key = ['constructor'];
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const [unused, key] = [...['safe', 'constructor'], 'safe'];
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const key = ['safe'];
      key[0] = 'constructor';
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const [...[, key]] = [[0, 'safe'], 'constructor'];
      const Loader = ({})[key][key];
      Loader("return import('./hidden.mjs')")();
    `,
    `
      for (const key of ['constructor']) {
        ({})[key][key]("return import('./hidden.mjs')")();
      }
    `,
    `
      let key = 'safe';
      for (key of ['constructor']) {
        ({})[key][key]("return import('./hidden.mjs')")();
      }
    `,
    `
      let key = 'safe';
      for (key of ['safe', ...['constructor']]) {
        ({})[key][key]("return import('./hidden.mjs')")();
      }
    `,
    `
      const key = 'constructor';
      let Loader = () => undefined;
      for ({ [key]: Loader } of [
        Object.getPrototypeOf(async function () {})
      ]) {
        Loader("return import('./hidden.mjs')")();
      }
    `,
    `
      const { constructor } =
        Object.getPrototypeOf(async function () {});
      constructor("return import('./hidden.mjs')")();
    `,
    `
      const Loader = Object.getOwnPropertyDescriptor(
        Object.getPrototypeOf(async function () {}), 'constructor').value;
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const Loader = Object.getOwnPropertyDescriptor.call(
        Object,
        Object.getPrototypeOf(async function () {}),
        'constructor'
      ).value;
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const api = 'getOwnPropertyDescriptor';
      const Loader = Object[api](
        Object.getPrototypeOf(async function () {}),
        'constructor'
      ).value;
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const { getOwnPropertyDescriptor: descriptor } = Object;
      const Loader = descriptor(
        Object.getPrototypeOf(async function () {}),
        'constructor'
      ).value;
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const O = Object;
      const Loader = O.getOwnPropertyDescriptor(
        Object.getPrototypeOf(async function () {}),
        'constructor'
      ).value;
      Loader("return import('./hidden.mjs')")();
    `,
    `
      let descriptor;
      ({ holder: { ['getOwnPropertyDescriptor']: descriptor } } =
        { holder: Object });
      const Loader = descriptor(
        Object.getPrototypeOf(async function () {}),
        'constructor'
      ).value;
      Loader("return import('./hidden.mjs')")();
    `,
    `
      const descriptors = Object.getOwnPropertyDescriptors(
        Object.getPrototypeOf(async function () {})
      );
      const Loader = Object.values(descriptors)[0].value;
      Loader("return import('./hidden.mjs')")();
    `
  ]) {
    assert.throws(() => importSpecifiers(source, {
      strictNodeLoaders: true
    }), /(?:Node loader imports|Dependency-mutating Hvigor APIs) are not supported/);
  }
});

test('strict import scanning allows safe indexed writes and loop shadowing', () => {
  assert.doesNotThrow(() => importSpecifiers(`
    const key = 'safe';
    const values = {};
    values[key] = () => true;
    values[key]();
    const counts = { safe: 0 };
    counts[key] += 1;
    const handlers = { safe: () => true };
    handlers[key]();
    interface Helper {
      getOwnPropertyDescriptor(): string;
    }
    const helper: Helper = {
      getOwnPropertyDescriptor: () => 'safe'
    };
    helper.getOwnPropertyDescriptor();
    for (const key of ['other']) {
      void key;
    }
    values[key]();
    for (const key of ['safe']) {
      handlers[key]();
    }
  `, {
    strictNodeLoaders: true
  }));
});
