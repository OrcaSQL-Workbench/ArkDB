import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, posix, resolve } from 'node:path';
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
  const barrel = "export type { PublishedFactory } from './PublishedFactory';\n";
  const current = packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['PublishedFactory.ets', 'export class PublishedFactory {}\n']
  ]));
  assert.throws(() => assertPublishedExportsRetained(published, current),
    /PublishedFactory \(value -> type\)/);
});

test('rejects an unchanged value re-export when its declaration becomes type-only', () => {
  const barrel = "export { PublishedFactory as PublicFactory } from './Alias';\n";
  const alias = "export { PublishedFactory } from './PublishedFactory';\n";
  const publishedFiles = new Map([
    ['Index.ets', barrel],
    ['Alias.ets', alias],
    ['PublishedFactory.ets', 'export class PublishedFactory {}\n']
  ]);
  const currentFiles = new Map([
    ['Index.ets', barrel],
    ['Alias.ets', alias],
    ['PublishedFactory.ets', 'export interface PublishedFactory {}\n']
  ]);
  const published = packageRootExports(barrel, 'Index.ets', publishedFiles);
  const current = packageRootExports(barrel, 'Index.ets', currentFiles);
  assert.deepEqual(published, [{ name: 'PublicFactory', kind: 'value' }]);
  assert.throws(() => assertPublishedExportsRetained(published, current),
    /PublicFactory \(value -> type\)/);
});

test('rejects a value re-export routed through a type-only star export', () => {
  const barrel = "export { PublishedFactory } from './Alias';\n";
  const publishedFiles = new Map([
    ['Index.ets', barrel],
    ['Alias.ets', "export * from './PublishedFactory';\n"],
    ['PublishedFactory.ets', 'export class PublishedFactory {}\n']
  ]);
  const currentFiles = new Map([
    ['Index.ets', barrel],
    ['Alias.ets', "export type * from './PublishedFactory';\n"],
    ['PublishedFactory.ets', 'export class PublishedFactory {}\n']
  ]);
  const published = packageRootExports(barrel, 'Index.ets', publishedFiles);
  const current = packageRootExports(barrel, 'Index.ets', currentFiles);
  assert.throws(() => assertPublishedExportsRetained(published, current),
    /PublishedFactory \(value -> type\)/);
});

test('gives explicit type exports precedence over value star exports', () => {
  const barrel = "export { PublishedFactory } from './Alias';\n";
  const publishedFiles = new Map([
    ['Index.ets', barrel],
    ['Alias.ets', "export { PublishedFactory } from './Values';\n"],
    ['Values.ets', 'export class PublishedFactory {}\n']
  ]);
  const currentFiles = new Map([
    ['Index.ets', barrel],
    ['Alias.ets', "export type { PublishedFactory } from './Types';\n" +
      "export * from './Values';\n"],
    ['Types.ets', 'export interface PublishedFactory {}\n'],
    ['Values.ets', 'export class PublishedFactory {}\n']
  ]);
  const published = packageRootExports(barrel, 'Index.ets', publishedFiles);
  const current = packageRootExports(barrel, 'Index.ets', currentFiles);
  assert.throws(() => assertPublishedExportsRetained(published, current),
    /PublishedFactory \(value -> type\)/);
});

test('rejects a type-only re-export when its target declaration is missing', () => {
  const barrel = "export type { PublishedType } from './Types';\n";
  assert.throws(() => packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['Types.ets', 'export interface DifferentType {}\n']
  ])), /Cannot resolve exported declaration PublishedType/);
});

test('resolves a named alias of a default value export', () => {
  const barrel = "export { default as PublicFactory } from './Factory';\n";
  assert.deepEqual(packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['Factory.ets', 'export default class PublishedFactory {}\n']
  ])), [{ name: 'PublicFactory', kind: 'value' }]);
});

test('does not resolve default or ambiguous bindings through star exports', () => {
  const defaultBarrel = "export { default as PublicFactory } from './Alias';\n";
  assert.throws(() => packageRootExports(defaultBarrel, 'Index.ets', new Map([
    ['Index.ets', defaultBarrel],
    ['Alias.ets', "export * from './Factory';\n"],
    ['Factory.ets', 'export default class PublishedFactory {}\n']
  ])), /Cannot resolve exported declaration default/);

  const ambiguousBarrel = "export { PublishedFactory } from './Alias';\n";
  assert.throws(() => packageRootExports(ambiguousBarrel, 'Index.ets', new Map([
    ['Index.ets', ambiguousBarrel],
    ['Alias.ets', "export * from './First';\nexport * from './Second';\n"],
    ['First.ets', 'export class PublishedFactory {}\n'],
    ['Second.ets', 'export class PublishedFactory {}\n']
  ])), /Ambiguous package-root star export: PublishedFactory/);
});

test('collapses star diamonds that resolve to the same binding', () => {
  const files = new Map([
    ['Diamond.ets', "export * from './First';\nexport * from './Second';\n"],
    ['First.ets', "export { PublishedFactory } from './Common';\n"],
    ['Second.ets', "export { PublishedFactory } from './Common';\n"],
    ['Common.ets', 'export class PublishedFactory {}\n']
  ]);
  const namedBarrel = "export { PublishedFactory } from './Diamond';\n";
  assert.deepEqual(packageRootExports(namedBarrel, 'Index.ets', new Map([
    ['Index.ets', namedBarrel],
    ...files
  ])), [{ name: 'PublishedFactory', kind: 'value' }]);

  const starBarrel = "export * from './Diamond';\n";
  assert.deepEqual(packageRootExports(starBarrel, 'Index.ets', new Map([
    ['Index.ets', starBarrel],
    ...files
  ])), [{ name: 'PublishedFactory', kind: 'value' }]);
});

test('resolves cyclic star barrels through their non-cyclic exports', () => {
  const barrel = "export * from './Other';\nexport class FirstFactory {}\n";
  assert.deepEqual(packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['Other.ets', "export * from './Index';\nexport class SecondFactory {}\n"]
  ])), [
    { name: 'FirstFactory', kind: 'value' },
    { name: 'SecondFactory', kind: 'value' }
  ]);
});

test('collapses default and named paths to the same declaration', () => {
  const barrel = "export * from './Diamond';\n";
  assert.deepEqual(packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['Diamond.ets', "export * from './DefaultPath';\nexport * from './NamedPath';\n"],
    ['DefaultPath.ets', "export { default as PublishedFactory } from './Common';\n"],
    ['NamedPath.ets', "export { PublishedFactory } from './Common';\n"],
    ['Common.ets', 'export default class PublishedFactory {}\nexport { PublishedFactory };\n']
  ])), [{ name: 'PublishedFactory', kind: 'value' }]);
});

test('keeps identifier-default and named paths as distinct bindings', () => {
  const barrel = "export * from './Diamond';\n";
  assert.throws(() => packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['Diamond.ets', "export * from './DefaultPath';\nexport * from './NamedPath';\n"],
    ['DefaultPath.ets', "export { default as PublicApi } from './Common';\n"],
    ['NamedPath.ets', "export { api as PublicApi } from './Common';\n"],
    ['Common.ets', 'export namespace api {}\nexport default api;\n']
  ])), /Duplicate package-root star export: PublicApi/);
});

test('discovers direct and inherited namespace exports', () => {
  const namespace = "export * as PublicApi from './Api';\n";
  const files = new Map([
    ['Namespace.ets', namespace],
    ['Api.ets', 'export class ApiClient {}\n']
  ]);
  assert.deepEqual(packageRootExports(namespace, 'Index.ets', new Map([
    ['Index.ets', namespace],
    ['Api.ets', 'export class ApiClient {}\n']
  ])), [{ name: 'PublicApi', kind: 'value' }]);

  const inherited = "export * from './Namespace';\n";
  assert.deepEqual(packageRootExports(inherited, 'Index.ets', new Map([
    ['Index.ets', inherited],
    ...files
  ])), [{ name: 'PublicApi', kind: 'value' }]);
});

test('does not inherit namespace default exports through star barrels', () => {
  const barrel = "export * from './First';\nexport * from './Second';\n";
  assert.deepEqual(packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['First.ets', "export * as default from './Api';\n"],
    ['Second.ets', "export * as default from './Api';\n"],
    ['Api.ets', 'export class ApiClient {}\n']
  ])), []);
});

test('collapses root function overloads into one value export', () => {
  const barrel = `
    export function parseValue(value: string): string;
    export function parseValue(value: number): number;
    export function parseValue(value: string | number): string | number { return value; }
  `;
  assert.deepEqual(packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel]
  ])), [{ name: 'parseValue', kind: 'value' }]);
});

test('rejects duplicate explicit exports from distinct declarations', () => {
  const barrel = "export { PublishedFactory } from './Alias';\n";
  assert.throws(() => packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['Alias.ets', "export { PublishedFactory } from './First';\n" +
      "export { PublishedFactory } from './Second';\n"],
    ['First.ets', 'export class PublishedFactory {}\n'],
    ['Second.ets', 'export class PublishedFactory {}\n']
  ])), /Ambiguous explicit package-root export: PublishedFactory/);
});

test('excludes an explicitly named default from package-root enumeration', () => {
  const barrel = "export { default } from './Factory';\n";
  assert.deepEqual(packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['Factory.ets', 'export default class PublishedFactory {}\n']
  ])), []);
});

test('validates local imported bindings before type-only coercion', () => {
  const missingType = "import type { Missing } from './Types';\nexport type { Missing };\n";
  assert.throws(() => packageRootExports(missingType, 'Index.ets', new Map([
    ['Index.ets', missingType],
    ['Types.ets', 'export interface DifferentType {}\n']
  ])), /Cannot resolve local exported declaration Missing/);

  const missingNamespace = "import * as MissingNamespace from './Missing';\n" +
    'export { MissingNamespace };\n';
  assert.throws(() => packageRootExports(missingNamespace, 'Index.ets', new Map([
    ['Index.ets', missingNamespace]
  ])), /Cannot resolve package-root export source: \.\/Missing/);
});

test('discovers direct, value-star and type-star root exports', () => {
  const direct = 'export class DirectFactory {}\n';
  assert.deepEqual(packageRootExports(direct, 'Index.ets', new Map([
    ['Index.ets', direct]
  ])), [{ name: 'DirectFactory', kind: 'value' }]);

  const valueStar = "export * from './ValueFactory';\n";
  assert.deepEqual(packageRootExports(valueStar, 'Index.ets', new Map([
    ['Index.ets', valueStar],
    ['ValueFactory.ets', 'export class ValueFactory {}\n']
  ])), [{ name: 'ValueFactory', kind: 'value' }]);

  const typeStar = "export type * from './TypeFactory';\n";
  assert.deepEqual(packageRootExports(typeStar, 'Index.ets', new Map([
    ['Index.ets', typeStar],
    ['TypeFactory.ets', 'export interface TypeFactory {}\n']
  ])), [{ name: 'TypeFactory', kind: 'type' }]);
});

test('resolves directory exports through Index.ets', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'arkdb-v102-export-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const entry = join(directory, 'Index.ets');
  const barrel = "export { DirectoryFactory } from './factory';\n";
  await mkdir(join(directory, 'factory'));
  await writeFile(entry, barrel);
  await writeFile(join(directory, 'factory', 'Index.ets'),
    'export class DirectoryFactory {}\n');
  assert.deepEqual(packageRootExports(barrel, entry),
    [{ name: 'DirectoryFactory', kind: 'value' }]);
});

test('ignores export-looking text in comments and strings', () => {
  const barrel = `
    // export { CommentGhost } from './CommentGhost';
    const text = "export type { StringGhost } from './StringGhost';";
    export { RealFactory } from './RealFactory';
  `;
  assert.deepEqual(packageRootExports(barrel, 'Index.ets', new Map([
    ['Index.ets', barrel],
    ['RealFactory.ets', 'export class RealFactory {}\n']
  ])), [{ name: 'RealFactory', kind: 'value' }]);
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

function packageRootExports(source, file = 'Index.ets', virtualFiles) {
  const resolver = exportResolver(file, source, virtualFiles);
  const exports = resolver.exportsOf(resolver.root);
  for (let index = 1; index < exports.length; index++) {
    if (exports[index - 1].name === exports[index].name) {
      throw new Error(`Duplicate package-root export: ${exports[index].name}`);
    }
  }
  return exports;
}

function exportResolver(rootFile, rootSource, virtualFiles) {
  const virtual = virtualFiles !== undefined;
  const texts = new Map();
  const syntaxCache = new Map();
  const normalize = virtual ? normalizeVirtualPath :
    (file) => isAbsolute(file) ? resolve(file) : resolve(ROOT, file);
  if (virtual) {
    for (const [file, source] of virtualFiles) texts.set(normalize(file), source);
  }
  const root = normalize(rootFile);
  texts.set(root, rootSource);

  function source(file) {
    const normalized = normalize(file);
    if (texts.has(normalized)) return texts.get(normalized);
    if (virtual || !existsSync(normalized)) {
      throw new Error(`Cannot resolve exported source file: ${normalized}`);
    }
    const value = readFileSync(normalized, 'utf8');
    texts.set(normalized, value);
    return value;
  }

  function syntax(file) {
    const normalized = normalize(file);
    if (syntaxCache.has(normalized)) return syntaxCache.get(normalized);
    const parsed = ts.createSourceFile(
      normalized, source(normalized), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    if (parsed.parseDiagnostics.length > 0) {
      throw new Error(`Cannot parse package-root exports in ${normalized}.`);
    }
    syntaxCache.set(normalized, parsed);
    return parsed;
  }

  function moduleFile(file, specifier) {
    let base;
    if (virtual) {
      if (!specifier.startsWith('.')) {
        throw new Error(`Unsupported virtual package export: ${specifier}`);
      }
      base = normalize(posix.join(posix.dirname(normalize(file)), specifier));
    } else if (specifier === '@arkdb/core') {
      base = resolve(ROOT, 'core', 'Index.ets');
    } else if (specifier === '@arkdb/mysql') {
      base = resolve(ROOT, 'mysql', 'Index.ets');
    } else if (specifier.startsWith('.')) {
      base = resolve(dirname(normalize(file)), specifier);
    } else {
      throw new Error(`Unsupported package-root export source: ${specifier}`);
    }
    const candidates = [base, `${base}.ets`, `${base}.d.ets`, join(base, 'Index.ets')];
    for (const candidate of candidates) {
      const normalized = normalize(candidate);
      if (texts.has(normalized) ||
        (!virtual && existsSync(normalized) && statSync(normalized).isFile())) {
        return normalized;
      }
    }
    throw new Error(`Cannot resolve package-root export source: ${specifier} from ${file}`);
  }

  function elementKind(file, declaration, element, seen = new Set()) {
    const typeOnly = declaration.isTypeOnly || element.isTypeOnly;
    const localName = element.propertyName?.text ?? element.name.text;
    let kind;
    if (declaration.moduleSpecifier !== undefined) {
      if (!ts.isStringLiteral(declaration.moduleSpecifier)) {
        throw new Error(`Unsupported package-root export source in ${file}.`);
      }
      kind = exportedKind(
        moduleFile(file, declaration.moduleSpecifier.text), localName, seen);
      if (kind === undefined) {
        throw new Error(`Cannot resolve exported declaration ${localName} from ${file}.`);
      }
    } else {
      kind = localKind(file, localName, seen);
      if (kind === undefined) {
        throw new Error(`Cannot resolve local exported declaration ${localName} in ${file}.`);
      }
    }
    return typeOnly ? 'type' : kind;
  }

  function elementOrigin(file, declaration, element, seen = new Set()) {
    const localName = element.propertyName?.text ?? element.name.text;
    let origin;
    if (declaration.moduleSpecifier !== undefined) {
      if (!ts.isStringLiteral(declaration.moduleSpecifier)) {
        throw new Error(`Unsupported package-root export source in ${file}.`);
      }
      origin = exportedOrigin(
        moduleFile(file, declaration.moduleSpecifier.text), localName, seen);
      if (origin === undefined) {
        throw new Error(`Cannot resolve exported declaration ${localName} from ${file}.`);
      }
    } else {
      origin = localOrigin(file, localName, seen);
      if (origin === undefined) {
        throw new Error(`Cannot resolve local exported declaration ${localName} in ${file}.`);
      }
    }
    return origin;
  }

  function exportedOrigin(file, name, seen) {
    const normalized = normalize(file);
    const key = `${normalized}\0${name}`;
    if (seen.has(key)) return undefined;
    seen.add(key);
    try {
      const explicitOrigins = directDeclarationOrigins(
        syntax(normalized).statements, name, true, normalized);
      for (const statement of syntax(normalized).statements) {
        if (!ts.isExportDeclaration(statement) || statement.exportClause === undefined) {
          continue;
        }
        if (ts.isNamedExports(statement.exportClause)) {
          for (const element of statement.exportClause.elements) {
            if (element.name.text === name) {
              explicitOrigins.push(elementOrigin(normalized, statement, element, seen));
            }
          }
        } else if (ts.isNamespaceExport(statement.exportClause) &&
          statement.exportClause.name.text === name &&
          statement.moduleSpecifier !== undefined && ts.isStringLiteral(statement.moduleSpecifier)) {
          explicitOrigins.push(`namespace:${moduleFile(normalized, statement.moduleSpecifier.text)}`);
        }
      }
      if (explicitOrigins.length > 0) {
        return uniqueOrigin(explicitOrigins, `Ambiguous explicit package-root export: ${name}`);
      }
      if (name === 'default') return undefined;
      const starOrigins = [];
      for (const statement of syntax(normalized).statements) {
        if (ts.isExportDeclaration(statement) && statement.exportClause === undefined &&
          statement.moduleSpecifier !== undefined && ts.isStringLiteral(statement.moduleSpecifier)) {
          const origin = exportedOrigin(
            moduleFile(normalized, statement.moduleSpecifier.text), name, seen);
          if (origin !== undefined) starOrigins.push(origin);
        }
      }
      return uniqueOrigin(starOrigins, `Ambiguous package-root star export: ${name}`);
    } finally {
      seen.delete(key);
    }
  }

  function exportedKind(file, name, seen) {
    const normalized = normalize(file);
    const key = `${normalized}\0${name}`;
    if (seen.has(key)) return undefined;
    seen.add(key);
    try {
      const explicitKinds = directDeclarationKinds(syntax(normalized).statements, name, true);
      for (const statement of syntax(normalized).statements) {
        if (!ts.isExportDeclaration(statement)) continue;
        if (statement.exportClause !== undefined && ts.isNamedExports(statement.exportClause)) {
          for (const element of statement.exportClause.elements) {
            if (element.name.text === name) {
              explicitKinds.push(elementKind(normalized, statement, element, seen));
            }
          }
        } else if (statement.exportClause !== undefined &&
          ts.isNamespaceExport(statement.exportClause) &&
          statement.exportClause.name.text === name &&
          statement.moduleSpecifier !== undefined && ts.isStringLiteral(statement.moduleSpecifier)) {
          moduleFile(normalized, statement.moduleSpecifier.text);
          explicitKinds.push(statement.isTypeOnly ? 'type' : 'value');
        }
      }
      if (explicitKinds.length > 0) {
        const origin = exportedOrigin(normalized, name, new Set());
        if (origin === undefined) return undefined;
        return strongestKind(explicitKinds);
      }
      if (name === 'default') return undefined;
      const origin = exportedOrigin(normalized, name, new Set());
      if (origin === undefined) return undefined;
      const starKinds = [];
      for (const statement of syntax(normalized).statements) {
        if (ts.isExportDeclaration(statement) && statement.exportClause === undefined &&
          statement.moduleSpecifier !== undefined &&
          ts.isStringLiteral(statement.moduleSpecifier)) {
          const target = moduleFile(normalized, statement.moduleSpecifier.text);
          const kind = exportedKind(target, name, seen);
          if (kind !== undefined) starKinds.push(statement.isTypeOnly ? 'type' : kind);
        }
      }
      return strongestKind(starKinds);
    } finally {
      seen.delete(key);
    }
  }

  function localKind(file, name, seen) {
    const statements = syntax(file).statements;
    const kinds = directDeclarationKinds(statements, name, false);
    for (const statement of statements) {
      if (!ts.isImportDeclaration(statement) || statement.importClause === undefined ||
        statement.moduleSpecifier === undefined || !ts.isStringLiteral(statement.moduleSpecifier)) {
        continue;
      }
      const clause = statement.importClause;
      if (clause.name?.text === name) {
        const target = moduleFile(file, statement.moduleSpecifier.text);
        const importedKind = exportedKind(target, 'default', seen);
        if (importedKind !== undefined) kinds.push(clause.isTypeOnly ? 'type' : importedKind);
      }
      if (clause.namedBindings !== undefined && ts.isNamedImports(clause.namedBindings)) {
        for (const element of clause.namedBindings.elements) {
          if (element.name.text !== name) continue;
          const target = moduleFile(file, statement.moduleSpecifier.text);
          const importedName = element.propertyName?.text ?? element.name.text;
          const importedKind = exportedKind(target, importedName, seen);
          if (importedKind !== undefined) {
            kinds.push(clause.isTypeOnly || element.isTypeOnly ? 'type' : importedKind);
          }
        }
      } else if (clause.namedBindings !== undefined &&
        ts.isNamespaceImport(clause.namedBindings) && clause.namedBindings.name.text === name) {
        moduleFile(file, statement.moduleSpecifier.text);
        kinds.push(clause.isTypeOnly ? 'type' : 'value');
      }
    }
    return strongestKind(kinds);
  }

  function localOrigin(file, name, seen) {
    const statements = syntax(file).statements;
    const origins = directDeclarationOrigins(statements, name, false, normalize(file));
    for (const statement of statements) {
      if (!ts.isImportDeclaration(statement) || statement.importClause === undefined ||
        statement.moduleSpecifier === undefined || !ts.isStringLiteral(statement.moduleSpecifier)) {
        continue;
      }
      const clause = statement.importClause;
      if (clause.name?.text === name) {
        const target = moduleFile(file, statement.moduleSpecifier.text);
        const origin = exportedOrigin(target, 'default', seen);
        if (origin !== undefined) origins.push(origin);
      }
      if (clause.namedBindings !== undefined && ts.isNamedImports(clause.namedBindings)) {
        for (const element of clause.namedBindings.elements) {
          if (element.name.text !== name) continue;
          const target = moduleFile(file, statement.moduleSpecifier.text);
          const importedName = element.propertyName?.text ?? element.name.text;
          const origin = exportedOrigin(target, importedName, seen);
          if (origin !== undefined) origins.push(origin);
        }
      } else if (clause.namedBindings !== undefined &&
        ts.isNamespaceImport(clause.namedBindings) && clause.namedBindings.name.text === name) {
        origins.push(`namespace:${moduleFile(file, statement.moduleSpecifier.text)}`);
      }
    }
    return uniqueOrigin(origins, `Ambiguous local package-root export: ${name}`);
  }

  function exportsOf(file, seen = new Set()) {
    const normalized = normalize(file);
    if (seen.has(normalized)) return [];
    seen.add(normalized);
    try {
      const statements = syntax(normalized).statements;
      const explicit = collapseDirectEntries(statements.flatMap((statement) =>
        directDeclarationEntries(statement, true)
          .filter((entry) => entry.name !== 'default')));
      const stars = [];
      for (const statement of statements) {
        if (!ts.isExportDeclaration(statement)) continue;
        if (statement.exportClause !== undefined && ts.isNamedExports(statement.exportClause)) {
          for (const element of statement.exportClause.elements) {
            if (element.name.text !== 'default') {
              explicit.push({
                name: element.name.text,
                kind: elementKind(normalized, statement, element)
              });
            }
          }
        } else if (statement.exportClause !== undefined &&
          ts.isNamespaceExport(statement.exportClause) &&
          statement.moduleSpecifier !== undefined && ts.isStringLiteral(statement.moduleSpecifier)) {
          moduleFile(normalized, statement.moduleSpecifier.text);
          if (statement.exportClause.name.text !== 'default') {
            explicit.push({
              name: statement.exportClause.name.text,
              kind: statement.isTypeOnly ? 'type' : 'value'
            });
          }
        } else if (statement.exportClause === undefined && statement.moduleSpecifier !== undefined &&
          ts.isStringLiteral(statement.moduleSpecifier)) {
          stars.push(statement);
        }
      }
      const explicitNames = new Set(explicit.map((entry) => entry.name));
      const inherited = new Map();
      for (const statement of stars) {
        const target = moduleFile(normalized, statement.moduleSpecifier.text);
        for (const entry of exportsOf(target, seen)) {
          if (explicitNames.has(entry.name)) continue;
          const origin = exportedOrigin(target, entry.name, new Set());
          if (origin === undefined) {
            throw new Error(`Cannot resolve package-root star export: ${entry.name}`);
          }
          const kind = statement.isTypeOnly ? 'type' : entry.kind;
          const existing = inherited.get(entry.name);
          if (existing !== undefined) {
            if (existing.origin !== origin) {
              throw new Error(`Duplicate package-root star export: ${entry.name}`);
            }
            existing.kind = strongestKind([existing.kind, kind]);
            continue;
          }
          inherited.set(entry.name, {
            name: entry.name,
            kind,
            origin
          });
        }
      }
      return [...explicit, ...[...inherited.values()].map(({ name, kind }) => ({ name, kind }))]
        .sort(compareExports);
    } finally {
      seen.delete(normalized);
    }
  }

  return { exportsOf, root };
}

function directDeclarationKinds(statements, name, exportedOnly) {
  return statements.flatMap((statement) => directDeclarationEntries(statement, exportedOnly))
    .filter((entry) => entry.name === name)
    .map((entry) => entry.kind);
}

function directDeclarationOrigins(statements, name, exportedOnly, file) {
  const origins = [];
  for (const statement of statements) {
    if (ts.isExportAssignment(statement)) {
      if (exportedOnly && !statement.isExportEquals && name === 'default') {
        origins.push(`${file}\0<default>`);
      }
      continue;
    }
    if (exportedOnly && !hasModifier(statement, ts.SyntaxKind.ExportKeyword)) continue;
    const defaultExport = exportedOnly && hasModifier(statement, ts.SyntaxKind.DefaultKeyword);
    if (ts.isClassDeclaration(statement) || ts.isFunctionDeclaration(statement) ||
      ts.isEnumDeclaration(statement) || ts.isModuleDeclaration(statement) ||
      ts.isInterfaceDeclaration(statement) || ts.isTypeAliasDeclaration(statement)) {
      const exportedName = defaultExport ? 'default' : statement.name?.text;
      if (exportedName === name) {
        origins.push(`${file}\0${statement.name?.text ?? '<default>'}`);
      }
    } else if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        for (const localName of bindingNames(declaration.name)) {
          if (localName === name) origins.push(`${file}\0${localName}`);
        }
      }
    }
  }
  return origins;
}

function collapseDirectEntries(entries) {
  const collapsed = new Map();
  for (const entry of entries) {
    const existing = collapsed.get(entry.name);
    if (existing === undefined) collapsed.set(entry.name, { ...entry });
    else existing.kind = strongestKind([existing.kind, entry.kind]);
  }
  return [...collapsed.values()];
}

function directDeclarationEntries(statement, exportedOnly) {
  if (ts.isExportAssignment(statement)) {
    return exportedOnly && !statement.isExportEquals
      ? [{ name: 'default', kind: 'value' }]
      : [];
  }
  if (exportedOnly && !hasModifier(statement, ts.SyntaxKind.ExportKeyword)) return [];
  const exportedName = exportedOnly && hasModifier(statement, ts.SyntaxKind.DefaultKeyword)
    ? 'default'
    : undefined;
  if ((ts.isClassDeclaration(statement) || ts.isFunctionDeclaration(statement) ||
    ts.isEnumDeclaration(statement) || ts.isModuleDeclaration(statement)) &&
    (exportedName !== undefined || statement.name !== undefined)) {
    return [{ name: exportedName ?? statement.name.text, kind: 'value' }];
  }
  if (ts.isInterfaceDeclaration(statement) || ts.isTypeAliasDeclaration(statement)) {
    return [{ name: exportedName ?? statement.name.text, kind: 'type' }];
  }
  if (ts.isVariableStatement(statement)) {
    return statement.declarationList.declarations.flatMap((declaration) =>
      bindingNames(declaration.name).map((name) => ({ name, kind: 'value' })));
  }
  return [];
}

function bindingNames(name) {
  if (ts.isIdentifier(name)) return [name.text];
  const names = [];
  for (const element of name.elements) {
    if (!ts.isOmittedExpression(element)) names.push(...bindingNames(element.name));
  }
  return names;
}

function hasModifier(node, kind) {
  return ts.canHaveModifiers(node) && (ts.getModifiers(node) ?? [])
    .some((modifier) => modifier.kind === kind);
}

function strongestKind(kinds) {
  const resolved = kinds.filter((kind) => kind !== undefined);
  if (resolved.includes('value')) return 'value';
  if (resolved.includes('type')) return 'type';
  return undefined;
}

function uniqueOrigin(origins, message) {
  const unique = [...new Set(origins.filter((origin) => origin !== undefined))];
  if (unique.length > 1) throw new Error(message);
  return unique[0];
}

function normalizeVirtualPath(file) {
  return posix.normalize(file.replaceAll('\\', '/')).replace(/^\.?\//, '');
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
