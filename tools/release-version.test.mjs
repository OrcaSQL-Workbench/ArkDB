import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import {
  dependencyClosure, localOutputPaths, resolveDriver, ROOT
} from './workspace/driver-packages.mjs';

const MYSQL_VERSION = '1.1.0';
const CORE_VERSION = '1.1.0';

test('selects the 1.1.0 MySQL release with its exact core source dependency', () => {
  const driver = resolveDriver(ROOT, 'mysql');
  const closure = dependencyClosure(ROOT, 'mysql');
  const paths = localOutputPaths(ROOT, 'mysql');

  assert.equal(driver.version, MYSQL_VERSION);
  assert.equal(driver.manifest.dependencies['@arkdb/core'], CORE_VERSION);
  assert.deepEqual(closure.map((entry) => [entry.packageName, entry.version]), [
    ['@arkdb/core', CORE_VERSION],
    ['@arkdb/mysql', MYSQL_VERSION]
  ]);
  assert.equal(paths.tag, `mysql-v${MYSQL_VERSION}`);
  assert.equal(paths.ready, join(ROOT, 'dist', `mysql-v${MYSQL_VERSION}`));
});

test('keeps the published 1.0.2 compatibility baseline immutable', () => {
  const fixture = JSON.parse(readFileSync(
    join(ROOT, 'tools', 'test-fixtures', 'mysql-v1.0.2-public-api.json'), 'utf8'));

  assert.equal(fixture.releaseTag, 'mysql-v1.0.2');
  assert.equal(fixture.sourceCommit, 'f532d0c37adf4dbba7a1a313679f0024822ed752');
  assert.equal(fixture.harSha256,
    '8974e3bda9415fda26036b7b5b7d335a2c8f901ceda74381d1e657362c093986');
  assert.equal(fixture.packageRootExports.length, 111);
});
