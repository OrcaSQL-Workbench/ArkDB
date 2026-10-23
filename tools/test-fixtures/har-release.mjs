import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { tmpdir } from 'node:os';
import { create } from 'tar';
import JSON5 from 'json5';
import { checkPackage, ROOT } from '../check-package.mjs';
import { sha256, sourceFingerprint } from '../package-har.mjs';
import { sampleFingerprint } from '../test-consumer.mjs';

export const COMMIT = 'a'.repeat(40);
export const TAG_OBJECT = 'b'.repeat(40);
export const TAG = 'mysql-v1.0.0';
export const STEM = 'arkdb-mysql-1.0.0';
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
  await writeFile(fixtureManifestPath, `${JSON.stringify(fixtureManifest, null, 2)}\n`);
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
  const dist = join(root, 'dist');
  await mkdir(dist);
  await create({ file: join(dist, `${STEM}.har`), cwd: staging, gzip: true, portable: true }, ['package']);
  const bytes = await readFile(join(dist, `${STEM}.har`));
  const fingerprint = sourceFingerprint(root);
  const sample = sampleFingerprint(root);
  const identity = {
    schemaVersion: 1, packageName: '@arkdb/mysql', version: '1.0.0', driver: 'mysql', modulePath: 'mysql',
    sourceCommit: COMMIT, checkoutHead: COMMIT, sourceClean: true, file: `${STEM}.har`,
    sha256: sha256(bytes), byteLength: bytes.length, sourceFingerprint: fingerprint,
    format: 'bytecode-har', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
    useNormalizedOHMUrl: true, buildMode: 'release', published: false
  };
  const consumer = {
    schemaVersion: 1, packageName: '@arkdb/mysql', version: '1.0.0', artifactSha256: identity.sha256,
    sourceFingerprint: fingerprint, sampleFingerprint: sample, check: 'isolated-release-hap-and-local-tests',
    documentedExamples: 8, sampleHapCompiled: true, localTestsExecuted: true, localSampleCases: 6,
    verifiedAt: '2026-10-22T00:00:00.000Z', registryAcquisitionVerified: false, liveNetworkingVerified: false
  };
  const readiness = {
    ...consumer, ohpmPrepublishPassed: true, sourceClean: true, sourceCommit: COMMIT, published: false,
    publisherScopeOwnershipVerified: false
  };
  for (const [name, value] of Object.entries({ manifest: identity, consumer, readiness })) {
    await writeFile(join(dist, `${STEM}.${name}.json`), `${JSON.stringify(value, null, 2)}\n`);
  }
  await writeFile(join(dist, `${STEM}.har.sha256`), `${identity.sha256}  ${STEM}.har\n`);
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
    root, dist, identity, consumer, readiness, state, git,
    options: { root, driver: 'mysql', tag: TAG },
    dependencies: { git, verify: async () => ({ driverTestsPassed: 183 }) },
    changeRecord: async (name, overrides) => {
      const file = join(dist, `${STEM}.${name}.json`);
      await writeFile(file, `${JSON.stringify({ ...JSON.parse(await readFile(file, 'utf8')), ...overrides })}\n`);
    }
  };
}
