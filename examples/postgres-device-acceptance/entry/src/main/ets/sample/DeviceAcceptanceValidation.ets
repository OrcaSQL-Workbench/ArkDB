import { DEVICE_ACCEPTANCE_DEVICE_TYPES, DEVICE_ACCEPTANCE_MINIMUM_SDK, DEVICE_ACCEPTANCE_PROFILES,
  DEVICE_ACCEPTANCE_SUITE_ID } from './DeviceAcceptanceManifest';
import { DeviceEvidenceIdentity } from './DeviceEvidenceIdentity';

const CHALLENGE_LIFETIME_MS: number = 24 * 60 * 60 * 1000;

export class DevicePlatformInfo {
  deviceType: string = '';
  sdkApiVersion: number = 0;
  osFullName: string = '';
}

export function validBinding(binding: DeviceEvidenceIdentity): boolean {
  return binding.enabled && /^[0-9a-f]{32}$/.test(binding.challengeId) &&
    /^[0-9a-f]{64}$/.test(binding.receiptNonce) &&
    /^[0-9a-f]{64}$/.test(binding.schemaChallenge) &&
    validChallengeTime(binding.createdAt, binding.expiresAt) &&
    binding.suiteId === DEVICE_ACCEPTANCE_SUITE_ID &&
    /^[0-9a-f]{64}$/.test(binding.caseManifestSha256) &&
    /^[0-9a-f]{64}$/.test(binding.releaseSetSha256) &&
    binding.repository === 'OrcaSQL-Workbench/ArkDB' && binding.driver === 'pgsql' &&
    binding.packageName === '@arkdb/postgres' && /^[0-9]+\.[0-9]+\.[0-9]+$/.test(binding.version) &&
    /^[0-9a-f]{40}$/.test(binding.sourceCommit) &&
    /^[0-9a-f]{64}$/.test(binding.artifactSha256) &&
    Number.isSafeInteger(binding.artifactByteLength) && binding.artifactByteLength > 0 &&
    /^[0-9a-f]{64}$/.test(binding.consumerFingerprint) &&
    /^[0-9a-f]{64}$/.test(binding.acceptanceFingerprint) &&
    /^[A-Za-z0-9+/]+={0,2}$/.test(binding.publicKeySpkiBase64) &&
    /^[0-9a-f]{64}$/.test(binding.publicKeySpkiSha256) &&
    /^[A-Za-z0-9+/]+={0,2}$/.test(binding.privateKeyPkcs8Base64) &&
    binding.format === 'bytecode-har' && binding.compatibleSdkVersion === 24 &&
    binding.compatibleSdkType === 'HarmonyOS' && binding.useNormalizedOHMUrl &&
    binding.buildMode === 'release';
}

export function challengeIsActive(binding: DeviceEvidenceIdentity): boolean {
  const now = new Date().getTime();
  return now >= Date.parse(binding.createdAt) && now <= Date.parse(binding.expiresAt);
}

export function validPlatform(platform: DevicePlatformInfo): boolean {
  return DEVICE_ACCEPTANCE_DEVICE_TYPES.includes(platform.deviceType) &&
    Number.isSafeInteger(platform.sdkApiVersion) &&
    platform.sdkApiVersion >= DEVICE_ACCEPTANCE_MINIMUM_SDK &&
    safePublicLabel(platform.osFullName);
}

export function serverVersionMatchesProfile(version: string, profile: string): boolean {
  return DEVICE_ACCEPTANCE_PROFILES.includes(profile) && version.startsWith(profile.slice(1) + '.');
}

export function safePublicLabel(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9 ._()+/-]{0,127}$/.test(value);
}

function validChallengeTime(createdAt: string, expiresAt: string): boolean {
  try {
    const created = new Date(createdAt);
    const expires = new Date(expiresAt);
    return createdAt === created.toISOString() && expiresAt === expires.toISOString() &&
      expires.getTime() - created.getTime() === CHALLENGE_LIFETIME_MS;
  } catch (error) {
    return false;
  }
}
