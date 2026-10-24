import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import JSON5 from 'json5';
import { createDeliveryWorkspace, deliveryPlan } from './delivery-workspace.mjs';
import { listFiles } from './check-package.mjs';
import { sourceFingerprint } from './package-har.mjs';
import { sharedReleaseFixture } from './test-fixtures/har-release.mjs';

test('stages one SDK module without changing shared sources or retaining a core dependency', async (t) => {
  const fixture = await sharedReleaseFixture(t);
  const before = sourceFingerprint(fixture.root);
  const workspace = await createDeliveryWorkspace(fixture.root, 'mysql');
  const profile = JSON5.parse(await readFile(join(workspace.directory, 'build-profile.json5'), 'utf8'));
  const project = JSON5.parse(await readFile(join(workspace.directory, 'oh-package.json5'), 'utf8'));
  const manifest = JSON5.parse(await readFile(join(workspace.moduleDirectory, 'oh-package.json5'), 'utf8'));
  const index = await readFile(join(workspace.moduleDirectory, 'Index.ets'), 'utf8');

  assert.deepEqual(profile.modules, [{ name: 'mysql', srcPath: './module' }]);
  assert.deepEqual(manifest.dependencies, {});
  assert.equal(manifest.name, '@arkdb/mysql');
  assert.equal(project.overrides, undefined);
  assert.equal(project.devDependencies, undefined);
  assert.equal(sourceFingerprint(fixture.root), before);
  assert.match(index, /from ["']\.\/src\/main\/ets\/_deps\/core\/Index["']/);
  assert.doesNotMatch(index, /from ["']@arkdb\/core["']/);
  const runtime = listFiles(join(workspace.moduleDirectory, 'src', 'main', 'ets'));
  assert.equal(runtime.filter((file) => file.endsWith('ArkDbError.ets')).length, 1);
  const notice = await readFile(join(workspace.moduleDirectory, 'README.OpenSource'), 'utf8');
  assert.ok(notice.includes(await readFile(join(fixture.root, 'core', 'README.OpenSource'), 'utf8')));
  assert.ok(notice.includes(await readFile(join(fixture.root, 'mysql', 'README.OpenSource'), 'utf8')));
});

test('rewrites module syntax without touching comments or SQL strings and preserves dependency version profiles', async (t) => {
  const fixture = await sharedReleaseFixture(t);
  await writeFile(join(fixture.root, 'mysql', 'src', 'main', 'ets', 'Public.ets'), `
import type { ServerInfo } from '@arkdb/core';
export { ArkDbError } from '@arkdb/core';
export type ImportedInfo = import('@arkdb/core').ServerInfo;
// export { ArkDbError } from '@arkdb/core';
export class SyntheticDeclaration {
  sql: string = "from '@arkdb/core'";
  info: ServerInfo | null = null;
  async load(): Promise<Object> { return import('@arkdb/core'); }
}
`);
  const workspace = await createDeliveryWorkspace(fixture.root, 'mysql');
  const source = await readFile(join(workspace.moduleDirectory, 'src', 'main', 'ets', 'Public.ets'), 'utf8');

  assert.match(source, /import type \{ ServerInfo \} from "\.\/_deps\/core\/Index"/);
  assert.match(source, /export \{ ArkDbError \} from "\.\/_deps\/core\/Index"/);
  assert.match(source, /import\("\.\/_deps\/core\/Index"\)\.ServerInfo/);
  assert.match(source, /return import\("\.\/_deps\/core\/Index"\)/);
  assert.ok(source.includes('// export { ArkDbError } from \'@arkdb/core\';'));
  assert.ok(source.includes('sql: string = "from \'@arkdb/core\'";'));
  const profile = await readFile(join(workspace.moduleDirectory, 'src', 'main', 'ets',
    '_deps', 'core', 'BuildProfile.ets'), 'utf8');
  assert.match(profile, /HAR_VERSION = "1\.0\.0"/);
  assert.match(profile, /RootBuildProfile\.DEBUG/);
  const logger = await readFile(join(workspace.moduleDirectory, 'src', 'main', 'ets',
    '_deps', 'core', 'diagnostics', 'Logger.ets'), 'utf8');
  assert.match(logger, /from "\.\.\/BuildProfile"/);
});

test('a second adapter composes with MySQL and core once without editing MySQL implementation', async (t) => {
  const fixture = await sharedReleaseFixture(t);
  const before = await readFile(join(fixture.root, 'mysql', 'Index.ets'), 'utf8');
  const directory = join(fixture.root, 'drivers', 'probe');
  await mkdir(join(directory, 'src', 'main', 'ets'), { recursive: true });
  await mkdir(join(directory, 'src', 'test'), { recursive: true });
  for (const name of ['LICENSE', 'README.md', 'README.OpenSource', 'CHANGELOG.md']) {
    await writeFile(join(directory, name), await readFile(join(fixture.root, 'core', name)));
  }
  await writeFile(join(directory, 'oh-package.json5'), JSON.stringify({
    name: '@arkdb/probe', version: '1.0.0', main: 'Index.ets', author: 'Fixture', license: 'Apache-2.0',
    dependencies: { '@arkdb/core': '1.0.0', '@arkdb/mysql': '1.0.0' }
  }));
  await writeFile(join(directory, 'arkdb-package.json'), '{"kind":"driver"}');
  await writeFile(join(directory, 'build-profile.json5'), '{"apiType":"stageMode","buildOption":{"arkOptions":{"byteCodeHar":true}}}');
  await writeFile(join(directory, 'hvigorfile.ts'), 'export default {};\n');
  await writeFile(join(directory, 'src', 'main', 'module.json5'),
    '{"module":{"name":"probe","type":"har"}}');
  await writeFile(join(directory, 'src', 'main', 'ets', 'Probe.ets'), `
import { ArkDbError } from '@arkdb/core';
export class Probe { fail(): void { throw ArkDbError.validation('fixture'); } }
`);
  await writeFile(join(directory, 'Index.ets'),
    "export { Probe } from './src/main/ets/Probe';\nexport { SyntheticDeclaration } from '@arkdb/mysql';\n");
  await writeFile(join(directory, 'src', 'test', 'List.test.ets'),
    "import suite from './Probe.test';\nexport default function tests(): void { suite(); }\n");
  await writeFile(join(directory, 'src', 'test', 'Probe.test.ets'), 'export default function suite(): void {}\n');
  const profilePath = join(fixture.root, 'build-profile.json5');
  const profile = JSON5.parse(await readFile(profilePath, 'utf8'));
  profile.modules.push({ name: 'probe', srcPath: './drivers/probe' });
  await writeFile(profilePath, JSON.stringify(profile));
  const projectPath = join(fixture.root, 'oh-package.json5');
  const project = JSON5.parse(await readFile(projectPath, 'utf8'));
  project.overrides['@arkdb/mysql'] = 'file:./mysql';
  await writeFile(projectPath, JSON.stringify(project));

  const plan = deliveryPlan(fixture.root, 'probe');
  const workspace = await createDeliveryWorkspace(fixture.root, 'probe');

  assert.deepEqual(plan.packages.map((entry) => entry.driver.id), ['core', 'mysql', 'probe']);
  const files = listFiles(join(workspace.moduleDirectory, 'src', 'main', 'ets'));
  assert.equal(files.filter((file) => file.endsWith('ArkDbError.ets')).length, 1);
  assert.deepEqual(plan.definition.requestPermissions, [{ name: 'ohos.permission.INTERNET' }]);
  assert.equal(await readFile(join(fixture.root, 'mysql', 'Index.ets'), 'utf8'), before);
});
