import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { listFiles, ROOT } from '../workspace/check-package.mjs';
import { driverVerification } from '../workspace/driver-packages.mjs';
import { createSha256 } from '../lib/hash.mjs';

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
