import { createPublicKey, verify as verifySignature } from 'node:crypto';
import { basename, isAbsolute, relative, resolve, sep } from 'node:path';
import { deviceSampleFingerprint } from '../consumer/evidence.mjs';
import { packageStem } from '../workspace/driver-packages.mjs';
import { sha256 } from '../lib/hash.mjs';
import { jsonBytes } from '../lib/safe-files.mjs';

export const CASE_MANIFEST =
  'examples/mysql-device-acceptance/device-acceptance-cases.json';
export const CHALLENGE_LIFETIME_MS = 24 * 60 * 60 * 1000;
export const DEVICE_PROFILES = ['M1', 'M2', 'M3', 'M4'];
export const DEVICE_FEATURES = [
  'multi-statements', 'procedures', 'text-parameters', 'sha256', 'compression',
  'local-infile', 'failover', 'worker', 'session-observations', 'routing'
];
const DEVICE_AUTH_PLUGINS = ['mysql_native_password', 'caching_sha2_password'];
const CANONICAL_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const BASE64 =
  /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export function exactKeys(value, names, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
    JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...names].sort())) {
    throw new Error(`${label} has an invalid property set.`);
  }
}

export function readCaseManifest(bytes) {
  const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  exactKeys(value, ['schemaVersion', 'suiteId', 'caseIds', 'runtime'],
    'Device acceptance case manifest');
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

export function randomHex(bytes, size, label) {
  const value = bytes(size);
  if (!Buffer.isBuffer(value) || value.length !== size) {
    throw new Error(`Could not generate the ${label}.`);
  }
  return value.toString('hex');
}

function canonicalTime(value) {
  return typeof value === 'string' && CANONICAL_TIME.test(value) &&
    new Date(value).toISOString() === value;
}

function comparisonPath(value) {
  const path = resolve(value);
  return process.platform === 'win32' ? path.toLowerCase() : path;
}

export function pathWithin(parent, candidate) {
  const path = relative(comparisonPath(parent), comparisonPath(candidate));
  return path === '' || (!isAbsolute(path) && path !== '..' && !path.startsWith(`..${sep}`));
}

export function pathWithinDeviceVerifierStorage(buildRoot, candidate) {
  const path = relative(comparisonPath(buildRoot), comparisonPath(candidate));
  if (path === '' || isAbsolute(path) || path === '..' || path.startsWith(`..${sep}`)) {
    return false;
  }
  const parts = path.split(sep);
  return parts.length >= 3 &&
    (parts[1] === 'work' || parts[1] === 'evidence') &&
    parts[2] === 'device-acceptance';
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

function safePublicLabel(value) {
  return typeof value === 'string' &&
    /^[A-Za-z0-9][A-Za-z0-9 ._()+/-]{0,127}$/.test(value);
}

export function supportedDeviceSelection(profile, features, authPlugin) {
  if (['M1', 'M2', 'M3'].includes(profile)) return features.length === 0;
  return profile === 'M4' && features.length === 1 && features[0] === 'sha256' &&
    (authPlugin === undefined || authPlugin === 'caching_sha2_password');
}

export function validateChallenge(challenge, set, bundle, cases, caseBytes, root) {
  const stem = packageStem({ name: set.packageName, version: set.version });
  const artifact = set.assets.find((entry) => entry.name === `${stem}.har`);
  const fingerprintKeys = challenge.schemaVersion === 1
    ? ['sampleFingerprint']
    : challenge.schemaVersion === 2
      ? ['consumerFingerprint', 'acceptanceFingerprint']
      : [];
  exactKeys(challenge, [
    'schemaVersion', 'kind', 'state', 'repository', 'driver', 'packageName', 'version', 'tag',
    'sourceCommit', 'artifactSha256', 'artifactByteLength', ...fingerprintKeys,
    'releaseSetSha256', 'suiteId', 'caseManifestSha256', 'caseIds', 'runtime', 'platform',
    'challengeId', 'receiptNonce', 'schemaChallenge', 'createdAt', 'expiresAt',
    'publicKeySpkiBase64', 'publicKeySpkiSha256', 'preparedUnsignedHapSha256',
    'preparedUnsignedHapByteLength', 'preparedUnsignedHapContentSha256'
  ], 'Device evidence challenge');
  const publicKey = strictBase64(challenge.publicKeySpkiBase64,
    'Device challenge public key', 1024);
  const fingerprintsMatch = challenge.schemaVersion === 1
    ? challenge.sampleFingerprint === set.verification.sampleFingerprint
    : challenge.schemaVersion === 2 &&
      challenge.consumerFingerprint === set.verification.sampleFingerprint &&
      challenge.acceptanceFingerprint === deviceSampleFingerprint(root, set.driver);
  if (![1, 2].includes(challenge.schemaVersion) ||
    challenge.kind !== 'arkdb-device-evidence-challenge' ||
    challenge.state !== 'issued' || challenge.repository !== set.repository ||
    challenge.driver !== set.driver || challenge.packageName !== set.packageName ||
    challenge.version !== set.version || challenge.tag !== set.tag ||
    challenge.sourceCommit !== set.sourceCommit || challenge.artifactSha256 !== artifact?.sha256 ||
    challenge.artifactByteLength !== artifact?.byteLength ||
    !fingerprintsMatch ||
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
    Date.parse(challenge.expiresAt) - Date.parse(challenge.createdAt) !==
      CHALLENGE_LIFETIME_MS ||
    challenge.publicKeySpkiSha256 !== sha256(publicKey) ||
    !/^[0-9a-f]{64}$/.test(challenge.preparedUnsignedHapSha256 ?? '') ||
    !Number.isSafeInteger(challenge.preparedUnsignedHapByteLength) ||
    challenge.preparedUnsignedHapByteLength <= 0 ||
    !/^[0-9a-f]{64}$/.test(challenge.preparedUnsignedHapContentSha256 ?? '')) {
    throw new Error('Device evidence challenge differs from its sealed release binding.');
  }
}

export function parseReceiptEnvelope(bytes) {
  const envelope = jsonBytes(bytes);
  exactKeys(envelope, ['schemaVersion', 'kind', 'payload', 'signature'],
    'Device receipt envelope');
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

export function verifyEnvelopeSignature(parsed, expectedPublicKeySpkiBase64) {
  const { envelope } = parsed;
  const publicKeyBytes = strictBase64(envelope.signature.publicKeySpkiBase64,
    'Device receipt public key', 1024);
  const signature = strictBase64(envelope.signature.valueBase64,
    'Device receipt signature', 1024);
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

export function validateReceipt(envelope, receipt, challenge, cases, now) {
  const parsed = verifyEnvelopeSignature({ envelope, payload: receipt },
    challenge.publicKeySpkiBase64);
  const publicKeyBytes = Buffer.from(parsed.envelope.signature.publicKeySpkiBase64, 'base64');
  if (sha256(publicKeyBytes) !== challenge.publicKeySpkiSha256) {
    throw new Error('Device receipt signing identity differs from the prepared harness.');
  }
  const fingerprintKeys = receipt.schemaVersion === 1
    ? ['sampleFingerprint']
    : receipt.schemaVersion === 2
      ? ['consumerFingerprint', 'acceptanceFingerprint']
      : [];
  exactKeys(receipt, [
    'schemaVersion', 'profile', 'features', 'runId', 'sourceCommit', 'sourceClean',
    'harSha256', ...fingerprintKeys, 'hapSha256', 'apiVersion', 'deviceClass',
    'serverVersion', 'tlsMode', 'authPlugin', 'challengeIssuedAt', 'challengeExpiresAt',
    'startedAt', 'completedAt', 'operatorEvidenceId', 'cases'
  ], 'Device acceptance receipt');
  const fingerprintsMatch = receipt.schemaVersion === 1
    ? challenge.schemaVersion === 1 &&
      receipt.sampleFingerprint === challenge.sampleFingerprint
    : receipt.schemaVersion === 2 && challenge.schemaVersion === 2 &&
      receipt.consumerFingerprint === challenge.consumerFingerprint &&
      receipt.acceptanceFingerprint === challenge.acceptanceFingerprint;
  if (![1, 2].includes(receipt.schemaVersion) || !fingerprintsMatch ||
    !DEVICE_PROFILES.includes(receipt.profile) ||
    !Array.isArray(receipt.features) ||
    receipt.features.some((feature) => !DEVICE_FEATURES.includes(feature)) ||
    new Set(receipt.features).size !== receipt.features.length ||
    JSON.stringify([...receipt.features].sort()) !== JSON.stringify(receipt.features) ||
    !supportedDeviceSelection(receipt.profile, receipt.features, receipt.authPlugin) ||
    receipt.runId !== challenge.challengeId ||
    receipt.sourceCommit !== challenge.sourceCommit || receipt.sourceClean !== true ||
    receipt.harSha256 !== challenge.artifactSha256 ||
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
  if (Date.parse(receipt.completedAt) > now.getTime()) {
    throw new Error('Device receipt completion time is in the future.');
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
      throw new Error(
        'Device acceptance requires every mandatory case to pass with no failures or ignored cases.');
    }
  }
  if (receipt.cases.length === 0) {
    throw new Error(
      'Device acceptance requires every mandatory case to pass with no failures, errors, or ignored cases.');
  }
}

export function recordBytes(record) {
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

export function acceptedRecord(parsed, challenge, receiptBytes, now, acceptanceContext = null) {
  const fingerprints = challenge.schemaVersion === 1
    ? { sampleFingerprint: parsed.payload.sampleFingerprint }
    : {
        consumerFingerprint: parsed.payload.consumerFingerprint,
        acceptanceFingerprint: parsed.payload.acceptanceFingerprint
      };
  const record = {
    schemaVersion: challenge.schemaVersion,
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
    ...fingerprints,
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
    hapSigningCertificateSha256: acceptanceContext.hapSigningCertificateSha256,
    hapSigningProfileSha256: acceptanceContext.hapSigningProfileSha256,
    signedHapVerified: true,
    liveNetworkingVerified: true,
    operatorEvidenceBound: true,
    physicalDeviceAttestedByOperator: false,
    authorizedSchemaAttestedByOperator: false,
    operatorAttestationTrustBoundary:
      'Receipt, verified signed-HAP bytes, signing certificate/profile digests, and operator ' +
      'evidence ID are bound; no direct physical-device or schema attestation is inferred.'
  };
}

export function rejectedRecord(parsed, challenge, receiptBytes, now, error) {
  const fingerprints = challenge.schemaVersion === 2
    ? {
        consumerFingerprint: challenge.consumerFingerprint,
        acceptanceFingerprint: challenge.acceptanceFingerprint
      }
    : {};
  return {
    schemaVersion: challenge.schemaVersion,
    kind: 'arkdb-device-rejection',
    rejectedAt: now.toISOString(),
    challengeId: challenge.challengeId,
    receiptSha256: sha256(receiptBytes),
    payloadSha256: sha256(Buffer.from(parsed.envelope.payload, 'utf8')),
    ...fingerprints,
    reason: rejectionCode(error)
  };
}

export function claimRecord(challenge, receiptBytes, parsed, decision, recordPath, record, outputPath) {
  const bytes = recordBytes(record);
  return {
    schemaVersion: challenge.schemaVersion,
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

function validateClaimFingerprints(claim) {
  const challenge = claim.challenge;
  const record = claim.record;
  if (challenge?.schemaVersion === 1) {
    if (claim.schemaVersion !== 1 || record?.schemaVersion !== 1) return false;
    return record.kind === 'arkdb-device-rejection' ||
      record.sampleFingerprint === challenge.sampleFingerprint;
  }
  return challenge?.schemaVersion === 2 && claim.schemaVersion === 2 &&
    record?.schemaVersion === 2 &&
    record.consumerFingerprint === challenge.consumerFingerprint &&
    record.acceptanceFingerprint === challenge.acceptanceFingerprint;
}

export function validateClaim(claim, receiptBytes, parsed, decision, recordPath, outputPath) {
  exactKeys(claim, [
    'schemaVersion', 'kind', 'challenge', 'receiptSha256', 'payloadSha256',
    'decision', 'recordName', 'recordSha256', 'outputPath', 'record'
  ], 'Device verification claim');
  const artifactClaim = decision === 'accepted' &&
    claim.record?.kind === 'arkdb-device-acceptance' &&
    typeof claim.outputPath === 'string' && isAbsolute(claim.outputPath);
  const receiptClaim = decision === 'accepted' &&
    claim.record?.kind === 'arkdb-device-receipt-verification' && claim.outputPath === null;
  const rejectionClaim = decision === 'rejected' &&
    claim.record?.kind === 'arkdb-device-rejection' && claim.outputPath === null;
  if (![1, 2].includes(claim.schemaVersion) ||
    claim.kind !== 'arkdb-device-verification-claim' ||
    !validateClaimFingerprints(claim) ||
    claim.receiptSha256 !== sha256(receiptBytes) ||
    claim.payloadSha256 !== sha256(Buffer.from(parsed.envelope.payload, 'utf8')) ||
    claim.decision !== decision || claim.recordName !== basename(recordPath) ||
    claim.recordSha256 !== sha256(recordBytes(claim.record)) ||
    (decision === 'accepted' ? !artifactClaim && !receiptClaim : !rejectionClaim) ||
    claim.outputPath !== outputPath) {
    throw new Error('Device verification recovery belongs to a different receipt or decision.');
  }
  return claim;
}
