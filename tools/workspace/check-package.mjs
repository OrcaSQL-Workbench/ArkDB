import {
  existsSync, lstatSync, readFileSync, readdirSync, realpathSync, statSync
} from 'node:fs';
import {
  basename, dirname, isAbsolute, join, posix, relative, resolve, sep, win32
} from 'node:path';
import ts from 'typescript';
import { dependencyClosure, discoverPackages, driverArgument, readJson5, resolvePackage, ROOT } from './driver-packages.mjs';

export { readJson5, ROOT } from './driver-packages.mjs';

export function listFiles(directory) {
  const info = lstatSync(directory);
  if (info.isSymbolicLink()) throw new Error(`Source links are not supported: ${directory}`);
  if (!info.isDirectory()) throw new Error(`Expected a source directory: ${directory}`);
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

function unwrapImportExpression(node) {
  let current = node;
  while (ts.isParenthesizedExpression(current) ||
    ts.isAsExpression(current) ||
    ts.isTypeAssertionExpression(current) ||
    ts.isSatisfiesExpression(current) ||
    ts.isNonNullExpression(current)) {
    current = current.expression;
  }
  return current;
}

function isolatedProcessExpression(node) {
  const expression = unwrapImportExpression(node);
  return (ts.isIdentifier(expression) && expression.text === 'process') ||
    (ts.isPropertyAccessExpression(expression) &&
      ts.isIdentifier(unwrapImportExpression(expression.expression)) &&
      unwrapImportExpression(expression.expression).text === 'globalThis' &&
      expression.name.text === 'process') ||
    (ts.isElementAccessExpression(expression) &&
      ts.isIdentifier(unwrapImportExpression(expression.expression)) &&
      unwrapImportExpression(expression.expression).text === 'globalThis' &&
      expression.argumentExpression !== undefined &&
      ts.isStringLiteralLike(unwrapImportExpression(expression.argumentExpression)) &&
      unwrapImportExpression(expression.argumentExpression).text === 'process');
}

function isolatedModuleExpression(node) {
  const expression = unwrapImportExpression(node);
  return (ts.isIdentifier(expression) && expression.text === 'module') ||
    (ts.isPropertyAccessExpression(expression) &&
      ts.isIdentifier(unwrapImportExpression(expression.expression)) &&
      unwrapImportExpression(expression.expression).text === 'globalThis' &&
      expression.name.text === 'module') ||
    (ts.isElementAccessExpression(expression) &&
      ts.isIdentifier(unwrapImportExpression(expression.expression)) &&
      unwrapImportExpression(expression.expression).text === 'globalThis' &&
      expression.argumentExpression !== undefined &&
      constantString(expression.argumentExpression) === 'module');
}

function isolatedRootedAtGlobalThis(node) {
  let expression = unwrapImportExpression(node);
  while (ts.isPropertyAccessExpression(expression) ||
    ts.isElementAccessExpression(expression)) {
    expression = unwrapImportExpression(expression.expression);
  }
  return ts.isIdentifier(expression) && expression.text === 'globalThis';
}

const HVIGOR_DEPENDENCY_APIS = new Set([
  'getDependenciesOpt',
  'setDependenciesOpt',
  'getDevDependenciesOpt',
  'setDevDependenciesOpt',
  'getDynamicDependenciesOpt',
  'setDynamicDependenciesOpt'
]);
const NODE_LOADER_IDENTIFIERS = new Set([
  'constructor', 'createRequire', 'eval', 'Function', 'getBuiltinModule',
  'globalThis', 'process', 'Reflect'
]);
const NODE_BUILTIN_ROOTS = new Set([
  '_http_agent',
  '_http_client',
  '_http_common',
  '_http_incoming',
  '_http_outgoing',
  '_http_server',
  '_stream_duplex',
  '_stream_passthrough',
  '_stream_readable',
  '_stream_transform',
  '_stream_wrap',
  '_stream_writable',
  '_tls_common',
  '_tls_wrap',
  'assert',
  'async_hooks',
  'buffer',
  'child_process',
  'cluster',
  'console',
  'constants',
  'crypto',
  'dgram',
  'diagnostics_channel',
  'dns',
  'domain',
  'events',
  'fs',
  'http',
  'http2',
  'https',
  'inspector',
  'module',
  'net',
  'os',
  'path',
  'perf_hooks',
  'process',
  'punycode',
  'querystring',
  'readline',
  'repl',
  'stream',
  'string_decoder',
  'sys',
  'timers',
  'tls',
  'trace_events',
  'tty',
  'url',
  'util',
  'v8',
  'vm',
  'wasi',
  'worker_threads',
  'zlib'
]);
const NODE_PREFIX_ONLY_BUILTIN_ROOTS = new Set([
  'sea',
  'sqlite',
  'test'
]);
const SAFE_NODE_BUILTIN_ROOTS = new Set([
  'assert',
  'buffer',
  'crypto',
  'fs',
  'os',
  'path',
  'url',
  'util'
]);

function absoluteModuleSpecifier(value) {
  return isAbsolute(value) || posix.isAbsolute(value) || win32.isAbsolute(value);
}

function nodeBuiltinRoot(specifier) {
  const prefixed = specifier.startsWith('node:');
  const name = prefixed
    ? specifier.slice('node:'.length)
    : specifier;
  const root = name.split('/', 1)[0];
  if (NODE_PREFIX_ONLY_BUILTIN_ROOTS.has(root)) {
    return prefixed ? root : null;
  }
  return NODE_BUILTIN_ROOTS.has(root) ? root : null;
}

function constantString(node) {
  const expression = unwrapImportExpression(node);
  if (ts.isStringLiteralLike(expression)) return expression.text;
  if (ts.isBinaryExpression(expression) &&
    expression.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const left = constantString(expression.left);
    const right = constantString(expression.right);
    if (left !== null && right !== null) return `${left}${right}`;
  }
  return null;
}

function moduleRequireAccess(node) {
  let expression = unwrapImportExpression(node);
  const names = [];
  while (ts.isPropertyAccessExpression(expression) ||
    ts.isElementAccessExpression(expression)) {
    if (ts.isPropertyAccessExpression(expression)) {
      names.push(expression.name.text);
    } else if (expression.argumentExpression !== undefined) {
      names.push(constantString(expression.argumentExpression));
    }
    expression = unwrapImportExpression(expression.expression);
  }
  return ts.isIdentifier(expression) &&
    ['global', 'globalThis', 'module'].includes(expression.text) &&
    names.includes('require');
}

function memberOwnedBy(node, owner) {
  const expression = unwrapImportExpression(node);
  if (!ts.isPropertyAccessExpression(expression) &&
    !ts.isElementAccessExpression(expression)) {
    return false;
  }
  const target = unwrapImportExpression(expression.expression);
  return ts.isIdentifier(target) && target.text === owner;
}

function identifierInTypePosition(node) {
  const identifier = node;
  let current = node.parent;
  while (current !== undefined) {
    if (ts.isExpressionWithTypeArguments(current) &&
      ts.isHeritageClause(current.parent) &&
      current.parent.token === ts.SyntaxKind.ExtendsKeyword &&
      (ts.isClassDeclaration(current.parent.parent) ||
        ts.isClassExpression(current.parent.parent))) {
      let nested = identifier;
      while (nested !== current && nested.parent !== undefined) {
        if (nested === current.expression) return false;
        nested = nested.parent;
      }
      if (nested === current.expression) return false;
    }
    if (ts.isTypeNode(current)) return true;
    if (ts.isStatement(current)) return false;
    current = current.parent;
  }
  return false;
}

function referencedIdentifier(node, name) {
  if (!ts.isIdentifier(node) || node.text !== name) return false;
  if (identifierInTypePosition(node)) return false;
  const parent = node.parent;
  if (ts.isExportSpecifier(parent)) {
    const declaration = ts.isNamedExports(parent.parent) &&
      ts.isExportDeclaration(parent.parent.parent)
      ? parent.parent.parent
      : null;
    if (declaration?.moduleSpecifier !== undefined ||
      declaration?.isTypeOnly === true || parent.isTypeOnly) {
      return false;
    }
    return parent.propertyName === undefined
      ? parent.name === node
      : parent.propertyName === node;
  }
  if (parent && 'name' in parent && parent.name === node &&
    !ts.isShorthandPropertyAssignment(parent)) {
    return false;
  }
  if ((ts.isBindingElement(parent) && parent.propertyName === node) ||
    (ts.isImportSpecifier(parent) && parent.propertyName === node) ||
    (ts.isQualifiedName(parent) && parent.right === node)) {
    return false;
  }
  return true;
}

function sourceImportCandidates(base) {
  const runtimeSuffix = base.match(/\.(?:cjs|mjs|js)$/);
  return [
    base,
    ...(runtimeSuffix ? [
      base.replace(runtimeSuffix[0], '.d.ts'),
      base.replace(runtimeSuffix[0], '.d.ets')
    ] : []),
    `${base}.ets`,
    `${base}.ts`,
    `${base}.d.ets`,
    `${base}.d.ts`,
    `${base}.js`,
    `${base}.mjs`,
    join(base, 'Index.ets'),
    join(base, 'Index.ts'),
    join(base, 'Index.d.ets'),
    join(base, 'Index.d.ts'),
    join(base, 'Index.js'),
    join(base, 'Index.mjs')
  ];
}

function referencedPathSpecifier(fileName) {
  if (fileName.startsWith('.') || absoluteModuleSpecifier(fileName) ||
    /^[A-Za-z]:[\\/]/.test(fileName) ||
    /^[A-Za-z][A-Za-z0-9+.-]*:/.test(fileName)) {
    return fileName;
  }
  return `./${fileName}`;
}

export function importSpecifiers(source, { strictNodeLoaders = false } = {}) {
  const syntax = ts.createSourceFile(
    'ArkTsImports.ets', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const specifiers = [
    ...syntax.referencedFiles.map((reference) =>
      referencedPathSpecifier(reference.fileName)),
    ...syntax.typeReferenceDirectives.map((reference) => reference.fileName)
  ];
  function visit(node) {
    const computedName = ts.isElementAccessExpression(node) &&
      node.argumentExpression !== undefined
      ? constantString(node.argumentExpression)
      : null;
    if (strictNodeLoaders && referencedIdentifier(node, 'arguments')) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (referencedIdentifier(node, 'global') ||
      referencedIdentifier(node, 'globalThis') ||
      referencedIdentifier(node, 'module')) {
      throw new Error('CommonJS imports are not supported in isolated projects.');
    } else if ((ts.isPropertyAccessExpression(node) ||
      ts.isElementAccessExpression(node)) &&
      isolatedModuleExpression(node)) {
      throw new Error('CommonJS imports are not supported in isolated projects.');
    } else if ((ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node)) &&
      moduleRequireAccess(node)) {
      throw new Error('CommonJS imports are not supported in isolated projects.');
    } else if (ts.isVariableDeclaration(node) && node.initializer !== undefined &&
      isolatedModuleExpression(node.initializer)) {
      throw new Error('CommonJS imports are not supported in isolated projects.');
    } else if (ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      isolatedModuleExpression(node.right)) {
      throw new Error('CommonJS imports are not supported in isolated projects.');
    } else if (referencedIdentifier(node, 'require')) {
      throw new Error('CommonJS imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isIdentifier(node) &&
      HVIGOR_DEPENDENCY_APIS.has(node.text)) {
      throw new Error('Dependency-mutating Hvigor APIs are not supported.');
    } else if (strictNodeLoaders && computedName !== null &&
      HVIGOR_DEPENDENCY_APIS.has(computedName)) {
      throw new Error('Dependency-mutating Hvigor APIs are not supported.');
    } else if (strictNodeLoaders && ts.isIdentifier(node) &&
      NODE_LOADER_IDENTIFIERS.has(node.text)) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && computedName !== null &&
      NODE_LOADER_IDENTIFIERS.has(computedName)) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === 'require') {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isCallExpression(node) &&
      memberOwnedBy(node.expression, 'module')) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isVariableDeclaration(node) &&
      node.initializer !== undefined &&
      (isolatedProcessExpression(node.initializer) ||
        memberOwnedBy(node.initializer, 'module') ||
        memberOwnedBy(node.initializer, 'Reflect'))) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      isolatedProcessExpression(node.right)) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isElementAccessExpression(node) &&
      (isolatedProcessExpression(node.expression) ||
        isolatedRootedAtGlobalThis(node))) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isIdentifier(node) &&
      node.text === 'getBuiltinModule') {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if (strictNodeLoaders && ts.isCallExpression(node) &&
      memberOwnedBy(node.expression, 'Reflect')) {
      throw new Error('Node loader imports are not supported in isolated projects.');
    } else if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
      node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
      specifiers.push(node.moduleSpecifier.text);
    } else if (ts.isImportEqualsDeclaration(node) &&
      ts.isExternalModuleReference(node.moduleReference) &&
      node.moduleReference.expression &&
      ts.isStringLiteral(node.moduleReference.expression)) {
      if (!node.isTypeOnly) {
        throw new Error('CommonJS imports are not supported in isolated projects.');
      }
      specifiers.push(node.moduleReference.expression.text);
    } else if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument) &&
      ts.isStringLiteral(node.argument.literal)) {
      specifiers.push(node.argument.literal.text);
    } else if (ts.isCallExpression(node) &&
      node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      const specifier = node.arguments[0];
      if (!specifier || !ts.isStringLiteral(specifier)) {
        throw new Error('ArkTS dynamic imports must use literal module specifiers.');
      }
      specifiers.push(specifier.text);
    }
    ts.forEachChild(node, visit);
  }
  visit(syntax);
  return specifiers;
}

function within(parent, path) {
  const child = relative(parent, path);
  return child !== '..' && !child.startsWith(`..${sep}`) && !isAbsolute(child);
}

function exactRepositoryPath(root, target, kind, { optional = false } = {}) {
  const repository = resolve(root);
  const path = resolve(target);
  if (!within(repository, path)) {
    if (optional) return null;
    throw new Error(`ArkTS project path must remain inside the repository: ${target}`);
  }
  let current = repository;
  for (const part of relative(repository, path).split(sep)) {
    const entries = readdirSync(current, { withFileTypes: true });
    const entry = entries.find((candidate) => candidate.name === part);
    if (!entry) {
      const folded = entries.find((candidate) =>
        candidate.name.toLowerCase() === part.toLowerCase());
      if (folded) {
        throw new Error(`ArkTS project imports require exact path case: ` +
          `${relative(repository, path)}; found ${folded.name}`);
      }
      if (optional) return null;
      throw new Error(`ArkTS project path does not exist: ${relative(repository, path)}`);
    }
    current = join(current, part);
    const info = lstatSync(current);
    if (info.isSymbolicLink()) {
      throw new Error(`ArkTS project sources must not use symbolic links: ` +
        `${relative(repository, current)}`);
    }
  }
  const info = lstatSync(current);
  const valid = kind === 'directory' ? info.isDirectory() : info.isFile();
  if (!valid) {
    if (optional) return null;
    throw new Error(`ArkTS project path must be a ${kind}: ${relative(repository, path)}`);
  }
  return current;
}

function configuredWorkerPaths(value, result = []) {
  if (value === null || typeof value !== 'object') return result;
  if (Array.isArray(value)) {
    for (const entry of value) configuredWorkerPaths(entry, result);
    return result;
  }
  for (const [name, entry] of Object.entries(value)) {
    if (name !== 'workers') {
      configuredWorkerPaths(entry, result);
      continue;
    }
    if (!Array.isArray(entry) ||
      entry.some((path) => typeof path !== 'string' || path.length === 0)) {
      throw new Error('ArkTS project worker paths must be nonempty strings.');
    }
    result.push(...entry);
  }
  return result;
}

export function requiresCanonicalTestOwners(root, declaration,
  canonicalRoot = ROOT) {
  const mode = declaration?.testOwnership;
  if (mode === undefined) return true;
  if (mode !== 'fixture') {
    throw new Error(`Unsupported test ownership policy: ${String(mode)}`);
  }
  const actual = realpathSync.native(resolve(root));
  const canonical = realpathSync.native(resolve(canonicalRoot));
  const same = process.platform === 'win32'
    ? actual.toLowerCase() === canonical.toLowerCase()
    : actual === canonical;
  if (same) {
    throw new Error('Canonical packages cannot disable test ownership enforcement.');
  }
  return false;
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

function checkTestSources(root, id, testRoot, enforceCanonicalOwners = false) {
  const files = listFiles(testRoot);
  const invalidSource = files.find((file) =>
    /\.(?:ets|[cm]?js|[cm]?ts)$/i.test(file) && !file.endsWith('.ets'));
  if (invalidSource !== undefined) {
    throw new Error(`ArkDB package test source ${invalidSource} must use the exact ` +
      'lowercase .ets suffix.');
  }
  const sources = files.filter((file) => file.endsWith('.ets'));
  const testFiles = sources.filter((file) =>
    file.endsWith('.test.ets') && !file.endsWith(`${sep}List.test.ets`));
  const supportFiles = sources.filter((file) => !file.endsWith('.test.ets'));
  const registryFiles = sources.filter((file) =>
    file.endsWith(`${sep}List.test.ets`));
  const allowedRegistries = new Set([
    join(testRoot, 'List.test.ets'),
    ...(id === 'mysql' ? [join(testRoot, 'mysql', 'List.test.ets')] : [])
  ]);
  for (const file of registryFiles) {
    if (!allowedRegistries.has(file)) {
      throw new Error(`Unexpected ArkTS suite registry: ${relative(root, file)}`);
    }
    const cases = testCaseNames(testSyntax(file, readFileSync(file, 'utf8')));
    if (cases.length > 0) {
      throw new Error(`ArkTS suite registries must not declare test cases: ` +
        `${relative(root, file)}`);
    }
  }
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

  const ownedSources = sources.filter((file) =>
    !file.endsWith(`${sep}List.test.ets`));
  const sourceOwners = [...new Set(ownedSources.map((file) =>
    testOwner(testRoot, file)))].sort();
  const testOwners = [...new Set(testFiles.map((file) =>
    testOwner(testRoot, file)))].sort();
  if (id === 'mysql' && enforceCanonicalOwners) {
    const missingOwners = MYSQL_TEST_OWNERS.filter((owner) => !testOwners.includes(owner));
    const unexpectedOwners = sourceOwners.filter((owner) =>
      !MYSQL_TEST_OWNERS.includes(owner));
    if (unexpectedOwners.length > 0 || missingOwners.length > 0) {
      throw new Error(`MySQL tests must mirror production ownership; ` +
        `unexpected owners: ${unexpectedOwners.join(', ') || 'none'}; ` +
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

export function checkIsolatedArkTsProject(root, projectRoot) {
  const repository = resolve(root);
  const requestedProject = isAbsolute(projectRoot)
    ? resolve(projectRoot)
    : resolve(repository, projectRoot);
  if (!within(repository, requestedProject)) {
    throw new Error(`ArkTS project must remain inside the repository: ${projectRoot}`);
  }
  const project = exactRepositoryPath(repository, requestedProject, 'directory');
  const profileFile = exactRepositoryPath(
    repository, join(project, 'build-profile.json5'), 'file');
  const profile = readJson5(profileFile);
  if (!Array.isArray(profile.modules) || profile.modules.length === 0) {
    throw new Error('ArkTS project build profile must register modules.');
  }
  const moduleRoots = profile.modules.map((registration) => {
    if (typeof registration?.srcPath !== 'string' ||
      registration.srcPath.length === 0 || isAbsolute(registration.srcPath)) {
      throw new Error('ArkTS project module source paths must be nonempty and relative.');
    }
    const moduleRoot = resolve(project, registration.srcPath);
    if (!within(project, moduleRoot)) {
      throw new Error(`ArkTS project modules must remain inside the project: ` +
        `${registration.srcPath}`);
    }
    return exactRepositoryPath(repository, moduleRoot, 'directory');
  });
  if (new Set(moduleRoots).size !== moduleRoots.length) {
    throw new Error('ArkTS project modules must use unique source paths.');
  }
  const identities = new Set([basename(project)]);
  for (const product of profile.app?.products ?? []) {
    if (typeof product?.bundleName === 'string' && product.bundleName.length > 0) {
      identities.add(product.bundleName);
    }
  }
  const dependencies = [];
  const declaredEntries = [];
  const strictEntries = [];
  const sourcePattern = /\.(?:ets|ts|js|mjs)$/;
  for (const script of [
    join(project, 'hvigorfile.ts'),
    ...moduleRoots.map((moduleRoot) => join(moduleRoot, 'hvigorfile.ts'))
  ]) {
    const exactScript = exactRepositoryPath(
      repository, script, 'file', { optional: true });
    if (exactScript !== null) strictEntries.push(exactScript);
  }
  const appManifestFile = exactRepositoryPath(
    repository, join(project, 'AppScope', 'app.json5'), 'file', { optional: true });
  if (appManifestFile !== null) {
    const app = readJson5(appManifestFile);
    if (typeof app.app?.bundleName === 'string' && app.app.bundleName.length > 0) {
      identities.add(app.app.bundleName);
    }
  }
  for (const moduleRoot of moduleRoots) {
    const moduleProfileFile = exactRepositoryPath(
      repository, join(moduleRoot, 'build-profile.json5'), 'file', { optional: true });
    if (moduleProfileFile === null) continue;
    for (const worker of configuredWorkerPaths(readJson5(moduleProfileFile))) {
      const entry = resolve(moduleRoot, worker);
      if (!within(project, entry)) {
        throw new Error(`ArkTS project build source paths must remain inside the project: ` +
          `${worker}`);
      }
      if (!within(moduleRoot, entry)) {
        throw new Error(`ArkTS project build source paths must remain inside the module: ` +
          `${worker}`);
      }
      const exactEntry = exactRepositoryPath(repository, entry, 'file');
      if (!sourcePattern.test(exactEntry)) {
        throw new Error(`ArkTS project build source paths must use a supported source suffix: ` +
          `${worker}`);
      }
      declaredEntries.push(exactEntry);
    }
  }
  const moduleManifests = new Map(moduleRoots.map((moduleRoot) => [
    join(moduleRoot, 'oh-package.json5'),
    moduleRoot
  ]));
  const manifestFiles = [
    join(project, 'oh-package.json5'),
    join(project, 'hvigor', 'hvigor-config.json5'),
    ...moduleManifests.keys()
  ].map((file) => exactRepositoryPath(
    repository, file, 'file', { optional: true }))
    .filter((file) => file !== null);
  for (const manifestFile of manifestFiles) {
    const manifest = readJson5(manifestFile);
    if (Object.hasOwn(manifest, 'parameterFile') ||
      Object.hasOwn(manifest, 'overrideDependencyMap')) {
      throw new Error('Parameterized dependency rewriting is not supported in isolated projects.');
    }
    if (typeof manifest.name === 'string' && manifest.name.length > 0) {
      identities.add(manifest.name);
    }
    const moduleRoot = moduleManifests.get(manifestFile);
    if (moduleRoot !== undefined) {
      for (const field of ['main', 'types']) {
        const declared = manifest[field];
        if (typeof declared !== 'string' || declared.length === 0) continue;
        const entry = resolve(moduleRoot, declared);
        if (!within(moduleRoot, entry)) {
          throw new Error(`ArkTS project module entries must remain inside the module: ` +
            `${declared}`);
        }
        const exactEntry = exactRepositoryPath(repository, entry, 'file');
        if (!sourcePattern.test(exactEntry)) {
          throw new Error(`ArkTS project module entries must use a supported source suffix: ` +
            `${declared}`);
        }
        declaredEntries.push(exactEntry);
      }
    }
    for (const section of [
      'dependencies', 'devDependencies', 'dynamicDependencies', 'overrides'
    ]) {
      const entries = manifest[section] ?? {};
      if (typeof entries !== 'object' || entries === null || Array.isArray(entries)) continue;
      for (const [name, value] of Object.entries(entries)) {
        dependencies.push({
          manifest: relative(repository, manifestFile),
          name,
          value
        });
        if (typeof value !== 'string' || !value.startsWith('file:')) continue;
        const target = resolve(dirname(manifestFile), value.slice('file:'.length));
        if (!within(project, target)) {
          throw new Error(`ArkTS project dependencies must not reference a sibling project: ` +
            `${relative(repository, manifestFile)} -> ${relative(repository, target)}`);
        }
        if (!/\.har$/.test(target)) {
          throw new Error(
            'Local source-package dependencies are not supported in isolated projects.');
        }
        exactRepositoryPath(repository, target, 'file', { optional: true });
      }
    }
  }
  const sourceDirectories = moduleRoots.map((moduleRoot) =>
    exactRepositoryPath(
      repository, join(moduleRoot, 'src'), 'directory', { optional: true }))
    .filter((directory) => directory !== null);
  const initialSources = [...new Set([
    ...sourceDirectories.flatMap((directory) =>
      listFiles(directory).filter((file) => sourcePattern.test(file))),
    ...declaredEntries
  ])];
  const strictSourceSet = new Set(strictEntries);
  const pendingSources = [
    ...initialSources.map((file) => ({ file, strict: false })),
    ...strictEntries.map((file) => ({ file, strict: true }))
  ];
  const visitedSources = new Map();
  const externalImports = [];
  while (pendingSources.length > 0) {
    const pending = pendingSources.shift();
    const file = pending.file;
    const strict = pending.strict;
    const visitedStrict = visitedSources.get(file);
    if (visitedStrict === true || (visitedStrict === false && !strict)) continue;
    visitedSources.set(file, visitedStrict === true || strict);
    let specifiers;
    try {
      specifiers = importSpecifiers(readFileSync(file, 'utf8'), {
        strictNodeLoaders: strict
      });
    } catch (error) {
      throw new Error(`${error instanceof Error ? error.message : String(error)}: ` +
        `${relative(repository, file)}`, { cause: error });
    }
    for (const specifier of specifiers) {
      if (!specifier.startsWith('.')) {
        if (absoluteModuleSpecifier(specifier)) {
          throw new Error(
            'Absolute filesystem imports are not supported in isolated projects.');
        }
        const builtinRoot = nodeBuiltinRoot(specifier);
        if (builtinRoot !== null) {
          if (!strict) {
            throw new Error(
              'Node built-in imports are not supported in ordinary application sources.');
          }
          if (!SAFE_NODE_BUILTIN_ROOTS.has(builtinRoot)) {
            throw new Error(
              'Node built-in import is not allowed in isolated build tooling.');
          }
          continue;
        }
        if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(specifier)) {
          throw new Error('Absolute module URLs are not supported in isolated projects.');
        }
        externalImports.push({
          file: relative(repository, file),
          specifier
        });
        continue;
      }
      const base = resolve(dirname(file), specifier);
      let target = null;
      const candidates = sourceImportCandidates(base);
      for (const candidate of candidates) {
        if (!within(repository, candidate)) {
          target = candidate;
          break;
        }
        const exact = exactRepositoryPath(
          repository, candidate, 'file', { optional: true });
        if (exact !== null) {
          target = exact;
          break;
        }
      }
      if (target === null) {
        throw new Error(`Unresolved ArkTS project import in ${relative(repository, file)}: ${specifier}`);
      }
      if (!within(project, target)) {
        throw new Error(`ArkTS project sources must not import a sibling project: ` +
          `${relative(repository, file)} -> ${relative(repository, target)}`);
      }
      if (/\.(?:[cm]?js|[cm]?ts|ets)$/i.test(target) &&
        !sourcePattern.test(target)) {
        throw new Error(`Unsupported isolated project source suffix: ` +
          `${relative(repository, target)}`);
      }
      if (sourcePattern.test(target)) {
        pendingSources.push({
          file: target,
          strict: strict || strictSourceSet.has(target)
        });
      }
    }
  }
  return {
    sourceFiles: visitedSources.size,
    identities: [...identities],
    dependencies,
    externalImports
  };
}

export function checkPackage(root = ROOT, id = 'mysql') {
  const driver = resolvePackage(root, id);
  const enforceTestOwners = requiresCanonicalTestOwners(root, driver.declaration);
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
    ...listFiles(join(moduleRoot, 'src', 'main', 'ets')).filter((file) =>
      /\.(?:ets|ts|js)$/.test(file))];
  const available = new Set(files.map((file) => resolve(file)));
  let usesNetwork = false;
  for (const file of files) {
    for (const specifier of importSpecifiers(readFileSync(file, 'utf8'))) {
      usesNetwork ||= specifier === '@kit.NetworkKit' || specifier === '@ohos.net.socket';
      if (specifier.startsWith('.')) {
        const base = resolve(file, '..', specifier);
        const candidates = sourceImportCandidates(base);
        const target = candidates.find((candidate) => available.has(candidate));
        const generatedProfile = candidates.some((candidate) =>
          candidate === join(moduleRoot, 'BuildProfile.ets'));
        if (target === undefined && !generatedProfile) {
          throw new Error(`Unresolved or non-package import in ${relative(root, file)}: ${specifier}`);
        }
        if (target !== undefined && !within(moduleRoot, target)) {
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
  const { testFiles, testOwners, testCases } = checkTestSources(
    root, id, testRoot, enforceTestOwners);
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
