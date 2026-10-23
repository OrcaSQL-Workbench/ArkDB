import { lstatSync, readFileSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import JSON5 from 'json5';

export const ROOT = fileURLToPath(new URL('..', import.meta.url));
const DRIVER_ID = /^[a-z][a-z0-9_-]*$/;

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

export function resolveDriver(root = ROOT, id = 'mysql') {
  if (!DRIVER_ID.test(id) || id === 'all') throw new Error('Select a registered driver module name, not a filesystem path.');
  const modules = registrations(root);
  const registration = modules.find((module) => module.name === id);
  if (!registration) {
    throw new Error(`Driver "${id}" is not implemented/registered. Available module names: ${modules.map((module) => module.name).join(', ')}`);
  }
  const driver = moduleAt(root, registration);
  if (driver.definition.type !== 'har') throw new Error(`Module ${id} is not a driver HAR.`);
  return driver;
}

export function discoverDrivers(root = ROOT) {
  const drivers = registrations(root).map((registration) => moduleAt(root, registration))
    .filter((driver) => driver.definition.type === 'har');
  if (drivers.length === 0) throw new Error('No implemented HAR driver modules are registered.');
  const packages = new Set();
  return drivers.map((driver) => {
    const manifest = readJson5(join(driver.directory, 'oh-package.json5'));
    if (!/^@arkdb\/[a-z][a-z0-9-]*$/.test(manifest.name ?? '') ||
      !/^[1-9]\d?(?:\.(?:[1-9]?\d)){2}$/.test(manifest.version ?? '')) {
      throw new Error(`Driver ${driver.id} needs a valid ArkDB package name/version.`);
    }
    if (packages.has(manifest.name)) throw new Error('Each driver must have its own package identity.');
    packages.add(manifest.name);
    return { ...driver, packageName: manifest.name, version: manifest.version, artifact: packageStem(manifest) };
  });
}

export function packageStem(manifest) {
  if (!/^@arkdb\/[a-z][a-z0-9-]*$/.test(manifest.name ?? '') ||
    !/^[1-9]\d?(?:\.(?:[1-9]?\d)){2}$/.test(manifest.version ?? '')) {
    throw new Error('Cannot derive an artifact name from an invalid driver package identity.');
  }
  return `${manifest.name.slice(1).replace('/', '-')}-${manifest.version}`;
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
  return drivers.filter((driver) => paths.some((path) =>
    path === driver.sourcePath || path.startsWith(`${driver.sourcePath}/`)));
}

export function driverForTag(drivers, tag) {
  const match = tag.match(/^([a-z][a-z0-9_-]*)-v([1-9]\d?(?:\.(?:[1-9]?\d)){2})$/);
  if (!match) throw new Error('Driver tags must have the form mysql-v1.0.0.');
  const driver = drivers.find((entry) => entry.id === match[1]);
  if (!driver || driver.version !== match[2]) {
    throw new Error('Release tag must identify an implemented driver and match its committed package version.');
  }
  return driver;
}
