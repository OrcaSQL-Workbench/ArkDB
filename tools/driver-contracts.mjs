import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  checkIsolatedArkTsProject, checkPackage, importSpecifiers, listFiles
} from './check-package.mjs';
import {
  discoverDrivers, discoverPackages, driverVerification, ROOT
} from './driver-packages.mjs';

function namesProject(value, identity) {
  const escaped = identity.replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');
  return new RegExp(`(?:^|[:/])${escaped}(?:$|/)`).test(value);
}

export function checkDriverContracts(root = ROOT) {
  const packages = discoverPackages(root);
  const core = packages.find((entry) => entry.packageName === '@arkdb/core');
  if (!core || core.kind !== 'shared') throw new Error('One shared @arkdb/core HAR is required.');
  const drivers = discoverDrivers(root);
  for (const driver of drivers) {
    const siblings = drivers.filter((candidate) => candidate.id !== driver.id);
    for (const sibling of siblings) {
      if (Object.hasOwn(driver.manifest.dependencies ?? {}, sibling.packageName)) {
        throw new Error(`Drivers must not depend on another driver: ` +
          `${driver.packageName} -> ${sibling.packageName}`);
      }
    }
    const runtimeFiles = [
      join(driver.directory, 'Index.ets'),
      ...listFiles(join(driver.directory, 'src', 'main', 'ets'))
        .filter((file) => file.endsWith('.ets'))
    ];
    for (const file of runtimeFiles) {
      for (const specifier of importSpecifiers(readFileSync(file, 'utf8'))) {
        const sibling = siblings.find((candidate) =>
          specifier === candidate.packageName ||
          specifier.startsWith(`${candidate.packageName}/`));
        if (sibling !== undefined) {
          throw new Error(`Drivers must not import another driver: ` +
            `${driver.packageName} -> ${specifier}`);
        }
      }
    }
  }
  for (const entry of packages) checkPackage(root, entry.id);
  const publicNames = new Set(checkPackage(root, core.id).exports);
  const sourceRoot = join(core.directory, 'src', 'main', 'ets');
  const sources = [join(core.directory, 'Index.ets'),
    ...listFiles(sourceRoot).filter((file) => file.endsWith('.ets'))];
  for (const file of sources) {
    const source = readFileSync(file, 'utf8');
    if (/\b(?:mysql|mariadb|postgresql|pgsql|innodb|performance_schema)\b/i.test(source)) {
      throw new Error(`Shared contracts must not contain an engine registry or vendor semantics: ${file}`);
    }
    if (importSpecifiers(source).some((specifier) =>
      drivers.some((driver) => specifier === driver.packageName))) {
      throw new Error('Core must not import a driver.');
    }
  }
  const info = readFileSync(join(sourceRoot, 'model', 'ServerInfo.ets'), 'utf8');
  const result = readFileSync(join(sourceRoot, 'model', 'QueryResult.ets'), 'utf8');
  if (/\b(?:family|protocolVersion|connectionId|capabilities|charset|authPlugin)\s*:/.test(info) ||
    /\b(?:table|type|flags|charset|decimals|columnLength)\s*:/.test(result)) {
    throw new Error('Portable server/column information must not contain native wire fields.');
  }
  const factory = readFileSync(join(sourceRoot, 'driver', 'DbDriverFactory.ets'), 'utf8');
  if (/\b(?:ConnectionConfig|password|createMetadataProvider|createExecutionController|createServerMetricsProvider)\b/.test(factory) ||
    !/DbDriverFactory<TOptions,\s*TConnection extends DbConnection>/.test(factory)) {
    throw new Error('Factory creation must retain adapter-owned typed options and optional providers.');
  }
  const connection = readFileSync(join(sourceRoot, 'connection', 'DbConnection.ets'), 'utf8')
    .match(/export interface DbConnection\s*\{([^}]+)\}/)?.[1];
  if (!connection || /\b(?:ping|queryStream|changeContext|begin|setAutocommit|commit|rollback)\s*\(/.test(connection)) {
    throw new Error('The base connection must not require optional capabilities.');
  }
  const allSources = packages.flatMap((entry) =>
    listFiles(join(entry.directory, 'src', 'main', 'ets')).filter((file) => file.endsWith('.ets')));
  if (allSources.filter((file) => /\bclass ArkDbError\b/.test(readFileSync(file, 'utf8'))).length !== 1) {
    throw new Error('ArkDbError must have exactly one runtime identity.');
  }
  const projects = [];
  for (const driver of drivers) {
    if (typeof driver.declaration.verification?.consumer === 'string') {
      const verification = driverVerification(root, driver.id);
      projects.push(checkIsolatedArkTsProject(root, verification.consumerDirectory));
      if (verification.deviceConsumerDirectory !== undefined) {
        projects.push(checkIsolatedArkTsProject(
          root, verification.deviceConsumerDirectory));
      }
    }
    if (driver.manifest.dependencies?.[core.packageName] !== core.version ||
      existsSync(join(driver.directory, 'src', 'main', 'ets', 'core', 'model', 'ArkDbError.ets'))) {
      throw new Error('Drivers must consume the shared core instead of embedding a private copy.');
    }
    const files = [join(driver.directory, 'Index.ets'),
      ...listFiles(join(driver.directory, 'src')).filter((file) => file.endsWith('.ets'))];
    for (const file of files) {
      const source = readFileSync(file, 'utf8');
      for (const match of source.matchAll(/\b(?:import|export)\s+(?:type\s+)?\{([^}]+)\}\s+from\s+['"]@arkdb\/core['"]/g)) {
        for (const binding of match[1].split(',')) {
          const name = binding.trim().split(/\s+as\s+/)[0];
          if (!publicNames.has(name)) throw new Error(`Unknown core public symbol in ${file}: ${name}`);
        }
      }
    }
  }
  for (let sourceIndex = 0; sourceIndex < projects.length; sourceIndex += 1) {
    const source = projects[sourceIndex];
    for (let targetIndex = 0; targetIndex < projects.length; targetIndex += 1) {
      if (sourceIndex === targetIndex) continue;
      const target = projects[targetIndex];
      for (const identity of target.identities) {
        const dependency = source.dependencies.find((entry) =>
          namesProject(entry.name, identity) ||
          (typeof entry.value === 'string' && namesProject(entry.value, identity)));
        if (dependency !== undefined) {
          throw new Error(`ArkTS project dependencies must not name a sibling project: ` +
            `${dependency.manifest} -> ${identity}`);
        }
        const imported = source.externalImports.find((entry) =>
          namesProject(entry.specifier, identity));
        if (imported !== undefined) {
          throw new Error(`ArkTS project imports must not name a sibling project: ` +
            `${imported.file} -> ${imported.specifier}`);
        }
      }
    }
  }
  return { sharedPackage: core.packageName, drivers: drivers.map((driver) => driver.id) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const result = checkDriverContracts();
    console.log(`Checked shared contracts and ${result.drivers.length} registered driver(s).`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
