import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import ts from 'typescript';
import { ROOT } from './check-package.mjs';

const FIXTURE_PATH = join(ROOT, 'tools', 'test-fixtures', 'mysql-v1.0.2-public-api.json');
const RELEASE_TAG = 'mysql-v1.0.2';
const SOURCE_COMMIT = 'f532d0c37adf4dbba7a1a313679f0024822ed752';
const HAR_SHA256 = '8974e3bda9415fda26036b7b5b7d335a2c8f901ceda74381d1e657362c093986';
const PACKAGE_ROOT_EXPORTS_SHA256 = '47d7d77ef98de298946d2d84b6633082658a964cd9c77b80ea485d15c0873254';

test('rejects a published value export demoted to a type-only export', () => {
  const published = [{ name: 'PublishedFactory', kind: 'value' }];
  const current = packageRootExports(
    "export type { PublishedFactory } from './PublishedFactory';\n");
  assert.throws(() => assertPublishedExportsRetained(published, current),
    /PublishedFactory \(value -> type\)/);
});

test('ignores export-looking text in comments and strings', () => {
  assert.deepEqual(packageRootExports(`
    // export { CommentGhost } from './CommentGhost';
    const text = "export type { StringGhost } from './StringGhost';";
    export { RealFactory } from './RealFactory';
  `), [{ name: 'RealFactory', kind: 'value' }]);
});

test('pins the immutable mysql-v1.0.2 package identity', () => {
  const fixture = readFixture();
  assert.deepEqual(Object.keys(fixture).sort(),
    ['harSha256', 'packageRootExports', 'releaseTag', 'sourceCommit']);
  assert.equal(fixture.releaseTag, RELEASE_TAG);
  assert.match(fixture.releaseTag, /^mysql-v\d+\.\d+\.\d+$/);
  assert.equal(fixture.sourceCommit, SOURCE_COMMIT);
  assert.match(fixture.sourceCommit, /^[0-9a-f]{40}$/);
  assert.equal(fixture.harSha256, HAR_SHA256);
  assert.match(fixture.harSha256, /^[0-9a-f]{64}$/);
  assert.ok(Array.isArray(fixture.packageRootExports));
  assert.equal(fixture.packageRootExports.length, 111);
  assert.deepEqual(fixture.packageRootExports, [...fixture.packageRootExports].sort(compareExports));
  assert.equal(new Set(fixture.packageRootExports.map((entry) => entry.name)).size,
    fixture.packageRootExports.length);
  assert.equal(createHash('sha256').update(JSON.stringify(fixture.packageRootExports)).digest('hex'),
    PACKAGE_ROOT_EXPORTS_SHA256);
  assert.equal(fixture.packageRootExports.filter((entry) => entry.kind === 'value').length, 89);
  assert.equal(fixture.packageRootExports.filter((entry) => entry.kind === 'type').length, 22);
  for (const entry of fixture.packageRootExports) {
    assert.deepEqual(Object.keys(entry).sort(), ['kind', 'name']);
    assert.match(entry.name, /^[A-Za-z_$][\w$]*$/);
    assert.match(entry.kind, /^(?:type|value)$/);
  }
});

test('retains every mysql-v1.0.2 package-root export', () => {
  const fixture = readFixture();
  const current = packageRootExports(
    readFileSync(join(ROOT, 'mysql', 'Index.ets'), 'utf8'), 'mysql/Index.ets');
  assertPublishedExportsRetained(fixture.packageRootExports, current);
});

function readFixture() {
  return JSON.parse(readFileSync(FIXTURE_PATH, 'utf8'));
}

function packageRootExports(source, file = 'Index.ets') {
  const syntax = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  if (syntax.parseDiagnostics.length > 0) {
    throw new Error(`Cannot parse package-root exports in ${file}.`);
  }
  const exports = [];
  for (const statement of syntax.statements) {
    if (!ts.isExportDeclaration(statement) || statement.exportClause === undefined ||
      !ts.isNamedExports(statement.exportClause)) {
      continue;
    }
    for (const element of statement.exportClause.elements) {
      exports.push({
        name: element.name.text,
        kind: statement.isTypeOnly || element.isTypeOnly ? 'type' : 'value'
      });
    }
  }
  exports.sort(compareExports);
  for (let index = 1; index < exports.length; index++) {
    if (exports[index - 1].name === exports[index].name) {
      throw new Error(`Duplicate package-root export: ${exports[index].name}`);
    }
  }
  return exports;
}

function assertPublishedExportsRetained(published, current) {
  const currentByName = new Map(current.map((entry) => [entry.name, entry.kind]));
  const incompatible = [];
  for (const expected of published) {
    const actualKind = currentByName.get(expected.name);
    if (actualKind === undefined) incompatible.push(`${expected.name} (${expected.kind} missing)`);
    else if (actualKind !== expected.kind) {
      incompatible.push(`${expected.name} (${expected.kind} -> ${actualKind})`);
    }
  }
  assert.deepEqual(incompatible, [],
    `Missing or kind-incompatible published @arkdb/mysql exports: ${incompatible.join(', ')}`);
}

function compareExports(left, right) {
  if (left.name < right.name) return -1;
  if (left.name > right.name) return 1;
  if (left.kind < right.kind) return -1;
  if (left.kind > right.kind) return 1;
  return 0;
}
