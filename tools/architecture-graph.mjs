import { existsSync, lstatSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, isAbsolute, join, parse, relative, resolve, sep } from 'node:path';
import JSON5 from 'json5';
import ts from 'typescript';

/**
 * @typedef {{
 *   files: string[],
 *   dependencies: Record<string, string[]>
 * }} ArchitectureGraph
 *
 * @typedef {string | RegExp} ArchitecturePathPattern
 *
 * @typedef {{
 *   ownedSourceRoots?: Array<{
 *     root: string,
 *     files?: string[],
 *     directories?: string[]
 *   }>,
 *   forbiddenSources?: ArchitecturePathPattern[],
 *   prohibitedDependencies?: Array<{
 *     from: ArchitecturePathPattern,
 *     to: ArchitecturePathPattern,
 *     transitive?: boolean,
 *     message?: string
 *   }>
 * }} ArchitecturePolicy
 */

const IGNORED_DIRECTORIES = new Set([
  '.git', '.hvigor', '.idea', '.ohpm-cache', '.preview', '.test',
  'build', 'dist', 'node_modules', 'oh_modules', 'test-fixtures'
]);
const NODE_SOURCE = /\.mjs$/;
const NODE_LIKE_SOURCE = /\.(?:[cm]?js|[cm]?ts)$/i;
const ARKTS_LIKE_SOURCE = /\.(?:ets|[cm]?js|[cm]?ts)$/i;
const HVIGOR_SOURCE = /(?:^|[\\/])hvigorfile\.ts$/;

function buildToolSource(file) {
  return NODE_SOURCE.test(file) || HVIGOR_SOURCE.test(file);
}

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function pathKey(file) {
  const path = resolve(file);
  if (process.platform !== 'win32') return path;
  const root = parse(path).root;
  return `${root.toUpperCase()}${path.slice(root.length)}`;
}

function repositoryPath(root, file) {
  return relative(root, file).split(sep).join('/');
}

function ignoredDirectory(name) {
  return IGNORED_DIRECTORIES.has(name) || name.startsWith('.tmp-');
}

function exactEntry(parent, name, kind, { optional = false } = {}) {
  const entries = readdirSync(parent, { withFileTypes: true });
  const entry = entries.find((candidate) => candidate.name === name);
  if (!entry) {
    const folded = entries.find((candidate) =>
      candidate.name.toLowerCase() === name.toLowerCase());
    if (folded) {
      throw new Error(`Architecture sources require exact path case for ${join(parent, name)}; ` +
        `found ${folded.name}.`);
    }
    if (optional) return null;
    throw new Error(`Architecture source path does not exist: ${join(parent, name)}`);
  }
  const file = join(parent, name);
  if (entry.isSymbolicLink()) {
    throw new Error(`Architecture sources must not use symbolic links: ${file}`);
  }
  if ((kind === 'directory' && !entry.isDirectory()) || (kind === 'file' && !entry.isFile())) {
    throw new Error(`Architecture source must be a ${kind}: ${file}`);
  }
  return file;
}

function walk(directory, visitFile, shouldIgnore = (_parent, name) => ignoredDirectory(name)) {
  const info = lstatSync(directory);
  if (info.isSymbolicLink()) {
    throw new Error(`Architecture sources must not use symbolic links: ${directory}`);
  }
  if (!info.isDirectory()) throw new Error(`Architecture source must be a directory: ${directory}`);
  for (const entry of readdirSync(directory, { withFileTypes: true })
    .sort((left, right) => compareText(left.name, right.name))) {
    const file = join(directory, entry.name);
    if (shouldIgnore(directory, entry.name)) continue;
    if (entry.isSymbolicLink()) {
      throw new Error(`Architecture sources must not use symbolic links: ${file}`);
    }
    if (entry.isDirectory()) {
      walk(file, visitFile, shouldIgnore);
    } else if (entry.isFile()) {
      visitFile(file);
    }
  }
}

function packageDirectories(root) {
  const profileFile = exactEntry(root, 'build-profile.json5', 'file', { optional: true });
  if (profileFile === null) return [];
  let profile;
  try {
    profile = JSON5.parse(readFileSync(profileFile, 'utf8'));
  } catch (error) {
    throw new Error(`Cannot parse workspace build profile: ${profileFile}`, { cause: error });
  }
  if (!Array.isArray(profile?.modules)) {
    throw new Error('Workspace build profile must contain registered modules.');
  }
  const directories = [];
  for (const registration of profile.modules) {
    if (typeof registration?.srcPath !== 'string' || registration.srcPath.length === 0 ||
      isAbsolute(registration.srcPath)) {
      throw new Error('Workspace module source paths must be nonempty relative paths.');
    }
    const directory = resolve(root, registration.srcPath);
    const path = relative(root, directory);
    if (path === '' || path === '..' || path.startsWith(`..${sep}`) || isAbsolute(path)) {
      throw new Error(`Workspace module must remain inside the architecture root: ${registration.srcPath}`);
    }
    let current = root;
    for (const part of path.split(sep)) {
      if (ignoredDirectory(part)) {
        throw new Error(`Registered module must not use an ignored directory: ${part}`);
      }
      current = exactEntry(current, part, 'directory');
    }
    if (exactEntry(current, 'arkdb-package.json', 'file', { optional: true }) !== null) {
      directories.push(current);
    }
  }
  return directories.sort((left, right) =>
    compareText(repositoryPath(root, left), repositoryPath(root, right)));
}

function packageSources(directory) {
  const index = exactEntry(directory, 'Index.ets', 'file');
  const source = exactEntry(directory, 'src', 'directory');
  const main = exactEntry(source, 'main', 'directory');
  const runtime = exactEntry(main, 'ets', 'directory');
  const files = [index];
  walk(runtime, (file) => {
    if (file.endsWith('.ets')) {
      files.push(file);
    } else if (ARKTS_LIKE_SOURCE.test(file)) {
      throw new Error(`ArkDB runtime source ${file} must use the exact lowercase .ets suffix.`);
    }
  }, () => false);
  return files;
}

function toolingSources(root) {
  const directory = exactEntry(root, 'tools', 'directory', { optional: true });
  if (directory === null) return [];
  const files = [];
  walk(directory, (file) => {
    if (file.toLowerCase().endsWith(`${sep}package.json`.toLowerCase())) {
      throw new Error(`Nested Node tooling package scope is not supported: ${file}`);
    }
    if (/\.test\.(?:[cm]?[jt]s)$/.test(file)) return;
    if (NODE_LIKE_SOURCE.test(file) && !NODE_SOURCE.test(file)) {
      throw new Error(`Node tooling source ${file} must use the exact lowercase .mjs suffix.`);
    }
    if (NODE_SOURCE.test(file)) files.push(file);
  }, (parent, name) => parent === directory && name === 'build' ? false : ignoredDirectory(name));
  return files;
}

function hvigorSources(root, packageRoots) {
  return [
    exactEntry(root, 'hvigorfile.ts', 'file', { optional: true }),
    ...packageRoots.map((packageRoot) =>
      exactEntry(packageRoot, 'hvigorfile.ts', 'file', { optional: true }))
  ].filter((file) => file !== null);
}

function packageEntries(directories) {
  const entries = [];
  for (const directory of directories) {
    const manifestFile = exactEntry(directory, 'oh-package.json5', 'file');
    let manifest;
    try {
      manifest = JSON5.parse(readFileSync(manifestFile, 'utf8'));
    } catch (error) {
      throw new Error(`Cannot parse ArkDB package manifest: ${manifestFile}`, { cause: error });
    }
    if (typeof manifest?.name !== 'string' || manifest.name.length === 0) {
      throw new Error(`ArkDB package manifest is missing its name: ${manifestFile}`);
    }
    entries.push({ name: manifest.name, directory });
  }
  return entries;
}

function rootPackageName(root) {
  const manifestFile = exactEntry(root, 'package.json', 'file', { optional: true });
  if (manifestFile === null) return null;
  let manifest;
  try {
    manifest = JSON5.parse(readFileSync(manifestFile, 'utf8'));
  } catch (error) {
    throw new Error(`Cannot parse root Node package manifest: ${manifestFile}`, { cause: error });
  }
  return typeof manifest?.name === 'string' && manifest.name.length > 0 ? manifest.name : null;
}

function sourceSyntax(file) {
  const source = readFileSync(file, 'utf8');
  const kind = file.endsWith('.ets') || file.endsWith('.ts')
    ? ts.ScriptKind.TS
    : ts.ScriptKind.JS;
  const syntax = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind);
  if (syntax.parseDiagnostics.length > 0) {
    throw new Error(`Cannot parse architecture source: ${file}`);
  }
  return syntax;
}

function unwrapParentheses(node) {
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

function processExpression(node) {
  const expression = unwrapParentheses(node);
  return (ts.isIdentifier(expression) && expression.text === 'process') ||
    (ts.isPropertyAccessExpression(expression) &&
      ts.isIdentifier(unwrapParentheses(expression.expression)) &&
      unwrapParentheses(expression.expression).text === 'globalThis' &&
      expression.name.text === 'process') ||
    (ts.isElementAccessExpression(expression) &&
      ts.isIdentifier(unwrapParentheses(expression.expression)) &&
      unwrapParentheses(expression.expression).text === 'globalThis' &&
      expression.argumentExpression !== undefined &&
      ts.isStringLiteralLike(unwrapParentheses(expression.argumentExpression)) &&
      unwrapParentheses(expression.argumentExpression).text === 'process');
}

function reflectExpression(node) {
  const expression = unwrapParentheses(node);
  return (ts.isIdentifier(expression) && expression.text === 'Reflect') ||
    (ts.isPropertyAccessExpression(expression) &&
      ts.isIdentifier(unwrapParentheses(expression.expression)) &&
      unwrapParentheses(expression.expression).text === 'globalThis' &&
      expression.name.text === 'Reflect') ||
    (ts.isElementAccessExpression(expression) &&
      ts.isIdentifier(unwrapParentheses(expression.expression)) &&
      unwrapParentheses(expression.expression).text === 'globalThis' &&
      expression.argumentExpression !== undefined &&
      ts.isStringLiteralLike(unwrapParentheses(expression.argumentExpression)) &&
      unwrapParentheses(expression.argumentExpression).text === 'Reflect');
}

function moduleExpression(node) {
  const expression = unwrapParentheses(node);
  return (ts.isIdentifier(expression) && expression.text === 'module') ||
    (ts.isPropertyAccessExpression(expression) &&
      ts.isIdentifier(unwrapParentheses(expression.expression)) &&
      unwrapParentheses(expression.expression).text === 'globalThis' &&
      expression.name.text === 'module') ||
    (ts.isElementAccessExpression(expression) &&
      ts.isIdentifier(unwrapParentheses(expression.expression)) &&
      unwrapParentheses(expression.expression).text === 'globalThis' &&
      expression.argumentExpression !== undefined &&
      constantString(expression.argumentExpression) === 'module');
}

function rootedAtGlobalThis(node) {
  let expression = unwrapParentheses(node);
  while (ts.isPropertyAccessExpression(expression) ||
    ts.isElementAccessExpression(expression)) {
    expression = unwrapParentheses(expression.expression);
  }
  return ts.isIdentifier(expression) && expression.text === 'globalThis';
}

function memberOwnedBy(node, owner) {
  const expression = unwrapParentheses(node);
  if (!ts.isPropertyAccessExpression(expression) &&
    !ts.isElementAccessExpression(expression)) {
    return false;
  }
  const target = unwrapParentheses(expression.expression);
  return ts.isIdentifier(target) && target.text === owner;
}

function reflectiveCall(node) {
  if (!ts.isCallExpression(node)) return false;
  return memberOwnedBy(node.expression, 'Reflect');
}

function moduleRequireAccess(node) {
  let expression = unwrapParentheses(node);
  const names = [];
  while (ts.isPropertyAccessExpression(expression) ||
    ts.isElementAccessExpression(expression)) {
    if (ts.isPropertyAccessExpression(expression)) {
      names.push(expression.name.text);
    } else if (expression.argumentExpression !== undefined) {
      names.push(constantString(expression.argumentExpression));
    }
    expression = unwrapParentheses(expression.expression);
  }
  return ts.isIdentifier(expression) &&
    ['global', 'globalThis', 'module'].includes(expression.text) &&
    names.includes('require');
}

function constantString(node) {
  const expression = unwrapParentheses(node);
  if (ts.isStringLiteralLike(expression)) return expression.text;
  if (ts.isBinaryExpression(expression) &&
    expression.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const left = constantString(expression.left);
    const right = constantString(expression.right);
    if (left !== null && right !== null) return `${left}${right}`;
  }
  return null;
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

function referencedLoaderIdentifier(node, name) {
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

function referencedPathSpecifier(fileName) {
  if (fileName.startsWith('.') || isAbsolute(fileName) ||
    /^[A-Za-z]:[\\/]/.test(fileName) ||
    /^[A-Za-z][A-Za-z0-9+.-]*:/.test(fileName)) {
    return fileName;
  }
  return `./${fileName}`;
}

function staticSpecifiers(file) {
  const syntax = sourceSyntax(file);
  const specifiers = [
    ...syntax.referencedFiles.map((reference) =>
      referencedPathSpecifier(reference.fileName)),
    ...syntax.typeReferenceDirectives.map((reference) => reference.fileName)
  ];
  function visit(node) {
    if (buildToolSource(file) && ts.isIdentifier(node) &&
      (node.text === 'eval' || node.text === 'Function')) {
      throw new Error(`Node code generation is not supported: ${file}`);
    } else if (buildToolSource(file) &&
      referencedLoaderIdentifier(node, 'require')) {
      throw new Error(`CommonJS loader access is not supported: ${file}`);
    } else if (HVIGOR_SOURCE.test(file) &&
      (referencedLoaderIdentifier(node, 'arguments') ||
        referencedLoaderIdentifier(node, 'global') ||
        referencedLoaderIdentifier(node, 'globalThis') ||
        referencedLoaderIdentifier(node, 'module'))) {
      throw new Error(`CommonJS loader access is not supported: ${file}`);
    } else if (HVIGOR_SOURCE.test(file) &&
      (ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node)) &&
      moduleExpression(node)) {
      throw new Error(`CommonJS loader access is not supported: ${file}`);
    } else if (buildToolSource(file) &&
      ((ts.isPropertyAccessExpression(node) && node.name.text === 'constructor') ||
        (ts.isElementAccessExpression(node) &&
          node.argumentExpression !== undefined &&
          constantString(node.argumentExpression) === 'constructor'))) {
      throw new Error(`Node code generation is not supported: ${file}`);
    } else if (HVIGOR_SOURCE.test(file) &&
      (ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node)) &&
      moduleRequireAccess(node)) {
      throw new Error(`CommonJS loader access is not supported: ${file}`);
    } else if (buildToolSource(file) && ts.isIdentifier(node) &&
      node.text === 'getBuiltinModule') {
      throw new Error(`Node getBuiltinModule access is not supported: ${file}`);
    } else if (buildToolSource(file) && reflectiveCall(node)) {
      throw new Error(`Node reflective access is not supported: ${file}`);
    } else if (HVIGOR_SOURCE.test(file) && ts.isVariableDeclaration(node) &&
      node.initializer !== undefined &&
      moduleExpression(node.initializer)) {
      throw new Error(`CommonJS loader access is not supported: ${file}`);
    } else if (HVIGOR_SOURCE.test(file) && ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      moduleExpression(node.right)) {
      throw new Error(`CommonJS loader access is not supported: ${file}`);
    } else if (buildToolSource(file) && ts.isVariableDeclaration(node) &&
      node.initializer !== undefined &&
      ((ts.isIdentifier(unwrapParentheses(node.initializer)) &&
        unwrapParentheses(node.initializer).text === 'globalThis') ||
        reflectExpression(node.initializer) ||
        processExpression(node.initializer))) {
      const kind = ts.isIdentifier(unwrapParentheses(node.initializer)) &&
        unwrapParentheses(node.initializer).text === 'globalThis'
        ? 'globalThis'
        : reflectExpression(node.initializer) ? 'reflective' : 'process';
      throw new Error(`Node ${kind} aliases are not supported: ${file}`);
    } else if (buildToolSource(file) && ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ((ts.isIdentifier(unwrapParentheses(node.right)) &&
        unwrapParentheses(node.right).text === 'globalThis') ||
        reflectExpression(node.right) ||
        processExpression(node.right))) {
      const kind = ts.isIdentifier(unwrapParentheses(node.right)) &&
        unwrapParentheses(node.right).text === 'globalThis'
        ? 'globalThis'
        : reflectExpression(node.right) ? 'reflective' : 'process';
      throw new Error(`Node ${kind} aliases are not supported: ${file}`);
    } else if (buildToolSource(file) && ts.isElementAccessExpression(node) &&
      rootedAtGlobalThis(node)) {
      throw new Error(`Node computed globalThis access is not supported: ${file}`);
    } else if (buildToolSource(file) && ts.isElementAccessExpression(node) &&
      node.argumentExpression !== undefined &&
      ts.isStringLiteralLike(unwrapParentheses(node.argumentExpression)) &&
      unwrapParentheses(node.argumentExpression).text === 'getBuiltinModule') {
      throw new Error(`Node getBuiltinModule access is not supported: ${file}`);
    } else if (buildToolSource(file) && ts.isElementAccessExpression(node) &&
      processExpression(node.expression)) {
      throw new Error(`Node computed process access is not supported: ${file}`);
    } else if (ts.isCallExpression(node) &&
      node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      const kind = buildToolSource(file) ? 'Node' : 'ArkTS';
      throw new Error(`Dynamic ${kind} imports are not supported: ${file}`);
    } else if (buildToolSource(file) && ts.isCallExpression(node) &&
      memberOwnedBy(node.expression, 'module')) {
      throw new Error(`CommonJS loader access is not supported: ${file}`);
    } else if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
      node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
      if (buildToolSource(file) &&
        ['process', 'node:process'].includes(node.moduleSpecifier.text)) {
        throw new Error(`Node process module imports are not supported: ${file}`);
      }
      if (buildToolSource(file) &&
        ['module', 'node:module'].includes(node.moduleSpecifier.text)) {
        throw new Error(`Node createRequire-capable module imports are not supported: ${file}`);
      }
      specifiers.push(node.moduleSpecifier.text);
    } else if (ts.isImportEqualsDeclaration(node) &&
      ts.isExternalModuleReference(node.moduleReference) &&
      node.moduleReference.expression &&
      ts.isStringLiteral(node.moduleReference.expression)) {
      if (buildToolSource(file)) {
        throw new Error(`CommonJS imports are not supported: ${file}`);
      }
      specifiers.push(node.moduleReference.expression.text);
    } else if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument) &&
      ts.isStringLiteral(node.argument.literal)) {
      specifiers.push(node.argument.literal.text);
    }
    ts.forEachChild(node, visit);
  }
  visit(syntax);
  return specifiers;
}

function generatedBuildProfileImport(file, base, packages) {
  const owner = packages.find((entry) => {
    const path = relative(entry.directory, file);
    return path !== '..' && !path.startsWith(`..${sep}`) && !isAbsolute(path);
  });
  if (!owner) return false;
  const profile = join(owner.directory, 'BuildProfile');
  return pathKey(base) === pathKey(profile) || pathKey(base) === pathKey(`${profile}.ets`);
}

function canonicalNodeRelativePath(specifier) {
  const path = specifier.split(/[?#]/, 1)[0];
  if (path.includes('%')) return null;
  const segments = path.split('/');
  let start = 0;
  if (segments[0] === '.') start = 1;
  else {
    while (segments[start] === '..') start += 1;
    if (start === 0) return null;
  }
  const remainder = segments.slice(start);
  if (remainder.length === 0 || remainder.some((segment) =>
    segment.length === 0 || segment === '.' || segment === '..' ||
    !/^[A-Za-z0-9._-]+$/.test(segment)) ||
    !remainder.at(-1).endsWith('.mjs')) {
    return null;
  }
  return path;
}

function hasNoncanonicalNodeDotSegment(specifier) {
  const segments = specifier.split(/[?#]/, 1)[0].split('/');
  let start = 0;
  if (segments[0] === '.') start = 1;
  else while (segments[start] === '..') start += 1;
  return segments.slice(start).some((segment) => /^(?:(?:\.|%2e)){1,2}$/i.test(segment));
}

function resolveSource(file, specifier, sources, packages, toolingPackage) {
  let base;
  let required = false;
  let arkTsRequired = false;
  const nodeSource = NODE_SOURCE.test(file);
  const buildSource = buildToolSource(file);
  if (buildSource && /[\u0000-\u0020]/.test(specifier)) {
    throw new Error(`Node tooling imports must use canonical URL encoding: ${specifier}`);
  }
  if (buildSource && specifier.includes('\\')) {
    throw new Error(`Node tooling imports must use URL path separators: ${specifier}`);
  }
  const nodeRelative = specifier === '.' || specifier === '..' ||
    specifier.startsWith('./') || specifier.startsWith('../');
  if (buildSource && specifier.startsWith('.') && !nodeRelative) {
    throw new Error(`Node tooling imports require a valid relative Node specifier: ${specifier}`);
  }
  if (buildSource && specifier.startsWith('#')) {
    throw new Error(`Node package import mappings are not supported by architecture scanning: ${specifier}`);
  }
  let absoluteUrl = null;
  if (buildSource && !nodeRelative) {
    try {
      absoluteUrl = new URL(specifier);
    } catch {
      absoluteUrl = null;
    }
  }
  if (buildSource && absoluteUrl !== null && absoluteUrl.protocol !== 'node:') {
    throw new Error(`Unsupported absolute Node module URL: ${specifier}`);
  }
  if (buildSource && absoluteUrl?.protocol === 'node:') return null;
  if (buildSource && specifier.startsWith('/')) {
    throw new Error(`Unsupported absolute Node module URL: ${specifier}`);
  }
  let nodeLocal = false;
  if (HVIGOR_SOURCE.test(file) && nodeRelative) {
    throw new Error(`Hvigor local imports are not supported by architecture scanning: ${specifier}`);
  } else if (nodeSource && nodeRelative) {
    const rawPath = specifier.split(/[?#]/, 1)[0];
    if (/%(?:2f|5c)/i.test(rawPath)) {
      throw new Error(`Node tooling imports must not use an encoded path separator: ${specifier}`);
    }
    if (!rawPath.endsWith('.mjs')) {
      throw new Error(`Node tooling imports must target .mjs sources: ${specifier}`);
    }
    const path = canonicalNodeRelativePath(specifier);
    if (path === null) {
      if (hasNoncanonicalNodeDotSegment(specifier)) {
        throw new Error(`Node tooling imports must not use a noncanonical dot segment: ${specifier}`);
      }
      throw new Error(`Node tooling imports require a canonical relative .mjs specifier: ${specifier}`);
    }
    nodeLocal = true;
    required = true;
    base = resolve(dirname(file), ...path.split('/'));
  } else if (specifier.startsWith('.')) {
    base = resolve(dirname(file), specifier);
    arkTsRequired = true;
  } else {
    if (buildSource) {
      if (toolingPackage !== null &&
        (specifier === toolingPackage || specifier.startsWith(`${toolingPackage}/`))) {
        throw new Error(`Root Node package self-reference is not supported: ${specifier}`);
      }
      return null;
    }
    const entry = packages.find((candidate) =>
      specifier === candidate.name || specifier.startsWith(`${candidate.name}/`));
    if (!entry) return null;
    const suffix = specifier === entry.name ? 'Index' : specifier.slice(entry.name.length + 1);
    base = resolve(entry.directory, suffix);
    arkTsRequired = true;
  }
  const candidates = nodeLocal ? [base] : [
    base, `${base}.ets`, `${base}.d.ets`, join(base, 'Index.ets')
  ];
  for (const candidate of candidates) {
    const target = sources.get(pathKey(candidate));
    if (target !== undefined) return target;
  }
  const foldedCandidates = new Set(candidates.map((candidate) => pathKey(candidate).toLowerCase()));
  for (const [sourcePath, target] of sources) {
    if (foldedCandidates.has(sourcePath.toLowerCase())) {
      throw new Error(`Architecture imports require exact import path case for ${specifier} ` +
        `from ${file}; found ${target}.`);
    }
  }
  if (required) {
    throw new Error(`Cannot resolve local architecture import ${specifier} from ${file}`);
  }
  if (arkTsRequired) {
    if (generatedBuildProfileImport(file, base, packages)) return null;
    throw new Error(`Cannot resolve ArkTS architecture import ${specifier} from ${file}`);
  }
  return null;
}

/**
 * Reads ArkDB runtime and Node tooling sources without loading or executing them.
 *
 * @param {string} root
 * @returns {ArchitectureGraph}
 */
export function readArkTsGraph(root) {
  const directory = resolve(root);
  if (!existsSync(directory)) throw new Error(`Architecture root does not exist: ${directory}`);
  const info = lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new Error(`Architecture root must be a real directory: ${directory}`);
  }
  const packageRoots = packageDirectories(directory);
  const packages = packageEntries(packageRoots);
  const toolingPackage = rootPackageName(directory);
  const absoluteFiles = [
    ...packageRoots.flatMap((packageRoot) => packageSources(packageRoot)),
    ...hvigorSources(directory, packageRoots),
    ...toolingSources(directory)
  ];
  const sources = new Map(absoluteFiles.map((file) => [pathKey(file), file]));
  const files = absoluteFiles.map((file) => repositoryPath(directory, file))
    .sort(compareText);
  const dependencies = {};
  for (const file of absoluteFiles.sort((left, right) =>
    compareText(repositoryPath(directory, left), repositoryPath(directory, right)))) {
    const sourcePath = repositoryPath(directory, file);
    dependencies[sourcePath] = [...new Set(staticSpecifiers(file)
      .map((specifier) => resolveSource(file, specifier, sources, packages, toolingPackage))
      .filter((target) => target !== null)
      .map((target) => repositoryPath(directory, target)))]
      .sort(compareText);
  }
  return { files, dependencies };
}

function checkedGraph(graph) {
  if (!graph || !Array.isArray(graph.files) || graph.files.some((file) => typeof file !== 'string') ||
    !graph.dependencies || typeof graph.dependencies !== 'object' || Array.isArray(graph.dependencies)) {
    throw new Error('Architecture graph must contain files and dependencies.');
  }
  const files = [...graph.files].sort(compareText);
  if (new Set(files).size !== files.length) throw new Error('Architecture graph files must be unique.');
  const known = new Set(files);
  const dependencies = new Map();
  for (const file of files) {
    const targets = graph.dependencies[file];
    if (!Array.isArray(targets) || targets.some((target) => typeof target !== 'string')) {
      throw new Error(`Architecture graph dependencies must be listed for ${file}.`);
    }
    const ordered = [...targets].sort(compareText);
    if (new Set(ordered).size !== ordered.length || ordered.some((target) => !known.has(target))) {
      throw new Error(`Architecture graph contains an invalid dependency from ${file}.`);
    }
    dependencies.set(file, ordered);
  }
  return { files, dependencies };
}

/**
 * Returns deterministic cyclic strongly connected file sets.
 *
 * @param {ArchitectureGraph} graph
 * @returns {string[][]}
 */
export function stronglyConnectedFiles(graph) {
  const { files, dependencies } = checkedGraph(graph);
  const indices = new Map();
  const lowLinks = new Map();
  const stack = [];
  const stacked = new Set();
  const components = [];
  let nextIndex = 0;

  function connect(file) {
    indices.set(file, nextIndex);
    lowLinks.set(file, nextIndex);
    nextIndex += 1;
    stack.push(file);
    stacked.add(file);

    for (const dependency of dependencies.get(file)) {
      if (!indices.has(dependency)) {
        connect(dependency);
        lowLinks.set(file, Math.min(lowLinks.get(file), lowLinks.get(dependency)));
      } else if (stacked.has(dependency)) {
        lowLinks.set(file, Math.min(lowLinks.get(file), indices.get(dependency)));
      }
    }

    if (lowLinks.get(file) !== indices.get(file)) return;
    const component = [];
    let member;
    do {
      member = stack.pop();
      stacked.delete(member);
      component.push(member);
    } while (member !== file);
    component.sort(compareText);
    if (component.length > 1 || dependencies.get(file).includes(file)) components.push(component);
  }

  for (const file of files) {
    if (!indices.has(file)) connect(file);
  }
  return components.sort((left, right) => {
    const first = compareText(left[0], right[0]);
    return first === 0 ? compareText(left.join('\0'), right.join('\0')) : first;
  });
}

function matchesPath(file, pattern) {
  if (typeof pattern === 'string') {
    if (!pattern.includes('*')) return file === pattern;
    const expression = pattern.split('*')
      .map((part) => part.replace(/[\\^$.[\]{}()+?|]/g, '\\$&')).join('.*');
    return new RegExp(`^${expression}$`).test(file);
  }
  if (pattern instanceof RegExp) {
    pattern.lastIndex = 0;
    return pattern.test(file);
  }
  throw new Error('Architecture policy path patterns must be strings or regular expressions.');
}

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype;
}

function unknownField(value, allowed) {
  return Object.keys(value).find((field) => !allowed.has(field));
}

function architecturePathPattern(value) {
  return (typeof value === 'string' && value.length > 0) || value instanceof RegExp;
}

function dependencyPaths(source, dependencies) {
  const paths = new Map();
  const visited = new Set([source]);
  const pending = dependencies.get(source)
    .map((dependency) => [source, dependency]);
  while (pending.length > 0) {
    const path = pending.shift();
    const target = path.at(-1);
    if (visited.has(target)) continue;
    visited.add(target);
    paths.set(target, path);
    for (const dependency of dependencies.get(target)) {
      pending.push([...path, dependency]);
    }
  }
  return paths;
}

/**
 * Enforces zero import cycles and prohibited dependency rules.
 *
 * @param {ArchitectureGraph} graph
 * @param {ArchitecturePolicy} policy
 * @returns {void}
 */
export function assertImportPolicy(graph, policy) {
  if (!plainObject(policy)) throw new Error('Architecture policy must be a plain object.');
  if (Object.hasOwn(policy, 'allowedCycles')) {
    throw new Error('Cycle allowlists are not supported.');
  }
  const unexpectedPolicyField = unknownField(policy, new Set([
    'ownedSourceRoots', 'forbiddenSources', 'prohibitedDependencies'
  ]));
  if (unexpectedPolicyField !== undefined) {
    throw new Error(`Unknown architecture policy field: ${unexpectedPolicyField}`);
  }
  const { files, dependencies } = checkedGraph(graph);
  const forbiddenSources = policy.forbiddenSources ?? [];
  if (!Array.isArray(forbiddenSources)) throw new Error('Forbidden sources must be a list.');
  if (forbiddenSources.some((pattern) => !architecturePathPattern(pattern))) {
    throw new Error('Forbidden sources must contain path patterns.');
  }
  for (const file of files) {
    if (forbiddenSources.some((pattern) => matchesPath(file, pattern))) {
      throw new Error(`Stale architecture source is forbidden: ${file}`);
    }
  }
  if (!Array.isArray(policy.ownedSourceRoots) ||
    policy.ownedSourceRoots.length === 0) {
    throw new Error('Architecture policy must define nonempty owned source roots.');
  }
  const roots = policy.ownedSourceRoots.map((entry) => {
      if (!plainObject(entry)) {
        throw new Error('Owned source roots must contain plain objects.');
      }
      const unexpectedRootField = unknownField(entry, new Set([
        'root', 'files', 'directories'
      ]));
      if (unexpectedRootField !== undefined) {
        throw new Error(`Unknown owned source root field: ${unexpectedRootField}`);
      }
      const root = entry?.root;
      const ownedFiles = entry?.files ?? [];
      const ownedDirectories = entry?.directories ?? [];
      if (typeof root !== 'string' ||
        (root !== '' &&
          !/^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*$/.test(root)) ||
        !Array.isArray(ownedFiles) ||
        ownedFiles.some((file) =>
          typeof file !== 'string' || !/^[A-Za-z0-9._-]+$/.test(file)) ||
        new Set(ownedFiles).size !== ownedFiles.length ||
        !Array.isArray(ownedDirectories) ||
        ownedDirectories.some((directory) =>
          typeof directory !== 'string' || !/^[A-Za-z0-9._-]+$/.test(directory)) ||
        new Set(ownedDirectories).size !== ownedDirectories.length) {
        throw new Error('Owned source roots must define canonical roots, files, and directories.');
      }
      return {
        root,
        files: new Set(ownedFiles),
        directories: new Set(ownedDirectories)
      };
  });
  if (new Set(roots.map((entry) => entry.root)).size !== roots.length) {
    throw new Error('Owned source roots must be unique.');
  }
  roots.sort((left, right) => right.root.length - left.root.length);
  for (const file of files) {
    const owner = roots.find((entry) =>
      entry.root === '' || file.startsWith(`${entry.root}/`));
    if (owner === undefined) throw new Error(`Unowned architecture source: ${file}`);
    const path = owner.root === '' ? file : file.slice(owner.root.length + 1);
    const separator = path.indexOf('/');
    const owned = separator === -1
      ? owner.files.has(path)
      : owner.directories.has(path.slice(0, separator));
    if (!owned) throw new Error(`Unowned architecture source: ${file}`);
  }
  const rules = policy.prohibitedDependencies ?? [];
  if (!Array.isArray(rules)) throw new Error('Prohibited dependencies must be a list.');
  for (const rule of rules) {
    if (!plainObject(rule) || !('from' in rule) || !('to' in rule)) {
      throw new Error('Each prohibited dependency must define from and to patterns.');
    }
    const unexpectedRuleField = unknownField(rule, new Set([
      'from', 'to', 'transitive', 'message'
    ]));
    if (unexpectedRuleField !== undefined) {
      throw new Error(`Unknown architecture dependency rule field: ${unexpectedRuleField}`);
    }
    if (!architecturePathPattern(rule.from) || !architecturePathPattern(rule.to)) {
      throw new Error('Architecture dependency rules must use path patterns.');
    }
    if (rule.transitive !== undefined && typeof rule.transitive !== 'boolean') {
      throw new Error('Architecture dependency rule transitive must be boolean.');
    }
    if (rule.message !== undefined && typeof rule.message !== 'string') {
      throw new Error('Architecture dependency rule message must be a string.');
    }
    for (const file of files) {
      if (!matchesPath(file, rule.from)) continue;
      const paths = rule.transitive === true
        ? dependencyPaths(file, dependencies)
        : new Map(dependencies.get(file).map((dependency) =>
          [dependency, [file, dependency]]));
      for (const [dependency, path] of paths) {
        if (!matchesPath(dependency, rule.to)) continue;
        const message = rule.message ?? 'Prohibited dependency';
        throw new Error(`${message}: ${path.join(' -> ')}`);
      }
    }
  }

  const actual = stronglyConnectedFiles(graph);
  if (actual.length > 0) {
    throw new Error(`Unexpected import cycle: ${actual[0].join(' -> ')}`);
  }
}
