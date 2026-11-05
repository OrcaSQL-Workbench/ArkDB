import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import ts from 'typescript';
import { dependencyClosure, discoverPackages, driverArgument, readJson5, resolvePackage, ROOT } from './driver-packages.mjs';

export { readJson5, ROOT } from './driver-packages.mjs';

export function listFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Source links are not supported: ${path}`);
    if (entry.isDirectory()) return listFiles(path);
    if (!entry.isFile()) throw new Error(`Expected a regular source file: ${path}`);
    return [path];
  });
}

export function exportedNames(source) {
  const names = [];
  for (const match of source.matchAll(/\bexport\s+(?:type\s+)?\{([^}]+)\}\s+from\s+['"][^'"]+['"]/g)) {
    for (const binding of match[1].split(',')) {
      const name = binding.trim().split(/\s+as\s+/).at(-1);
      if (!/^[A-Za-z_$][\w$]*$/.test(name)) throw new Error(`Unsupported export: ${binding}`);
      if (names.includes(name)) throw new Error(`Duplicate public export: ${name}`);
      names.push(name);
    }
  }
  return names.sort();
}

export function importSpecifiers(source) {
  return [...source.matchAll(/\b(?:import|export)\s+(?:type\s+)?[^;]*?\bfrom\s+['"]([^'"]+)['"]/g)]
    .map((match) => match[1]);
}

function within(parent, path) {
  const child = relative(parent, path);
  return child !== '..' && !child.startsWith(`..${sep}`) && !isAbsolute(child);
}

function testSyntax(file, source) {
  const syntax = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  if (syntax.parseDiagnostics.length > 0) {
    throw new Error(`Cannot parse ArkTS test source: ${file}`);
  }
  return syntax;
}

function exportedFixtureStatement(statement) {
  if (ts.isExportDeclaration(statement)) return true;
  if (ts.isExportAssignment(statement)) return statement.isExportEquals;
  const modifiers = ts.canHaveModifiers(statement) ? ts.getModifiers(statement) ?? [] : [];
  const exported = modifiers.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword);
  const defaulted = modifiers.some((modifier) => modifier.kind === ts.SyntaxKind.DefaultKeyword);
  return exported && !defaulted;
}

function suiteCalls(syntax, bindings) {
  const calls = new Map([...bindings].map((binding) => [binding, 0]));
  function visit(node) {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) &&
      calls.has(node.expression.text)) {
      calls.set(node.expression.text, calls.get(node.expression.text) + 1);
    }
    ts.forEachChild(node, visit);
  }
  visit(syntax);
  return calls;
}

function listSuiteImports(file, source) {
  const syntax = testSyntax(file, source);
  const imports = [];
  for (const statement of syntax.statements) {
    if (!ts.isImportDeclaration(statement) || !statement.importClause?.name ||
      !ts.isStringLiteral(statement.moduleSpecifier)) continue;
    imports.push({
      binding: statement.importClause.name.text,
      specifier: statement.moduleSpecifier.text
    });
  }
  const calls = suiteCalls(syntax, new Set(imports.map((entry) => entry.binding)));
  return imports.map((entry) => ({ ...entry, calls: calls.get(entry.binding) }));
}

function testCaseNames(syntax) {
  const names = [];
  function visit(node) {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) &&
      node.expression.text === 'it') {
      const name = node.arguments[0];
      if (!name || !ts.isStringLiteral(name)) {
        throw new Error(`ArkTS test cases must use literal names: ${syntax.fileName}`);
      }
      names.push(name.text);
    }
    ts.forEachChild(node, visit);
  }
  visit(syntax);
  return names;
}

function testOwner(testRoot, file) {
  const parts = relative(testRoot, file).split(sep);
  if (parts[0] !== 'mysql') return parts.length > 1 ? parts[0] : '.';
  if (parts[1] === 'features') return `features/${parts[2]}`;
  return parts[1];
}

const MYSQL_TEST_OWNERS = [
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
];

function checkTestSources(root, id, testRoot) {
  const sources = listFiles(testRoot).filter((file) => file.endsWith('.ets'));
  const testFiles = sources.filter((file) =>
    file.endsWith('.test.ets') && !file.endsWith(`${sep}List.test.ets`));
  const supportFiles = sources.filter((file) => !file.endsWith('.test.ets'));
  const testCases = [];
  for (const file of sources) {
    for (const specifier of importSpecifiers(readFileSync(file, 'utf8'))) {
      if (!specifier.startsWith('.')) continue;
      const base = resolve(dirname(file), specifier);
      const candidates = [base, `${base}.ets`, join(base, 'Index.ets')];
      if (!candidates.some((candidate) =>
        existsSync(candidate) && statSync(candidate).isFile())) {
        throw new Error(`Unresolved ArkTS test import in ${relative(root, file)}: ${specifier}`);
      }
    }
  }
  for (const file of supportFiles) {
    const parts = relative(testRoot, file).split(sep);
    if (!parts.includes('fixtures')) {
      throw new Error(`Test support source must live under a fixtures directory: ${relative(root, file)}`);
    }
  }
  for (const file of testFiles) {
    const source = readFileSync(file, 'utf8');
    const syntax = testSyntax(file, source);
    testCases.push(...testCaseNames(syntax));
    if (syntax.statements.some(exportedFixtureStatement)) {
      throw new Error(`Executable ArkTS suite must not export shared fixtures: ${relative(root, file)}`);
    }
    for (const specifier of importSpecifiers(source)) {
      if (specifier.startsWith('.') && /\.test(?:\.ets)?$/.test(specifier)) {
        throw new Error(`Executable ArkTS suites must not import fixtures from another suite: ` +
          `${relative(root, file)} -> ${specifier}`);
      }
    }
  }

  const registrations = new Map();
  const reachedLists = new Set();
  const pending = [join(testRoot, 'List.test.ets')];
  while (pending.length > 0) {
    const file = pending.pop();
    if (reachedLists.has(file)) continue;
    reachedLists.add(file);
    const source = readFileSync(file, 'utf8');
    for (const entry of listSuiteImports(file, source)) {
      if (entry.calls !== 1) {
        throw new Error(`Imported test suite must be called exactly once in ${relative(root, file)}: ` +
          `${entry.binding} is called ${entry.calls} times.`);
      }
      const target = resolve(file, '..', `${entry.specifier}.ets`);
      if (!within(testRoot, target)) {
        throw new Error(`Registered ArkTS suite must stay inside its test package: ${entry.specifier}`);
      }
      const targetSource = sources.includes(target);
      if (!targetSource) {
        throw new Error(`Registered ArkTS suite does not exist: ${relative(root, target)}`);
      }
      const count = (registrations.get(target) ?? 0) + 1;
      registrations.set(target, count);
      if (count > 1) {
        throw new Error(`ArkTS suite is registered more than once: ${relative(root, target)}`);
      }
      if (target.endsWith(`${sep}List.test.ets`)) pending.push(target);
      else if (!target.endsWith('.test.ets')) {
        throw new Error(`Registered ArkTS suite must use the .test.ets suffix: ${relative(root, target)}`);
      }
    }
  }
  const unregistered = testFiles.filter((file) => registrations.get(file) !== 1);
  if (unregistered.length > 0 || testFiles.length === 0) {
    throw new Error(`Unregistered or missing ArkTS suites: ${unregistered
      .map((file) => relative(root, file)).join(', ')}`);
  }
  const duplicateCases = [...new Set(testCases.filter((name, index) =>
    testCases.indexOf(name) !== index))].sort();
  if (duplicateCases.length > 0) {
    throw new Error(`Duplicate ArkTS test case names: ${duplicateCases.join(', ')}`);
  }

  const testOwners = [...new Set(testFiles.map((file) => testOwner(testRoot, file)))].sort();
  if (id === 'mysql' && resolve(root) === resolve(ROOT)) {
    const missingOwners = MYSQL_TEST_OWNERS.filter((owner) => !testOwners.includes(owner));
    if (testOwners.includes('core') || missingOwners.length > 0) {
      throw new Error(`MySQL tests must mirror production ownership; ` +
        `misleading owners: ${testOwners.includes('core') ? 'core' : 'none'}; ` +
        `missing owners: ${missingOwners.join(', ') || 'none'}.`);
    }
  }
  return { testFiles, testOwners, testCases };
}

export function checkArkTsTests(root, testRoot, id = 'tests') {
  const result = checkTestSources(root, id, resolve(root, testRoot));
  return {
    testSuites: result.testFiles.length,
    testCases: result.testCases.length,
    testOwners: result.testOwners
  };
}

export function checkPackage(root = ROOT, id = 'mysql') {
  const driver = resolvePackage(root, id);
  const moduleRoot = driver.directory;
  const manifest = readJson5(join(moduleRoot, 'oh-package.json5'));
  if (!/^@arkdb\/[a-z][a-z0-9-]*$/.test(manifest.name ?? '') || manifest.main !== 'Index.ets' ||
    manifest.license !== 'Apache-2.0' || typeof manifest.author !== 'string' ||
    manifest.author.trim() === '' ||
    !/^[1-9]\d?(?:\.(?:[1-9]?\d)){2}$/.test(manifest.version)) {
    throw new Error('Invalid standalone package identity, license, entry, author, or version.');
  }
  for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
    if (readFileSync(join(moduleRoot, name), 'utf8').trim().length === 0) {
      throw new Error(`Package ${name} must not be empty.`);
    }
  }
  if (!readFileSync(join(root, 'LICENSE')).equals(readFileSync(join(moduleRoot, 'LICENSE')))) {
    throw new Error('Repository and package licenses must match.');
  }

  const module = driver.definition;
  const dependencies = dependencyClosure(root, id).filter((entry) => entry.id !== id);
  const dependencyNames = new Set(dependencies.map((entry) => entry.packageName));
  if (dependencies.length > 0) {
    const overrides = readJson5(join(root, 'oh-package.json5')).overrides ?? {};
    for (const dependency of dependencies) {
      if (![ `file:./${dependency.sourcePath}`, `@module:${dependency.id}` ].includes(overrides[dependency.packageName])) {
        throw new Error(`Workspace dependency override must select registered source: ${dependency.packageName}.`);
      }
    }
  }
  const files = [join(moduleRoot, 'Index.ets'),
    ...listFiles(join(moduleRoot, 'src', 'main', 'ets')).filter((file) => file.endsWith('.ets'))];
  const available = new Set(files.map((file) => resolve(file)));
  let usesNetwork = false;
  for (const file of files) {
    for (const specifier of importSpecifiers(readFileSync(file, 'utf8'))) {
      usesNetwork ||= specifier === '@kit.NetworkKit' || specifier === '@ohos.net.socket';
      if (specifier.startsWith('.')) {
        const target = resolve(file, '..', `${specifier}.ets`);
        const generatedProfile = target === join(moduleRoot, 'BuildProfile.ets');
        if (!within(moduleRoot, target) || (!available.has(target) && !generatedProfile)) {
          throw new Error(`Unresolved or non-package import in ${relative(root, file)}: ${specifier}`);
        }
      } else if (!specifier.startsWith('@kit.') && !specifier.startsWith('@ohos.')) {
        if (!Object.hasOwn(manifest.dependencies ?? {}, specifier) || !dependencyNames.has(specifier)) {
          throw new Error(`Undeclared runtime dependency in ${relative(root, file)}: ${specifier}`);
        }
      }
      if (usesNetwork && !module.requestPermissions?.some((permission) => permission.name === 'ohos.permission.INTERNET')) {
        throw new Error(`The ${id} HAR uses networking and must declare INTERNET.`);
      }
    }
  }
  const exports = exportedNames(readFileSync(join(moduleRoot, 'Index.ets'), 'utf8'));
  if (exports.length === 0) throw new Error('Public entry must expose named exports.');

  const testRoot = join(moduleRoot, 'src', 'test');
  const { testFiles, testOwners, testCases } = checkTestSources(root, id, testRoot);
  return {
    manifest,
    exports,
    driver,
    sourceFiles: files.length,
    testSuites: testFiles.length,
    testCases: testCases.length,
    testOwners
  };
}

export function runCheckPackageCli(args = process.argv.slice(2)) {
  const drivers = args.length === 0
    ? discoverPackages().map((driver) => driver.id)
    : [driverArgument(args)];
  for (const id of drivers) {
    const result = checkPackage(ROOT, id);
    console.log(`Checked ${result.manifest.name}@${result.manifest.version}: ` +
      `${result.sourceFiles} source files, ${result.exports.length} exports, ` +
      `${result.testSuites} ArkTS suites, ${result.testCases} ArkTS cases.`);
  }
}
