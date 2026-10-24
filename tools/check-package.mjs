import { readFileSync, readdirSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
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
  const testFiles = listFiles(testRoot).filter((file) =>
    file.endsWith('.test.ets') && !file.endsWith(`${sep}List.test.ets`));
  const reached = new Set();
  const pending = [join(testRoot, 'List.test.ets')];
  while (pending.length > 0) {
    const file = pending.pop();
    if (reached.has(file)) continue;
    reached.add(file);
    const source = readFileSync(file, 'utf8');
    for (const match of source.matchAll(/\bimport\s+(\w+)\s+from\s+['"]([^'"]+)['"]/g)) {
      if (!new RegExp(`\\b${match[1]}\\s*\\(`).test(source)) {
        throw new Error(`Imported test suite is not called in ${relative(root, file)}.`);
      }
      const target = resolve(file, '..', `${match[2]}.ets`);
      if (target.endsWith(`${sep}List.test.ets`)) pending.push(target);
      else reached.add(target);
    }
  }
  const unregistered = testFiles.filter((file) => !reached.has(file));
  if (unregistered.length > 0 || testFiles.length === 0) {
    throw new Error(`Unregistered or missing ArkTS suites: ${unregistered.map((file) => relative(root, file)).join(', ')}`);
  }
  return { manifest, exports, driver, sourceFiles: files.length, testSuites: testFiles.length };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    const drivers = args.length === 0 ? discoverPackages().map((driver) => driver.id) : [driverArgument(args)];
    for (const id of drivers) {
      const result = checkPackage(ROOT, id);
      console.log(`Checked ${result.manifest.name}@${result.manifest.version}: ` +
        `${result.sourceFiles} source files, ${result.exports.length} exports, ${result.testSuites} ArkTS suites.`);
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
