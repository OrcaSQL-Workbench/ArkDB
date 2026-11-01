import { copyFile, cp, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import JSON5 from 'json5';
import { exportedNames, listFiles, ROOT } from './check-package.mjs';
import { addDocumentationChecks } from './doc-examples.mjs';
import { inspectHar, sha256, sourceFingerprint, verifiedArtifact } from './package-har.mjs';
import {
  jsonBytes, plainPath, releaseFile, SHA256, MAX_RELEASE_ASSET_BYTES, validateEmbeddedPackages
} from './har-release.mjs';
import { runHvigor, runOhpm } from './run-hvigor.mjs';
import { parseHypiumResults } from './run-ohos-tests.mjs';
import { driverVerification, localOutputPaths, resolvePackage } from './driver-packages.mjs';
import { artifactReference, verifiedArtifactSet } from './package-har.mjs';
import { hapContentFingerprint } from './hap-content.mjs';

export const REGISTRY = 'https://ohpm.openharmony.cn/ohpm/';
export { verifiedArtifact } from './package-har.mjs';

const CURRENT_CONSUMER_PROFILE = 'current';
const LEGACY_SCHEMA_1_CONSUMER_PROFILE = 'legacy-schema-1';

export function sampleFingerprint(root = ROOT, driver = 'mysql') {
  const sample = driverVerification(root, driver).consumerDirectory;
  const files = [
    ...['README.md', 'build-profile.json5', 'hvigorfile.ts', 'oh-package.json5',
      'device-acceptance-cases.json'].map((name) => join(sample, name)),
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

async function prepareDependency(workspace, source, registry, dependencies, restoreArguments) {
  const packagePath = join(workspace, 'entry', 'oh-package.json5');
  const packageManifest = JSON5.parse(await readFile(packagePath, 'utf8'));
  const projectPath = join(workspace, 'oh-package.json5');
  const projectManifest = JSON5.parse(await readFile(projectPath, 'utf8'));
  packageManifest.dependencies ??= {};
  projectManifest.overrides ??= {};
  for (const values of [packageManifest.dependencies, projectManifest.overrides]) {
    for (const name of Object.keys(values)) if (name.startsWith('@arkdb/')) delete values[name];
  }
  if (!registry) await mkdir(join(workspace, 'dependency'), { recursive: true });
  for (const archive of source.archives) {
    const { manifest } = archive;
    packageManifest.dependencies[manifest.packageName] = registry ? manifest.version :
      `file:../dependency/${manifest.driver}.har`;
    if (!registry) {
      if (source.archives.at(-1).manifest.delivery !== 'self-contained') {
        projectManifest.overrides[manifest.packageName] = `file:./dependency/${manifest.driver}.har`;
      }
      const target = join(workspace, 'dependency', `${manifest.driver}.har`);
      await copyFile(archive.artifactPath, target);
      if (sha256(await readFile(target)) !== archive.expectedSha256) {
        throw new Error('The sample received a different archive.');
      }
      if (Object.keys(projectManifest.overrides).length === 0) delete projectManifest.overrides;
    }
  }
  await writeFile(packagePath, `${JSON.stringify(packageManifest, null, 2)}\n`);
  await writeFile(projectPath, `${JSON.stringify(projectManifest, null, 2)}\n`);
  const args = restoreArguments ?? ['install', '--all'];
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

async function buildSample(workspace, dependencies = {}, requiresInternet = true) {
  requireBuild((dependencies.runHvigor ?? runHvigor)([
    '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', 'assembleHap', '--no-daemon'
  ], { cwd: workspace }), 'Sample HAP/Worker compilation');
  const hap = join(workspace, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap');
  if (!(await stat(hap)).isFile() || (await stat(hap)).size === 0) throw new Error('Sample HAP output is missing.');
  const module = JSON5.parse(await readFile(join(workspace, 'entry', 'build', 'default',
    'intermediates', 'merge_profile', 'default', 'module.json'), 'utf8')).module;
  if (requiresInternet && !module.requestPermissions?.some((permission) => permission.name === 'ohos.permission.INTERNET')) {
    throw new Error('The sample merged module is missing INTERNET.');
  }
  return hap;
}

async function prepareConsumerProfile(workspace, profile) {
  if (profile === CURRENT_CONSUMER_PROFILE) return;
  if (profile !== LEGACY_SCHEMA_1_CONSUMER_PROFILE) {
    throw new Error('Unsupported HAR consumer profile.');
  }
  await rm(join(workspace, 'device-acceptance-cases.json'), { force: true });
  await rm(join(workspace, 'entry', 'src', 'main', 'ets', 'sample'),
    { recursive: true, force: true });
  await rm(join(workspace, 'entry', 'src', 'main', 'ets', 'workers'),
    { recursive: true, force: true });
  await rm(join(workspace, 'entry', 'src', 'main', 'ets', 'pages'),
    { recursive: true, force: true });
  await rm(join(workspace, 'entry', 'src', 'test'), { recursive: true, force: true });
  await mkdir(join(workspace, 'entry', 'src', 'main', 'ets', 'pages'), { recursive: true });
  await mkdir(join(workspace, 'entry', 'src', 'test'), { recursive: true });
  const buildProfilePath = join(workspace, 'entry', 'build-profile.json5');
  const buildProfile = JSON5.parse(await readFile(buildProfilePath, 'utf8'));
  buildProfile.buildOption ??= {};
  buildProfile.buildOption.sourceOption ??= {};
  buildProfile.buildOption.sourceOption.workers = [];
  await writeFile(buildProfilePath, `${JSON.stringify(buildProfile, null, 2)}\n`);
  await writeFile(join(workspace, 'entry', 'src', 'main', 'ets', 'pages', 'Index.ets'),
    `import { ConnectionConfig, MySqlDriverFactory } from '@arkdb/mysql';

@Entry
@Component
struct Index {
  @State private status: string = 'Ready to verify the downloaded legacy HAR.';

  private async closeIdleConnection(): Promise<void> {
    const connection = new MySqlDriverFactory().createConnection(new ConnectionConfig(), '');
    await connection.close();
    this.status = 'The downloaded HAR created and closed an idle connection.';
  }

  build() {
    Column({ space: 12 }) {
      Text('ArkDB MySQL legacy release verifier').fontSize(24)
      Button('Verify downloaded HAR')
        .onClick((): void => { this.closeIdleConnection(); })
      Text(this.status)
    }
    .width('100%')
    .height('100%')
    .padding(24)
  }
}
`);
  await writeFile(join(workspace, 'entry', 'src', 'test', 'LegacyReleaseConsumer.test.ets'),
    `import { describe, expect, it } from '@ohos/hypium';
import { ConnectionConfig, MySqlDriverFactory } from '@arkdb/mysql';

export default function legacyReleaseConsumerTest(): void {
  describe('Legacy release consumer', () => {
    it('legacyReleasePublicSurfaceCompiles', 0, async () => {
      const connection = new MySqlDriverFactory().createConnection(new ConnectionConfig(), '');
      expect(connection !== undefined).assertTrue();
      await connection.close();
    });
  });
}
`);
  await writeFile(join(workspace, 'entry', 'src', 'test', 'List.test.ets'),
    `import legacyReleaseConsumerTest from './LegacyReleaseConsumer.test';

export default function tests(): void {
  legacyReleaseConsumerTest();
}
`);
}

export async function verifyHarConsumer({
  root = ROOT, driver = 'mysql', artifactPath, manifestPath, expectedSha256,
  dependencyArtifacts = [], workspaceDirectory, compileOnly = false, registry = false,
  consumerProfile = CURRENT_CONSUMER_PROFILE
}, dependencies = {}) {
  const verification = driverVerification(root, driver);
  if (!Array.isArray(dependencyArtifacts) || dependencyArtifacts.length > 8) {
    throw new Error('Consumer dependency HAR set exceeds its bounded allowlist.');
  }
  if (registry && compileOnly) throw new Error('Registry and compile-only verification cannot be combined.');
  if (![CURRENT_CONSUMER_PROFILE, LEGACY_SCHEMA_1_CONSUMER_PROFILE].includes(consumerProfile)) {
    throw new Error('Unsupported HAR consumer profile.');
  }
  const archives = [];
  for (const supplied of [...dependencyArtifacts, { artifactPath, manifestPath, expectedSha256 }]) {
    const bytes = releaseFile(dirname(supplied.artifactPath), basename(supplied.artifactPath), MAX_RELEASE_ASSET_BYTES);
    const manifest = jsonBytes(releaseFile(dirname(supplied.manifestPath), basename(supplied.manifestPath)));
    const registered = resolvePackage(root, manifest.driver);
    if (!SHA256.test(supplied.expectedSha256 ?? '') || sha256(bytes) !== supplied.expectedSha256 ||
      manifest.sha256 !== supplied.expectedSha256 || manifest.byteLength !== bytes.length ||
      manifest.schemaVersion !== 1 || manifest.packageName !== registered.packageName ||
      manifest.file !== basename(supplied.artifactPath) || !SHA256.test(manifest.sourceFingerprint ?? '') ||
      archives.some((archive) => archive.manifest.packageName === manifest.packageName)) {
      throw new Error('The supplied HAR digest or manifest identity is inconsistent.');
    }
    const inspected = await inspectHar(supplied.artifactPath, {
      name: manifest.packageName, version: manifest.version, license: 'Apache-2.0',
      dependencies: manifest.dependencies ?? {}
    }, undefined, manifest.delivery === 'self-contained' ? manifest.moduleDefinition : registered.definition);
    if (manifest.delivery === 'self-contained') validateEmbeddedPackages(manifest);
    archives.push({ ...supplied, manifest, inspected });
  }
  const { manifest, inspected } = archives.at(-1);
  if (manifest.driver !== driver) throw new Error('The supplied archive is not the selected driver.');
  const references = archives.slice(0, -1).map((archive) => suppliedReference(archive.manifest));
  if (JSON.stringify(manifest.dependencyArtifacts ?? []) !== JSON.stringify(references)) {
    throw new Error('The supplied dependency HAR set differs from the driver manifest.');
  }
  for (const archive of archives) {
    for (const [name, version] of Object.entries(archive.manifest.dependencies ?? {})) {
      const dependency = archives.find((candidate) => candidate.manifest.packageName === name);
      if (!dependency || dependency === archive || dependency.manifest.version !== version) {
        throw new Error('Missing or incompatible supplied dependency HAR.');
      }
    }
    function dependenciesOf(archive, visiting = new Set()) {
      if (visiting.has(archive.manifest.packageName)) throw new Error('Cyclic supplied HAR dependencies.');
      const path = new Set(visiting).add(archive.manifest.packageName);
      const names = new Set();
      for (const name of Object.keys(archive.manifest.dependencies ?? {})) {
        const dependency = archives.find((candidate) => candidate.manifest.packageName === name);
        for (const child of dependenciesOf(dependency, path)) names.add(child);
        names.add(name);
      }
      return names;
    }
    for (const archive of archives) {
      const names = dependenciesOf(archive);
      const expected = archives.filter((candidate) => names.has(candidate.manifest.packageName))
        .map((candidate) => suppliedReference(candidate.manifest));
      if (JSON.stringify(archive.manifest.dependencyArtifacts ?? []) !== JSON.stringify(expected)) {
        throw new Error('Supplied HAR dependency identity graph is inconsistent or contains unrelated archives.');
      }
    }
  }
  const sampleSource = sampleFingerprint(root, driver);
  const build = plainPath(root, join(root, 'build'), { allowMissing: true });
  await mkdir(build, { recursive: true });
  plainPath(root, build);
  let workspace;
  if (workspaceDirectory !== undefined) {
    workspace = plainPath(build, workspaceDirectory, { allowMissing: true });
    await mkdir(workspace);
  } else {
    const consumers = plainPath(root, localOutputPaths(root, driver).consumers, { allowMissing: true });
    await mkdir(consumers, { recursive: true });
    plainPath(root, consumers);
    workspace = await mkdtemp(join(consumers, 'consumer-'));
  }
  try {
    const generated = new Set(['build', '.hvigor', '.test', 'oh_modules', 'node_modules', 'dependency',
      'BuildProfile.ets', 'oh-package-lock.json5', '.ohpmrc', '.npmrc', 'local.properties']);
    await cp(verification.consumerDirectory, workspace,
      { recursive: true, filter: (file) => !generated.has(basename(file)) });
    await prepareConsumerProfile(workspace, consumerProfile);
    const markdown = new TextDecoder('utf-8', { fatal: true }).decode(inspected.entries.get('package/README.md').bytes);
    const examples = await addDocumentationChecks(workspace, markdown);
    const isolatedRuntime = manifest.delivery === 'self-contained' && !registry;
    const testDependencies = [];
    const cache = join(workspace, '.ohpm-cache');
    if (isolatedRuntime) {
      if (archives.length !== 1 || Object.keys(manifest.dependencies ?? {}).length !== 0) {
        throw new Error('Self-contained consumption requires exactly one HAR and no external runtime dependencies.');
      }
      for (const file of [join(workspace, 'oh-package.json5'), join(workspace, 'entry', 'oh-package.json5')]) {
        const config = JSON5.parse(await readFile(file, 'utf8'));
        if (config.devDependencies !== undefined) {
          testDependencies.push({ file, value: config.devDependencies });
          delete config.devDependencies;
          await writeFile(file, `${JSON.stringify(config, null, 2)}\n`);
        }
      }
    }
    await prepareDependency(workspace, { archives }, registry, dependencies, isolatedRuntime
      ? ['install', '--all', '--cache', cache, '--registry', 'http://127.0.0.1:9'] : undefined);
    let acquisition;
    const dependencyAcquisition = [];
    if (registry) {
      const lock = JSON5.parse(await readFile(join(workspace, 'oh-package-lock.json5'), 'utf8'));
      for (const archive of archives) {
        const requested = archive.manifest;
        const identity = registryIdentity(lock, requested.packageName, requested.version);
        const installed = join(workspace, 'entry', 'oh_modules', ...requested.packageName.split('/'));
        const resolved = JSON5.parse(await readFile(join(installed, 'oh-package.json5'), 'utf8'));
        if (resolved.name !== requested.packageName || resolved.version !== requested.version ||
          resolved.types !== 'Index.d.ets' || resolved.license !== 'Apache-2.0' ||
          JSON.stringify(exportedNames(await readFile(join(installed, 'Index.d.ets'), 'utf8'))) !==
            JSON.stringify(archive.inspected.publicExports)) {
          throw new Error('The installed registry package identity or public declarations differ from the candidate.');
        }
        if (archive.manifest.driver === driver) acquisition = identity;
        else dependencyAcquisition.push({ packageName: requested.packageName, ...identity });
      }
    }
    const sampleHap = await buildSample(workspace, dependencies, verification.requiresInternet);
    const sampleHapBytes = releaseFile(dirname(sampleHap), basename(sampleHap), MAX_RELEASE_ASSET_BYTES);
    const sampleHapSha256 = sha256(sampleHapBytes);
    const sampleHapContentSha256 =
      (dependencies.hapContentFingerprint ?? hapContentFingerprint)(sampleHapBytes);
    let verdict = null;
    if (!compileOnly) {
      if (isolatedRuntime && testDependencies.length > 0) {
        for (const saved of testDependencies) {
          const config = JSON5.parse(await readFile(saved.file, 'utf8'));
          config.devDependencies = saved.value;
          await writeFile(saved.file, `${JSON.stringify(config, null, 2)}\n`);
        }
        const restored = (dependencies.runOhpm ?? runOhpm)([
          'install', '--all', '--cache', cache, '--registry', REGISTRY
        ], { cwd: workspace });
        if (restored.status !== 0 || /ohpm ERROR/.test(restored.output)) {
          throw new Error('The test-framework restore failed after isolated runtime verification.');
        }
      }
      requireBuild((dependencies.runHvigor ?? runHvigor)([
        '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', 'test', '--no-daemon'
      ], { cwd: workspace }), 'Offline sample lifecycle tests');
      verdict = parseHypiumResults(await readFile(join(workspace, 'entry', '.test', 'default',
        'intermediates', 'test', 'coverage_data', 'test_result.txt'), 'utf8'));
    }
    if (sha256(releaseFile(dirname(artifactPath), basename(artifactPath), MAX_RELEASE_ASSET_BYTES)) !== expectedSha256 ||
      sampleFingerprint(root, driver) !== sampleSource ||
      archives.some((archive) => sha256(releaseFile(dirname(archive.artifactPath),
        basename(archive.artifactPath), MAX_RELEASE_ASSET_BYTES)) !== archive.expectedSha256) ||
      sha256(releaseFile(dirname(sampleHap), basename(sampleHap), MAX_RELEASE_ASSET_BYTES)) !== sampleHapSha256) {
      throw new Error('The supplied archive, dependency set or consumer example changed during verification.');
    }
    return {
      schemaVersion: 3, packageName: manifest.packageName, version: manifest.version,
      consumerProfile,
      ...(registry ? { referenceLocalArtifactSha256: expectedSha256 } : { artifactSha256: expectedSha256 }),
      sourceFingerprint: manifest.sourceFingerprint, sampleFingerprint: sampleSource,
      dependencyArtifacts: references,
      ...(manifest.delivery === 'self-contained' ? { selfContainedRuntimeVerified: isolatedRuntime } : {}),
      check: compileOnly ? 'isolated-release-hap-compilation'
        : registry ? 'isolated-registry-hap-and-local-tests' : 'isolated-release-hap-and-local-tests',
      verifiedAt: new Date().toISOString(), documentedExamples: examples,
      localSampleCases: verdict?.total ?? null, localTestsExecuted: !compileOnly,
      sampleHapCompiled: true, sampleHapSha256, sampleHapByteLength: sampleHapBytes.length,
      sampleHapContentSha256,
      registryAcquisitionVerified: registry, liveNetworkingVerified: false,
      ...(acquisition ? { acquisition, dependencyAcquisition } : {})
    };
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}

export function suppliedReference(manifest) {
  return {
    id: manifest.driver, packageName: manifest.packageName, version: manifest.version,
    file: manifest.file, sha256: manifest.sha256, byteLength: manifest.byteLength
  };
}

export function consumerArguments(argv) {
  const flags = [];
  let driver = 'mysql';
  let selected = false;
  for (let index = 0; index < argv.length; index++) {
    if (argv[index] === '--driver' && !selected && /^[a-z][a-z0-9_-]*$/.test(argv[index + 1] ?? '')) {
      driver = argv[++index];
      selected = true;
    } else flags.push(argv[index]);
  }
  return { driver, mode: consumerMode(flags) };
}

async function main() {
  const { driver, mode } = consumerArguments(process.argv.slice(2));
  const sources = await verifiedArtifactSet(ROOT, driver);
  const source = sources.at(-1);
  const supplied = sources.map((entry) => ({
    artifactPath: entry.artifact, manifestPath: join(entry.dist, `${entry.stem}.manifest.json`),
    expectedSha256: entry.identity.sha256, manifest: entry.identity
  }));
  const verification = driverVerification(ROOT, driver);
  if (mode === '--prepare' || mode === '--example') {
    const workspace = verification.consumerDirectory;
    await prepareDependency(workspace, { archives: supplied }, false, {});
    if (mode === '--example') console.log(`Built unsigned sample: ${await buildSample(workspace, {}, verification.requiresInternet)}`);
    else console.log(`Prepared ${workspace}. Open it in DevEco Studio; configure your own debug signing.`);
    return;
  }
  const record = await verifyHarConsumer({
    driver, artifactPath: source.artifact,
    manifestPath: join(source.dist, `${source.stem}.manifest.json`), expectedSha256: source.identity.sha256,
    dependencyArtifacts: supplied.slice(0, -1),
    compileOnly: mode === '--compile-only', registry: mode === '--registry'
  });
  if (sourceFingerprint(ROOT, driver) !== source.identity.sourceFingerprint ||
    JSON.stringify(record.dependencyArtifacts) !== JSON.stringify(sources.slice(0, -1).map(artifactReference))) {
    throw new Error('Current driver source or dependency set changed during consumer verification.');
  }
  await mkdir(source.evidenceDirectory, { recursive: true });
  await writeFile(join(source.evidenceDirectory, `${source.stem}.${mode === '--compile-only' ? 'compile'
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
