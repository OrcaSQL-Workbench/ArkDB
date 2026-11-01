import {
  createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes as systemRandomBytes,
  sign as signBytes, verify as verifySignature
} from 'node:crypto';
import { existsSync } from 'node:fs';
import {
  copyFile, cp, link, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, stat, writeFile
} from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { ROOT } from './check-package.mjs';
import { driverVerification, packageStem, tagOutputPaths } from './driver-packages.mjs';
import { gitReader, jsonBytes, plainPath, releaseFile } from './har-release.mjs';
import { sha256, sourceFingerprint } from './package-har.mjs';
import { readReleaseBundle } from './prepare-har-release.mjs';
import { runHvigor, runOhpm } from './run-hvigor.mjs';
import { sampleFingerprint } from './test-consumer.mjs';
import { hapSigningContentFingerprint } from './hap-content.mjs';

const CASE_MANIFEST = join('examples', 'mysql-client', 'device-acceptance-cases.json');
const CHALLENGE_LIFETIME_MS = 24 * 60 * 60 * 1000;
const CANONICAL_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const PREPARATION_JOURNAL = /^([0-9a-f]{32})\.prepare\.json$/;
const DEVICE_PROFILES = ['M1', 'M2', 'M3', 'M4'];
const DEVICE_FEATURES = [
  'multi-statements', 'procedures', 'text-parameters', 'sha256', 'compression',
  'local-infile', 'failover', 'worker', 'session-observations', 'routing'
];
const DEVICE_AUTH_PLUGINS = ['mysql_native_password', 'caching_sha2_password'];

async function syncDirectory(directory) {
  let handle;
  try {
    handle = await open(directory, 'r');
    await handle.sync();
  } catch (error) {
    if (!['EISDIR', 'EPERM', 'EINVAL', 'EACCES'].includes(error?.code)) throw error;
  } finally {
    await handle?.close();
  }
}

async function syncPreparedFile(path, dependencies) {
  if (dependencies.syncPreparedFile) {
    await dependencies.syncPreparedFile(path);
    return;
  }
  const handle = await open(path, 'r+');
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

function atomicTempPath(destination, kind, bytes) {
  return join(dirname(destination), `.${basename(destination)}.tmp-${kind}-${sha256(bytes)}-` +
    `${process.pid}-${systemRandomBytes(8).toString('hex')}`);
}

function atomicWriteStagingPath(destination, kind) {
  return join(dirname(destination), `.${basename(destination)}.write-${kind}-${process.pid}-` +
    systemRandomBytes(8).toString('hex'));
}

async function writeSyncedTemp(destination, bytes, kind) {
  const temp = atomicTempPath(destination, kind, bytes);
  const staging = atomicWriteStagingPath(destination, kind);
  let handle;
  try {
    handle = await open(staging, 'wx');
    await handle.writeFile(bytes);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(staging, temp);
    await syncDirectory(dirname(destination));
    return temp;
  } catch (error) {
    await handle?.close();
    await rm(staging, { force: true });
    await rm(temp, { force: true });
    throw error;
  }
}

async function atomicWriteNew(destination, bytes, hooks = {}) {
  const temp = await writeSyncedTemp(destination, bytes, 'new');
  let linked = false;
  try {
    await link(temp, destination);
    linked = true;
    if (hooks.afterLink) await hooks.afterLink({ destination, temp });
    await syncDirectory(dirname(destination));
    await rm(temp, { force: true });
    await syncDirectory(dirname(destination));
    return;
  } catch (error) {
    if (!linked) await rm(temp, { force: true });
    throw error;
  } finally {
    if (!linked) await rm(temp, { force: true });
  }
}

async function atomicReplace(destination, bytes) {
  const temp = await writeSyncedTemp(destination, bytes, 'replace');
  try {
    await rename(temp, destination);
    await syncDirectory(dirname(destination));
  } catch (error) {
    await rm(temp, { force: true });
    throw error;
  }
}

async function atomicRename(source, destination) {
  await rename(source, destination);
  await syncDirectory(dirname(destination));
}

export async function recoverAtomicState(destination) {
  const prefix = `.${basename(destination)}.tmp-`;
  const writePrefix = `.${basename(destination)}.write-`;
  let directoryNames;
  try {
    directoryNames = await readdir(dirname(destination));
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  let removedStaging = false;
  for (const name of directoryNames.filter((entry) => entry.startsWith(writePrefix))) {
    const match = name.slice(writePrefix.length).match(/^(?:new|replace)-(\d+)-[0-9a-f]{16}$/);
    if (!match || processAlive(Number(match[1]), {})) continue;
    await rm(join(dirname(destination), name), { force: true });
    removedStaging = true;
  }
  if (removedStaging) await syncDirectory(dirname(destination));
  const names = directoryNames.filter((name) => name.startsWith(prefix));
  if (names.length === 0) return;
  const entries = [];
  for (const name of names) {
    const path = join(dirname(destination), name);
    const bytes = await readFile(path);
    const suffix = name.slice(prefix.length);
    const typed = suffix.match(/^(new|replace)-([0-9a-f]{64})-/);
    const writer = suffix.match(/^(?:new|replace)-[0-9a-f]{64}-(\d+)-[0-9a-f]{16}$/);
    entries.push({
      name, path, bytes, kind: typed?.[1] ?? 'legacy',
      digestMatches: typed === null || typed[2] === sha256(bytes),
      liveWriter: writer !== null && processAlive(Number(writer[1]), {})
    });
  }
  const incompleteTyped = entries.filter((entry) =>
    entry.kind !== 'legacy' && !entry.digestMatches && !entry.liveWriter);
  for (const entry of incompleteTyped) await rm(entry.path, { force: true });
  if (incompleteTyped.length > 0) await syncDirectory(dirname(destination));
  const replacements = entries.filter((entry) =>
    entry.kind === 'replace' && entry.digestMatches && !entry.liveWriter);
  const ordinary = entries.filter((entry) =>
    entry.kind !== 'replace' && !entry.liveWriter &&
    (entry.kind === 'legacy' || entry.digestMatches));
  if (!existsSync(destination)) {
    for (const entry of ordinary) await rm(entry.path, { force: true });
    if (replacements.length > 0) {
      const digest = sha256(replacements[0].bytes);
      if (replacements.some((entry) => sha256(entry.bytes) !== digest)) {
        throw new Error(`Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
      }
      await rename(replacements[0].path, destination);
      await syncDirectory(dirname(destination));
      for (const entry of replacements.slice(1)) await rm(entry.path, { force: true });
    }
    await syncDirectory(dirname(destination));
    return;
  }
  const destinationInfo = await lstat(destination);
  const destinationBytes = await readFile(destination);
  for (const entry of entries.filter((candidate) =>
    candidate.liveWriter && candidate.kind === 'new')) {
    const tempInfo = await lstat(entry.path);
    const published = destinationInfo.dev === tempInfo.dev &&
      destinationInfo.ino === tempInfo.ino &&
      sha256(destinationBytes) === sha256(entry.bytes);
    if (published) await rm(entry.path, { force: true });
  }
  if (ordinary.some((entry) => !entry.digestMatches)) {
    throw new Error(`Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
  }
  for (const entry of ordinary) {
    const tempInfo = await lstat(entry.path);
    const sameInode = destinationInfo.dev === tempInfo.dev && destinationInfo.ino === tempInfo.ino;
    const sameContent = destinationBytes.length === entry.bytes.length &&
      sha256(destinationBytes) === sha256(entry.bytes);
    if (!sameInode || !sameContent) {
      throw new Error(`Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
    }
    await rm(entry.path);
  }
  if (replacements.length > 0) {
    const replacementDigest = sha256(replacements[0].bytes);
    if (replacements.some((entry) => sha256(entry.bytes) !== replacementDigest)) {
      throw new Error(`Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
    }
    if (sha256(destinationBytes) !== replacementDigest) {
      await rename(replacements[0].path, destination);
      await syncDirectory(dirname(destination));
      for (const entry of replacements.slice(1)) await rm(entry.path, { force: true });
    } else {
      for (const entry of replacements) await rm(entry.path, { force: true });
    }
  }
  await syncDirectory(dirname(destination));
}

async function atomicStateExists(path) {
  await recoverAtomicState(path);
  return existsSync(path);
}

async function readAtomicJson(path) {
  await recoverAtomicState(path);
  return jsonBytes(releaseFile(dirname(path), basename(path)));
}

async function readBoundedRegularBytes(path, label) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size <= 0 || info.size > 2 * 1024 * 1024) {
    throw new Error(`${label} is not a bounded regular file: ${basename(path)}`);
  }
  return await readFile(path);
}

async function readLockJson(path) {
  await recoverAtomicState(path);
  return jsonBytes(await readBoundedRegularBytes(path, 'Lock state'));
}

function tombstonePrefix(work) {
  return `.${basename(work)}.tombstone-`;
}

async function recoverWorkTombstones(work, dependencies) {
  const parent = dirname(work);
  let names;
  try {
    names = (await readdir(parent)).filter((name) => name.startsWith(tombstonePrefix(work)));
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  for (const name of names) {
    const tombstone = join(parent, name);
    if (dependencies.removeWork) await dependencies.removeWork(tombstone);
    else await rm(tombstone, { recursive: true, force: true });
  }
  if (names.length > 0) await syncDirectory(parent);
}

async function durableDeleteWork(work, dependencies) {
  await recoverWorkTombstones(work, dependencies);
  if (!existsSync(work)) return;
  const tombstone = join(dirname(work), `${tombstonePrefix(work)}${process.pid}-` +
    systemRandomBytes(8).toString('hex'));
  await atomicRename(work, tombstone);
  if (dependencies.afterWorkspaceRename) {
    await dependencies.afterWorkspaceRename({ work, tombstone });
  }
  if (dependencies.removeWork) await dependencies.removeWork(tombstone);
  else await rm(tombstone, { recursive: true, force: true });
  await syncDirectory(dirname(work));
}

async function assertNoSecretWorkspace(work) {
  if (existsSync(work)) throw new Error('Device secret workspace still exists.');
  const names = await readdir(dirname(work));
  if (names.some((name) => name.startsWith(tombstonePrefix(work)))) {
    throw new Error('Device secret workspace tombstone still exists.');
  }
}

async function recoverPreparationJournals(root, paths, dependencies) {
  const evidenceDirectory = plainPath(root, join(paths.evidence, 'device-acceptance'),
    { allowMissing: true });
  const workParent = plainPath(root, join(paths.workspaces, 'device-acceptance'),
    { allowMissing: true });
  await mkdir(evidenceDirectory, { recursive: true });
  await mkdir(workParent, { recursive: true });
  let names = await readdir(evidenceDirectory);
  for (const name of names) {
    const match = name.match(/^\.([0-9a-f]{32}\.prepare\.json)\.tmp-/);
    if (match) await recoverAtomicState(join(evidenceDirectory, match[1]));
  }
  names = await readdir(evidenceDirectory);
  for (const name of names.filter((entry) => PREPARATION_JOURNAL.test(entry))) {
    const challengeId = name.match(PREPARATION_JOURNAL)[1];
    const journalPath = join(evidenceDirectory, name);
    const journal = await readAtomicJson(journalPath);
    exactKeys(journal, ['schemaVersion', 'kind', 'challengeId', 'ownerToken'],
      'Device preparation journal');
    if (journal.schemaVersion !== 1 || journal.kind !== 'arkdb-device-preparation' ||
      journal.challengeId !== challengeId ||
      typeof journal.ownerToken !== 'string' || !/^[0-9a-f]{32}$/.test(journal.ownerToken)) {
      throw new Error('Device preparation journal is invalid.');
    }
    const staging = plainPath(root, join(workParent, `.staging-${challengeId}`),
      { allowMissing: true });
    const work = plainPath(root, join(workParent, challengeId), { allowMissing: true });
    const pending = plainPath(root, join(evidenceDirectory, `${challengeId}.pending.json`),
      { allowMissing: true });
    await recoverWorkTombstones(staging, dependencies);
    await recoverWorkTombstones(work, dependencies);
    const pendingExists = await atomicStateExists(pending);
    if (pendingExists) {
      if (!existsSync(work)) {
        throw new Error('Published device challenge has no secret workspace to complete verification.');
      }
      await durableDeleteWork(staging, dependencies);
    } else {
      await durableDeleteWork(staging, dependencies);
      await durableDeleteWork(work, dependencies);
    }
    await rm(journalPath);
    await syncDirectory(evidenceDirectory);
  }
}

function exactKeys(value, names, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
    JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...names].sort())) {
    throw new Error(`${label} has an invalid property set.`);
  }
}

function readCaseManifest(bytes) {
  const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  exactKeys(value, ['schemaVersion', 'suiteId', 'caseIds', 'runtime'], 'Device acceptance case manifest');
  exactKeys(value.runtime, ['minimumSdkApiVersion', 'deviceTypes', 'serverFamilies'],
    'Device acceptance runtime manifest');
  if (value.schemaVersion !== 1 || value.suiteId !== 'arkdb.mysql.device-acceptance' ||
    !Array.isArray(value.caseIds) || value.caseIds.length === 0 || value.caseIds.length > 32 ||
    new Set(value.caseIds).size !== value.caseIds.length ||
    value.caseIds.some((id) => !/^[a-z][a-z0-9_]{1,63}$/.test(id)) ||
    !Number.isSafeInteger(value.runtime.minimumSdkApiVersion) ||
    value.runtime.minimumSdkApiVersion < 1 ||
    JSON.stringify(value.runtime.deviceTypes) !== JSON.stringify(['tablet', '2in1']) ||
    JSON.stringify(value.runtime.serverFamilies) !== JSON.stringify(['MySQL'])) {
    throw new Error('Invalid device acceptance case manifest.');
  }
  return value;
}

function randomHex(bytes, size, label) {
  const value = bytes(size);
  if (!Buffer.isBuffer(value) || value.length !== size) {
    throw new Error(`Could not generate the ${label}.`);
  }
  return value.toString('hex');
}

function stringLiteral(value) {
  return JSON.stringify(value);
}

function canonicalTime(value) {
  return typeof value === 'string' && CANONICAL_TIME.test(value) &&
    new Date(value).toISOString() === value;
}

function pathWithin(parent, candidate) {
  const path = relative(resolve(parent), resolve(candidate));
  return path === '' || (!isAbsolute(path) && path !== '..' && !path.startsWith(`..${sep}`));
}

function strictBase64(value, label, maximumBytes) {
  if (typeof value !== 'string' || value.length === 0 || value.length > maximumBytes * 2 ||
    !BASE64.test(value)) throw new Error(`${label} is not bounded canonical base64.`);
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length === 0 || bytes.length > maximumBytes || bytes.toString('base64') !== value) {
    throw new Error(`${label} is not bounded canonical base64.`);
  }
  return bytes;
}

function signingKeyPair(dependencies) {
  if (dependencies.generateSigningKeyPair) return dependencies.generateSigningKeyPair();
  const pair = generateKeyPairSync('ed25519');
  return {
    publicKeySpki: Buffer.from(pair.publicKey.export({ format: 'der', type: 'spki' })),
    privateKeyPkcs8: Buffer.from(pair.privateKey.export({ format: 'der', type: 'pkcs8' }))
  };
}

export function renderDeviceEvidenceBinding(binding) {
  return `import { DeviceEvidenceIdentity } from './DeviceEvidenceIdentity';

export { DeviceEvidenceIdentity } from './DeviceEvidenceIdentity';

export function currentDeviceEvidenceBinding(): DeviceEvidenceIdentity {
  const binding = new DeviceEvidenceIdentity();
  binding.enabled = true;
  binding.challengeId = ${stringLiteral(binding.challengeId)};
  binding.receiptNonce = ${stringLiteral(binding.receiptNonce)};
  binding.schemaChallenge = ${stringLiteral(binding.schemaChallenge)};
  binding.createdAt = ${stringLiteral(binding.createdAt)};
  binding.expiresAt = ${stringLiteral(binding.expiresAt)};
  binding.suiteId = ${stringLiteral(binding.suiteId)};
  binding.caseManifestSha256 = ${stringLiteral(binding.caseManifestSha256)};
  binding.releaseSetSha256 = ${stringLiteral(binding.releaseSetSha256)};
  binding.repository = ${stringLiteral(binding.repository)};
  binding.driver = ${stringLiteral(binding.driver)};
  binding.packageName = ${stringLiteral(binding.packageName)};
  binding.version = ${stringLiteral(binding.version)};
  binding.sourceCommit = ${stringLiteral(binding.sourceCommit)};
  binding.artifactSha256 = ${stringLiteral(binding.artifactSha256)};
  binding.artifactByteLength = ${binding.artifactByteLength};
  binding.sampleFingerprint = ${stringLiteral(binding.sampleFingerprint)};
  binding.publicKeySpkiBase64 = ${stringLiteral(binding.publicKeySpkiBase64)};
  binding.publicKeySpkiSha256 = ${stringLiteral(binding.publicKeySpkiSha256)};
  binding.privateKeyPkcs8Base64 = ${stringLiteral(binding.privateKeyPkcs8Base64)};
  binding.format = ${stringLiteral(binding.platform.format)};
  binding.compatibleSdkVersion = ${binding.platform.compatibleSdkVersion};
  binding.compatibleSdkType = ${stringLiteral(binding.platform.compatibleSdkType)};
  binding.useNormalizedOHMUrl = ${binding.platform.useNormalizedOHMUrl};
  binding.buildMode = ${stringLiteral(binding.platform.buildMode)};
  return binding;
}
`;
}

function assertCleanReleaseSource(root, driver, set, git) {
  if (git(['status', '--porcelain', '--untracked-files=all']).trim() !== '' ||
    git(['rev-parse', '--verify', 'HEAD']).trim() !== set.sourceCommit ||
    sourceFingerprint(root, driver) !== set.sourceFingerprint ||
    sampleFingerprint(root, driver) !== set.verification.sampleFingerprint) {
    throw new Error('Device harness preparation requires the exact clean sealed-release source and sample.');
  }
}

async function defaultBuildHarness({
  sampleDirectory, artifactBytes, bindingSource, hapPath
}, dependencies) {
  const generated = new Set([
    'build', '.hvigor', '.test', 'oh_modules', 'node_modules', 'dependency',
    'BuildProfile.ets', 'oh-package-lock.json5', '.ohpmrc', '.npmrc', 'local.properties'
  ]);
  await cp(dependencies.sampleSource, sampleDirectory, {
    recursive: true,
    filter: (file) => !generated.has(basename(file))
  });
  const bindingPath = join(sampleDirectory, 'entry', 'src', 'main', 'ets', 'sample',
    'DeviceEvidenceBinding.ets');
  await writeFile(bindingPath, bindingSource);
  const dependencyDirectory = join(sampleDirectory, 'dependency');
  await mkdir(dependencyDirectory);
  const artifactPath = join(dependencyDirectory, 'mysql.har');
  await writeFile(artifactPath, artifactBytes, { flag: 'wx' });
  if (sha256(await readFile(artifactPath)) !== sha256(artifactBytes)) {
    throw new Error('The isolated device harness received different HAR bytes.');
  }
  const restored = (dependencies.runOhpm ?? runOhpm)(['install', '--all'], { cwd: sampleDirectory });
  if (restored.status !== 0 || /ohpm ERROR/.test(restored.output)) {
    throw new Error('The isolated device harness dependency restore failed.');
  }
  const built = (dependencies.runHvigor ?? runHvigor)([
    '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default',
    'assembleHap', '--no-daemon'
  ], { cwd: sampleDirectory });
  if (built.status !== 0 || /hvigor ERROR/.test(built.output) || !/BUILD SUCCESSFUL/.test(built.output)) {
    throw new Error('The isolated device harness HAP build failed.');
  }
  const output = join(sampleDirectory, 'entry', 'build', 'default', 'outputs', 'default',
    'entry-default-unsigned.hap');
  const info = await stat(output);
  if (!info.isFile() || info.size <= 0) throw new Error('The isolated device harness HAP is missing.');
  await copyFile(output, hapPath);
}

export async function prepareDeviceEvidence({
  root = ROOT, driver = 'mysql', bundleDirectory
}, dependencies = {}) {
  const bundle = await readReleaseBundle(bundleDirectory);
  const set = bundle.releaseSet;
  if (set.driver !== driver) throw new Error('The sealed release is not for the selected driver.');
  const git = dependencies.git ?? gitReader(root);
  assertCleanReleaseSource(root, driver, set, git);
  const stem = packageStem({ name: set.packageName, version: set.version });
  const artifact = set.assets.find((entry) => entry.name === `${stem}.har`);
  const artifactBytes = bundle.assets.get(`${stem}.har`);
  if (!artifact || !artifactBytes) throw new Error('The sealed release has no selected driver HAR identity.');
  const paths = tagOutputPaths(root, driver, set.tag);
  const evidenceDirectory = plainPath(root, join(paths.evidence, 'device-acceptance'), { allowMissing: true });
  await mkdir(evidenceDirectory, { recursive: true });
  plainPath(root, evidenceDirectory);
  const workParent = plainPath(root, join(paths.workspaces, 'device-acceptance'), { allowMissing: true });
  await mkdir(workParent, { recursive: true });
  plainPath(root, workParent);
  const caseBytes = await readFile(join(root, CASE_MANIFEST));
  const cases = readCaseManifest(caseBytes);
  const now = dependencies.now ? dependencies.now() : new Date();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error('Invalid device challenge time.');
  const bytes = dependencies.randomBytes ?? systemRandomBytes;
  const challengeId = randomHex(bytes, 16, 'challenge id');
  const receiptNonce = randomHex(bytes, 32, 'receipt nonce');
  const schemaChallenge = randomHex(bytes, 32, 'schema challenge');
  const createdAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + CHALLENGE_LIFETIME_MS).toISOString();
  const keys = signingKeyPair(dependencies);
  if (!Buffer.isBuffer(keys.publicKeySpki) || !Buffer.isBuffer(keys.privateKeyPkcs8) ||
    keys.publicKeySpki.length === 0 || keys.privateKeyPkcs8.length === 0) {
    throw new Error('Could not generate the one-time Ed25519 signing identity.');
  }
  const generatedPublicKey = createPublicKey({ key: keys.publicKeySpki, format: 'der', type: 'spki' });
  const generatedPrivateKey = createPrivateKey({ key: keys.privateKeyPkcs8, format: 'der', type: 'pkcs8' });
  const keyProbe = Buffer.from(`arkdb-device-key:${challengeId}`, 'utf8');
  if (generatedPublicKey.asymmetricKeyType !== 'ed25519' ||
    generatedPrivateKey.asymmetricKeyType !== 'ed25519' ||
    !verifySignature(null, keyProbe, generatedPublicKey, signBytes(null, keyProbe, generatedPrivateKey))) {
    throw new Error('The one-time signing key pair is not a valid Ed25519 identity.');
  }
  const publicKeySpkiBase64 = keys.publicKeySpki.toString('base64');
  const publicKeySpkiSha256 = sha256(keys.publicKeySpki);
  const binding = {
    challengeId, receiptNonce, schemaChallenge, createdAt, expiresAt,
    repository: set.repository, driver: set.driver, packageName: set.packageName,
    version: set.version, sourceCommit: set.sourceCommit,
    artifactSha256: artifact.sha256, artifactByteLength: artifact.byteLength,
    sampleFingerprint: set.verification.sampleFingerprint,
    releaseSetSha256: sha256(bundle.releaseSetBytes),
    suiteId: cases.suiteId, caseManifestSha256: sha256(caseBytes),
    publicKeySpkiBase64, publicKeySpkiSha256,
    privateKeyPkcs8Base64: keys.privateKeyPkcs8.toString('base64'),
    platform: set.platform
  };
  const preparationLockPath = plainPath(root,
    join(evidenceDirectory, 'preparation.lock.json'), { allowMissing: true });
  const preparationLock = await acquireProcessLock(
    preparationLockPath, 'arkdb-device-preparation-lock', dependencies);
  try {
    await recoverPreparationJournals(root, paths, dependencies);
  const stagingDirectory = plainPath(root, join(workParent, `.staging-${challengeId}`), { allowMissing: true });
  const workDirectory = plainPath(root, join(workParent, challengeId), { allowMissing: true });
  const pendingPath = plainPath(root, join(evidenceDirectory, `${challengeId}.pending.json`),
    { allowMissing: true });
  const preparationPath = plainPath(root, join(evidenceDirectory, `${challengeId}.prepare.json`),
    { allowMissing: true });
  if (existsSync(stagingDirectory) || existsSync(workDirectory) || existsSync(pendingPath) ||
    existsSync(preparationPath)) {
    throw new Error('Device challenge output already exists.');
  }
  await atomicWriteNew(preparationPath, recordBytes({
    schemaVersion: 1,
    kind: 'arkdb-device-preparation',
    challengeId,
    ownerToken: preparationLock.token
  }));
  let committed = false;
  let challengeBytes;
  try {
    await mkdir(stagingDirectory);
    const sampleDirectory = join(stagingDirectory, 'sample');
    const hapPath = join(stagingDirectory, 'entry-default-unsigned.hap');
    const buildHarness = dependencies.buildHarness ?? defaultBuildHarness;
    await buildHarness({
      root, driver, sampleDirectory, artifactBytes,
      bindingSource: renderDeviceEvidenceBinding(binding), hapPath
    }, {
      ...dependencies,
      sampleSource: driverVerification(root, driver).consumerDirectory
    });
    const hapBytes = releaseFile(stagingDirectory, basename(hapPath), 128 * 1024 * 1024);
    const preparedUnsignedHapSha256 = sha256(hapBytes);
    const preparedUnsignedHapByteLength = hapBytes.length;
    const preparedUnsignedHapContentSha256 = hapSigningContentFingerprint(hapBytes);
    await rm(sampleDirectory, { recursive: true, force: true });
    const provisioningPath = join(stagingDirectory, 'schema-challenge.json');
    await writeFile(provisioningPath, `${JSON.stringify({
      schemaVersion: 1,
      table: 'arkdb_device_acceptance',
      challengeId,
      challengeValue: schemaChallenge,
      createdAt,
      expiresAt
    }, null, 2)}\n`, { flag: 'wx' });
    const contextPath = join(stagingDirectory, 'receipt-context.json');
    await writeFile(contextPath, `${JSON.stringify({
      schemaVersion: 1,
      challengeId,
      preparedUnsignedHapSha256,
      preparedUnsignedHapByteLength,
      preparedUnsignedHapContentSha256,
      publicKeySpkiSha256,
      createdAt,
      expiresAt
    }, null, 2)}\n`, { flag: 'wx' });
    const challenge = {
      schemaVersion: 1,
      kind: 'arkdb-device-evidence-challenge',
      state: 'issued',
      repository: set.repository,
      driver: set.driver,
      packageName: set.packageName,
      version: set.version,
      tag: set.tag,
      sourceCommit: set.sourceCommit,
      artifactSha256: artifact.sha256,
      artifactByteLength: artifact.byteLength,
      sampleFingerprint: set.verification.sampleFingerprint,
      releaseSetSha256: sha256(bundle.releaseSetBytes),
      suiteId: cases.suiteId,
      caseManifestSha256: sha256(caseBytes),
      caseIds: cases.caseIds,
      runtime: cases.runtime,
      platform: set.platform,
      challengeId,
      receiptNonce,
      schemaChallenge,
      createdAt,
      expiresAt,
      publicKeySpkiBase64,
      publicKeySpkiSha256,
      preparedUnsignedHapSha256,
      preparedUnsignedHapByteLength,
      preparedUnsignedHapContentSha256
    };
    challengeBytes = recordBytes(challenge);
    assertCleanReleaseSource(root, driver, set, git);
    const currentBundle = await readReleaseBundle(bundleDirectory);
    if (sha256(currentBundle.releaseSetBytes) !== challenge.releaseSetSha256) {
      throw new Error('The sealed release changed while the device harness was built.');
    }
    for (const file of [hapPath, provisioningPath, contextPath]) {
      await syncPreparedFile(file, dependencies);
    }
    await syncDirectory(stagingDirectory);
    await atomicRename(stagingDirectory, workDirectory);
    if (dependencies.beforePending) await dependencies.beforePending({ challenge, workDirectory });
    await atomicWriteNew(pendingPath, challengeBytes, {
      afterLink: dependencies.afterPendingLink
        ? (state) => dependencies.afterPendingLink({ ...state, challenge, workDirectory })
        : undefined
    });
    committed = true;
    await rm(preparationPath);
    await syncDirectory(evidenceDirectory);
    return {
      challenge,
      challengePath: pendingPath,
      workDirectory,
      hapPath: join(workDirectory, 'entry-default-unsigned.hap'),
      provisioningPath: join(workDirectory, 'schema-challenge.json'),
      contextPath: join(workDirectory, 'receipt-context.json')
    };
  } finally {
    if (!committed) {
      if (challengeBytes !== undefined && existsSync(pendingPath)) {
        const published = await readFile(pendingPath);
        committed = sha256(published) === sha256(challengeBytes);
      }
      if (!committed) {
        await durableDeleteWork(stagingDirectory, dependencies);
        await durableDeleteWork(workDirectory, dependencies);
        await rm(preparationPath, { force: true });
        await syncDirectory(evidenceDirectory);
      }
    }
  }
  } finally {
    await releaseProcessLock(preparationLockPath, preparationLock);
  }
}

function safePublicLabel(value) {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9 ._()+/-]{0,127}$/.test(value);
}

function supportedDeviceSelection(profile, features, authPlugin) {
  if (['M1', 'M2', 'M3'].includes(profile)) return features.length === 0;
  return profile === 'M4' && features.length === 1 && features[0] === 'sha256' &&
    (authPlugin === undefined || authPlugin === 'caching_sha2_password');
}

function validateChallenge(challenge, set, bundle, cases, caseBytes) {
  const stem = packageStem({ name: set.packageName, version: set.version });
  const artifact = set.assets.find((entry) => entry.name === `${stem}.har`);
  exactKeys(challenge, [
    'schemaVersion', 'kind', 'state', 'repository', 'driver', 'packageName', 'version', 'tag',
    'sourceCommit', 'artifactSha256', 'artifactByteLength', 'sampleFingerprint',
    'releaseSetSha256', 'suiteId', 'caseManifestSha256', 'caseIds', 'runtime', 'platform',
    'challengeId', 'receiptNonce', 'schemaChallenge', 'createdAt', 'expiresAt',
    'publicKeySpkiBase64', 'publicKeySpkiSha256', 'preparedUnsignedHapSha256',
    'preparedUnsignedHapByteLength', 'preparedUnsignedHapContentSha256'
  ], 'Device evidence challenge');
  const publicKey = strictBase64(challenge.publicKeySpkiBase64, 'Device challenge public key', 1024);
  if (challenge.schemaVersion !== 1 || challenge.kind !== 'arkdb-device-evidence-challenge' ||
    challenge.state !== 'issued' || challenge.repository !== set.repository ||
    challenge.driver !== set.driver || challenge.packageName !== set.packageName ||
    challenge.version !== set.version || challenge.tag !== set.tag ||
    challenge.sourceCommit !== set.sourceCommit || challenge.artifactSha256 !== artifact?.sha256 ||
    challenge.artifactByteLength !== artifact?.byteLength ||
    challenge.sampleFingerprint !== set.verification.sampleFingerprint ||
    challenge.releaseSetSha256 !== sha256(bundle.releaseSetBytes) ||
    challenge.suiteId !== cases.suiteId ||
    challenge.caseManifestSha256 !== sha256(caseBytes) ||
    JSON.stringify(challenge.caseIds) !== JSON.stringify(cases.caseIds) ||
    JSON.stringify(challenge.runtime) !== JSON.stringify(cases.runtime) ||
    JSON.stringify(challenge.platform) !== JSON.stringify(set.platform) ||
    !/^[0-9a-f]{32}$/.test(challenge.challengeId ?? '') ||
    !/^[0-9a-f]{64}$/.test(challenge.receiptNonce ?? '') ||
    !/^[0-9a-f]{64}$/.test(challenge.schemaChallenge ?? '') ||
    !canonicalTime(challenge.createdAt) || !canonicalTime(challenge.expiresAt) ||
    Date.parse(challenge.expiresAt) - Date.parse(challenge.createdAt) !== CHALLENGE_LIFETIME_MS ||
    challenge.publicKeySpkiSha256 !== sha256(publicKey) ||
    !/^[0-9a-f]{64}$/.test(challenge.preparedUnsignedHapSha256 ?? '') ||
    !Number.isSafeInteger(challenge.preparedUnsignedHapByteLength) ||
    challenge.preparedUnsignedHapByteLength <= 0 ||
    !/^[0-9a-f]{64}$/.test(challenge.preparedUnsignedHapContentSha256 ?? '')) {
    throw new Error('Device evidence challenge differs from its sealed release binding.');
  }
}

function parseReceiptEnvelope(bytes) {
  const envelope = jsonBytes(bytes);
  exactKeys(envelope, ['schemaVersion', 'kind', 'payload', 'signature'], 'Device receipt envelope');
  exactKeys(envelope.signature, ['algorithm', 'publicKeySpkiBase64', 'valueBase64'],
    'Device receipt signature');
  if (envelope.schemaVersion !== 1 || envelope.kind !== 'arkdb-device-acceptance-envelope' ||
    typeof envelope.payload !== 'string' || envelope.payload.length === 0 ||
    Buffer.byteLength(envelope.payload) > 1024 * 1024 ||
    envelope.signature.algorithm !== 'Ed25519') {
    throw new Error('Invalid device receipt envelope.');
  }
  let payload;
  try {
    payload = JSON.parse(envelope.payload);
  } catch (error) {
    throw new Error('Device receipt payload is not valid JSON.', { cause: error });
  }
  if (JSON.stringify(payload) !== envelope.payload) {
    throw new Error('Device receipt payload is not canonical exact JSON.');
  }
  return { envelope, payload };
}

function verifyEnvelopeSignature(parsed, expectedPublicKeySpkiBase64) {
  const { envelope } = parsed;
  const publicKeyBytes = strictBase64(envelope.signature.publicKeySpkiBase64,
    'Device receipt public key', 1024);
  const signature = strictBase64(envelope.signature.valueBase64, 'Device receipt signature', 1024);
  if (envelope.signature.publicKeySpkiBase64 !== expectedPublicKeySpkiBase64) {
    throw new Error('Device receipt signing identity differs from the prepared harness.');
  }
  let publicKey;
  try {
    publicKey = createPublicKey({ key: publicKeyBytes, format: 'der', type: 'spki' });
  } catch (error) {
    throw new Error('Device receipt public key is invalid.', { cause: error });
  }
  if (publicKey.asymmetricKeyType !== 'ed25519' ||
    !verifySignature(null, Buffer.from(envelope.payload, 'utf8'), publicKey, signature)) {
    throw new Error('Device receipt signature verification failed.');
  }
  return parsed;
}

export function verifyDeviceReceiptEnvelope(bytes, expectedPublicKeySpkiBase64) {
  return verifyEnvelopeSignature(parseReceiptEnvelope(bytes), expectedPublicKeySpkiBase64);
}

function validateReceipt(envelope, receipt, challenge, cases) {
  const parsed = verifyEnvelopeSignature({ envelope, payload: receipt }, challenge.publicKeySpkiBase64);
  const publicKeyBytes = Buffer.from(parsed.envelope.signature.publicKeySpkiBase64, 'base64');
  if (sha256(publicKeyBytes) !== challenge.publicKeySpkiSha256) {
    throw new Error('Device receipt signing identity differs from the prepared harness.');
  }
  exactKeys(receipt, [
    'schemaVersion', 'profile', 'features', 'runId', 'sourceCommit', 'sourceClean',
    'harSha256', 'sampleFingerprint', 'hapSha256', 'apiVersion', 'deviceClass',
    'serverVersion', 'tlsMode', 'authPlugin', 'challengeIssuedAt', 'challengeExpiresAt',
    'startedAt', 'completedAt', 'operatorEvidenceId', 'cases'
  ], 'Device acceptance receipt');
  if (receipt.schemaVersion !== 1 || !DEVICE_PROFILES.includes(receipt.profile) ||
    !Array.isArray(receipt.features) ||
    receipt.features.some((feature) => !DEVICE_FEATURES.includes(feature)) ||
    new Set(receipt.features).size !== receipt.features.length ||
    JSON.stringify([...receipt.features].sort()) !== JSON.stringify(receipt.features) ||
    !supportedDeviceSelection(receipt.profile, receipt.features, receipt.authPlugin) ||
    receipt.runId !== challenge.challengeId ||
    receipt.sourceCommit !== challenge.sourceCommit || receipt.sourceClean !== true ||
    receipt.harSha256 !== challenge.artifactSha256 ||
    receipt.sampleFingerprint !== challenge.sampleFingerprint ||
    !/^[0-9a-f]{64}$/.test(receipt.hapSha256 ?? '') ||
    !Number.isSafeInteger(receipt.apiVersion) ||
    receipt.apiVersion < cases.runtime.minimumSdkApiVersion ||
    !cases.runtime.deviceTypes.includes(receipt.deviceClass) ||
    !safePublicLabel(receipt.serverVersion) || receipt.tlsMode !== 'verify_identity' ||
    !DEVICE_AUTH_PLUGINS.includes(receipt.authPlugin) ||
    receipt.challengeIssuedAt !== challenge.createdAt ||
    receipt.challengeExpiresAt !== challenge.expiresAt ||
    !canonicalTime(receipt.startedAt) || !canonicalTime(receipt.completedAt) ||
    Date.parse(receipt.startedAt) < Date.parse(challenge.createdAt) ||
    Date.parse(receipt.completedAt) < Date.parse(receipt.startedAt) ||
    Date.parse(receipt.completedAt) > Date.parse(challenge.expiresAt) ||
    typeof receipt.operatorEvidenceId !== 'string' ||
    !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(receipt.operatorEvidenceId)) {
    throw new Error('Device receipt release/harness binding does not match the pending challenge.');
  }
  if (!Array.isArray(receipt.cases) || receipt.cases.length !== challenge.caseIds.length) {
    throw new Error('Device receipt case manifest is incomplete or differently bound.');
  }
  for (let index = 0; index < receipt.cases.length; index++) {
    const result = receipt.cases[index];
    const keys = Object.keys(result).sort();
    if (JSON.stringify(keys) !== JSON.stringify(
      (result.errorKind === undefined
        ? ['durationMs', 'id', 'status']
        : ['durationMs', 'errorKind', 'id', 'status']).sort()
    ) ||
      result.id !== challenge.caseIds[index] ||
      !['pass', 'fail', 'ignored'].includes(result.status) ||
      !Number.isSafeInteger(result.durationMs) || result.durationMs < 0 ||
      result.durationMs > CHALLENGE_LIFETIME_MS ||
      (result.errorKind !== undefined && !safePublicLabel(result.errorKind))) {
      throw new Error('Device receipt case IDs or verdicts differ from the required manifest.');
    }
    if (result.status !== 'pass' || result.errorKind !== undefined) {
      throw new Error('Device acceptance requires every mandatory case to pass with no failures or ignored cases.');
    }
  }
  if (receipt.cases.length === 0) {
    throw new Error('Device acceptance requires every mandatory case to pass with no failures, errors, or ignored cases.');
  }
}

function statePaths(root, paths, challengeId) {
  const evidenceDirectory = plainPath(root, join(paths.evidence, 'device-acceptance'));
  return {
    evidenceDirectory,
    pending: plainPath(root, join(evidenceDirectory, `${challengeId}.pending.json`), { allowMissing: true }),
    verifying: plainPath(root, join(evidenceDirectory, `${challengeId}.verifying.json`), { allowMissing: true }),
    accepted: plainPath(root, join(evidenceDirectory, `${challengeId}.accepted.json`), { allowMissing: true }),
    rejected: plainPath(root, join(evidenceDirectory, `${challengeId}.rejected.json`), { allowMissing: true }),
    lock: plainPath(root, join(evidenceDirectory, `${challengeId}.claim.json`), { allowMissing: true }),
    acceptedRecord: plainPath(root, join(evidenceDirectory, `${challengeId}.evidence.json`), { allowMissing: true }),
    rejectedRecord: plainPath(root, join(evidenceDirectory, `${challengeId}.rejection.json`), { allowMissing: true }),
    work: plainPath(root, join(paths.workspaces, 'device-acceptance', challengeId), { allowMissing: true })
  };
}

async function recoverableChallenge(root, set, challengeId) {
  const states = statePaths(root, tagOutputPaths(root, set.driver, set.tag), challengeId);
  for (const path of [states.pending, states.verifying, states.accepted, states.rejected]) {
    if (!await atomicStateExists(path)) continue;
    const value = await readAtomicJson(path);
    return value.kind === 'arkdb-device-evidence-challenge' ? value : value.challenge;
  }
  throw new Error('Device challenge is not pending or recoverable.');
}

function recordBytes(record) {
  return Buffer.from(`${JSON.stringify(record, null, 2)}\n`);
}

function rejectionCode(error) {
  const message = error instanceof Error ? error.message : String(error);
  if (/signature/i.test(message)) return 'signature_invalid';
  if (/signing identity|public key/i.test(message)) return 'signing_identity_mismatch';
  if (/case|pass|failures|ignored/i.test(message)) return 'case_verdict_invalid';
  if (/challenge.*expired/i.test(message)) return 'challenge_expired';
  if (/property|unsafe|canonical/i.test(message)) return 'receipt_schema_invalid';
  return 'receipt_binding_invalid';
}

function acceptedRecord(parsed, challenge, receiptBytes, now, acceptanceContext = null) {
  const record = {
    schemaVersion: 1,
    kind: 'arkdb-device-receipt-verification',
    verifiedAt: now.toISOString(),
    receiptSha256: sha256(receiptBytes),
    tag: challenge.tag,
    profile: parsed.payload.profile,
    features: parsed.payload.features,
    runId: parsed.payload.runId,
    sourceCommit: parsed.payload.sourceCommit,
    sourceClean: parsed.payload.sourceClean,
    harSha256: parsed.payload.harSha256,
    sampleFingerprint: parsed.payload.sampleFingerprint,
    preparedUnsignedHapContentSha256: challenge.preparedUnsignedHapContentSha256,
    hapSha256: parsed.payload.hapSha256,
    apiVersion: parsed.payload.apiVersion,
    deviceClass: parsed.payload.deviceClass,
    serverVersion: parsed.payload.serverVersion,
    tlsMode: parsed.payload.tlsMode,
    authPlugin: parsed.payload.authPlugin,
    challengeIssuedAt: parsed.payload.challengeIssuedAt,
    challengeExpiresAt: parsed.payload.challengeExpiresAt,
    startedAt: parsed.payload.startedAt,
    completedAt: parsed.payload.completedAt,
    operatorEvidenceId: parsed.payload.operatorEvidenceId,
    cases: parsed.payload.cases,
    receiptAccepted: true,
    signedHapVerified: false,
    liveNetworkingVerified: false,
    operatorEvidenceBound: false,
    hardwareAttested: false,
    readOnlyPrivilegeVerified: false,
    productionCertified: false
  };
  if (acceptanceContext === null) return record;
  return {
    ...record,
    kind: 'arkdb-device-acceptance',
    hapSha256: acceptanceContext.hapSha256,
    hapByteLength: acceptanceContext.hapByteLength,
    hapContentSha256: acceptanceContext.hapContentSha256,
    signedHapVerified: true,
    liveNetworkingVerified: true,
    operatorEvidenceBound: true,
    physicalDeviceAttestedByOperator: true,
    authorizedSchemaAttestedByOperator: true,
    operatorAttestationTrustBoundary:
      'Receipt, signed-HAP bytes, and operator evidence ID are bound; no hardware remote attestation is claimed.'
  };
}

function rejectedRecord(parsed, challenge, receiptBytes, now, error) {
  return {
    schemaVersion: 1,
    kind: 'arkdb-device-rejection',
    rejectedAt: now.toISOString(),
    challengeId: challenge.challengeId,
    receiptSha256: sha256(receiptBytes),
    payloadSha256: sha256(Buffer.from(parsed.envelope.payload, 'utf8')),
    reason: rejectionCode(error)
  };
}

function claimRecord(challenge, receiptBytes, parsed, decision, recordPath, record, outputPath) {
  const bytes = recordBytes(record);
  return {
    schemaVersion: 1,
    kind: 'arkdb-device-verification-claim',
    challenge,
    receiptSha256: sha256(receiptBytes),
    payloadSha256: sha256(Buffer.from(parsed.envelope.payload, 'utf8')),
    decision,
    recordName: basename(recordPath),
    recordSha256: sha256(bytes),
    outputPath,
    record
  };
}

function validateClaim(claim, receiptBytes, parsed, decision, recordPath, outputPath) {
  exactKeys(claim, [
    'schemaVersion', 'kind', 'challenge', 'receiptSha256', 'payloadSha256',
    'decision', 'recordName', 'recordSha256', 'outputPath', 'record'
  ], 'Device verification claim');
  if (claim.schemaVersion !== 1 || claim.kind !== 'arkdb-device-verification-claim' ||
    claim.receiptSha256 !== sha256(receiptBytes) ||
    claim.payloadSha256 !== sha256(Buffer.from(parsed.envelope.payload, 'utf8')) ||
    claim.decision !== decision || claim.recordName !== basename(recordPath) ||
    claim.recordSha256 !== sha256(recordBytes(claim.record)) ||
    claim.outputPath !== outputPath) {
    throw new Error('Device verification recovery belongs to a different receipt or decision.');
  }
  return claim;
}

function processAlive(pid, dependencies) {
  if (dependencies.isProcessAlive) return dependencies.isProcessAlive(pid);
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function lockRecoveryPaths(path) {
  return {
    snapshot: join(dirname(path), `${basename(path)}.recovery-snapshot`),
    owner: join(dirname(path), `${basename(path)}.recovery-owner.json`)
  };
}

async function releaseRecoveryOwner(paths, token) {
  let owned = false;
  if (existsSync(paths.owner)) {
    const owner = await readAtomicJson(paths.owner);
    if (owner.token === token) {
      await rm(paths.owner);
      owned = true;
    }
  }
  if (owned) {
    await rm(paths.snapshot, { force: true });
    await syncDirectory(dirname(paths.owner));
  }
}

async function acquireRecoveryOwner(path, observedBytes, dependencies) {
  const paths = lockRecoveryPaths(path);
  await recoverAtomicState(paths.owner);
  let observedSnapshot = null;
  for (let attempt = 0; attempt < 3 && observedSnapshot === null; attempt++) {
    if (!existsSync(paths.snapshot)) {
      try {
        await link(path, paths.snapshot);
        await syncDirectory(dirname(path));
      } catch (error) {
        if (error?.code === 'ENOENT') return null;
        if (error?.code !== 'EEXIST') throw error;
      }
    }
    try {
      observedSnapshot = await readBoundedRegularBytes(paths.snapshot, 'Lock recovery snapshot');
    } catch (error) {
      await rm(paths.snapshot, { recursive: true, force: true });
      await syncDirectory(dirname(paths.snapshot));
      if (attempt === 2) throw error;
    }
  }
  const token = systemRandomBytes(16).toString('hex');
  const identity = {
    schemaVersion: 1,
    kind: 'arkdb-lock-recovery-owner',
    pid: process.pid,
    token
  };
  let acquired = false;
  for (let attempt = 0; attempt < 4 && !acquired; attempt++) {
    try {
      await atomicWriteNew(paths.owner, recordBytes(identity));
      acquired = true;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
      const owner = await readAtomicJson(paths.owner);
      exactKeys(owner, ['schemaVersion', 'kind', 'pid', 'token'], 'Lock recovery owner');
      if (owner.schemaVersion !== 1 || owner.kind !== 'arkdb-lock-recovery-owner' ||
        typeof owner.token !== 'string' || !/^[0-9a-f]{32}$/.test(owner.token)) {
        throw new Error('Lock recovery owner is invalid.');
      }
      if (processAlive(owner.pid, dependencies)) {
        throw new Error('Lock recovery is already in progress.');
      }
      if (dependencies.beforeStaleRecoveryOwnerRetire) {
        await dependencies.beforeStaleRecoveryOwnerRetire({
          path, ownerPath: paths.owner, observedToken: owner.token
        });
      }
      if (!existsSync(paths.owner)) continue;
      const currentOwner = await readAtomicJson(paths.owner);
      if (currentOwner.token !== owner.token || processAlive(currentOwner.pid, dependencies)) {
        continue;
      }
      if (dependencies.afterStaleRecoveryOwnerRecheck) {
        await dependencies.afterStaleRecoveryOwnerRecheck({
          path, ownerPath: paths.owner, observedToken: owner.token
        });
      }
      const retired = join(dirname(paths.owner), `${basename(paths.owner)}.stale-${process.pid}-` +
        systemRandomBytes(8).toString('hex'));
      try {
        await rename(paths.owner, retired);
        await syncDirectory(dirname(paths.owner));
        const retiredOwner = await readAtomicJson(retired);
        if (retiredOwner.token !== owner.token) {
          try {
            await link(retired, paths.owner);
            await syncDirectory(dirname(paths.owner));
          } catch (restoreError) {
            if (restoreError?.code !== 'EEXIST') throw restoreError;
          }
          await rm(retired, { force: true });
          continue;
        }
        await rm(retired, { force: true });
      } catch (retireError) {
        if (retireError?.code !== 'ENOENT') throw retireError;
      }
    }
  }
  if (!acquired) throw new Error('Lock recovery owner could not be acquired.');
  try {
    const snapshotBytes =
      await readBoundedRegularBytes(paths.snapshot, 'Lock recovery snapshot');
    if (sha256(snapshotBytes) !== sha256(observedBytes) ||
      sha256(observedSnapshot) !== sha256(snapshotBytes)) {
      await releaseRecoveryOwner(paths, token);
      return null;
    }
    if (dependencies.afterRecoveryOwner) {
      await dependencies.afterRecoveryOwner({ path, ownerPath: paths.owner, snapshotPath: paths.snapshot });
    }
    return { ...paths, token };
  } catch (error) {
    await releaseRecoveryOwner(paths, token);
    throw error;
  }
}

async function replaceStaleLock(path, observedBytes, replacementBytes, dependencies) {
  const recovery = await acquireRecoveryOwner(path, observedBytes, dependencies);
  if (recovery === null) return false;
  try {
    if (!existsSync(recovery.owner) ||
      (await readAtomicJson(recovery.owner)).token !== recovery.token) return false;
    if (!existsSync(path) || sha256(await readFile(path)) !== sha256(observedBytes)) return false;
    await atomicReplace(path, replacementBytes);
    return true;
  } finally {
    await releaseRecoveryOwner(recovery, recovery.token);
  }
}

async function acquireProcessLock(path, kind, dependencies) {
  for (let attempt = 0; attempt < 4; attempt++) {
    await recoverAtomicState(path);
    const identity = {
      schemaVersion: 1,
      kind,
      pid: process.pid,
      token: systemRandomBytes(16).toString('hex')
    };
    const bytes = recordBytes(identity);
    try {
      await atomicWriteNew(path, bytes);
      return identity;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
    }
    const existingBytes = await readFile(path);
    const existing = jsonBytes(existingBytes);
    exactKeys(existing, ['schemaVersion', 'kind', 'pid', 'token'], 'Process lock');
    if (existing.schemaVersion !== 1 || existing.kind !== kind ||
      typeof existing.token !== 'string' || !/^[0-9a-f]{32}$/.test(existing.token)) {
      throw new Error('Process lock is invalid.');
    }
    if (processAlive(existing.pid, dependencies)) {
      throw new Error('Device preparation is already in progress.');
    }
    if (await replaceStaleLock(path, existingBytes, bytes, dependencies)) return identity;
  }
  throw new Error('Device preparation lock changed during recovery.');
}

async function releaseProcessLock(path, identity) {
  if (!existsSync(path)) return;
  const current = await readAtomicJson(path);
  if (current.token !== identity.token) return;
  await rm(path);
  await syncDirectory(dirname(path));
}

async function acquireClaimLock(path, candidateClaim, receiptBytes, parsed, outputPath, dependencies) {
  await recoverAtomicState(path);
  const identity = {
    schemaVersion: 1,
    kind: 'arkdb-device-claim-lock',
    pid: process.pid,
    claim: candidateClaim
  };
  const bytes = recordBytes(identity);
  try {
    await atomicWriteNew(path, bytes);
    if (dependencies.afterClaimLock) await dependencies.afterClaimLock({ path, claim: candidateClaim });
    return candidateClaim;
  } catch (error) {
    if (error?.code !== 'EEXIST') throw error;
  }
  for (let attempt = 0; attempt < 4; attempt++) {
    const existingBytes = await readFile(path);
    const existing = jsonBytes(existingBytes);
    exactKeys(existing, ['schemaVersion', 'kind', 'pid', 'claim'], 'Device claim lock');
    if (existing.schemaVersion !== 1 || existing.kind !== 'arkdb-device-claim-lock') {
      throw new Error('Device challenge claim lock is invalid.');
    }
    const decision = existing.claim?.decision;
    const recordPath = decision === 'accepted'
      ? join(dirname(path), `${existing.claim?.challenge?.challengeId}.evidence.json`)
      : decision === 'rejected'
        ? join(dirname(path), `${existing.claim?.challenge?.challengeId}.rejection.json`) : '';
    if (recordPath.length === 0) throw new Error('Device challenge claim lock has no valid decision.');
    const storedClaim = validateClaim(existing.claim, receiptBytes, parsed, decision, recordPath,
      decision === 'accepted' ? outputPath : null);
    if (candidateClaim !== null &&
      (candidateClaim.receiptSha256 !== storedClaim.receiptSha256 ||
        candidateClaim.payloadSha256 !== storedClaim.payloadSha256 ||
        candidateClaim.decision !== storedClaim.decision ||
        candidateClaim.recordSha256 !== storedClaim.recordSha256 ||
        candidateClaim.outputPath !== storedClaim.outputPath ||
        JSON.stringify(candidateClaim.challenge) !== JSON.stringify(storedClaim.challenge))) {
      throw new Error('Device challenge is claimed by a different receipt.');
    }
    if (processAlive(existing.pid, dependencies)) {
      throw new Error('Device challenge verification is already in progress.');
    }
    const replacement = recordBytes({
      schemaVersion: 1,
      kind: 'arkdb-device-claim-lock',
      pid: process.pid,
      claim: storedClaim
    });
    if (await replaceStaleLock(path, existingBytes, replacement, dependencies)) return storedClaim;
  }
  throw new Error('Device challenge claim lock changed during recovery.');
}

async function validateExistingRecord(path, expectedSha256) {
  await recoverAtomicState(path);
  if (!existsSync(path)) return false;
  const bytes = releaseFile(dirname(path), basename(path));
  if (sha256(bytes) !== expectedSha256) {
    throw new Error('Device verification record differs from its claimed identity.');
  }
  jsonBytes(bytes);
  return true;
}

async function publishRecord(path, record, expectedSha256, dependencies) {
  await recoverAtomicState(path);
  if (await validateExistingRecord(path, expectedSha256)) return;
  if (dependencies.writeRecord) {
    await dependencies.writeRecord(path, record);
  } else {
    await atomicWriteNew(path, recordBytes(record));
  }
  await validateExistingRecord(path, expectedSha256);
}

async function publishExternalRecord(path, record, expectedSha256, dependencies) {
  if (path === null) return;
  await recoverAtomicState(path);
  if (await validateExistingRecord(path, expectedSha256)) return;
  if (dependencies.writeExternalRecord) {
    await dependencies.writeExternalRecord(path, record);
  } else {
    await atomicWriteNew(path, recordBytes(record));
  }
  await validateExistingRecord(path, expectedSha256);
}

export async function verifyDeviceEvidence({
  root = ROOT,
  driver = 'mysql',
  bundleDirectory,
  receiptPath,
  confirmPhysicalDevice = false,
  confirmAuthorizedSchema = false,
  acceptanceContext = null,
  outputPath = null
}, dependencies = {}) {
  if (confirmPhysicalDevice !== true || confirmAuthorizedSchema !== true) {
    throw new Error('Device evidence requires explicit physical-device and authorized-schema operator attestations.');
  }
  const requestedOutputPath = outputPath === null ? null : resolve(outputPath);
  let frozenOutputPath = requestedOutputPath;
  let canonicalOutputPath = null;
  if ((acceptanceContext === null) !== (frozenOutputPath === null) ||
    (acceptanceContext !== null &&
      (!/^[0-9a-f]{64}$/.test(acceptanceContext.hapSha256 ?? '') ||
        !/^[0-9a-f]{64}$/.test(acceptanceContext.hapContentSha256 ?? '') ||
        !Number.isSafeInteger(acceptanceContext.hapByteLength) ||
        acceptanceContext.hapByteLength <= 0))) {
    throw new Error('Final device evidence requires one exact signed-HAP/output context.');
  }
  if (frozenOutputPath !== null) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(basename(frozenOutputPath))) {
      throw new Error('Device evidence output filename is unsupported.');
    }
    const parent = await lstat(dirname(frozenOutputPath));
    if (!parent.isDirectory() || parent.isSymbolicLink()) {
      throw new Error('Device evidence output must use a real existing directory.');
    }
    canonicalOutputPath = join(await realpath(dirname(frozenOutputPath)),
      basename(frozenOutputPath));
    if (existsSync(frozenOutputPath)) {
      const output = await lstat(frozenOutputPath);
      if (!output.isFile() || output.isSymbolicLink()) {
        throw new Error('Device evidence output destination must be a regular file.');
      }
    }
    frozenOutputPath = canonicalOutputPath;
  }
  const resolvedBundleDirectory = resolve(bundleDirectory);
  const canonicalBundleDirectory = await realpath(resolvedBundleDirectory);
  if (frozenOutputPath !== null &&
    (pathWithin(resolvedBundleDirectory, requestedOutputPath) ||
      pathWithin(canonicalBundleDirectory, canonicalOutputPath))) {
    throw new Error('Device evidence output must be outside the sealed release bundle.');
  }
  const bundle = await readReleaseBundle(resolvedBundleDirectory);
  const set = bundle.releaseSet;
  if (set.driver !== driver) throw new Error('The sealed release is not for the selected driver.');
  const receiptBytes = releaseFile(dirname(receiptPath), basename(receiptPath));
  const parsed = parseReceiptEnvelope(receiptBytes);
  if (!/^[0-9a-f]{32}$/.test(parsed.payload?.runId ?? '')) {
    throw new Error('Device receipt has no valid challenge identity.');
  }
  const paths = tagOutputPaths(root, driver, set.tag);
  const preparationLockPath = plainPath(root,
    join(paths.evidence, 'device-acceptance', 'preparation.lock.json'),
    { allowMissing: true });
  const preparationLock = await acquireProcessLock(
    preparationLockPath, 'arkdb-device-preparation-lock', dependencies);
  try {
    await recoverPreparationJournals(root, paths, dependencies);
  } finally {
    await releaseProcessLock(preparationLockPath, preparationLock);
  }
  const states = statePaths(root, paths, parsed.payload.runId);
  const canonicalWorkPath = existsSync(states.work) ? await realpath(states.work) : null;
  if (frozenOutputPath !== null &&
    pathWithin(states.evidenceDirectory, canonicalOutputPath)) {
    throw new Error('Device evidence output must be outside the verifier state directory.');
  }
  if (frozenOutputPath !== null &&
    (pathWithin(states.work, requestedOutputPath) ||
      (canonicalWorkPath !== null && pathWithin(canonicalWorkPath, canonicalOutputPath)))) {
    throw new Error('Device evidence output must be outside the secret workspace.');
  }
  const caseBytes = await readFile(join(root, CASE_MANIFEST));
  const cases = readCaseManifest(caseBytes);
  await recoverWorkTombstones(states.work, dependencies);
  const acceptedExists = await atomicStateExists(states.accepted);
  const rejectedExists = await atomicStateExists(states.rejected);
  if (acceptedExists && rejectedExists) {
    throw new Error('Device challenge has conflicting terminal states.');
  }
  const terminal = acceptedExists ? states.accepted : rejectedExists ? states.rejected : null;
  if (terminal !== null) {
    const claim = await readAtomicJson(terminal);
    const expectedDecision = terminal === states.accepted ? 'accepted' : 'rejected';
    const recordPath = claim.decision === 'accepted' ? states.acceptedRecord : states.rejectedRecord;
    validateClaim(claim, receiptBytes, parsed, expectedDecision, recordPath,
      expectedDecision === 'accepted' ? frozenOutputPath : null);
    if (!await validateExistingRecord(recordPath, claim.recordSha256)) {
      throw new Error('Device terminal state has no exact verified record.');
    }
    await publishExternalRecord(claim.outputPath, claim.record, claim.recordSha256, dependencies);
    await rm(states.lock, { force: true });
    await syncDirectory(states.evidenceDirectory);
    if (expectedDecision === 'accepted' && frozenOutputPath !== null) {
      return { record: claim.record, recordPath: frozenOutputPath, statePath: terminal };
    }
    throw new Error(`Device challenge was ${claim.decision} and consumed.`);
  }
  const lockExists = await atomicStateExists(states.lock);
  let lockedClaim = null;
  if (lockExists) {
    const activeLock = await readLockJson(states.lock);
    exactKeys(activeLock, ['schemaVersion', 'kind', 'pid', 'claim'], 'Device claim lock');
    if (activeLock.schemaVersion !== 1 || activeLock.kind !== 'arkdb-device-claim-lock') {
      throw new Error('Device challenge claim lock is invalid.');
    }
    if (activeLock.claim?.receiptSha256 !== sha256(receiptBytes) ||
      activeLock.claim?.payloadSha256 !== sha256(Buffer.from(parsed.envelope.payload, 'utf8'))) {
      throw new Error('Device challenge is claimed by a different receipt.');
    }
    if (processAlive(activeLock.pid, dependencies)) {
      throw new Error('Device challenge verification is already in progress.');
    }
    lockedClaim = activeLock.claim;
  }
  const verifyingExists = await atomicStateExists(states.verifying);
  const pendingExists = await atomicStateExists(states.pending);
  let claim;
  let validationFailure = null;
  let initialClaim = false;
  let pendingHasClaim = false;
  let pendingRawWithLock = false;
  if (verifyingExists) {
    claim = await readAtomicJson(states.verifying);
  } else if (pendingExists) {
    const pending = await readAtomicJson(states.pending);
    if (pending.kind === 'arkdb-device-verification-claim') {
      claim = pending;
      pendingHasClaim = true;
    } else if (lockExists) {
      claim = null;
      pendingRawWithLock = true;
      validateChallenge(pending, set, bundle, cases, caseBytes);
    } else {
      validateChallenge(pending, set, bundle, cases, caseBytes);
      const now = dependencies.now ? dependencies.now() : new Date();
      if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
        throw new Error('Invalid device verification time.');
      }
      try {
        if (now.getTime() > Date.parse(pending.expiresAt)) throw new Error('Device challenge has expired.');
        validateReceipt(parsed.envelope, parsed.payload, pending, cases);
      } catch (error) {
        validationFailure = error;
      }
      const decision = validationFailure === null ? 'accepted' : 'rejected';
      const recordPath = decision === 'accepted' ? states.acceptedRecord : states.rejectedRecord;
      const record = decision === 'accepted'
        ? acceptedRecord(parsed, pending, receiptBytes, now, acceptanceContext)
        : rejectedRecord(parsed, pending, receiptBytes, now, validationFailure);
      claim = claimRecord(pending, receiptBytes, parsed, decision, recordPath, record,
        decision === 'accepted' ? frozenOutputPath : null);
      initialClaim = true;
    }
  } else {
    if (lockExists) {
      throw new Error('Device challenge verification is already in progress.');
    }
    throw new Error('Device challenge is not pending or recoverable.');
  }
  if (frozenOutputPath !== null && existsSync(frozenOutputPath)) {
    if (initialClaim && claim.decision === 'accepted') {
      throw new Error('Device evidence output must be unused for a fresh challenge.');
    }
    const recoverableClaim = claim ?? lockedClaim;
    if (recoverableClaim?.decision === 'accepted') {
      const validatedClaim = validateClaim(recoverableClaim, receiptBytes, parsed, 'accepted',
        states.acceptedRecord, frozenOutputPath);
      await validateExistingRecord(frozenOutputPath, validatedClaim.recordSha256);
    }
  }
  claim = await acquireClaimLock(states.lock, claim, receiptBytes, parsed, frozenOutputPath,
    dependencies);
  validateChallenge(claim.challenge, set, bundle, cases, caseBytes);
  const decision = claim.decision;
  const recordPath = decision === 'accepted' ? states.acceptedRecord : states.rejectedRecord;
  claim = validateClaim(claim, receiptBytes, parsed, decision, recordPath,
    decision === 'accepted' ? frozenOutputPath : null);
  if (!verifyingExists) {
    if (initialClaim || pendingRawWithLock) await atomicReplace(states.pending, recordBytes(claim));
    else if (!pendingHasClaim) throw new Error('Device pending recovery state is invalid.');
    await atomicRename(states.pending, states.verifying);
  }
  try {
    await durableDeleteWork(states.work, dependencies);
  } catch (cleanup) {
    throw new Error('Device challenge cleanup failed; verification remains recoverable.', { cause: cleanup });
  }
  await assertNoSecretWorkspace(states.work);
  await publishRecord(recordPath, claim.record, claim.recordSha256, dependencies);
  await publishExternalRecord(claim.outputPath, claim.record, claim.recordSha256, dependencies);
  const terminalPath = decision === 'accepted' ? states.accepted : states.rejected;
  await atomicRename(states.verifying, terminalPath);
  await rm(states.lock, { force: true });
  await syncDirectory(states.evidenceDirectory);
  if (decision === 'rejected') {
    if (validationFailure !== null) throw validationFailure;
    throw new Error(`Device receipt was rejected: ${claim.record.reason}.`);
  }
  return { record: claim.record, recordPath, statePath: terminalPath };
}

export async function verifyDeviceEvidenceArtifacts({
  root = ROOT,
  receiptPath,
  manifestPath,
  consumerPath,
  hapPath,
  profile,
  features = [],
  outPath
}, dependencies = {}) {
  if (!DEVICE_PROFILES.includes(profile) || !Array.isArray(features) ||
    new Set(features).size !== features.length ||
    JSON.stringify([...features].sort()) !== JSON.stringify(features) ||
    features.some((feature) => !DEVICE_FEATURES.includes(feature)) ||
    (profile !== 'M4' && features.length !== 0)) {
    throw new Error('Device evidence profile or product features are invalid.');
  }
  const manifestDirectory = dirname(resolve(manifestPath));
  const requestedOutputPath = resolve(outPath);
  const canonicalOutputPath = join(await realpath(dirname(requestedOutputPath)),
    basename(requestedOutputPath));
  const canonicalManifestDirectory = await realpath(manifestDirectory);
  if (pathWithin(manifestDirectory, requestedOutputPath) ||
    pathWithin(canonicalManifestDirectory, canonicalOutputPath)) {
    throw new Error('Device evidence output must be outside the sealed release bundle.');
  }
  if (dirname(resolve(consumerPath)) !== manifestDirectory) {
    throw new Error('Device manifest and consumer evidence must come from one sealed bundle.');
  }
  const bundle = await readReleaseBundle(manifestDirectory);
  const set = bundle.releaseSet;
  const stem = packageStem({ name: set.packageName, version: set.version });
  if (basename(manifestPath) !== `${stem}.manifest.json` ||
    basename(consumerPath) !== `${stem}.consumer.json`) {
    throw new Error('Device evidence files do not match the sealed package identity.');
  }
  const manifestBytes = releaseFile(manifestDirectory, basename(manifestPath));
  const consumerBytes = releaseFile(manifestDirectory, basename(consumerPath));
  if (sha256(manifestBytes) !== sha256(bundle.assets.get(`${stem}.manifest.json`)) ||
    sha256(consumerBytes) !== sha256(bundle.assets.get(`${stem}.consumer.json`))) {
    throw new Error('Device manifest or consumer evidence differs from the sealed bundle.');
  }
  const manifest = jsonBytes(manifestBytes);
  const consumer = jsonBytes(consumerBytes);
  const hapBytes = releaseFile(dirname(resolve(hapPath)), basename(hapPath), 128 * 1024 * 1024);
  const actualHapSha256 = sha256(hapBytes);
  const actualHapContentSha256 = hapSigningContentFingerprint(hapBytes);
  const receiptBytes = releaseFile(dirname(resolve(receiptPath)), basename(receiptPath));
  const parsed = parseReceiptEnvelope(receiptBytes);
  const challenge = await recoverableChallenge(root, set, parsed.payload.runId);
  if (manifest.sourceClean !== true || manifest.sourceCommit !== set.sourceCommit ||
    manifest.sha256 !== parsed.payload.harSha256 ||
    consumer.schemaVersion !== 3 || consumer.consumerProfile !== 'current' ||
    consumer.artifactSha256 !== manifest.sha256 ||
    consumer.sampleFingerprint !== parsed.payload.sampleFingerprint ||
    parsed.payload.profile !== profile ||
    JSON.stringify(parsed.payload.features) !== JSON.stringify(features) ||
    !supportedDeviceSelection(profile, features, parsed.payload.authPlugin) ||
    parsed.payload.hapSha256 !== actualHapSha256 ||
    challenge.preparedUnsignedHapContentSha256 !== actualHapContentSha256) {
    throw new Error('Receipt, sealed release, consumer evidence, or actual signed HAP identity differs.');
  }
  const preliminary = await verifyDeviceEvidence({
    root,
    driver: set.driver,
    bundleDirectory: manifestDirectory,
    receiptPath: resolve(receiptPath),
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true,
    acceptanceContext: {
      hapSha256: actualHapSha256,
      hapByteLength: hapBytes.length,
      hapContentSha256: actualHapContentSha256
    },
    outputPath: requestedOutputPath
  }, dependencies);
  return { ...preliminary, recordPath: canonicalOutputPath };
}

export function deviceEvidenceCaseManifestPath(root = ROOT) {
  return resolve(root, CASE_MANIFEST);
}

export function deviceEvidenceArguments(argv) {
  if (argv[0] === 'prepare') {
    const options = { command: 'prepare', driver: 'mysql' };
    const seen = new Set();
    for (let index = 1; index < argv.length; index++) {
      const flag = argv[index];
      if (seen.has(flag)) throw new Error('Device evidence options must not be repeated.');
      seen.add(flag);
      if (['--driver', '--bundle'].includes(flag) &&
        typeof argv[index + 1] === 'string' && argv[index + 1].length > 0) {
        options[flag === '--bundle' ? 'bundleDirectory' : 'driver'] = argv[++index];
      } else {
        throw new Error('Usage: prepare --driver mysql --bundle DIRECTORY');
      }
    }
    if (!/^[a-z][a-z0-9_-]*$/.test(options.driver) ||
      typeof options.bundleDirectory !== 'string') {
      throw new Error('An explicit registered driver and sealed bundle directory are required.');
    }
    return options;
  }
  const options = { command: 'validate', features: [] };
  const seen = new Set();
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (seen.has(flag)) throw new Error('Device evidence options must not be repeated.');
    seen.add(flag);
    if (['--receipt', '--manifest', '--consumer', '--hap', '--profile', '--features', '--out']
      .includes(flag) &&
      typeof argv[index + 1] === 'string' && argv[index + 1].length > 0) {
      const names = {
        '--receipt': 'receiptPath',
        '--manifest': 'manifestPath',
        '--consumer': 'consumerPath',
        '--hap': 'hapPath',
        '--profile': 'profile',
        '--out': 'outPath'
      };
      const value = argv[++index];
      if (flag === '--features') {
        options.features = value.split(',').map((feature) => feature.trim()).filter(Boolean).sort();
      } else {
        options[names[flag]] = value;
      }
    } else {
      throw new Error('Usage: --receipt FILE --manifest FILE --consumer FILE --hap FILE ' +
        '--profile M1|M2|M3|M4 [--features KEYS] --out FILE');
    }
  }
  if (['receiptPath', 'manifestPath', 'consumerPath', 'hapPath', 'profile', 'outPath']
    .some((name) => typeof options[name] !== 'string') ||
    !DEVICE_PROFILES.includes(options.profile) ||
    new Set(options.features).size !== options.features.length ||
    options.features.some((feature) => !DEVICE_FEATURES.includes(feature)) ||
    (options.profile !== 'M4' && options.features.length !== 0)) {
    throw new Error('Artifact validation requires explicit files, a valid profile, and product feature keys.');
  }
  return options;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const options = deviceEvidenceArguments(process.argv.slice(2));
    if (options.command === 'prepare') {
      const prepared = await prepareDeviceEvidence({
        root: ROOT, driver: options.driver, bundleDirectory: resolve(ROOT, options.bundleDirectory)
      });
      console.log(`Prepared one-time device challenge: ${prepared.challenge.challengeId}`);
      console.log(`Unsigned bound HAP: ${prepared.hapPath}`);
      console.log(`Receipt context: ${prepared.contextPath}`);
      console.log(`Schema provisioning record: ${prepared.provisioningPath}`);
      console.log('The private key source was removed. No device, server, or acceptance result was claimed.');
    } else {
      const accepted = await verifyDeviceEvidenceArtifacts({
        root: ROOT,
        receiptPath: resolve(options.receiptPath),
        manifestPath: resolve(options.manifestPath),
        consumerPath: resolve(options.consumerPath),
        hapPath: resolve(options.hapPath),
        profile: options.profile,
        features: options.features,
        outPath: resolve(options.outPath)
      });
      console.log(`Verified signed-HAP device evidence: ${accepted.recordPath}`);
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
