import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { inspectHar } from '../artifact/har-inspection.mjs';
import { embeddedSourcePackages } from '../artifact/local-artifact.mjs';
import { sourceFingerprint } from '../artifact/source-identity.mjs';
import { checkPackage, ROOT } from '../workspace/check-package.mjs';
import { localArtifactStem, localOutputPaths, resolveDriver } from '../workspace/driver-packages.mjs';
import { sha256 } from '../lib/hash.mjs';
import { plainPath } from '../lib/safe-files.mjs';
import { runHvigor, runOhpm } from '../workspace/run-hvigor.mjs';
import { createDeliveryWorkspace } from '../workspace/delivery-workspace.mjs';

async function packageOne(root, id) {
  const { manifest, exports, driver } = checkPackage(root, id);
  const fingerprint = sourceFingerprint(root, id);
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  const sourceClean = execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'],
    { cwd: root, encoding: 'utf8' }).trim().length === 0;
  const workspace = await createDeliveryWorkspace(root, id);
  try {
    const restored = runOhpm(['install', '--all'], { cwd: workspace.directory });
    if (restored.status !== 0 || /ohpm ERROR/.test(restored.output)) {
      throw new Error('Delivery workspace dependency restore failed; no artifact was prepared.');
    }
    const result = runHvigor([
      '--mode', 'module', '-p', `module=${driver.id}@default`, '-p', 'product=default',
      '-p', 'buildMode=release', 'assembleHar', '--no-daemon'
    ], { cwd: workspace.directory });
    if (result.status !== 0 || /hvigor ERROR/.test(result.output) || !/BUILD SUCCESSFUL/.test(result.output)) {
      throw new Error('Release HAR compilation failed; no new artifact was prepared.');
    }
    if (sourceFingerprint(root, id) !== fingerprint) throw new Error('Source changed during the release build.');
    const built = join(workspace.moduleDirectory, 'build', 'default', 'outputs', 'default', `${driver.id}.har`);
    const inspected = await inspectHar(built, workspace.plan.manifest, exports, workspace.plan.definition);
    for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
      const source = name === 'README.OpenSource' ? workspace.plan.notice : await readFile(join(driver.directory, name));
      if (inspected.entries.get(`package/${name}`).sha256 !== sha256(source)) {
        throw new Error(`Packaged ${name} differs from its reviewed source.`);
      }
    }
    const dist = plainPath(root, localOutputPaths(root, id).artifacts, { allowMissing: true });
    await mkdir(dist, { recursive: true });
    plainPath(root, dist);
    const stem = localArtifactStem(manifest);
    const name = `${stem}.har`;
    const bytes = await readFile(built);
    const identity = {
      schemaVersion: 1, packageName: manifest.name, version: manifest.version,
      driver: driver.id, modulePath: driver.sourcePath, kind: driver.kind,
      delivery: 'self-contained', artifactChannel: 'local', moduleDefinition: workspace.plan.definition, dependencies: {},
      sourceDependencies: manifest.dependencies ?? {}, embeddedPackages: embeddedSourcePackages(root, id),
      dependencyArtifacts: [],
      sourceCommit: sourceClean ? sourceCommit : null, checkoutHead: sourceCommit, sourceClean,
      file: name, sha256: sha256(bytes), byteLength: bytes.length, sourceFingerprint: fingerprint,
      format: 'bytecode-har', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
      useNormalizedOHMUrl: true, buildMode: 'release', published: false
    };
    await copyFile(built, join(dist, name));
    if (sha256(await readFile(join(dist, name))) !== identity.sha256 ||
      sourceFingerprint(root, id) !== fingerprint ||
      execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim() !== sourceCommit ||
      (sourceClean && execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'],
        { cwd: root, encoding: 'utf8' }).trim().length !== 0)) {
      throw new Error('Artifact or source changed while preparing the package.');
    }
    await writeFile(join(dist, `${stem}.manifest.json`), `${JSON.stringify(identity, null, 2)}\n`);
    await writeFile(join(dist, `${name}.sha256`), `${identity.sha256}  ${name}\n`);
    console.log(`Prepared ${name} (${bytes.length} bytes, SHA-256 ${identity.sha256}). One self-contained HAR; not published.`);
    return identity;
  } finally {
    await rm(workspace.directory, { recursive: true, force: true });
  }
}

export async function packageHar(root = ROOT, id = 'mysql') {
  resolveDriver(root, id);
  return packageOne(root, id);
}
