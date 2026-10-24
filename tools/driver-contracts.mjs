import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkPackage, importSpecifiers, listFiles } from './check-package.mjs';
import { discoverDrivers, discoverPackages, ROOT } from './driver-packages.mjs';

export function checkDriverContracts(root = ROOT) {
  const packages = discoverPackages(root);
  const core = packages.find((entry) => entry.packageName === '@arkdb/core');
  if (!core || core.kind !== 'shared') throw new Error('One shared @arkdb/core HAR is required.');
  const drivers = discoverDrivers(root);
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
  for (const driver of drivers) {
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
