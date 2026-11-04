import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { checkPackage, ROOT } from '../workspace/check-package.mjs';
import { dependencyClosure, localArtifactStem, localOutputPaths } from '../workspace/driver-packages.mjs';
import { sha256 } from '../lib/hash.mjs';
import { plainPath } from '../lib/safe-files.mjs';
import { deliveryPlan } from '../workspace/delivery-workspace.mjs';
import { inspectHar } from './har-inspection.mjs';
import { sourceFingerprint } from './source-identity.mjs';

export function artifactReference(source) {
  return {
    id: source.driver.id, packageName: source.manifest.name, version: source.manifest.version,
    file: source.identity.file, sha256: source.identity.sha256, byteLength: source.identity.byteLength
  };
}

async function dependencyArtifacts(root, id) {
  const packages = dependencyClosure(root, id).filter((entry) => entry.id !== id);
  const sources = [];
  for (const entry of packages) sources.push(await verifiedArtifact(root, entry.id));
  return sources;
}

export function embeddedSourcePackages(root, id) {
  return dependencyClosure(root, id).filter((entry) => entry.id !== id).map((entry) => ({
    id: entry.id, packageName: entry.packageName, version: entry.version,
    modulePath: entry.sourcePath, sourceFingerprint: sourceFingerprint(root, entry.id),
    dependencies: entry.manifest.dependencies ?? {}
  }));
}

export async function verifiedArtifact(root = ROOT, id = 'mysql') {
  const { manifest, exports, driver } = checkPackage(root, id);
  const stem = localArtifactStem(manifest);
  const paths = localOutputPaths(root, id);
  const dist = plainPath(root, paths.artifacts);
  const evidenceDirectory = plainPath(root, paths.evidence, { allowMissing: true });
  const artifact = join(dist, `${stem}.har`);
  const identity = JSON.parse(await readFile(join(dist, `${stem}.manifest.json`), 'utf8'));
  const bytes = await readFile(artifact);
  const standalone = identity.delivery === 'self-contained';
  if (identity.delivery !== undefined && !standalone) throw new Error('Unknown HAR delivery identity.');
  const plan = standalone ? deliveryPlan(root, id) : null;
  const dependencies = standalone ? [] : await dependencyArtifacts(root, id);
  const packagedManifest = plan ? plan.manifest : manifest;
  const definition = plan ? plan.definition : driver.definition;
  if (identity.schemaVersion !== 1 || identity.driver !== id || identity.modulePath !== driver.sourcePath ||
    identity.packageName !== manifest.name || identity.version !== manifest.version ||
    identity.artifactChannel !== 'local' || identity.file !== `${stem}.har` || identity.byteLength !== bytes.length ||
    identity.sha256 !== sha256(bytes) || identity.sourceFingerprint !== sourceFingerprint(root, id) ||
    JSON.stringify(identity.dependencies ?? {}) !== JSON.stringify(packagedManifest.dependencies ?? {}) ||
    JSON.stringify(identity.dependencyArtifacts ?? []) !== JSON.stringify(dependencies.map(artifactReference)) ||
    (standalone && (JSON.stringify(identity.sourceDependencies) !== JSON.stringify(manifest.dependencies ?? {}) ||
      JSON.stringify(identity.embeddedPackages) !== JSON.stringify(embeddedSourcePackages(root, id)) ||
      JSON.stringify(identity.moduleDefinition) !== JSON.stringify(definition)))) {
    throw new Error(`Release HAR identity is missing, stale, or inconsistent. Run npm run pack -- --driver ${id}.`);
  }
  await inspectHar(artifact, packagedManifest, exports, definition);
  return { manifest, packagedManifest, definition, driver, stem, dist, evidenceDirectory, artifact, identity };
}

export async function verifiedArtifactSet(root = ROOT, id = 'mysql') {
  const selected = await verifiedArtifact(root, id);
  if (selected.identity.delivery === 'self-contained') return [selected];
  const dependencies = await dependencyArtifacts(root, id);
  return [...dependencies, selected];
}
