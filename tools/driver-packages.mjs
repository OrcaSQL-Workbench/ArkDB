import { lstatSync, readFileSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import JSON5 from 'json5';

export const ROOT = fileURLToPath(new URL('..', import.meta.url));
const DRIVER_ID = /^[a-z][a-z0-9_-]*$/;
const DRIVER_TAG = /^([a-z][a-z0-9_-]*)-v([1-9]\d?(?:\.(?:[1-9]?\d)){2})$/;

export function readJson5(file) {
  const info = lstatSync(file);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error(`Expected a regular configuration file: ${file}`);
  return JSON5.parse(readFileSync(file, 'utf8'));
}

function registrations(root) {
  const modules = readJson5(join(root, 'build-profile.json5'))?.modules;
  if (!Array.isArray(modules)) throw new Error('Workspace build profile must contain a module registry.');
  const names = new Set();
  for (const module of modules) {
    if (typeof module?.name !== 'string' || !DRIVER_ID.test(module.name) || names.has(module.name) ||
      typeof module.srcPath !== 'string' || module.srcPath.length === 0 || isAbsolute(module.srcPath)) {
      throw new Error('Workspace module names/paths must be explicit, unique, and valid.');
    }
    names.add(module.name);
  }
  return modules;
}

function moduleAt(root, registration) {
  const directory = resolve(root, registration.srcPath);
  const path = relative(resolve(root), directory);
  if (path === '' || path === '..' || path.startsWith(`..${sep}`) || isAbsolute(path)) {
    throw new Error(`Driver ${registration.name} must be inside the repository.`);
  }
  let current = resolve(root);
  for (const part of path.split(sep)) {
    current = join(current, part);
    let info;
    try {
      info = lstatSync(current);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      throw new Error(`Workspace must register the ${registration.name} HAR at an existing source path.`, { cause: error });
    }
    if (info.isSymbolicLink() || !info.isDirectory()) {
      throw new Error(`Driver ${registration.name} must use real source directories, not links.`);
    }
  }
  const definition = readJson5(join(directory, 'src', 'main', 'module.json5')).module;
  if (definition?.name !== registration.name) throw new Error(`Module identity differs at ${registration.srcPath}.`);
  return {
    id: registration.name, directory, sourcePath: path.split(sep).join('/'),
    definition
  };
}

export function resolvePackage(root = ROOT, id = 'mysql') {
  if (!DRIVER_ID.test(id) || id === 'all') throw new Error('Select a registered driver module name, not a filesystem path.');
  const modules = registrations(root);
  const registration = modules.find((module) => module.name === id);
  if (!registration) {
    throw new Error(`Driver "${id}" is not implemented/registered. Available module names: ${modules.map((module) => module.name).join(', ')}`);
  }
  const driver = moduleAt(root, registration);
  if (driver.definition.type !== 'har') throw new Error(`Module ${id} is not an ArkDB HAR.`);
  const manifest = readJson5(join(driver.directory, 'oh-package.json5'));
  const artifact = packageStem(manifest);
  const declaration = readJson5(join(driver.directory, 'arkdb-package.json'));
  const kind = declaration.kind;
  if (!['driver', 'shared'].includes(kind)) {
    throw new Error(`HAR ${id} must declare kind as driver or shared in arkdb-package.json.`);
  }
  return { ...driver, manifest, declaration, kind, packageName: manifest.name, version: manifest.version, artifact };
}

export function resolveDriver(root = ROOT, id = 'mysql') {
  const driver = resolvePackage(root, id);
  if (driver.kind !== 'driver') throw new Error(`Shared HAR ${id} is not a database driver.`);
  return driver;
}

export function discoverPackages(root = ROOT) {
  const packages = registrations(root).map((registration) => moduleAt(root, registration))
    .filter((entry) => entry.definition.type === 'har').map((entry) => resolvePackage(root, entry.id));
  if (packages.length === 0) throw new Error('No implemented ArkDB HAR modules are registered.');
  if (new Set(packages.map((entry) => entry.packageName)).size !== packages.length) {
    throw new Error('Each HAR must have its own package identity.');
  }
  return packages;
}

function orderedDependencies(packages, id) {
  const ordered = [];
  const visited = new Set();
  const visiting = new Set();
  function visit(entry) {
    if (visited.has(entry.id)) return;
    if (visiting.has(entry.id)) throw new Error(`Cyclic HAR dependency at ${entry.id}.`);
    visiting.add(entry.id);
    for (const [name, version] of Object.entries(entry.manifest.dependencies ?? {})) {
      const dependency = packages.find((candidate) => candidate.packageName === name);
      if (!dependency || dependency.version !== version) {
        throw new Error(`HAR ${entry.id} requires an exact, registered dependency: ${name}@${version}.`);
      }
      if (entry.kind === 'shared' && dependency.kind === 'driver') {
        throw new Error(`Shared HAR ${entry.id} must not depend on driver ${dependency.id}.`);
      }
      visit(dependency);
    }
    visiting.delete(entry.id);
    visited.add(entry.id);
    ordered.push(entry);
  }
  const selected = packages.find((entry) => entry.id === id);
  if (!selected) throw new Error(`HAR ${id} is not implemented/registered.`);
  visit(selected);
  return ordered;
}

export function dependencyClosure(root = ROOT, id = 'mysql') {
  return orderedDependencies(discoverPackages(root), id);
}

export function localOutputPaths(root = ROOT, id = 'mysql') {
  const entry = resolvePackage(root, id);
  return versionOutputPaths(root, entry.id, entry.version);
}

function versionOutputPaths(root, id, version) {
  const tag = `${id}-v${version}`;
  const directory = join(root, 'build', tag);
  return {
    tag, directory, artifacts: directory,
    evidence: join(directory, 'evidence'),
    publicationRecord: join(directory, 'evidence', `${tag}.publication.json`),
    consumers: join(directory, 'work'),
    workspaces: join(directory, 'work'),
    ready: join(root, 'dist', tag)
  };
}

export function tagOutputPaths(root, id, tag) {
  const driver = resolveDriver(root, id);
  const match = typeof tag === 'string' ? tag.match(DRIVER_TAG) : null;
  if (!match || match[1] !== driver.id) {
    throw new Error('Output paths require a matching registered driver-version tag.');
  }
  return versionOutputPaths(root, driver.id, match[2]);
}

export function downloadOutputPaths(root, id, tag) {
  const paths = tagOutputPaths(root, id, tag);
  return { directory: paths.workspaces, record: join(paths.evidence, `${tag}.download.json`) };
}

export function discoverDrivers(root = ROOT) {
  const packages = discoverPackages(root);
  const drivers = packages.filter((entry) => entry.kind === 'driver').map((entry) => ({
    ...entry, dependencySourcePaths: orderedDependencies(packages, entry.id)
      .filter((dependency) => dependency.id !== entry.id).map((dependency) => dependency.sourcePath)
  }));
  if (drivers.length === 0) throw new Error('No implemented HAR driver modules are registered.');
  return drivers;
}

export function driverVerification(root = ROOT, id = 'mysql') {
  const driver = resolveDriver(root, id);
  const verification = driver.declaration.verification;
  const closure = dependencyClosure(root, id);
  if (typeof verification?.consumer !== 'string' ||
    !/^[a-zA-Z0-9_-]+(?:\/[a-zA-Z0-9_-]+)*$/.test(verification.consumer) ||
    !Array.isArray(verification.nativeModules) ||
    verification.nativeModules.length !== closure.length ||
    new Set(verification.nativeModules).size !== closure.length ||
    closure.some((entry) => !verification.nativeModules.includes(entry.id)) ||
    typeof verification.requiresInternet !== 'boolean') {
    throw new Error(`Driver ${id} must declare its own consumer and native verification modules.`);
  }
  const consumerDirectory = join(root, ...verification.consumer.split('/'));
  let current = resolve(root);
  for (const part of verification.consumer.split('/')) {
    current = join(current, part);
    const info = lstatSync(current);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Consumer must use real in-repository directories.');
  }
  return { ...verification, consumerDirectory, driver };
}

export function packageStem(manifest) {
  if (!/^@arkdb\/[a-z][a-z0-9-]*$/.test(manifest.name ?? '') ||
    !/^[1-9]\d?(?:\.(?:[1-9]?\d)){2}$/.test(manifest.version ?? '')) {
    throw new Error('Cannot derive an artifact name from an invalid ArkDB package identity.');
  }
  return `${manifest.name.slice(1).replace('/', '-')}-${manifest.version}`;
}

export function localArtifactStem(manifest) {
  return `${packageStem(manifest)}-local`;
}

export function driverArgument(args) {
  if (args.length === 0) return 'mysql';
  if (args.length !== 2 || args[0] !== '--driver' || !DRIVER_ID.test(args[1]) || args[1] === 'all') {
    throw new Error('Usage: --driver REGISTERED_MODULE_NAME (default: mysql)');
  }
  return args[1];
}

export function affectedDrivers(drivers, paths) {
  const shared = new Set(['LICENSE', 'build-profile.json5', 'hvigorfile.ts', 'oh-package.json5',
    'package.json', 'package-lock.json']);
  if (paths.some((path) => shared.has(path) || path.startsWith('hvigor/') ||
    path.startsWith('tools/') || path.startsWith('AppScope/') || path.startsWith('examples/') ||
    path.startsWith('.github/workflows/') || path.startsWith('.github/actions/'))) {
    return drivers;
  }
  return drivers.filter((driver) => [driver.sourcePath, ...(driver.dependencySourcePaths ?? [])]
    .some((sourcePath) => paths.some((path) => path === sourcePath || path.startsWith(`${sourcePath}/`))));
}

export function driverForTag(drivers, tag) {
  const match = tag.match(DRIVER_TAG);
  if (!match) throw new Error('Driver tags must have the form mysql-v1.0.0.');
  const driver = drivers.find((entry) => entry.id === match[1]);
  if (!driver || driver.version !== match[2]) {
    throw new Error('Release tag must identify an implemented driver and match its committed package version.');
  }
  return driver;
}
