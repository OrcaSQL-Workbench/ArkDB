import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { driverForTag, packageStem } from './driver-packages.mjs';
import { sha256 } from './package-har.mjs';

export const RELEASE_REPOSITORY = 'OrcaSQL-Workbench/ArkDB';
export const MAX_RELEASE_ASSET_BYTES = 32 * 1024 * 1024;
export const MAX_RELEASE_JSON_BYTES = 1024 * 1024;
export const SHA256 = /^[0-9a-f]{64}$/;
export const GIT_SHA = /^[0-9a-f]{40}$/;

export function gitReader(root) {
  return (args) => execFileSync('git', args, {
    cwd: root, encoding: 'utf8', windowsHide: true, timeout: 30_000, maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  });
}

export function releaseArguments(argv, { publishing = false } = {}) {
  const options = { driver: 'mysql', confirmPublish: false };
  const seen = new Set();
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (seen.has(flag)) throw new Error('Release options must not be repeated.');
    seen.add(flag);
    if (flag === '--confirm-publish' && publishing) options.confirmPublish = true;
    else if ((flag === '--driver' || flag === '--tag') && typeof argv[index + 1] === 'string') {
      options[flag.slice(2)] = argv[++index];
    } else throw new Error('Usage: --driver mysql --tag mysql-v1.0.0' + (publishing ? ' --confirm-publish' : ''));
  }
  if (!/^[a-z][a-z0-9_-]*$/.test(options.driver) ||
    !/^[a-z][a-z0-9_-]*-v[1-9]\d?(?:\.(?:[1-9]?\d)){2}$/.test(options.tag ?? '')) {
    throw new Error('A registered driver and an explicit driver-version tag are required.');
  }
  return options;
}

export function releaseIdentity(driver, manifest, tag, git) {
  driverForTag([{ id: driver.id, version: manifest.version }], tag);
  if (git(['status', '--porcelain', '--untracked-files=all']).trim() !== '') {
    throw new Error('Release preparation requires reviewed, committed, clean source.');
  }
  const sourceCommit = git(['rev-parse', '--verify', 'HEAD']).trim();
  const reference = `refs/tags/${tag}`;
  if (git(['cat-file', '-t', reference]).trim() !== 'tag') {
    throw new Error('Release tags must be annotated, not lightweight.');
  }
  const tagObject = git(['rev-parse', '--verify', reference]).trim();
  const tagCommit = git(['rev-parse', '--verify', `${reference}^{commit}`]).trim();
  if (!GIT_SHA.test(sourceCommit) || !GIT_SHA.test(tagObject) || sourceCommit !== tagCommit) {
    throw new Error('The annotated tag must identify the current clean source commit.');
  }
  return { tag, tagObject, sourceCommit };
}

function samePath(a, b) {
  return process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
}

export function plainPath(root, target, { allowMissing = false } = {}) {
  const base = resolve(root);
  const path = resolve(target);
  const child = relative(base, path);
  if (child === '..' || child.startsWith(`..${sep}`) || isAbsolute(child)) {
    throw new Error('Release paths must remain inside their owning directory.');
  }
  if (lstatSync(base).isSymbolicLink() || !samePath(realpathSync(base), base)) {
    throw new Error('Release directories must not be links or use linked parents.');
  }
  let current = base;
  for (const part of child.split(sep).filter(Boolean)) {
    current = join(current, part);
    let info;
    try {
      info = lstatSync(current);
    } catch (error) {
      if (allowMissing && error.code === 'ENOENT') return path;
      throw error;
    }
    if (info.isSymbolicLink()) throw new Error('Release files/directories must not be links.');
    if (current !== path && !info.isDirectory()) throw new Error('Release parent is not a directory.');
  }
  return path;
}

export function releaseFile(directory, name, maximumBytes = MAX_RELEASE_JSON_BYTES) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) throw new Error('Invalid release asset filename.');
  const file = plainPath(directory, join(directory, name));
  const before = lstatSync(file);
  if (!before.isFile() || before.nlink !== 1 || before.size <= 0 || before.size > maximumBytes) {
    throw new Error(`Release asset is not a bounded regular file: ${name}`);
  }
  const bytes = readFileSync(file);
  const after = lstatSync(file);
  if (!after.isFile() || after.isSymbolicLink() || bytes.length !== before.size ||
    ['dev', 'ino', 'size', 'mtimeMs', 'nlink'].some((field) => before[field] !== after[field])) {
    throw new Error(`Release asset changed while reading: ${name}`);
  }
  return bytes;
}

export function jsonBytes(bytes) {
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}

export function releaseAssetNames(value) {
  const stem = packageStem({ name: value.packageName, version: value.version });
  return [`${stem}.har`, `${stem}.har.sha256`, `${stem}.manifest.json`,
    `${stem}.consumer.json`, `${stem}.readiness.json`];
}

export function validateReleaseSet(value) {
  if (value?.schemaVersion !== 1 || value.repository !== RELEASE_REPOSITORY ||
    typeof value.driver !== 'string' || !/^[a-z][a-z0-9_-]*$/.test(value.driver) ||
    !GIT_SHA.test(value.sourceCommit ?? '') || !GIT_SHA.test(value.tagObject ?? '') ||
    !SHA256.test(value.sourceFingerprint ?? '') || typeof value.modulePath !== 'string' ||
    !/^[a-zA-Z0-9_./-]+$/.test(value.modulePath) ||
    value.modulePath.split('/').some((part) => !part || part === '.' || part === '..')) {
    throw new Error('Invalid release-set source/package identity.');
  }
  driverForTag([{ id: value.driver, version: value.version }], value.tag);
  const names = releaseAssetNames(value);
  const platform = value.platform;
  if (platform?.format !== 'bytecode-har' || platform.compatibleSdkVersion !== 24 ||
    platform.compatibleSdkType !== 'HarmonyOS' || platform.useNormalizedOHMUrl !== true ||
    platform.buildMode !== 'release') throw new Error('Unsupported release platform identity.');
  const verification = value.verification;
  for (const name of ['driverTestsPassed', 'documentedExamples', 'localSampleCases']) {
    if (!Number.isSafeInteger(verification?.[name]) || verification[name] <= 0) {
      throw new Error('Release verification must contain successful local tests/examples.');
    }
  }
  if (verification.ohpmPrepublishPassed !== true || verification.realDeviceVerified !== false ||
    !SHA256.test(verification.sampleFingerprint ?? '') ||
    !Array.isArray(verification.publicExports) || verification.publicExports.length === 0 ||
    verification.publicExports.some((name) => typeof name !== 'string' || !/^[A-Za-z_$][\w$]*$/.test(name)) ||
    new Set(verification.publicExports).size !== verification.publicExports.length) {
    throw new Error('Invalid release verification evidence.');
  }
  if (!Array.isArray(value.assets) || value.assets.length !== names.length ||
    new Set(value.assets.map((asset) => asset.name)).size !== names.length ||
    value.assets.some((asset) => !names.includes(asset.name) || !SHA256.test(asset.sha256 ?? '') ||
      !Number.isSafeInteger(asset.byteLength) || asset.byteLength <= 0 ||
      asset.byteLength > (asset.name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : MAX_RELEASE_JSON_BYTES))) {
    throw new Error('Release assets do not match the bounded allowlist.');
  }
  return value;
}

export function validateEvidence(set, assets) {
  const stem = packageStem({ name: set.packageName, version: set.version });
  const identity = jsonBytes(assets.get(`${stem}.manifest.json`));
  const har = assets.get(`${stem}.har`);
  const consumer = jsonBytes(assets.get(`${stem}.consumer.json`));
  const readiness = jsonBytes(assets.get(`${stem}.readiness.json`));
  if (identity.schemaVersion !== 1 || identity.packageName !== set.packageName ||
    identity.version !== set.version || identity.driver !== set.driver || identity.modulePath !== set.modulePath ||
    identity.sourceClean !== true || identity.sourceCommit !== set.sourceCommit ||
    identity.sourceFingerprint !== set.sourceFingerprint || identity.file !== `${stem}.har` ||
    identity.sha256 !== sha256(har) || identity.byteLength !== har.length || identity.published !== false ||
    Object.entries(set.platform).some(([key, value]) => identity[key] !== value)) {
    throw new Error('Release artifact identity/source evidence does not match the release set.');
  }
  if (assets.get(`${stem}.har.sha256`).toString('utf8') !== `${identity.sha256}  ${stem}.har\n`) {
    throw new Error('Release checksum sidecar differs from the actual HAR.');
  }
  for (const record of [consumer, readiness]) {
    if (record.schemaVersion !== 1 || record.packageName !== set.packageName || record.version !== set.version ||
      record.artifactSha256 !== identity.sha256 || record.sourceFingerprint !== set.sourceFingerprint ||
      record.sampleFingerprint !== set.verification.sampleFingerprint ||
      record.sampleHapCompiled !== true || record.documentedExamples !== set.verification.documentedExamples ||
      record.localSampleCases !== set.verification.localSampleCases || record.liveNetworkingVerified !== false) {
      throw new Error('Release consumer/readiness evidence is stale or inconsistent.');
    }
  }
  if (consumer.check !== 'isolated-release-hap-and-local-tests' || consumer.localTestsExecuted !== true ||
    readiness.ohpmPrepublishPassed !== true || readiness.sourceClean !== true ||
    readiness.sourceCommit !== set.sourceCommit || readiness.published !== false) {
    throw new Error('Release verification evidence is incomplete or does not identify clean source.');
  }
  return identity;
}
