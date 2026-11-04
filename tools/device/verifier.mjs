import { existsSync } from 'node:fs';
import { lstat, readFile, realpath, rm } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { ROOT } from '../workspace/check-package.mjs';
import { sampleFingerprint } from '../consumer/evidence.mjs';
import { packageStem, tagOutputPaths } from '../workspace/driver-packages.mjs';
import { hapSigningContentFingerprint } from '../artifact/hap-content.mjs';
import { sha256 } from '../lib/hash.mjs';
import { jsonBytes, plainPath, releaseFile } from '../lib/safe-files.mjs';
import { readReleaseBundle } from '../release/bundle.mjs';
import {
  acquireProcessLock, assertNoSecretWorkspace, atomicRename, atomicReplace,
  atomicStateExists, atomicWriteNew, durableDeleteWork, processAlive, readAtomicJson,
  readBoundedRegularBytes, readLockJson, recoverAtomicState, recoverWorkTombstones,
  releaseProcessLock, replaceStaleLock, syncDirectory
} from './atomic-store.mjs';
import {
  acceptedRecord, CASE_MANIFEST, claimRecord,
  DEVICE_FEATURES, DEVICE_PROFILES, exactKeys, parseReceiptEnvelope, pathWithin,
  pathWithinDeviceVerifierStorage, readCaseManifest, recordBytes,
  rejectedRecord, supportedDeviceSelection, validateChallenge, validateClaim,
  validateReceipt, verifyEnvelopeSignature
} from './contracts.mjs';
import { recoverPreparationJournals } from './challenge.mjs';
import { verifyHapPackageSignature } from './hap-signature.mjs';

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

async function readChallengeWithoutRecovery(states, challengeId) {
  for (let attempt = 0; attempt < 3; attempt++) {
    let observed = null;
    for (const path of [
      states.pending, states.verifying, states.accepted, states.rejected, states.lock
    ]) {
      if (!existsSync(path)) continue;
      let value;
      try {
        value = jsonBytes(await readBoundedRegularBytes(path, 'Device challenge state'));
      } catch (error) {
        if (error?.code === 'ENOENT') continue;
        throw error;
      }
      const challenge = value.kind === 'arkdb-device-evidence-challenge'
        ? value
        : value.kind === 'arkdb-device-claim-lock'
          ? value.claim?.challenge
          : value.challenge;
      if (!challenge || challenge.challengeId !== challengeId) {
        throw new Error('Device challenge state does not match the requested identity.');
      }
      if (observed !== null && JSON.stringify(observed) !== JSON.stringify(challenge)) {
        throw new Error('Device challenge has conflicting unrecovered states.');
      }
      observed = challenge;
    }
    if (observed !== null) return observed;
  }
  throw new Error('Device challenge is not pending or recoverable.');
}

async function recoverableChallenge(root, set, challengeId) {
  const states = statePaths(root, tagOutputPaths(root, set.driver, set.tag), challengeId);
  return await readChallengeWithoutRecovery(states, challengeId);
}

async function acquireClaimLock(path, candidateClaim, receiptBytes, parsed, dependencies) {
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
      decision === 'accepted' ? existing.claim?.outputPath : null);
    if (candidateClaim !== null &&
      (candidateClaim.receiptSha256 !== storedClaim.receiptSha256 ||
        candidateClaim.payloadSha256 !== storedClaim.payloadSha256 ||
        candidateClaim.decision !== storedClaim.decision ||
        candidateClaim.recordName !== storedClaim.recordName ||
        candidateClaim.recordSha256 !== storedClaim.recordSha256 ||
        JSON.stringify(candidateClaim.challenge) !== JSON.stringify(storedClaim.challenge))) {
      throw new Error('Device challenge is claimed by a different receipt.');
    }
    if (processAlive(existing.pid, dependencies)) {
      throw new Error('Device challenge verification is already in progress.');
    }
    const selectedClaim = storedClaim;
    const replacement = recordBytes({
      schemaVersion: 1,
      kind: 'arkdb-device-claim-lock',
      pid: process.pid,
      claim: selectedClaim
    });
    if (await replaceStaleLock(path, existingBytes, replacement, dependencies)) return selectedClaim;
  }
  throw new Error('Device challenge claim lock changed during recovery.');
}

async function releaseClaimLock(path, claim) {
  if (!existsSync(path)) return;
  const lock = await readLockJson(path);
  if (lock.pid !== process.pid || JSON.stringify(lock.claim) !== JSON.stringify(claim)) return;
  await rm(path);
  await syncDirectory(dirname(path));
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

async function verifyBoundDeviceEvidence({
  root = ROOT,
  driver = 'mysql',
  bundleDirectory,
  receiptPath,
  receiptSnapshot = null,
  confirmPhysicalDevice = false,
  confirmAuthorizedSchema = false,
  acceptanceContext = null,
  outputPath = null
}, dependencies = {}) {
  if (acceptanceContext === null &&
    (confirmPhysicalDevice !== true || confirmAuthorizedSchema !== true)) {
    throw new Error('Device evidence requires explicit physical-device and authorized-schema operator attestations.');
  }
  const requestedOutputPath = outputPath === null ? null : resolve(outputPath);
  let frozenOutputPath = requestedOutputPath;
  let canonicalOutputPath = null;
  if ((acceptanceContext === null) !== (frozenOutputPath === null) ||
    (acceptanceContext !== null &&
      (!/^[0-9a-f]{64}$/.test(acceptanceContext.hapSha256 ?? '') ||
        !/^[0-9a-f]{64}$/.test(acceptanceContext.hapContentSha256 ?? '') ||
        !/^[0-9a-f]{64}$/.test(acceptanceContext.hapSigningCertificateSha256 ?? '') ||
        !/^[0-9a-f]{64}$/.test(acceptanceContext.hapSigningProfileSha256 ?? '') ||
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
  if (receiptSnapshot !== null &&
    (!Buffer.isBuffer(receiptSnapshot) || receiptSnapshot.length === 0 ||
      receiptSnapshot.length > 2 * 1024 * 1024)) {
    throw new Error('Device receipt snapshot is invalid.');
  }
  const receiptBytes = receiptSnapshot === null
    ? releaseFile(dirname(receiptPath), basename(receiptPath))
    : Buffer.from(receiptSnapshot);
  const parsed = parseReceiptEnvelope(receiptBytes);
  if (!/^[0-9a-f]{32}$/.test(parsed.payload?.runId ?? '')) {
    throw new Error('Device receipt has no valid challenge identity.');
  }
  const paths = tagOutputPaths(root, driver, set.tag);
  const states = statePaths(root, paths, parsed.payload.runId);
  const caseBytes = await readFile(join(root, CASE_MANIFEST));
  const cases = readCaseManifest(caseBytes);
  const observedChallenge = await readChallengeWithoutRecovery(states, parsed.payload.runId);
  validateChallenge(observedChallenge, set, bundle, cases, caseBytes, root);
  verifyEnvelopeSignature(parsed, observedChallenge.publicKeySpkiBase64);
  const buildRoot = join(root, 'build');
  const canonicalBuildRoot = await realpath(buildRoot);
  if (frozenOutputPath !== null &&
    pathWithin(states.evidenceDirectory, canonicalOutputPath)) {
    throw new Error('Device evidence output must be outside the verifier state directory.');
  }
  if (frozenOutputPath !== null &&
    (pathWithinDeviceVerifierStorage(buildRoot, requestedOutputPath) ||
      pathWithinDeviceVerifierStorage(canonicalBuildRoot, canonicalOutputPath))) {
    throw new Error('Device evidence output must be outside every verifier workspace and state directory.');
  }
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
      validateChallenge(pending, set, bundle, cases, caseBytes, root);
    } else {
      validateChallenge(pending, set, bundle, cases, caseBytes, root);
      const now = dependencies.now ? dependencies.now() : new Date();
      if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
        throw new Error('Invalid device verification time.');
      }
      try {
        if (now.getTime() > Date.parse(pending.expiresAt)) throw new Error('Device challenge has expired.');
        validateReceipt(parsed.envelope, parsed.payload, pending, cases, now);
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
  const recoverableClaim = claim ?? lockedClaim;
  if (recoverableClaim?.decision === 'accepted') {
    const storedArtifactMode = recoverableClaim.record?.kind === 'arkdb-device-acceptance';
    const storedReceiptMode =
      recoverableClaim.record?.kind === 'arkdb-device-receipt-verification';
    if ((!storedArtifactMode && !storedReceiptMode) ||
      storedArtifactMode !== (acceptanceContext !== null)) {
      throw new Error('Device verification mode cannot change during recovery.');
    }
  }
  if (frozenOutputPath !== null && existsSync(frozenOutputPath)) {
    if (initialClaim && claim.decision === 'accepted') {
      throw new Error('Device evidence output must be unused for a fresh challenge.');
    }
    if (recoverableClaim?.decision === 'accepted') {
      const validatedClaim = validateClaim(recoverableClaim, receiptBytes, parsed, 'accepted',
        states.acceptedRecord, recoverableClaim.outputPath);
      await validateExistingRecord(frozenOutputPath, validatedClaim.recordSha256);
    }
  }
  if (dependencies.beforeClaimLock) {
    await dependencies.beforeClaimLock({ path: states.lock, claim });
  }
  claim = await acquireClaimLock(states.lock, claim, receiptBytes, parsed, dependencies);
  const acceptedAfterLock = await atomicStateExists(states.accepted);
  const rejectedAfterLock = await atomicStateExists(states.rejected);
  if (acceptedAfterLock || rejectedAfterLock) {
    await releaseClaimLock(states.lock, claim);
    if (acceptedAfterLock && rejectedAfterLock) {
      throw new Error('Device challenge has conflicting terminal states.');
    }
    throw new Error(`Device challenge was ${acceptedAfterLock ? 'accepted' : 'rejected'} and consumed.`);
  }
  const sourceState = verifyingExists ? states.verifying : states.pending;
  if (!await atomicStateExists(sourceState)) {
    await releaseClaimLock(states.lock, claim);
    throw new Error('Device challenge state changed before claim-lock acquisition.');
  }
  validateChallenge(claim.challenge, set, bundle, cases, caseBytes, root);
  const decision = claim.decision;
  const recordPath = decision === 'accepted' ? states.acceptedRecord : states.rejectedRecord;
  claim = validateClaim(claim, receiptBytes, parsed, decision, recordPath,
    decision === 'accepted' ? claim.outputPath : null);
  if (decision === 'accepted' && claim.outputPath !== frozenOutputPath) {
    if (claim.outputPath === null || frozenOutputPath === null) {
      throw new Error('Device verification mode cannot change during recovery.');
    }
    if (await validateExistingRecord(claim.outputPath, claim.recordSha256)) {
      throw new Error('Published device evidence cannot be retargeted.');
    }
    claim = { ...claim, outputPath: frozenOutputPath };
    await atomicReplace(states.lock, recordBytes({
      schemaVersion: 1,
      kind: 'arkdb-device-claim-lock',
      pid: process.pid,
      claim
    }));
  }
  claim = validateClaim(claim, receiptBytes, parsed, decision, recordPath,
    decision === 'accepted' ? frozenOutputPath : null);
  if (verifyingExists) {
    await atomicReplace(states.verifying, recordBytes(claim));
  } else {
    if (!initialClaim && !pendingRawWithLock && !pendingHasClaim) {
      throw new Error('Device pending recovery state is invalid.');
    }
    await atomicReplace(states.pending, recordBytes(claim));
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

export async function verifyDeviceEvidence(options, dependencies = {}) {
  if (options?.acceptanceContext != null || options?.outputPath != null ||
    options?.receiptSnapshot != null) {
    throw new Error('Signed-HAP acceptance requires the artifact verification entry point.');
  }
  return await verifyBoundDeviceEvidence({
    ...options,
    receiptSnapshot: null,
    acceptanceContext: null,
    outputPath: null
  }, dependencies);
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
  verifyEnvelopeSignature(parsed, challenge.publicKeySpkiBase64);
  const receiptConsumerFingerprint = parsed.payload.schemaVersion === 1
    ? parsed.payload.sampleFingerprint
    : parsed.payload.schemaVersion === 2
      ? parsed.payload.consumerFingerprint
      : undefined;
  if (manifest.sourceClean !== true || manifest.sourceCommit !== set.sourceCommit ||
    manifest.sha256 !== parsed.payload.harSha256 ||
    consumer.schemaVersion !== 3 || consumer.consumerProfile !== 'current' ||
    consumer.artifactSha256 !== manifest.sha256 ||
    consumer.sampleFingerprint !== receiptConsumerFingerprint ||
    parsed.payload.profile !== profile ||
    JSON.stringify(parsed.payload.features) !== JSON.stringify(features) ||
    !supportedDeviceSelection(profile, features, parsed.payload.authPlugin) ||
    parsed.payload.hapSha256 !== actualHapSha256 ||
    challenge.preparedUnsignedHapContentSha256 !== actualHapContentSha256) {
    throw new Error('Receipt, sealed release, consumer evidence, or actual signed HAP identity differs.');
  }
  const hapSignature = await verifyHapPackageSignature(hapBytes, dependencies);
  const preliminary = await verifyBoundDeviceEvidence({
    root,
    driver: set.driver,
    bundleDirectory: manifestDirectory,
    receiptPath: resolve(receiptPath),
    receiptSnapshot: receiptBytes,
    acceptanceContext: {
      hapSha256: actualHapSha256,
      hapByteLength: hapBytes.length,
      hapContentSha256: actualHapContentSha256,
      hapSigningCertificateSha256: hapSignature.certificateSha256,
      hapSigningProfileSha256: hapSignature.profileSha256
    },
    outputPath: requestedOutputPath
  }, dependencies);
  return { ...preliminary, recordPath: canonicalOutputPath };
}
