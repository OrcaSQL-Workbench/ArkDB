import { packageStem } from '../workspace/driver-packages.mjs';
import { SHA256 } from '../lib/hash.mjs';

export function validateEmbeddedPackages(value) {
  if (value.delivery !== 'self-contained' || !Array.isArray(value.embeddedPackages) ||
    value.embeddedPackages.length > 32 || !value.sourceDependencies ||
    typeof value.sourceDependencies !== 'object' || Array.isArray(value.sourceDependencies)) {
    throw new Error('Invalid self-contained source package identity.');
  }
  const packages = [...value.embeddedPackages, {
    id: value.driver, packageName: value.packageName, version: value.version,
    modulePath: value.modulePath, sourceFingerprint: value.sourceFingerprint,
    dependencies: value.sourceDependencies
  }];
  if (new Set(packages.map((entry) => entry.id)).size !== packages.length ||
    new Set(packages.map((entry) => entry.packageName)).size !== packages.length) {
    throw new Error('Embedded source package identities must be unique.');
  }
  for (const entry of packages) {
    packageStem({ name: entry.packageName, version: entry.version });
    if (!/^[a-z][a-z0-9_-]*$/.test(entry.id ?? '') || !SHA256.test(entry.sourceFingerprint ?? '') ||
      !/^[a-zA-Z0-9_-]+(?:\/[a-zA-Z0-9_-]+)*$/.test(entry.modulePath ?? '') ||
      !entry.dependencies || typeof entry.dependencies !== 'object' || Array.isArray(entry.dependencies)) {
      throw new Error('Invalid embedded source package metadata.');
    }
  }
  const visited = new Set();
  const visiting = new Set();
  function visit(entry) {
    if (visited.has(entry.packageName)) return;
    if (visiting.has(entry.packageName)) throw new Error('Cyclic embedded source dependencies.');
    visiting.add(entry.packageName);
    for (const [name, version] of Object.entries(entry.dependencies)) {
      const dependency = packages.find((candidate) => candidate.packageName === name);
      if (!dependency || dependency.version !== version) {
        throw new Error('Missing or mismatched embedded source dependency.');
      }
      visit(dependency);
    }
    visiting.delete(entry.packageName);
    visited.add(entry.packageName);
  }
  visit(packages.at(-1));
  if (visited.size !== packages.length) throw new Error('Unrelated embedded source package.');
  return value.embeddedPackages;
}
