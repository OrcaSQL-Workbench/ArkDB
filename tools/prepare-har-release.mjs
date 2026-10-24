import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkPackage, ROOT } from './check-package.mjs';
import { extractExamples } from './doc-examples.mjs';
import { driverVerification, packageStem, tagOutputPaths } from './driver-packages.mjs';
import { inspectHar, sha256, sourceFingerprint, verifiedArtifactSet } from './package-har.mjs';
import { deliveryPlan } from './delivery-workspace.mjs';
import { sampleFingerprint } from './test-consumer.mjs';
import {
  gitReader, jsonBytes, MAX_RELEASE_ASSET_BYTES, plainPath, releaseArguments, releaseAssetNames,
  releaseFile, releaseIdentity, RELEASE_REPOSITORY, validateEvidence, validateReleaseSet
} from './har-release.mjs';

export async function readReleaseBundle(bundleDirectory) {
  const bytes = releaseFile(bundleDirectory, 'release-set.json');
  const releaseSet = validateReleaseSet(jsonBytes(bytes));
  const expected = [...releaseAssetNames(releaseSet), 'release-set.json'].sort();
  if (JSON.stringify(readdirSync(bundleDirectory).sort()) !== JSON.stringify(expected)) {
    throw new Error('Unexpected files in the release bundle; only the explicit allowlist may be published.');
  }
  const assets = new Map();
  for (const asset of releaseSet.assets) {
    const data = releaseFile(bundleDirectory, asset.name,
      asset.name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : undefined);
    if (data.length !== asset.byteLength || sha256(data) !== asset.sha256) {
      throw new Error(`Release bundle asset digest/size mismatch: ${asset.name}`);
    }
    assets.set(asset.name, data);
  }
  validateEvidence(releaseSet, assets);
  return { releaseSet, assets, releaseSetBytes: bytes };
}

export async function verifyLocally(root, id, dependencies = {}) {
  const verification = driverVerification(root, id);
  const npm = dependencies.npm ?? process.env.npm_execpath ??
    join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js');
  if (!existsSync(npm)) throw new Error('Run preparation through npm run release:prepare to locate the npm CLI.');
  const result = (dependencies.spawnSync ?? spawnSync)(process.execPath, [npm, 'run', 'verify', '--', '--driver', id], {
    cwd: root, windowsHide: true, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.stdout) (dependencies.output ?? process.stdout).write(result.stdout);
  if (result.stderr) (dependencies.errorOutput ?? process.stderr).write(result.stderr);
  if (result.error) throw new Error('Could not execute local release verification.', { cause: result.error });
  if (result.status !== 0) throw new Error('Local release verification failed; no release bundle was prepared.');
  // The strict runner checks native results before printing this verdict; later clean packaging removes its raw report.
  const passedModules = [];
  for (const module of verification.nativeModules) {
    const pattern = new RegExp(`^PASSED ${module} \\(([1-9]\\d*) native cases\\)$`, 'gm');
    const verdicts = [...(result.stdout ?? '').replace(/\r\n/g, '\n').matchAll(pattern)];
    const passed = Number(verdicts[0]?.[1]);
    if (verdicts.length !== 1 || !Number.isSafeInteger(passed) || passed <= 0) {
      throw new Error(`Local driver verification has no unique checked native verdict for ${module}.`);
    }
    passedModules.push({ module, passed });
  }
  return { driverTestsPassed: passedModules.reduce((total, entry) => total + entry.passed, 0), nativeModules: passedModules };
}

function releaseReferences(references) {
  return (references ?? []).map((entry) => ({
    ...entry, file: `${packageStem({ name: entry.packageName, version: entry.version })}.har`
  }));
}

function readyAssetBytes(source, suffix, bytes) {
  const stem = packageStem(source.manifest);
  if (suffix === 'har') return bytes;
  if (suffix === 'har.sha256') {
    if (bytes.toString('utf8') !== `${source.identity.sha256}  ${source.identity.file}\n`) {
      throw new Error('Local checksum sidecar differs from the verified HAR.');
    }
    return Buffer.from(`${source.identity.sha256}  ${stem}.har\n`);
  }
  const record = jsonBytes(bytes);
  if (JSON.stringify(record.dependencyArtifacts ?? []) !==
    JSON.stringify(source.identity.dependencyArtifacts ?? [])) {
    throw new Error('Local release evidence has inconsistent dependency identities.');
  }
  if (suffix === 'manifest.json') {
    if (record.file !== source.identity.file || record.artifactChannel !== 'local') {
      throw new Error('Release input is not the verified local artifact identity.');
    }
    record.file = `${stem}.har`;
    record.artifactChannel = 'release';
  }
  if (record.dependencyArtifacts !== undefined) {
    record.dependencyArtifacts = releaseReferences(record.dependencyArtifacts);
  }
  return Buffer.from(`${JSON.stringify(record, null, 2)}\n`);
}

export async function prepareHarRelease({ root = ROOT, driver: id = 'mysql', tag, destination }, dependencies = {}) {
  const source = checkPackage(root, id);
  driverVerification(root, id);
  const git = dependencies.git ?? gitReader(root);
  const before = releaseIdentity(source.driver, source.manifest, tag, git);
  if (resolve(git(['rev-parse', '--show-toplevel']).trim()) !== resolve(root)) {
    throw new Error('Release preparation must run at the source repository root.');
  }
  const directory = tagOutputPaths(root, id, tag).ready;
  if (destination !== undefined && resolve(destination) !== resolve(directory)) {
    throw new Error('Release destination must be its driver-version dist directory.');
  }
  plainPath(root, directory, { allowMissing: true });
  if (existsSync(directory)) throw new Error('Release destination already exists; preserve it and inspect the previous attempt.');
  const fingerprint = sourceFingerprint(root, id);
  const sample = sampleFingerprint(root, id);
  const verification = await (dependencies.verify ?? verifyLocally)(root, id);
  const after = releaseIdentity(source.driver, source.manifest, tag, git);
  if (JSON.stringify(before) !== JSON.stringify(after) || fingerprint !== sourceFingerprint(root, id) ||
    sample !== sampleFingerprint(root, id)) throw new Error('Release source or tag changed while verification ran.');
  if (!Number.isSafeInteger(verification?.driverTestsPassed) || verification.driverTestsPassed <= 0) {
    throw new Error('Release verification did not establish successful driver tests.');
  }
  const stem = packageStem(source.manifest);
  const outputs = await verifiedArtifactSet(root, id);
  const selected = outputs.at(-1);
  const packages = outputs.map((entry) => entry.driver);
  const assetInputs = new Map();
  for (const output of outputs) {
    const name = packageStem(output.manifest);
    for (const suffix of ['har', 'har.sha256', 'manifest.json']) {
      assetInputs.set(`${name}.${suffix}`, {
        source: output, directory: output.dist, file: `${output.stem}.${suffix}`, suffix
      });
    }
  }
  for (const suffix of ['consumer.json', 'readiness.json']) {
    assetInputs.set(`${stem}.${suffix}`, {
      source: selected, directory: selected.evidenceDirectory, file: `${selected.stem}.${suffix}`, suffix
    });
  }
  const dependenciesToSeal = packages.filter((entry) => entry.id !== id).map((entry) => ({
    driver: entry.id, modulePath: entry.sourcePath, packageName: entry.packageName, version: entry.version,
    sourceFingerprint: sourceFingerprint(root, entry.id), moduleDefinition: entry.definition,
    publicExports: checkPackage(root, entry.id).exports,
    dependencies: entry.manifest.dependencies ?? {}
  }));
  const assets = new Map(releaseAssetNames({
    packageName: source.manifest.name, version: source.manifest.version, dependencies: dependenciesToSeal
  })
    .map((name) => {
      const input = assetInputs.get(name);
      if (!input) throw new Error(`No registered output location for release asset: ${name}`);
      plainPath(root, input.directory);
      const bytes = releaseFile(input.directory, input.file,
        name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : undefined);
      return [name, readyAssetBytes(input.source, input.suffix, bytes)];
    }));
  const identity = jsonBytes(assets.get(`${stem}.manifest.json`));
  const consumer = jsonBytes(assets.get(`${stem}.consumer.json`));
  const releaseSet = {
    schemaVersion: dependenciesToSeal.length > 0 ? 2 : 1,
    repository: RELEASE_REPOSITORY, driver: id, modulePath: source.driver.sourcePath,
    packageName: source.manifest.name, version: source.manifest.version, ...before, sourceFingerprint: fingerprint,
    ...(selected.identity.delivery === 'self-contained' ? {
      delivery: 'self-contained', sourceDependencies: selected.identity.sourceDependencies,
      embeddedPackages: selected.identity.embeddedPackages, moduleDefinition: selected.definition
    } : {}),
    ...(dependenciesToSeal.length > 0 ? {
      dependencies: dependenciesToSeal, packageDependencies: selected.identity.dependencies ?? {},
      moduleDefinition: selected.definition
    } : {}),
    platform: {
      format: 'bytecode-har', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
      useNormalizedOHMUrl: true, buildMode: 'release'
    },
    verification: {
      driverTestsPassed: verification.driverTestsPassed,
      documentedExamples: extractExamples(readFileSync(join(source.driver.directory, 'README.md'), 'utf8')).length,
      localSampleCases: consumer.localSampleCases, sampleFingerprint: sample, publicExports: source.exports,
      ohpmPrepublishPassed: true, realDeviceVerified: false,
      ...(selected.identity.delivery === 'self-contained' ? {
        selfContainedRuntimeVerified: consumer.selfContainedRuntimeVerified
      } : {})
    },
    assets: [...assets].map(([name, bytes]) => ({ name, sha256: sha256(bytes), byteLength: bytes.length }))
  };
  validateReleaseSet(releaseSet);
  validateEvidence(releaseSet, assets);
  for (const output of outputs) {
    const entry = output.driver;
    const checked = checkPackage(root, entry.id);
    const inspected = await inspectHar(output.artifact,
      output.packagedManifest, checked.exports, output.definition);
    for (const file of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
      const expected = file === 'README.OpenSource' && output.identity.delivery === 'self-contained'
        ? deliveryPlan(root, entry.id).notice : readFileSync(join(entry.directory, file));
      if (inspected.entries.get(`package/${file}`).sha256 !==
        sha256(expected)) {
        throw new Error(`Packaged ${file} differs from its reviewed source.`);
      }
    }
  }
  if (identity.sha256 !== sha256(assets.get(`${stem}.har`)) ||
    sourceFingerprint(root, id) !== fingerprint || JSON.stringify(before) !==
      JSON.stringify(releaseIdentity(source.driver, source.manifest, tag, git))) {
    throw new Error('Release artifact or source changed before sealing the bundle.');
  }
  const parent = join(root, 'dist');
  plainPath(root, parent, { allowMissing: true });
  await mkdir(parent, { recursive: true });
  plainPath(root, parent);
  await mkdir(directory);
  for (const [name, bytes] of assets) await writeFile(join(directory, name), bytes, { flag: 'wx' });
  await writeFile(join(directory, 'release-set.json'), `${JSON.stringify(releaseSet, null, 2)}\n`, { flag: 'wx' });
  await readReleaseBundle(directory);
  return { bundleDirectory: directory, releaseSet };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const options = releaseArguments(process.argv.slice(2));
    const prepared = await prepareHarRelease(options);
    console.log(`Prepared immutable local release bundle: ${prepared.bundleDirectory}. Nothing was published.`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
