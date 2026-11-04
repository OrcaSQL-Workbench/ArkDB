import { resolve } from 'node:path';
import { ROOT } from '../workspace/check-package.mjs';
import { prepareDeviceEvidence } from './challenge.mjs';
import { CASE_MANIFEST, DEVICE_FEATURES, DEVICE_PROFILES } from './contracts.mjs';
import { verifyDeviceEvidenceArtifacts } from './verifier.mjs';

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

export async function runDeviceEvidenceCli(argv = process.argv.slice(2)) {
  const options = deviceEvidenceArguments(argv);
  if (options.command === 'prepare') {
    const prepared = await prepareDeviceEvidence({
      root: ROOT, driver: options.driver, bundleDirectory: resolve(ROOT, options.bundleDirectory)
    });
    console.log(`Prepared one-time device challenge: ${prepared.challenge.challengeId}`);
    console.log(`Unsigned bound HAP: ${prepared.hapPath}`);
    console.log(`Receipt context: ${prepared.contextPath}`);
    console.log(`Schema provisioning record: ${prepared.provisioningPath}`);
    console.log('The private key source was removed. No device, server, or acceptance result was claimed.');
    return;
  }
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
