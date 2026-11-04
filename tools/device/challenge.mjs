import {
  createPrivateKey, createPublicKey, generateKeyPairSync,
  randomBytes as systemRandomBytes, sign as signBytes, verify as verifySignature
} from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { sourceFingerprint } from '../artifact/source-identity.mjs';
import { ROOT } from '../workspace/check-package.mjs';
import { deviceSampleFingerprint, sampleFingerprint } from '../consumer/evidence.mjs';
import { driverVerification, packageStem, tagOutputPaths } from '../workspace/driver-packages.mjs';
import { hapSigningContentFingerprint } from '../artifact/hap-content.mjs';
import { sha256 } from '../lib/hash.mjs';
import { plainPath, releaseFile } from '../lib/safe-files.mjs';
import { readReleaseBundle } from '../release/bundle.mjs';
import { gitReader } from '../release/contracts.mjs';
import {
  acquireProcessLock, atomicRename, atomicStateExists, atomicWriteNew,
  durableDeleteWork, readAtomicJson, recoverAtomicState, recoverWorkTombstones,
  releaseProcessLock, syncDirectory, syncPreparedFile
} from './atomic-store.mjs';
import {
  CASE_MANIFEST, CHALLENGE_LIFETIME_MS, exactKeys, randomHex, readCaseManifest,
  recordBytes
} from './contracts.mjs';
import { secureSecretDirectory } from './hap-signature.mjs';
import { buildDeviceHarness, renderDeviceEvidenceBinding } from './harness.mjs';

const PREPARATION_JOURNAL = /^([0-9a-f]{32})\.prepare\.json$/;

export async function recoverPreparationJournals(root, paths, dependencies) {
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
        throw new Error(
          'Published device challenge has no secret workspace to complete verification.');
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

function signingKeyPair(dependencies) {
  if (dependencies.generateSigningKeyPair) return dependencies.generateSigningKeyPair();
  const pair = generateKeyPairSync('ed25519');
  return {
    publicKeySpki: Buffer.from(pair.publicKey.export({ format: 'der', type: 'spki' })),
    privateKeyPkcs8: Buffer.from(pair.privateKey.export({ format: 'der', type: 'pkcs8' }))
  };
}

function assertCleanReleaseSource(root, driver, set, acceptanceFingerprint, git) {
  if (git(['status', '--porcelain', '--untracked-files=all']).trim() !== '' ||
    git(['rev-parse', '--verify', 'HEAD']).trim() !== set.sourceCommit ||
    sourceFingerprint(root, driver) !== set.sourceFingerprint ||
    sampleFingerprint(root, driver) !== set.verification.sampleFingerprint ||
    deviceSampleFingerprint(root, driver) !== acceptanceFingerprint) {
    throw new Error(
      'Device harness preparation requires the exact clean sealed-release source and consumers.');
  }
}

export async function prepareDeviceEvidence({
  root = ROOT, driver = 'mysql', bundleDirectory
}, dependencies = {}) {
  const bundle = await readReleaseBundle(bundleDirectory);
  const set = bundle.releaseSet;
  if (set.driver !== driver) throw new Error('The sealed release is not for the selected driver.');
  const git = dependencies.git ?? gitReader(root);
  const acceptanceFingerprint = deviceSampleFingerprint(root, driver);
  assertCleanReleaseSource(root, driver, set, acceptanceFingerprint, git);
  const stem = packageStem({ name: set.packageName, version: set.version });
  const artifact = set.assets.find((entry) => entry.name === `${stem}.har`);
  const artifactBytes = bundle.assets.get(`${stem}.har`);
  if (!artifact || !artifactBytes) {
    throw new Error('The sealed release has no selected driver HAR identity.');
  }
  const paths = tagOutputPaths(root, driver, set.tag);
  const evidenceDirectory = plainPath(root,
    join(paths.evidence, 'device-acceptance'), { allowMissing: true });
  await mkdir(evidenceDirectory, { recursive: true });
  plainPath(root, evidenceDirectory);
  const workParent = plainPath(root,
    join(paths.workspaces, 'device-acceptance'), { allowMissing: true });
  await mkdir(workParent, { recursive: true });
  plainPath(root, workParent);
  const caseBytes = await readFile(join(root, CASE_MANIFEST));
  const cases = readCaseManifest(caseBytes);
  const now = dependencies.now ? dependencies.now() : new Date();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
    throw new Error('Invalid device challenge time.');
  }
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
  const generatedPublicKey =
    createPublicKey({ key: keys.publicKeySpki, format: 'der', type: 'spki' });
  const generatedPrivateKey =
    createPrivateKey({ key: keys.privateKeyPkcs8, format: 'der', type: 'pkcs8' });
  const keyProbe = Buffer.from(`arkdb-device-key:${challengeId}`, 'utf8');
  if (generatedPublicKey.asymmetricKeyType !== 'ed25519' ||
    generatedPrivateKey.asymmetricKeyType !== 'ed25519' ||
    !verifySignature(null, keyProbe, generatedPublicKey,
      signBytes(null, keyProbe, generatedPrivateKey))) {
    throw new Error('The one-time signing key pair is not a valid Ed25519 identity.');
  }
  const publicKeySpkiBase64 = keys.publicKeySpki.toString('base64');
  const publicKeySpkiSha256 = sha256(keys.publicKeySpki);
  const binding = {
    challengeId, receiptNonce, schemaChallenge, createdAt, expiresAt,
    repository: set.repository, driver: set.driver, packageName: set.packageName,
    version: set.version, sourceCommit: set.sourceCommit,
    artifactSha256: artifact.sha256, artifactByteLength: artifact.byteLength,
    consumerFingerprint: set.verification.sampleFingerprint,
    acceptanceFingerprint,
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
    const stagingDirectory = plainPath(root,
      join(workParent, `.staging-${challengeId}`), { allowMissing: true });
    const workDirectory = plainPath(root,
      join(workParent, challengeId), { allowMissing: true });
    const pendingPath = plainPath(root,
      join(evidenceDirectory, `${challengeId}.pending.json`), { allowMissing: true });
    const preparationPath = plainPath(root,
      join(evidenceDirectory, `${challengeId}.prepare.json`), { allowMissing: true });
    if (existsSync(stagingDirectory) || existsSync(workDirectory) ||
      existsSync(pendingPath) || existsSync(preparationPath)) {
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
      await mkdir(stagingDirectory, { mode: 0o700 });
      await secureSecretDirectory(stagingDirectory);
      const sampleDirectory = join(stagingDirectory, 'sample');
      const hapPath = join(stagingDirectory, 'entry-default-unsigned.hap');
      const buildHarness = dependencies.buildHarness ?? buildDeviceHarness;
      await buildHarness({
        root, driver, sampleDirectory, artifactBytes,
        bindingSource: renderDeviceEvidenceBinding(binding), hapPath
      }, {
        ...dependencies,
        sampleSource: driverVerification(root, driver).deviceConsumerDirectory
      });
      const hapBytes =
        releaseFile(stagingDirectory, basename(hapPath), 128 * 1024 * 1024);
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
        schemaVersion: 2,
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
        consumerFingerprint: set.verification.sampleFingerprint,
        acceptanceFingerprint,
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
      assertCleanReleaseSource(root, driver, set, acceptanceFingerprint, git);
      const currentBundle = await readReleaseBundle(bundleDirectory);
      if (sha256(currentBundle.releaseSetBytes) !== challenge.releaseSetSha256) {
        throw new Error('The sealed release changed while the device harness was built.');
      }
      for (const file of [hapPath, provisioningPath, contextPath]) {
        await syncPreparedFile(file, dependencies);
      }
      await syncDirectory(stagingDirectory);
      await atomicRename(stagingDirectory, workDirectory);
      if (dependencies.beforePending) {
        await dependencies.beforePending({ challenge, workDirectory });
      }
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
