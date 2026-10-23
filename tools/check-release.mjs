import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { ROOT } from './check-package.mjs';
import { extractExamples } from './doc-examples.mjs';
import { runOhpm } from './run-hvigor.mjs';
import { sampleFingerprint, verifiedArtifact } from './test-consumer.mjs';

export function requireConsumerEvidence(identity, consumer, currentSample, examples) {
  if (consumer.schemaVersion !== 1 || consumer.artifactSha256 !== identity.sha256 ||
    consumer.sourceFingerprint !== identity.sourceFingerprint || consumer.sampleFingerprint !== currentSample ||
    consumer.check !== 'isolated-release-hap-and-local-tests' || consumer.sampleHapCompiled !== true ||
    consumer.documentedExamples !== examples || !Number.isSafeInteger(consumer.localSampleCases) ||
    consumer.localSampleCases <= 0) {
    throw new Error('Current sample/README verification is missing or stale. Run npm run test:consumer.');
  }
}

export function requireCleanSource(identity, sourceClean, sourceCommit) {
  if (!sourceClean || identity.sourceClean !== true || identity.sourceCommit !== sourceCommit) {
    throw new Error('Build the HAR from the reviewed, committed, clean source before publication.');
  }
}

async function main() {
  const flags = process.argv.slice(2);
  if (flags.some((flag) => flag !== '--require-clean') || flags.length > 1) {
    throw new Error('Usage: node tools/check-release.mjs [--require-clean]');
  }
  const source = await verifiedArtifact();
  const consumer = JSON.parse(await readFile(join(source.dist, `${source.stem}.consumer.json`), 'utf8'));
  const examples = extractExamples(await readFile(join(ROOT, 'mysql', 'README.md'), 'utf8')).length;
  requireConsumerEvidence(source.identity, consumer, sampleFingerprint(), examples);
  const prepublish = runOhpm(['prepublish', source.artifact]);
  if (prepublish.status !== 0 || /ohpm ERROR/.test(prepublish.output) ||
    !prepublish.output.includes(`prepublish ${source.manifest.name} ${source.manifest.version} succeed`)) {
    throw new Error('OHPM prepublication validation did not succeed. Nothing was published.');
  }
  const status = execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'], {
    cwd: ROOT, encoding: 'utf8', windowsHide: true
  });
  const sourceClean = status.trim().length === 0;
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: ROOT, encoding: 'utf8', windowsHide: true
  }).trim();
  if (flags.includes('--require-clean')) requireCleanSource(source.identity, sourceClean, sourceCommit);
  await writeFile(join(source.dist, `${source.stem}.readiness.json`), `${JSON.stringify({
    schemaVersion: 1, packageName: source.manifest.name, version: source.manifest.version,
    artifactSha256: source.identity.sha256, sourceFingerprint: source.identity.sourceFingerprint,
    sampleFingerprint: consumer.sampleFingerprint, checkedAt: new Date().toISOString(),
    ohpmPrepublishPassed: true, documentedExamples: examples, sampleHapCompiled: true,
    localSampleCases: consumer.localSampleCases, sourceClean, sourceCommit,
    publisherScopeOwnershipVerified: false, registryAcquisitionVerified: false,
    liveNetworkingVerified: false, published: false
  }, null, 2)}\n`);
  console.log(`Local publication preparation verified: ${examples} compiled README examples and the sample HAP.`);
  console.log(`Source is ${sourceClean ? 'clean' : 'not yet committed/clean'}. ` +
    'Publisher approval, registry publication/acquisition, and real-device evidence are separate.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
