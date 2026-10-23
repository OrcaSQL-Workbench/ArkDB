import { copyFile, cp, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import JSON5 from 'json5';
import { exportedNames, listFiles, ROOT } from './check-package.mjs';
import { addDocumentationChecks } from './doc-examples.mjs';
import { inspectHar, sha256, sourceFingerprint, verifiedArtifact } from './package-har.mjs';
import { jsonBytes, plainPath, releaseFile, SHA256, MAX_RELEASE_ASSET_BYTES } from './har-release.mjs';
import { runHvigor, runOhpm } from './run-hvigor.mjs';
import { parseHypiumResults } from './run-ohos-tests.mjs';

export const REGISTRY = 'https://ohpm.openharmony.cn/ohpm/';
export { verifiedArtifact } from './package-har.mjs';

export function sampleFingerprint(root = ROOT) {
  const sample = join(root, 'examples', 'mysql-client');
  const files = [
    ...['README.md', 'build-profile.json5', 'hvigorfile.ts', 'oh-package.json5'].map((name) => join(sample, name)),
    ...['build-profile.json5', 'hvigorfile.ts', 'oh-package.json5'].map((name) => join(sample, 'entry', name)),
    ...listFiles(join(sample, 'AppScope')), ...listFiles(join(sample, 'hvigor')),
    ...listFiles(join(sample, 'entry', 'src'))
  ];
  const hash = createHash('sha256');
  for (const file of files.sort()) hash.update(file.slice(sample.length).replaceAll('\\', '/'))
    .update('\0').update(readFileSync(file)).update('\0');
  return hash.digest('hex');
}

export function registryIdentity(lock, name, version) {
  const packages = Object.values(lock?.packages ?? {}).filter((entry) =>
    entry?.name === name && entry?.version === version);
  if (packages.length !== 1) throw new Error('Registry lock must identify exactly the requested package version.');
  const entry = packages[0];
  const digest = typeof entry.integrity === 'string'
    ? entry.integrity.match(/^sha(256|512)-([A-Za-z0-9+/]+=*)$/) : null;
  const digestBytes = digest ? Buffer.from(digest[2], 'base64') : Buffer.alloc(0);
  const url = typeof entry.resolved === 'string' ? URL.parse(entry.resolved) : null;
  if (entry.registryType !== 'ohpm' || !digest ||
    digestBytes.length !== Number(digest[1]) / 8 || digestBytes.toString('base64') !== digest[2] ||
    !url || url.origin !== new URL(REGISTRY).origin || !url.pathname.startsWith('/ohpm/') ||
    !url.pathname.endsWith('.har') || url.username || url.password || url.search || url.hash) {
    throw new Error('Registry acquisition must have a public-registry URL and package integrity, not a local override.');
  }
  return { resolved: entry.resolved, integrity: entry.integrity, version: entry.version };
}

async function prepareDependency(workspace, source, registry, dependencies) {
  const packagePath = join(workspace, 'entry', 'oh-package.json5');
  const packageManifest = JSON5.parse(await readFile(packagePath, 'utf8'));
  if (registry) {
    packageManifest.dependencies[source.manifest.packageName] = source.manifest.version;
    await writeFile(packagePath, `${JSON.stringify(packageManifest, null, 2)}\n`);
  } else {
    if (packageManifest.dependencies[source.manifest.packageName] !== 'file:../dependency/mysql.har') {
      throw new Error('Sample verification requires the explicit release-HAR dependency, not another override.');
    }
    await mkdir(join(workspace, 'dependency'), { recursive: true });
    await copyFile(source.artifactPath, join(workspace, 'dependency', 'mysql.har'));
    if (sha256(await readFile(join(workspace, 'dependency', 'mysql.har'))) !== source.expectedSha256) {
      throw new Error('The sample received a different archive.');
    }
  }
  const args = ['install', '--all'];
  if (registry) args.push('--registry', REGISTRY, '--cache', join(workspace, '.ohpm-cache'));
  const restored = (dependencies.runOhpm ?? runOhpm)(args, { cwd: workspace });
  if (restored.status !== 0 || /ohpm ERROR/.test(restored.output)) throw new Error('The sample dependency restore failed.');
}

function requireBuild(result, label) {
  if (result.status !== 0 || /hvigor ERROR/.test(result.output) || !/BUILD SUCCESSFUL/.test(result.output)) {
    throw new Error(`${label} failed.`);
  }
}

export function consumerMode(flags) {
  if (flags.length > 1 || flags.some((flag) =>
    !['--prepare', '--example', '--registry', '--compile-only'].includes(flag))) {
    throw new Error('Usage: node tools/test-consumer.mjs [--prepare | --example | --registry | --compile-only]');
  }
  return flags[0] ?? '--verify';
}

async function buildSample(workspace, dependencies = {}) {
  requireBuild((dependencies.runHvigor ?? runHvigor)([
    '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', 'assembleHap', '--no-daemon'
  ], { cwd: workspace }), 'Sample HAP/Worker compilation');
  const hap = join(workspace, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
  if (!(await stat(hap)).isFile() || (await stat(hap)).size === 0) throw new Error('Sample HAP output is missing.');
  const module = JSON5.parse(await readFile(join(workspace, 'entry', 'build', 'default',
    'intermediates', 'merge_profile', 'default', 'module.json'), 'utf8')).module;
  if (!module.requestPermissions?.some((permission) => permission.name === 'ohos.permission.INTERNET')) {
    throw new Error('The sample merged module is missing INTERNET.');
  }
  return hap;
}

export async function verifyHarConsumer({
  root = ROOT, driver = 'mysql', artifactPath, manifestPath, expectedSha256,
  workspaceDirectory, compileOnly = false, registry = false
}, dependencies = {}) {
  if (driver !== 'mysql') throw new Error(`No independent consumer is implemented for driver ${driver}.`);
  if (registry && compileOnly) throw new Error('Registry and compile-only verification cannot be combined.');
  const bytes = releaseFile(dirname(artifactPath), basename(artifactPath), MAX_RELEASE_ASSET_BYTES);
  const manifest = jsonBytes(releaseFile(dirname(manifestPath), basename(manifestPath)));
  if (!SHA256.test(expectedSha256 ?? '') || sha256(bytes) !== expectedSha256 ||
    manifest.sha256 !== expectedSha256 || manifest.byteLength !== bytes.length ||
    manifest.schemaVersion !== 1 || manifest.packageName !== '@arkdb/mysql' || manifest.driver !== driver ||
    manifest.file !== basename(artifactPath) || !SHA256.test(manifest.sourceFingerprint ?? '')) {
    throw new Error('The supplied HAR digest or manifest identity is inconsistent.');
  }
  const inspected = await inspectHar(artifactPath, {
    name: manifest.packageName, version: manifest.version, license: 'Apache-2.0', dependencies: {}
  }, undefined);
  const sampleSource = sampleFingerprint(root);
  const build = plainPath(root, join(root, 'build'), { allowMissing: true });
  await mkdir(build, { recursive: true });
  plainPath(root, build);
  let workspace;
  if (workspaceDirectory !== undefined) {
    workspace = plainPath(build, workspaceDirectory, { allowMissing: true });
    await mkdir(workspace);
  } else workspace = await mkdtemp(join(build, 'consumer-'));
  try {
    const generated = new Set(['build', '.hvigor', '.test', 'oh_modules', 'node_modules', 'dependency',
      'BuildProfile.ets', 'oh-package-lock.json5', '.ohpmrc', '.npmrc', 'local.properties']);
    await cp(join(root, 'examples', 'mysql-client'), workspace,
      { recursive: true, filter: (file) => !generated.has(basename(file)) });
    const markdown = new TextDecoder('utf-8', { fatal: true }).decode(inspected.entries.get('package/README.md').bytes);
    const examples = await addDocumentationChecks(workspace, markdown);
    await prepareDependency(workspace, { artifactPath, manifest, expectedSha256 }, registry, dependencies);
    let acquisition;
    if (registry) {
      acquisition = registryIdentity(JSON5.parse(await readFile(join(workspace, 'oh-package-lock.json5'), 'utf8')),
        manifest.packageName, manifest.version);
      const installed = join(workspace, 'entry', 'oh_modules', '@arkdb', 'mysql');
      const resolved = JSON5.parse(await readFile(join(installed, 'oh-package.json5'), 'utf8'));
      if (resolved.name !== manifest.packageName || resolved.version !== manifest.version ||
        resolved.types !== 'Index.d.ets' || resolved.license !== 'Apache-2.0' ||
        JSON.stringify(exportedNames(await readFile(join(installed, 'Index.d.ets'), 'utf8'))) !==
          JSON.stringify(inspected.publicExports)) {
        throw new Error('The installed registry package identity or public declarations differ from the candidate.');
      }
    }
    await buildSample(workspace, dependencies);
    let verdict = null;
    if (!compileOnly) {
      requireBuild((dependencies.runHvigor ?? runHvigor)([
        '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', 'test', '--no-daemon'
      ], { cwd: workspace }), 'Offline sample lifecycle tests');
      verdict = parseHypiumResults(await readFile(join(workspace, 'entry', '.test', 'default',
        'intermediates', 'test', 'coverage_data', 'test_result.txt'), 'utf8'));
    }
    if (sha256(releaseFile(dirname(artifactPath), basename(artifactPath), MAX_RELEASE_ASSET_BYTES)) !== expectedSha256 ||
      sampleFingerprint(root) !== sampleSource) throw new Error('The supplied archive or consumer example changed during verification.');
    return {
      schemaVersion: 1, packageName: manifest.packageName, version: manifest.version,
      ...(registry ? { referenceLocalArtifactSha256: expectedSha256 } : { artifactSha256: expectedSha256 }),
      sourceFingerprint: manifest.sourceFingerprint, sampleFingerprint: sampleSource,
      check: compileOnly ? 'isolated-release-hap-compilation'
        : registry ? 'isolated-registry-hap-and-local-tests' : 'isolated-release-hap-and-local-tests',
      verifiedAt: new Date().toISOString(), documentedExamples: examples,
      localSampleCases: verdict?.total ?? null, localTestsExecuted: !compileOnly,
      sampleHapCompiled: true, registryAcquisitionVerified: registry, liveNetworkingVerified: false,
      ...(acquisition ? { acquisition } : {})
    };
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}

async function main() {
  const mode = consumerMode(process.argv.slice(2));
  const source = await verifiedArtifact();
  if (mode === '--prepare' || mode === '--example') {
    const workspace = join(ROOT, 'examples', 'mysql-client');
    await prepareDependency(workspace, {
      artifactPath: source.artifact, manifest: source.identity, expectedSha256: source.identity.sha256
    }, false, {});
    if (mode === '--example') console.log(`Built unsigned sample: ${await buildSample(workspace)}`);
    else console.log(`Prepared ${workspace}. Open it in DevEco Studio; configure your own debug signing.`);
    return;
  }
  const record = await verifyHarConsumer({
    driver: 'mysql', artifactPath: source.artifact,
    manifestPath: join(source.dist, `${source.stem}.manifest.json`), expectedSha256: source.identity.sha256,
    compileOnly: mode === '--compile-only', registry: mode === '--registry'
  });
  if (sourceFingerprint() !== source.identity.sourceFingerprint) throw new Error('Current driver source changed during consumer verification.');
  await writeFile(join(source.dist, `${source.stem}.${mode === '--compile-only' ? 'compile'
    : mode === '--registry' ? 'registry' : 'consumer'}.json`), `${JSON.stringify(record, null, 2)}\n`);
  console.log(`Isolated sample HAP/Worker and ${record.documentedExamples} README examples compiled.`);
  console.log(record.localTestsExecuted ? `${record.localSampleCases} local sample cases passed.`
    : 'Compile-only evidence: local Previewer tests were not run.');
  console.log(mode === '--registry' ? 'Public registry acquisition verified; live networking remains unverified.'
    : 'Local HAR consumption verified. Registry acquisition and live networking remain unverified.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
