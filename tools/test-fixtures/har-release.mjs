import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { tmpdir } from 'node:os';
import { create } from 'tar';
import JSON5 from 'json5';
import { checkPackage, ROOT } from '../check-package.mjs';
import { sha256, sourceFingerprint } from '../package-har.mjs';
import { sampleFingerprint } from '../test-consumer.mjs';
import { localOutputPaths } from '../driver-packages.mjs';
import { deliveryPlan } from '../delivery-workspace.mjs';

export const COMMIT = 'a'.repeat(40);
export const TAG_OBJECT = 'b'.repeat(40);
export const TAG = 'mysql-v1.0.0';
export const STEM = 'arkdb-mysql-1.0.0';
export const LOCAL_STEM = 'arkdb-mysql-1.0.0-local';
export const REPO = 'OrcaSQL-Workbench/ArkDB';

export async function releaseFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-release-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const ignored = new Set(['build', '.test', '.hvigor', 'oh_modules', 'node_modules', 'dependency',
    'BuildProfile.ets', 'oh-package-lock.json5', '.ohpmrc', '.npmrc', 'local.properties']);
  for (const name of ['mysql', 'examples', 'hvigor', 'AppScope', 'build-profile.json5',
    'hvigorfile.ts', 'oh-package.json5', 'LICENSE']) {
    await cp(join(ROOT, name), join(root, name), { recursive: true, filter: (file) => !ignored.has(basename(file)) });
  }

  const fixtureManifestPath = join(root, 'mysql', 'oh-package.json5');
  const fixtureManifest = JSON5.parse(await readFile(fixtureManifestPath, 'utf8'));
  fixtureManifest.version = '1.0.0';
  fixtureManifest.dependencies = {};
  const declarationPath = join(root, 'mysql', 'arkdb-package.json');
  const declaration = JSON5.parse(await readFile(declarationPath, 'utf8'));
  declaration.verification.nativeModules = ['mysql'];
  await writeFile(declarationPath, JSON.stringify(declaration));
  await writeFile(fixtureManifestPath, `${JSON.stringify(fixtureManifest, null, 2)}\n`);
  // A synthetic legacy, single-HAR source layout, not the current core-dependent implementation.
  const profilePath = join(root, 'build-profile.json5');
  const profile = JSON5.parse(await readFile(profilePath, 'utf8'));
  profile.modules = profile.modules.filter((entry) => entry.name === 'mysql');
  await writeFile(profilePath, JSON.stringify(profile));
  await rm(join(root, 'mysql', 'src'), { recursive: true });
  await mkdir(join(root, 'mysql', 'src', 'main', 'ets'), { recursive: true });
  await mkdir(join(root, 'mysql', 'src', 'test'), { recursive: true });
  await writeFile(join(root, 'mysql', 'src', 'main', 'module.json5'), JSON.stringify({
    module: { name: 'mysql', type: 'har', requestPermissions: [{ name: 'ohos.permission.INTERNET' }] }
  }));
  await writeFile(join(root, 'mysql', 'src', 'main', 'ets', 'Public.ets'),
    'export class SyntheticDeclaration {}\n');
  await writeFile(join(root, 'mysql', 'Index.ets'), "export { SyntheticDeclaration } from './src/main/ets/Public';\n");
  await writeFile(join(root, 'mysql', 'src', 'test', 'List.test.ets'),
    "import suite from './Synthetic.test';\nexport default function tests(): void { suite(); }\n");
  await writeFile(join(root, 'mysql', 'src', 'test', 'Synthetic.test.ets'),
    'export default function suite(): void {}\n');
  const { manifest, exports, driver } = checkPackage(root);
  const staging = join(root, 'build', 'fixture');
  const files = {
    'oh-package.json5': JSON.stringify({
      ...manifest, types: 'Index.d.ets', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
      metadata: { byteCodeHar: true, debug: false, useNormalizedOHMUrl: true }
    }),
    'Index.d.ets': `export { ${exports.join(', ')} } from './public';\n`,
    'public.d.ets': 'export declare class SyntheticDeclaration {}\n',
    'src/main/module.json': JSON.stringify({ module: driver.definition }),
    'ets/modules.abc': 'Synthetic test bytecode, never executed.'
  };
  for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
    files[name] = await readFile(join(root, 'mysql', name));
  }
  for (const [name, content] of Object.entries(files)) {
    const path = join(staging, 'package', name);
    await mkdir(join(path, '..'), { recursive: true });
    await writeFile(path, content);
  }
  const paths = localOutputPaths(root, 'mysql');
  const dist = paths.artifacts;
  const evidence = paths.evidence;
  await mkdir(dist, { recursive: true });
  await mkdir(evidence, { recursive: true });
  await mkdir(join(root, 'dist'), { recursive: true });
  await create({ file: join(dist, `${LOCAL_STEM}.har`), cwd: staging, gzip: true, portable: true }, ['package']);
  const bytes = await readFile(join(dist, `${LOCAL_STEM}.har`));
  const fingerprint = sourceFingerprint(root);
  const sample = sampleFingerprint(root);
  const identity = {
    schemaVersion: 1, packageName: '@arkdb/mysql', version: '1.0.0', driver: 'mysql', modulePath: 'mysql',
    sourceCommit: COMMIT, checkoutHead: COMMIT, sourceClean: true,
    artifactChannel: 'local', file: `${LOCAL_STEM}.har`,
    sha256: sha256(bytes), byteLength: bytes.length, sourceFingerprint: fingerprint,
    format: 'bytecode-har', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
    useNormalizedOHMUrl: true, buildMode: 'release', published: false
  };
  const consumer = {
    schemaVersion: 3, packageName: '@arkdb/mysql', version: '1.0.0', artifactSha256: identity.sha256,
    consumerProfile: 'current',
    sourceFingerprint: fingerprint, sampleFingerprint: sample, check: 'isolated-release-hap-and-local-tests',
    documentedExamples: 8, sampleHapCompiled: true, localTestsExecuted: true, localSampleCases: 6,
    sampleHapSha256: 'f'.repeat(64), sampleHapByteLength: 12345,
    sampleHapContentSha256: 'e'.repeat(64),
    verifiedAt: '2026-10-22T00:00:00.000Z', registryAcquisitionVerified: false, liveNetworkingVerified: false
  };
  const readiness = {
    ...consumer, ohpmPrepublishPassed: true, sourceClean: true, sourceCommit: COMMIT, published: false,
    publisherScopeOwnershipVerified: false
  };
  for (const [name, value] of Object.entries({ manifest: identity, consumer, readiness })) {
    await writeFile(join(name === 'manifest' ? dist : evidence, `${LOCAL_STEM}.${name}.json`),
      `${JSON.stringify(value, null, 2)}\n`);
  }
  await writeFile(join(dist, `${LOCAL_STEM}.har.sha256`), `${identity.sha256}  ${LOCAL_STEM}.har\n`);
  const state = { dirty: false, head: COMMIT, tagCommit: COMMIT, tagObject: TAG_OBJECT, tagType: 'tag' };
  function git(args) {
    const command = args.join(' ');
    if (command === 'rev-parse --show-toplevel') return root;
    if (command === 'remote get-url origin') return `https://github.com/${REPO}.git`;
    if (command === 'status --porcelain --untracked-files=all') return state.dirty ? ' M mysql/README.md\n' : '';
    if (command === 'rev-parse --verify HEAD') return state.head;
    if (command === `cat-file -t refs/tags/${TAG}`) return state.tagType;
    if (command === `rev-parse --verify refs/tags/${TAG}`) return state.tagObject;
    if (command === `rev-parse --verify refs/tags/${TAG}^{commit}`) return state.tagCommit;
    throw new Error(`Unexpected fixture Git read: ${command}`);
  }
  return {
    root, dist, evidence, localStem: LOCAL_STEM, identity, consumer, readiness, state, git,
    options: { root, driver: 'mysql', tag: TAG },
    dependencies: { git, verify: async () => ({ driverTestsPassed: 183 }) },
    changeRecord: async (name, overrides) => {
      const file = join(name === 'manifest' ? dist : evidence, `${LOCAL_STEM}.${name}.json`);
      await writeFile(file, `${JSON.stringify({ ...JSON.parse(await readFile(file, 'utf8')), ...overrides })}\n`);
    }
  };
}

/** Synthetic archives and receipts only; no compiler, device or publisher is invoked. */
export async function sharedReleaseFixture(t) {
  const fixture = await releaseFixture(t);
  const ignored = new Set(['build', '.test', '.hvigor', 'oh_modules', 'node_modules',
    'BuildProfile.ets', 'oh-package-lock.json5']);
  await cp(join(ROOT, 'core'), join(fixture.root, 'core'), {
    recursive: true, filter: (file) => !ignored.has(basename(file))
  });
  const profilePath = join(fixture.root, 'build-profile.json5');
  const profile = JSON5.parse(await readFile(profilePath, 'utf8'));
  profile.modules.unshift({ name: 'core', srcPath: './core' });
  await writeFile(profilePath, JSON.stringify(profile));
  const manifestPath = join(fixture.root, 'mysql', 'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.dependencies = { '@arkdb/core': '1.0.0' };
  const declarationPath = join(fixture.root, 'mysql', 'arkdb-package.json');
  const declaration = JSON5.parse(await readFile(declarationPath, 'utf8'));
  declaration.verification.nativeModules = ['core', 'mysql'];
  await writeFile(declarationPath, JSON.stringify(declaration));
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(join(fixture.root, 'mysql', 'Index.ets'),
    "export { SyntheticDeclaration } from './src/main/ets/Public';\nexport { ArkDbError } from '@arkdb/core';\n");
  const archives = [];
  for (const id of ['core', 'mysql']) {
    const checked = checkPackage(fixture.root, id);
    const stem = `${checked.manifest.name.slice(1).replace('/', '-')}-${checked.manifest.version}-local`;
    const staging = join(fixture.root, 'build', `shared-fixture-${id}`);
    const exports = checked.exports.filter((name) => id !== 'mysql' || name !== 'ArkDbError');
    const files = {
      'oh-package.json5': JSON.stringify({
        ...checked.manifest, types: 'Index.d.ets', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
        metadata: { byteCodeHar: true, debug: false, useNormalizedOHMUrl: true }
      }),
      'Index.d.ets': `export { ${exports.join(', ')} } from './public';\n` +
        (id === 'mysql' ? "export { ArkDbError } from '@arkdb/core';\n" : ''),
      'public.d.ets': 'export declare class SyntheticDeclaration {}\n',
      'src/main/module.json': JSON.stringify({ module: checked.driver.definition }),
      'ets/modules.abc': 'Synthetic dependency-set fixture; never executable.'
    };
    for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
      files[name] = await readFile(join(checked.driver.directory, name));
    }
    for (const [name, content] of Object.entries(files)) {
      const path = join(staging, 'package', name);
      await mkdir(join(path, '..'), { recursive: true });
      await writeFile(path, content);
    }
    const dist = localOutputPaths(fixture.root, id).artifacts;
    await mkdir(dist, { recursive: true });
    const artifactPath = join(dist, `${stem}.har`);
    await create({ file: artifactPath, cwd: staging, gzip: true, portable: true }, ['package']);
    const bytes = await readFile(artifactPath);
    const identity = {
      ...fixture.identity, packageName: checked.manifest.name, version: checked.manifest.version,
      driver: id, kind: checked.driver.kind, modulePath: checked.driver.sourcePath,
      moduleDefinition: checked.driver.definition, dependencies: checked.manifest.dependencies,
      dependencyArtifacts: archives.map((archive) => ({
        id: archive.identity.driver, packageName: archive.identity.packageName, version: archive.identity.version,
        file: archive.identity.file, sha256: archive.identity.sha256, byteLength: archive.identity.byteLength
      })),
      file: `${stem}.har`, sha256: sha256(bytes), byteLength: bytes.length,
      sourceFingerprint: sourceFingerprint(fixture.root, id)
    };
    const manifestPath = join(dist, `${stem}.manifest.json`);
    await writeFile(manifestPath, JSON.stringify(identity));
    await writeFile(join(dist, `${stem}.har.sha256`), `${identity.sha256}  ${stem}.har\n`);
    archives.push({ id, stem, identity, artifactPath, manifestPath, expectedSha256: identity.sha256 });
  }
  const identity = archives.at(-1).identity;
  const consumer = {
    ...fixture.consumer, artifactSha256: identity.sha256, sourceFingerprint: identity.sourceFingerprint,
    sampleFingerprint: sampleFingerprint(fixture.root), dependencyArtifacts: identity.dependencyArtifacts
  };
  const readiness = { ...fixture.readiness, ...consumer };
  for (const [name, value] of Object.entries({ consumer, readiness })) {
    await writeFile(join(fixture.evidence, `${LOCAL_STEM}.${name}.json`), JSON.stringify(value));
  }
  return { ...fixture, identity, consumer, readiness, archives };
}

export async function standaloneReleaseFixture(t) {
  const fixture = await sharedReleaseFixture(t);
  const plan = deliveryPlan(fixture.root, 'mysql');
  const staging = join(fixture.root, 'build', 'standalone-fixture');
  const files = {
    'oh-package.json5': JSON.stringify({
      ...plan.manifest, types: 'Index.d.ets', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
      metadata: { byteCodeHar: true, debug: false, useNormalizedOHMUrl: true }
    }),
    'Index.d.ets': "export { SyntheticDeclaration } from './public';\n" +
      "export { ArkDbError } from './src/main/ets/_deps/core/Index';\n",
    'public.d.ets': 'export declare class SyntheticDeclaration {}\n',
    'src/main/ets/_deps/core/Index.d.ets': 'export declare class ArkDbError extends Error {}\n',
    'src/main/module.json': JSON.stringify({ module: plan.definition }),
    'ets/modules.abc': 'Synthetic self-contained fixture; never executable.',
    'README.OpenSource': plan.notice
  };
  for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    files[name] = await readFile(join(fixture.root, 'mysql', name));
  }
  for (const [name, bytes] of Object.entries(files)) {
    const file = join(staging, 'package', name);
    await mkdir(join(file, '..'), { recursive: true });
    await writeFile(file, bytes);
  }
  const artifactPath = join(fixture.dist, `${LOCAL_STEM}.har`);
  await create({ file: artifactPath, cwd: staging, gzip: true, portable: true }, ['package']);
  const bytes = await readFile(artifactPath);
  const identity = {
    ...fixture.identity, delivery: 'self-contained', dependencies: {}, dependencyArtifacts: [],
    sourceDependencies: { '@arkdb/core': '1.0.0' },
    embeddedPackages: [{
      id: 'core', packageName: '@arkdb/core', version: '1.0.0', modulePath: 'core',
      sourceFingerprint: sourceFingerprint(fixture.root, 'core'), dependencies: {}
    }],
    moduleDefinition: plan.definition,
    byteLength: bytes.length, sha256: sha256(bytes)
  };
  await writeFile(join(fixture.dist, `${LOCAL_STEM}.manifest.json`), JSON.stringify(identity));
  await writeFile(join(fixture.dist, `${LOCAL_STEM}.har.sha256`), `${identity.sha256}  ${LOCAL_STEM}.har\n`);
  const consumer = {
    ...fixture.consumer, artifactSha256: identity.sha256, dependencyArtifacts: [],
    selfContainedRuntimeVerified: true
  };
  const readiness = { ...fixture.readiness, ...consumer };
  for (const [name, value] of Object.entries({ consumer, readiness })) {
    await writeFile(join(fixture.evidence, `${LOCAL_STEM}.${name}.json`), JSON.stringify(value));
  }
  return { ...fixture, identity, consumer, readiness, plan, coreArtifact: fixture.archives[0].artifactPath };
}
