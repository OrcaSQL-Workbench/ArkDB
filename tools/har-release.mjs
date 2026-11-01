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
    `${stem}.consumer.json`, `${stem}.readiness.json`,
    ...(value.dependencies ?? []).flatMap((dependency) => {
      const name = packageStem({ name: dependency.packageName, version: dependency.version });
      return [`${name}.har`, `${name}.har.sha256`, `${name}.manifest.json`];
    })];
}

export function releasePackages(value) {
  return [
    ...(value.dependencies ?? []),
    { ...value, dependencies: value.packageDependencies ?? {} }
  ];
}

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
      if (!dependency || dependency.version !== version) throw new Error('Missing or mismatched embedded source dependency.');
      visit(dependency);
    }
    visiting.delete(entry.packageName);
    visited.add(entry.packageName);
  }
  visit(packages.at(-1));
  if (visited.size !== packages.length) throw new Error('Unrelated embedded source package.');
  return value.embeddedPackages;
}

export function releaseDependencyReferences(set, selected = set) {
  const packages = releasePackages(set);
  const primary = packages.find((entry) => entry.driver === selected.driver);
  const names = new Set();
  const visiting = new Set();
  function visit(entry) {
    if (visiting.has(entry.packageName)) throw new Error('Cyclic release package dependencies.');
    visiting.add(entry.packageName);
    for (const [name, version] of Object.entries(entry.dependencies ?? {})) {
      const dependency = packages.find((candidate) => candidate.packageName === name);
      if (!dependency || dependency.version !== version) throw new Error('Release dependency identity/version is missing.');
      if (!names.has(name)) {
        visit(dependency);
        names.add(name);
      }
    }
    visiting.delete(entry.packageName);
  }
  visit(primary);
  return packages.filter((entry) => names.has(entry.packageName)).map((entry) => {
    const file = `${packageStem({ name: entry.packageName, version: entry.version })}.har`;
    const asset = set.assets.find((candidate) => candidate.name === file);
    if (!asset) throw new Error('Required dependency HAR is missing from the release set.');
    return {
      id: entry.driver, packageName: entry.packageName, version: entry.version,
      file, sha256: asset.sha256, byteLength: asset.byteLength
    };
  });
}

export function validateReleaseSet(value) {
  if (![1, 2].includes(value?.schemaVersion) || value.repository !== RELEASE_REPOSITORY ||
    typeof value.driver !== 'string' || !/^[a-z][a-z0-9_-]*$/.test(value.driver) ||
    !GIT_SHA.test(value.sourceCommit ?? '') || !GIT_SHA.test(value.tagObject ?? '') ||
    !SHA256.test(value.sourceFingerprint ?? '') || typeof value.modulePath !== 'string' ||
    !/^[a-zA-Z0-9_./-]+$/.test(value.modulePath) ||
    value.modulePath.split('/').some((part) => !part || part === '.' || part === '..')) {
    throw new Error('Invalid release-set source/package identity.');
  }
  if (value.schemaVersion === 1 && (value.dependencies !== undefined || value.packageDependencies !== undefined)) {
    throw new Error('Legacy release sets cannot silently acquire new package dependencies.');
  }
  if (value.delivery !== undefined) {
    if (value.delivery !== 'self-contained' || value.schemaVersion !== 1 ||
      value.moduleDefinition?.name !== value.driver || value.moduleDefinition?.type !== 'har' ||
      value.verification?.selfContainedRuntimeVerified !== true) {
      throw new Error('Invalid self-contained release identity or runtime evidence.');
    }
    validateEmbeddedPackages(value);
  }
  if (value.schemaVersion === 2) {
    if (!Array.isArray(value.dependencies) || value.dependencies.length === 0 || value.dependencies.length > 8 ||
      !value.packageDependencies || typeof value.packageDependencies !== 'object' ||
      Array.isArray(value.packageDependencies)) throw new Error('Invalid shared-HAR release dependency set.');
    const packages = releasePackages(value);
    if (new Set(packages.map((entry) => entry.driver)).size !== packages.length ||
      new Set(packages.map((entry) => entry.packageName)).size !== packages.length) {
      throw new Error('Release package identities must be unique.');
    }
    for (const entry of packages) {
      packageStem({ name: entry.packageName, version: entry.version });
      if (!/^[a-z][a-z0-9_-]*$/.test(entry.driver ?? '') ||
        !SHA256.test(entry.sourceFingerprint ?? '') ||
        typeof entry.modulePath !== 'string' || !/^[a-zA-Z0-9_-]+(?:\/[a-zA-Z0-9_-]+)*$/.test(entry.modulePath) ||
        entry.moduleDefinition?.name !== entry.driver || entry.moduleDefinition?.type !== 'har' ||
        !entry.dependencies || typeof entry.dependencies !== 'object' || Array.isArray(entry.dependencies)) {
        throw new Error('Invalid release dependency source/module identity.');
      }
      if (entry.driver !== value.driver && (!Array.isArray(entry.publicExports) ||
        entry.publicExports.length === 0 || entry.publicExports.some((name) => !/^[A-Za-z_$][\w$]*$/.test(name)))) {
        throw new Error('Release dependencies require their reviewed public exports.');
      }
    }
  }
  driverForTag([{ id: value.driver, version: value.version }], value.tag);
  const names = releaseAssetNames(value);
  const platform = value.platform;
  if (platform?.format !== 'bytecode-har' || platform.compatibleSdkVersion !== 24 ||
    platform.compatibleSdkType !== 'HarmonyOS' || platform.useNormalizedOHMUrl !== true ||
    platform.buildMode !== 'release') throw new Error('Unsupported release platform identity.');
  const verification = value.verification;
  const verificationSchema = verification?.schemaVersion ?? 1;
  if (![1, 3].includes(verificationSchema)) {
    throw new Error('Unsupported release verification evidence schema.');
  }
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
  if (verificationSchema === 3 && (!SHA256.test(verification.sampleHapSha256 ?? '') ||
    !SHA256.test(verification.sampleHapContentSha256 ?? '') ||
    !Number.isSafeInteger(verification.sampleHapByteLength) || verification.sampleHapByteLength <= 0 ||
    verification.consumerProfile !== 'current')) {
    throw new Error('Current release verification requires exact compiled HAP evidence.');
  }
  if (verificationSchema === 1 && (verification.sampleHapSha256 !== undefined ||
    verification.sampleHapByteLength !== undefined || verification.sampleHapContentSha256 !== undefined ||
    verification.consumerProfile !== undefined)) {
    throw new Error('Legacy release verification cannot silently acquire current HAP evidence.');
  }
  if (!Array.isArray(value.assets) || value.assets.length !== names.length ||
    new Set(value.assets.map((asset) => asset.name)).size !== names.length ||
    value.assets.some((asset) => !names.includes(asset.name) || !SHA256.test(asset.sha256 ?? '') ||
      !Number.isSafeInteger(asset.byteLength) || asset.byteLength <= 0 ||
      asset.byteLength > (asset.name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : MAX_RELEASE_JSON_BYTES))) {
    throw new Error('Release assets do not match the bounded allowlist.');
  }
  if (value.schemaVersion === 2) {
    const references = releaseDependencyReferences(value);
    if (references.length !== value.dependencies.length) {
      throw new Error('Release contains an unrelated or missing shared dependency.');
    }
  }
  return value;
}

export function validateEvidence(set, assets) {
  const stem = packageStem({ name: set.packageName, version: set.version });
  const identity = jsonBytes(assets.get(`${stem}.manifest.json`));
  const har = assets.get(`${stem}.har`);
  const consumer = jsonBytes(assets.get(`${stem}.consumer.json`));
  const readiness = jsonBytes(assets.get(`${stem}.readiness.json`));
  const references = releaseDependencyReferences(set);
  const verificationSchema = set.verification.schemaVersion ?? 1;
  if (identity.schemaVersion !== 1 || identity.packageName !== set.packageName ||
    identity.version !== set.version || identity.driver !== set.driver || identity.modulePath !== set.modulePath ||
    identity.sourceClean !== true || identity.sourceCommit !== set.sourceCommit ||
    identity.sourceFingerprint !== set.sourceFingerprint || identity.file !== `${stem}.har` ||
    identity.sha256 !== sha256(har) || identity.byteLength !== har.length || identity.published !== false ||
    Object.entries(set.platform).some(([key, value]) => identity[key] !== value) ||
    JSON.stringify(identity.dependencies ?? {}) !== JSON.stringify(set.packageDependencies ?? {}) ||
    JSON.stringify(identity.dependencyArtifacts ?? []) !== JSON.stringify(references) ||
    (set.schemaVersion === 2 && JSON.stringify(identity.moduleDefinition) !== JSON.stringify(set.moduleDefinition))) {
    throw new Error('Release artifact identity/source evidence does not match the release set.');
  }
  if (identity.artifactChannel !== undefined && identity.artifactChannel !== 'release') {
    throw new Error('A sealed release cannot retain a local artifact channel.');
  }
  if (identity.delivery !== set.delivery) throw new Error('Release delivery mode differs from its artifact.');
  if (set.delivery === 'self-contained') {
    validateEmbeddedPackages(identity);
    if (JSON.stringify(identity.embeddedPackages) !== JSON.stringify(set.embeddedPackages) ||
      JSON.stringify(identity.sourceDependencies) !== JSON.stringify(set.sourceDependencies) ||
      JSON.stringify(identity.moduleDefinition) !== JSON.stringify(set.moduleDefinition) ||
      consumer.selfContainedRuntimeVerified !== true || readiness.selfContainedRuntimeVerified !== true) {
      throw new Error('Self-contained release source or runtime evidence is inconsistent.');
    }
  }
  for (const dependency of set.dependencies ?? []) {
    const name = packageStem({ name: dependency.packageName, version: dependency.version });
    const record = jsonBytes(assets.get(`${name}.manifest.json`));
    const bytes = assets.get(`${name}.har`);
    if (record.schemaVersion !== 1 || record.packageName !== dependency.packageName ||
      (record.artifactChannel !== undefined && record.artifactChannel !== 'release') ||
      record.version !== dependency.version || record.driver !== dependency.driver ||
      record.modulePath !== dependency.modulePath || record.sourceClean !== true ||
      record.sourceCommit !== set.sourceCommit || record.sourceFingerprint !== dependency.sourceFingerprint ||
      record.file !== `${name}.har` || record.sha256 !== sha256(bytes) ||
      record.byteLength !== bytes.length || record.published !== false ||
      JSON.stringify(record.dependencies ?? {}) !== JSON.stringify(dependency.dependencies) ||
      JSON.stringify(record.moduleDefinition) !== JSON.stringify(dependency.moduleDefinition) ||
      JSON.stringify(record.dependencyArtifacts ?? []) !== JSON.stringify(releaseDependencyReferences(set, dependency)) ||
      Object.entries(set.platform).some(([key, value]) => record[key] !== value) ||
      assets.get(`${name}.har.sha256`).toString('utf8') !== `${record.sha256}  ${name}.har\n`) {
      throw new Error('Shared dependency artifact/source evidence differs from the release set.');
    }
  }
  if (assets.get(`${stem}.har.sha256`).toString('utf8') !== `${identity.sha256}  ${stem}.har\n`) {
    throw new Error('Release checksum sidecar differs from the actual HAR.');
  }
  for (const record of [consumer, readiness]) {
    if (record.schemaVersion !== verificationSchema ||
      record.packageName !== set.packageName || record.version !== set.version ||
      record.artifactSha256 !== identity.sha256 || record.sourceFingerprint !== set.sourceFingerprint ||
      record.sampleFingerprint !== set.verification.sampleFingerprint ||
      record.sampleHapCompiled !== true || record.documentedExamples !== set.verification.documentedExamples ||
      record.localSampleCases !== set.verification.localSampleCases || record.liveNetworkingVerified !== false ||
      JSON.stringify(record.dependencyArtifacts ?? []) !== JSON.stringify(references)) {
      throw new Error('Release consumer/readiness evidence is stale or inconsistent.');
    }
    if (verificationSchema === 3 &&
      (record.consumerProfile !== 'current' ||
        record.sampleHapSha256 !== set.verification.sampleHapSha256 ||
        record.sampleHapByteLength !== set.verification.sampleHapByteLength ||
        record.sampleHapContentSha256 !== set.verification.sampleHapContentSha256)) {
      throw new Error('Release compiled HAP evidence is stale or inconsistent.');
    }
    if (verificationSchema === 1 && (record.sampleHapSha256 !== undefined ||
      record.sampleHapByteLength !== undefined || record.sampleHapContentSha256 !== undefined ||
      record.consumerProfile !== undefined)) {
      throw new Error('Legacy release evidence cannot silently acquire current HAP fields.');
    }
  }
  if (consumer.check !== 'isolated-release-hap-and-local-tests' || consumer.localTestsExecuted !== true ||
    readiness.ohpmPrepublishPassed !== true || readiness.sourceClean !== true ||
    readiness.sourceCommit !== set.sourceCommit || readiness.published !== false) {
    throw new Error('Release verification evidence is incomplete or does not identify clean source.');
  }
  return identity;
}
