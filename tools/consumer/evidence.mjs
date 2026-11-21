import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { listFiles, ROOT } from '../workspace/check-package.mjs';
import { driverVerification } from '../workspace/driver-packages.mjs';
import { createSha256, sha256 } from '../lib/hash.mjs';
import { jsonBytes, releaseFile } from '../lib/safe-files.mjs';

const DEVICE_POLICY_MANIFEST = 'device-evidence-policy.json';

export function exactKeys(value, names, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
    JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...names].sort())) {
    throw new Error(`${label} has an invalid property set.`);
  }
}

function safePolicyLabel(value) {
  return typeof value === 'string' &&
    /^[A-Za-z0-9][A-Za-z0-9 ._()+/-]{0,127}$/.test(value);
}

function policyStringList(value, label) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 32 ||
    value.some((entry) => !safePolicyLabel(entry)) || new Set(value).size !== value.length) {
    throw new Error(`${label} must contain unique bounded labels.`);
  }
}

export function parseDeviceEvidencePolicy(bytes, expectedDriver) {
  const policy = jsonBytes(bytes);
  exactKeys(policy, [
    'schemaVersion', 'driver', 'caseManifestFile', 'suiteId', 'serverFamilies',
    'features', 'authPlugins', 'tlsModes', 'profiles'
  ], 'Device evidence policy');
  if (![1, 2].includes(policy.schemaVersion) || policy.driver !== expectedDriver ||
    policy.caseManifestFile !== 'device-acceptance-cases.json' ||
    !/^[a-z][a-z0-9_-]*$/.test(expectedDriver) ||
    !safePolicyLabel(policy.suiteId)) {
    throw new Error('Device evidence policy differs from the registered driver.');
  }
  policyStringList(policy.serverFamilies, 'Device policy server families');
  if (!Array.isArray(policy.features) || policy.features.length > 64 ||
    policy.features.some((feature) => typeof feature !== 'string' ||
      !/^[a-z][a-z0-9-]{0,63}$/.test(feature)) ||
    new Set(policy.features).size !== policy.features.length) {
    throw new Error('Device policy features are invalid.');
  }
  policyStringList(policy.authPlugins, 'Device policy authentication plugins');
  policyStringList(policy.tlsModes, 'Device policy TLS modes');
  if (!Array.isArray(policy.profiles) || policy.profiles.length === 0 ||
    policy.profiles.length > 16 || new Set(policy.profiles.map((profile) => profile?.id)).size !==
      policy.profiles.length) {
    throw new Error('Device policy profiles are invalid.');
  }
  for (const profile of policy.profiles) {
    exactKeys(profile, [
      'id', 'features', 'authPlugins', ...(policy.schemaVersion === 2 ? ['serverVersionPrefix'] : [])
    ], 'Device policy profile');
    if (typeof profile.id !== 'string' ||
      !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/.test(profile.id) ||
      (policy.schemaVersion === 2 && (typeof profile.serverVersionPrefix !== 'string' ||
        profile.serverVersionPrefix.length > 64 ||
        !/^[A-Za-z0-9]/.test(profile.serverVersionPrefix) ||
        /[^A-Za-z0-9._+-]/.test(profile.serverVersionPrefix))) ||
      !Array.isArray(profile.features) ||
      profile.features.some((feature) => !policy.features.includes(feature)) ||
      new Set(profile.features).size !== profile.features.length ||
      JSON.stringify([...profile.features].sort()) !== JSON.stringify(profile.features) ||
      !Array.isArray(profile.authPlugins) || profile.authPlugins.length === 0 ||
      profile.authPlugins.some((plugin) => !policy.authPlugins.includes(plugin)) ||
      new Set(profile.authPlugins).size !== profile.authPlugins.length) {
      throw new Error('Device policy profile selection is invalid.');
    }
  }
  return policy;
}

export function deviceEvidencePolicyBytes(root = ROOT, driver = 'mysql') {
  const directory = driverVerification(root, driver).deviceConsumerDirectory;
  if (directory === undefined) {
    throw new Error(`Driver ${driver} has no device acceptance consumer or policy.`);
  }
  return releaseFile(directory, DEVICE_POLICY_MANIFEST, 128 * 1024);
}

export function deviceEvidencePolicySha256(root = ROOT, driver = 'mysql') {
  try {
    const bytes = deviceEvidencePolicyBytes(root, driver);
    parseDeviceEvidencePolicy(bytes, driver);
    return sha256(bytes);
  } catch (error) {
    if (driver === 'mysql' && error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

function exampleFingerprint(sample, extraRootFiles = []) {
  const files = [
    ...['README.md', 'build-profile.json5', 'hvigorfile.ts', 'oh-package.json5',
      ...extraRootFiles].map((name) => join(sample, name)),
    ...['build-profile.json5', 'hvigorfile.ts', 'oh-package.json5']
      .map((name) => join(sample, 'entry', name)),
    ...listFiles(join(sample, 'AppScope')), ...listFiles(join(sample, 'hvigor')),
    ...listFiles(join(sample, 'entry', 'src'))
  ];
  const hash = createSha256();
  for (const file of files.sort()) {
    hash.update(file.slice(sample.length).replaceAll('\\', '/'))
      .update('\0').update(readFileSync(file)).update('\0');
  }
  return hash.digest('hex');
}

export function sampleFingerprint(root = ROOT, driver = 'mysql') {
  return exampleFingerprint(driverVerification(root, driver).consumerDirectory);
}

export function deviceSampleFingerprint(root = ROOT, driver = 'mysql') {
  const sample = driverVerification(root, driver).deviceConsumerDirectory;
  if (sample === undefined) throw new Error(`Driver ${driver} has no device acceptance consumer.`);
  return exampleFingerprint(sample, ['device-acceptance-cases.json']);
}
