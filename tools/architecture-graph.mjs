import { existsSync, lstatSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
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
 *   allowedCycles?: string[][],
 *   prohibitedDependencies?: Array<{
 *     from: ArchitecturePathPattern,
 *     to: ArchitecturePathPattern,
 *     message?: string
 *   }>
 * }} ArchitecturePolicy
 */

const IGNORED_DIRECTORIES = new Set([
  '.git', '.hvigor', '.idea', '.ohpm-cache', '.preview', '.test',
  'build', 'dist', 'node_modules', 'oh_modules', 'test-fixtures'
]);
const NODE_SOURCE = /\.(?:c|m)?js$/;

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function pathKey(file) {
  return resolve(file);
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

function walk(directory, visitFile) {
  const info = lstatSync(directory);
  if (info.isSymbolicLink()) {
    throw new Error(`Architecture sources must not use symbolic links: ${directory}`);
  }
  if (!info.isDirectory()) throw new Error(`Architecture source must be a directory: ${directory}`);
  for (const entry of readdirSync(directory, { withFileTypes: true })
    .sort((left, right) => compareText(left.name, right.name))) {
    const file = join(directory, entry.name);
    if (ignoredDirectory(entry.name)) continue;
    if (entry.isSymbolicLink()) {
      throw new Error(`Architecture sources must not use symbolic links: ${file}`);
    }
    if (entry.isDirectory()) {
      walk(file, visitFile);
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
    if (file.endsWith('.ets')) files.push(file);
  });
  return files;
}

function toolingSources(root) {
  const directory = exactEntry(root, 'tools', 'directory', { optional: true });
  if (directory === null) return [];
  const files = [];
  walk(directory, (file) => {
    if (NODE_SOURCE.test(file) && !/\.test\.(?:c|m)?js$/.test(file)) files.push(file);
  });
  return files;
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

function sourceSyntax(file) {
  const source = readFileSync(file, 'utf8');
  const kind = file.endsWith('.ets') ? ts.ScriptKind.TS : ts.ScriptKind.JS;
  const syntax = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind);
  if (syntax.parseDiagnostics.length > 0) {
    throw new Error(`Cannot parse architecture source: ${file}`);
  }
  return syntax;
}

function staticSpecifiers(file) {
  const specifiers = [];
  function visit(node) {
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
      node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
      specifiers.push(node.moduleSpecifier.text);
    } else if (ts.isImportEqualsDeclaration(node) &&
      ts.isExternalModuleReference(node.moduleReference) &&
      node.moduleReference.expression &&
      ts.isStringLiteral(node.moduleReference.expression)) {
      specifiers.push(node.moduleReference.expression.text);
    } else if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument) &&
      ts.isStringLiteral(node.argument.literal)) {
      specifiers.push(node.argument.literal.text);
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceSyntax(file));
  return specifiers;
}

function resolveSource(file, specifier, sources, packages) {
  let base;
  if (specifier.startsWith('.')) {
    base = resolve(dirname(file), specifier);
  } else {
    const entry = packages.find((candidate) =>
      specifier === candidate.name || specifier.startsWith(`${candidate.name}/`));
    if (!entry) return null;
    const suffix = specifier === entry.name ? 'Index' : specifier.slice(entry.name.length + 1);
    base = resolve(entry.directory, suffix);
  }
  const candidates = [
    base,
    `${base}.ets`,
    `${base}.d.ets`,
    `${base}.mjs`,
    `${base}.js`,
    `${base}.cjs`,
    join(base, 'Index.ets'),
    join(base, 'index.mjs'),
    join(base, 'index.js'),
    join(base, 'index.cjs')
  ];
  for (const candidate of candidates) {
    const target = sources.get(pathKey(candidate));
    if (target !== undefined) return target;
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
  const absoluteFiles = [
    ...packageRoots.flatMap((packageRoot) => packageSources(packageRoot)),
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
      .map((specifier) => resolveSource(file, specifier, sources, packages))
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

function cycleKey(cycle) {
  if (!Array.isArray(cycle) || cycle.length === 0 ||
    cycle.some((file) => typeof file !== 'string')) {
    throw new Error('Allowed architecture cycles must be nonempty file lists.');
  }
  const ordered = [...cycle].sort(compareText);
  if (new Set(ordered).size !== ordered.length) {
    throw new Error('Allowed architecture cycles must not repeat files.');
  }
  return ordered.join('\0');
}

/**
 * Enforces exact known cycle findings and prohibited dependency rules.
 *
 * @param {ArchitectureGraph} graph
 * @param {ArchitecturePolicy} policy
 * @returns {void}
 */
export function assertImportPolicy(graph, policy) {
  if (!policy || typeof policy !== 'object') throw new Error('Architecture policy is required.');
  const { files, dependencies } = checkedGraph(graph);
  const rules = policy.prohibitedDependencies ?? [];
  if (!Array.isArray(rules)) throw new Error('Prohibited dependencies must be a list.');
  for (const rule of rules) {
    if (!rule || !('from' in rule) || !('to' in rule)) {
      throw new Error('Each prohibited dependency must define from and to patterns.');
    }
    for (const file of files) {
      if (!matchesPath(file, rule.from)) continue;
      for (const dependency of dependencies.get(file)) {
        if (!matchesPath(dependency, rule.to)) continue;
        const message = rule.message ?? 'Prohibited dependency';
        throw new Error(`${message}: ${file} -> ${dependency}`);
      }
    }
  }

  const allowedCycles = policy.allowedCycles ?? [];
  if (!Array.isArray(allowedCycles)) throw new Error('Allowed cycles must be a list.');
  const allowed = new Map(allowedCycles.map((cycle) => [cycleKey(cycle), cycle]));
  if (allowed.size !== allowedCycles.length) throw new Error('Allowed cycles must be unique.');
  const actual = stronglyConnectedFiles(graph);
  const actualKeys = new Set(actual.map(cycleKey));
  for (const cycle of actual) {
    if (!allowed.has(cycleKey(cycle))) {
      throw new Error(`Unexpected import cycle: ${cycle.join(' -> ')}`);
    }
  }
  for (const [key, cycle] of allowed) {
    if (!actualKeys.has(key)) {
      throw new Error(`Allowed import cycle is not present: ${[...cycle]
        .sort(compareText).join(' -> ')}`);
    }
  }
}
