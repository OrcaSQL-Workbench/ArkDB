import assert from 'node:assert/strict';
import test from 'node:test';
import { changedPaths, selectBuilds } from './plan-har-builds.mjs';

const drivers = [
  { id: 'mysql', sourcePath: 'mysql', packageName: '@arkdb/mysql', version: '1.0.0', artifact: 'arkdb-mysql-1.0.0' },
  { id: 'pgsql', sourcePath: 'drivers/pgsql', packageName: '@arkdb/postgres', version: '2.0.0', artifact: 'arkdb-postgres-2.0.0' }
];

test('manual builds accept all or one actual registered driver', () => {
  assert.equal(selectBuilds(drivers).include.length, 2);
  assert.deepEqual(selectBuilds(drivers, { driver: 'mysql' }).include.map((entry) => entry.driver), ['mysql']);
  assert.throws(() => selectBuilds(drivers, { driver: 'mysql;echo injected' }), /not implemented/);
});

test('push/PR builds follow driver directories and shared build changes', () => {
  assert.deepEqual(selectBuilds(drivers, { event: 'push', paths: ['mysql/src/main/ets/Query.ets'] })
    .include.map((entry) => entry.driver), ['mysql']);
  assert.deepEqual(selectBuilds(drivers, { event: 'pull_request', paths: ['drivers/pgsql/README.md'] })
    .include.map((entry) => entry.driver), ['pgsql']);
  assert.equal(selectBuilds(drivers, { event: 'push', paths: ['tools/package-har.mjs'] }).include.length, 2);
  assert.deepEqual(selectBuilds(drivers, { event: 'push', paths: ['docs/releasing.md'] }).include, []);
  assert.equal(selectBuilds(drivers, { event: 'push', paths: null }).include.length, 2);
});

test('a driver tag builds only the matching versioned package', () => {
  assert.deepEqual(selectBuilds(drivers, { event: 'push', ref: 'refs/tags/pgsql-v2.0.0' })
    .include.map((entry) => entry.driver), ['pgsql']);
  assert.throws(() => selectBuilds(drivers, { event: 'push', ref: 'refs/tags/pgsql-v1.0.0' }), /match/);
});

test('event base commits are passed to Git as data, never interpolated into a shell', () => {
  const base = 'a'.repeat(40);
  const calls = [];
  const paths = changedPaths('push', { before: base }, (args) => {
    calls.push(args);
    return args[0] === 'diff' ? 'mysql/README.md\0mysql/src/main/ets/File with spaces.ets\0' : '';
  });
  assert.deepEqual(paths, ['mysql/README.md', 'mysql/src/main/ets/File with spaces.ets']);
  assert.deepEqual(calls, [
    ['cat-file', '-e', `${base}^{commit}`],
    ['diff', '--name-only', '-z', `${base}...HEAD`, '--']
  ]);
  assert.equal(changedPaths('push', { before: '0'.repeat(40) }, () => assert.fail()), null);
  assert.throws(() => changedPaths('push', { before: '--malicious' }, () => assert.fail()), /explicit event base/);
});
