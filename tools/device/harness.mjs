import { copyFile, cp, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { sha256 } from '../lib/hash.mjs';
import { runHvigor, runOhpm } from '../workspace/run-hvigor.mjs';

function stringLiteral(value) {
  return JSON.stringify(value);
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
  binding.consumerFingerprint = ${stringLiteral(binding.consumerFingerprint)};
  binding.acceptanceFingerprint = ${stringLiteral(binding.acceptanceFingerprint)};
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

export async function buildDeviceHarness({
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
  const restored = (dependencies.runOhpm ?? runOhpm)(['install', '--all'],
    { cwd: sampleDirectory });
  if (restored.status !== 0 || /ohpm ERROR/.test(restored.output)) {
    throw new Error('The isolated device harness dependency restore failed.');
  }
  const built = (dependencies.runHvigor ?? runHvigor)([
    '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default',
    'assembleHap', '--no-daemon'
  ], { cwd: sampleDirectory });
  if (built.status !== 0 || /hvigor ERROR/.test(built.output) ||
    !/BUILD SUCCESSFUL/.test(built.output)) {
    throw new Error('The isolated device harness HAP build failed.');
  }
  const output = join(sampleDirectory, 'entry', 'build', 'default', 'outputs', 'default',
    'entry-default-unsigned.hap');
  const info = await stat(output);
  if (!info.isFile() || info.size <= 0) {
    throw new Error('The isolated device harness HAP is missing.');
  }
  await copyFile(output, hapPath);
}
