import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { artifactReference, verifiedArtifactSet } from '../artifact/local-artifact.mjs';
import { ROOT } from '../workspace/check-package.mjs';
import { sampleFingerprint } from '../consumer/evidence.mjs';
import { extractExamples } from '../lib/doc-examples.mjs';
import { driverVerification } from '../workspace/driver-packages.mjs';
import { runOhpm } from '../workspace/run-hvigor.mjs';

export function requireConsumerEvidence(identity, consumer, currentSample, examples) {
  if (identity.delivery === 'self-contained' && consumer.selfContainedRuntimeVerified !== true) {
    throw new Error('Self-contained HAR readiness requires registry-independent runtime verification.');
  }
  if (consumer.schemaVersion !== 3 || consumer.consumerProfile !== 'current' ||
    consumer.artifactSha256 !== identity.sha256 ||
    consumer.sourceFingerprint !== identity.sourceFingerprint || consumer.sampleFingerprint !== currentSample ||
    consumer.check !== 'isolated-release-hap-and-local-tests' || consumer.sampleHapCompiled !== true ||
    consumer.localTestsExecuted !== true || !/^[0-9a-f]{64}$/.test(consumer.sampleHapSha256 ?? '') ||
    !/^[0-9a-f]{64}$/.test(consumer.sampleHapContentSha256 ?? '') ||
    !Number.isSafeInteger(consumer.sampleHapByteLength) || consumer.sampleHapByteLength <= 0 ||
    consumer.documentedExamples !== examples || !Number.isSafeInteger(consumer.localSampleCases) ||
    consumer.localSampleCases <= 0 ||
    JSON.stringify(consumer.dependencyArtifacts ?? []) !== JSON.stringify(identity.dependencyArtifacts ?? [])) {
    throw new Error('Current sample/README verification is missing or stale. Run npm run test:consumer.');
  }
}

export function requireCleanSource(identity, sourceClean, sourceCommit) {
  if (!sourceClean || identity.sourceClean !== true || identity.sourceCommit !== sourceCommit) {
    throw new Error('Build the HAR from the reviewed, committed, clean source before publication.');
  }
}

export async function runReleaseCheckCli(argv = process.argv.slice(2)) {
  const { driver, requireClean } = releaseCheckArguments(argv);
  const sources = await verifiedArtifactSet(ROOT, driver);
  const source = sources.at(-1);
  const verification = driverVerification(ROOT, driver);
  const consumer = JSON.parse(await readFile(join(source.evidenceDirectory, `${source.stem}.consumer.json`), 'utf8'));
  const examples = extractExamples(await readFile(join(verification.driver.directory, 'README.md'), 'utf8')).length;
  requireConsumerEvidence(source.identity, consumer, sampleFingerprint(ROOT, driver), examples);
  if (JSON.stringify(source.identity.dependencyArtifacts ?? []) !==
    JSON.stringify(sources.slice(0, -1).map(artifactReference))) {
    throw new Error('Consumer dependencies differ from the current verified HAR set.');
  }
  for (const entry of sources) {
    const prepublish = runOhpm(['prepublish', entry.artifact]);
    if (prepublish.status !== 0 || /ohpm ERROR/.test(prepublish.output) ||
      !prepublish.output.includes(`prepublish ${entry.manifest.name} ${entry.manifest.version} succeed`)) {
      throw new Error('OHPM prepublication validation did not succeed. Nothing was published.');
    }
  }
  const status = execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'], {
    cwd: ROOT, encoding: 'utf8', windowsHide: true
  });
  const sourceClean = status.trim().length === 0;
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: ROOT, encoding: 'utf8', windowsHide: true
  }).trim();
  if (requireClean) requireCleanSource(source.identity, sourceClean, sourceCommit);
  await mkdir(source.evidenceDirectory, { recursive: true });
  await writeFile(join(source.evidenceDirectory, `${source.stem}.readiness.json`), `${JSON.stringify({
    schemaVersion: 3, packageName: source.manifest.name, version: source.manifest.version,
    consumerProfile: 'current',
    artifactSha256: source.identity.sha256, sourceFingerprint: source.identity.sourceFingerprint,
    sampleFingerprint: consumer.sampleFingerprint, checkedAt: new Date().toISOString(),
    dependencyArtifacts: source.identity.dependencyArtifacts ?? [],
    ...(source.identity.delivery === 'self-contained' ? {
      selfContainedRuntimeVerified: consumer.selfContainedRuntimeVerified
    } : {}),
    ohpmPrepublishPassed: true, documentedExamples: examples, sampleHapCompiled: true,
    sampleHapSha256: consumer.sampleHapSha256, sampleHapByteLength: consumer.sampleHapByteLength,
    sampleHapContentSha256: consumer.sampleHapContentSha256,
    localSampleCases: consumer.localSampleCases, sourceClean, sourceCommit,
    publisherScopeOwnershipVerified: false, registryAcquisitionVerified: false,
    liveNetworkingVerified: false, published: false
  }, null, 2)}\n`);
  console.log(`Local publication preparation verified: ${examples} compiled README examples and the sample HAP.`);
  console.log(`Source is ${sourceClean ? 'clean' : 'not yet committed/clean'}. ` +
    'Publisher approval, registry publication/acquisition, and real-device evidence are separate.');
}

export function releaseCheckArguments(argv) {
  let driver = 'mysql';
  let requireClean = false;
  let selected = false;
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === '--require-clean' && !requireClean) requireClean = true;
    else if (flag === '--driver' && !selected && /^[a-z][a-z0-9_-]*$/.test(argv[index + 1] ?? '')) {
      driver = argv[++index];
      selected = true;
    } else throw new Error('Usage: node tools/check-release.mjs [--driver MODULE] [--require-clean]');
  }
  return { driver, requireClean };
}
