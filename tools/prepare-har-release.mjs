import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkPackage, ROOT } from './check-package.mjs';
import { extractExamples } from './doc-examples.mjs';
import { packageStem } from './driver-packages.mjs';
import { inspectHar, sha256, sourceFingerprint } from './package-har.mjs';
import { sampleFingerprint } from './test-consumer.mjs';
import { parseHypiumResults } from './run-ohos-tests.mjs';
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

async function verifyLocally(root, id) {
  if (id !== 'mysql') throw new Error(`No complete local release verification is implemented for driver ${id}.`);
  const npm = process.env.npm_execpath ?? join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js');
  if (!existsSync(npm)) throw new Error('Run preparation through npm run release:prepare to locate the npm CLI.');
  const result = spawnSync(process.execPath, [npm, 'run', 'verify'], {
    cwd: root, windowsHide: true, stdio: 'inherit'
  });
  if (result.error) throw new Error('Could not execute local release verification.', { cause: result.error });
  if (result.status !== 0) throw new Error('Local release verification failed; no release bundle was prepared.');
  const report = join(root, id, '.test', 'default', 'intermediates', 'test', 'coverage_data', 'test_result.txt');
  return { driverTestsPassed: parseHypiumResults(readFileSync(report, 'utf8')).passed };
}

export async function prepareHarRelease({ root = ROOT, driver: id = 'mysql', tag, destination }, dependencies = {}) {
  const source = checkPackage(root, id);
  const git = dependencies.git ?? gitReader(root);
  const before = releaseIdentity(source.driver, source.manifest, tag, git);
  if (resolve(git(['rev-parse', '--show-toplevel']).trim()) !== resolve(root)) {
    throw new Error('Release preparation must run at the source repository root.');
  }
  const directory = join(root, 'dist', 'releases', tag);
  if (destination !== undefined && resolve(destination) !== resolve(directory)) {
    throw new Error('Release destination must be its versioned dist/releases directory.');
  }
  plainPath(root, directory, { allowMissing: true });
  if (existsSync(directory)) throw new Error('Release destination already exists; preserve it and inspect the previous attempt.');
  const fingerprint = sourceFingerprint(root, id);
  const sample = sampleFingerprint(root);
  const verification = await (dependencies.verify ?? verifyLocally)(root, id);
  const after = releaseIdentity(source.driver, source.manifest, tag, git);
  if (JSON.stringify(before) !== JSON.stringify(after) || fingerprint !== sourceFingerprint(root, id) ||
    sample !== sampleFingerprint(root)) throw new Error('Release source or tag changed while verification ran.');
  if (!Number.isSafeInteger(verification?.driverTestsPassed) || verification.driverTestsPassed <= 0) {
    throw new Error('Release verification did not establish successful driver tests.');
  }
  const stem = packageStem(source.manifest);
  const dist = join(root, 'dist');
  const assets = new Map(releaseAssetNames({ packageName: source.manifest.name, version: source.manifest.version })
    .map((name) => [name, releaseFile(dist, name, name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : undefined)]));
  const identity = jsonBytes(assets.get(`${stem}.manifest.json`));
  const consumer = jsonBytes(assets.get(`${stem}.consumer.json`));
  const releaseSet = {
    schemaVersion: 1, repository: RELEASE_REPOSITORY, driver: id, modulePath: source.driver.sourcePath,
    packageName: source.manifest.name, version: source.manifest.version, ...before, sourceFingerprint: fingerprint,
    platform: {
      format: 'bytecode-har', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
      useNormalizedOHMUrl: true, buildMode: 'release'
    },
    verification: {
      driverTestsPassed: verification.driverTestsPassed,
      documentedExamples: extractExamples(readFileSync(join(source.driver.directory, 'README.md'), 'utf8')).length,
      localSampleCases: consumer.localSampleCases, sampleFingerprint: sample, publicExports: source.exports,
      ohpmPrepublishPassed: true, realDeviceVerified: false
    },
    assets: [...assets].map(([name, bytes]) => ({ name, sha256: sha256(bytes), byteLength: bytes.length }))
  };
  validateReleaseSet(releaseSet);
  validateEvidence(releaseSet, assets);
  const inspected = await inspectHar(join(dist, `${stem}.har`), source.manifest, source.exports, source.driver.definition);
  for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
    if (inspected.entries.get(`package/${name}`).sha256 !==
      sha256(readFileSync(join(source.driver.directory, name)))) {
      throw new Error(`Packaged ${name} differs from its reviewed source.`);
    }
  }
  if (identity.sha256 !== sha256(assets.get(`${stem}.har`)) ||
    sourceFingerprint(root, id) !== fingerprint || JSON.stringify(before) !==
      JSON.stringify(releaseIdentity(source.driver, source.manifest, tag, git))) {
    throw new Error('Release artifact or source changed before sealing the bundle.');
  }
  const parent = join(root, 'dist', 'releases');
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
