import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  affectedDrivers, discoverDrivers, downloadOutputPaths, driverArgument, driverForTag, packageStem,
  resolveDriver, tagOutputPaths, ROOT
} from './driver-packages.mjs';

test('only the implemented MySQL driver is discoverable in this repository', () => {
  assert.deepEqual(discoverDrivers().map((driver) => driver.id), ['mysql']);
  assert.equal(resolveDriver().sourcePath, 'mysql');
  assert.equal(resolveDriver(ROOT, 'mysql').directory, join(ROOT, 'mysql'));
  assert.throws(() => resolveDriver(ROOT, 'pgsql'), /not implemented\/registered/);
});

test('future registered HARs are selected by their actual source path, not MySQL assumptions', async (t) => {
  const root = await fixture(t);
  const drivers = discoverDrivers(root);
  assert.deepEqual(drivers.map((driver) => driver.id), ['mysql', 'pgsql']);
  assert.equal(drivers[1].sourcePath, 'drivers/pgsql');
  assert.equal(drivers[1].artifact, 'arkdb-postgres-2.0.0');
  assert.deepEqual(affectedDrivers(drivers, ['drivers/pgsql/src/main/ets/Query.ets']).map((driver) => driver.id), ['pgsql']);
  assert.deepEqual(affectedDrivers(drivers, ['mysql/README.md']).map((driver) => driver.id), ['mysql']);
  assert.deepEqual(affectedDrivers(drivers, ['docs/releasing.md']), []);
  assert.deepEqual(affectedDrivers(drivers, ['tools/package-har.mjs']), drivers);
  assert.deepEqual(affectedDrivers(drivers, ['AppScope/app.json5']), drivers);
  assert.deepEqual(affectedDrivers(drivers, ['examples/mysql-client/entry/oh-package.json5']), drivers);
  assert.deepEqual(affectedDrivers(drivers, ['drivers/pgsql-other/source.ets']), []);
});

test('tag selection pins exactly one implemented package version', async (t) => {
  const drivers = discoverDrivers(await fixture(t));
  assert.equal(driverForTag(drivers, 'pgsql-v2.0.0').packageName, '@arkdb/postgres');
  for (const tag of ['v1.0.0', 'pgsql-v1.0.0', 'unknown-v1.0.0', 'mysql-v1.0.0-preview']) {
    assert.throws(() => driverForTag(drivers, tag), /tag/);
  }
});

test('rejects unsafe selectors and manifest-derived artifact names', () => {
  for (const value of ['../mysql', 'mysql@default', 'C:\\mysql', 'mysql;echo', 'all']) {
    assert.throws(() => driverArgument(['--driver', value]));
  }
  assert.equal(driverArgument([]), 'mysql');
  assert.equal(driverArgument(['--driver', 'pgsql']), 'pgsql');
  assert.throws(() => packageStem({ name: '@arkdb/../../private', version: '1.0.0' }));
  for (const version of ['1.0.0-local', '1.0.0-pr123', '1.0.0-preview', '1.0.0+build']) {
    assert.throws(() => packageStem({ name: '@arkdb/mysql', version }));
  }
});

test('release and receipt paths follow the requested tag rather than the current source version', async (t) => {
  const root = await fixture(t);
  const paths = tagOutputPaths(root, 'mysql', 'mysql-v1.0.1');
  assert.equal(paths.ready, join(root, 'dist', 'mysql-v1.0.1'));
  assert.equal(paths.publicationRecord,
    join(root, 'build', 'mysql-v1.0.1', 'evidence', 'mysql-v1.0.1.publication.json'));
  assert.deepEqual(downloadOutputPaths(root, 'mysql', 'mysql-v1.0.1'), {
    directory: join(root, 'build', 'mysql-v1.0.1', 'work'),
    record: join(root, 'build', 'mysql-v1.0.1', 'evidence', 'mysql-v1.0.1.download.json')
  });
  for (const tag of ['mysql-v1.0.1-local', 'pgsql-v1.0.1', '..\\mysql-v1.0.1']) {
    assert.throws(() => tagOutputPaths(root, 'mysql', tag), /matching.*tag/i);
  }
});

test('registered modules cannot escape the checkout or use linked source directories', async (t) => {
  const root = await fixture(t);
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify({
    modules: [{ name: 'mysql', srcPath: '../outside' }]
  }));
  assert.throws(() => resolveDriver(root, 'mysql'), /inside the repository/);
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify({
    modules: [{ name: 'alias', srcPath: './alias' }]
  }));
  await symlink(join(root, 'mysql'), join(root, 'alias'), process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => resolveDriver(root, 'alias'), /not links/);
});

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-drivers-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify({ modules: [
    { name: 'mysql', srcPath: './mysql' }, { name: 'pgsql', srcPath: './drivers/pgsql' }
  ] }));
  for (const [directory, id, name, version] of [
    ['mysql', 'mysql', '@arkdb/mysql', '1.0.0'],
    ['drivers\\pgsql', 'pgsql', '@arkdb/postgres', '2.0.0']
  ]) {
    const moduleRoot = join(root, ...directory.split('\\'));
    await mkdir(join(moduleRoot, 'src', 'main'), { recursive: true });
    await writeFile(join(moduleRoot, 'src', 'main', 'module.json5'), JSON.stringify({ module: { name: id, type: 'har' } }));
    await writeFile(join(moduleRoot, 'oh-package.json5'), JSON.stringify({ name, version }));
    await writeFile(join(moduleRoot, 'arkdb-package.json'), '{"kind":"driver"}');
  }
  return root;
}
