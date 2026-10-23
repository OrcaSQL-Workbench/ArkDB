import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { createReadStream, readFileSync } from 'node:fs';
import { join, posix, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Parser } from 'tar';
import JSON5 from 'json5';
import { checkPackage, exportedNames, importSpecifiers, listFiles, ROOT } from './check-package.mjs';
import { runHvigor } from './run-hvigor.mjs';
import { driverArgument, packageStem, resolveDriver } from './driver-packages.mjs';

const MAX_HAR_BYTES = 32 * 1024 * 1024;
const MAX_UNPACKED_BYTES = 64 * 1024 * 1024;
const TEXT_FILES = new Set([
  'package/oh-package.json5', 'package/Index.d.ets', 'package/src/main/module.json',
  'package/README.md', 'package/CHANGELOG.md', 'package/LICENSE', 'package/README.OpenSource'
]);

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function sourceFingerprint(root = ROOT, id = 'mysql') {
  const driver = resolveDriver(root, id);
  const files = [
    ...['build-profile.json5', 'oh-package.json5', 'hvigorfile.ts'].map((name) => join(root, name)),
    join(root, 'hvigor', 'hvigor-config.json5'), join(root, 'AppScope', 'app.json5'),
    ...['Index.ets', 'oh-package.json5', 'build-profile.json5', 'hvigorfile.ts',
      'README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']
      .map((name) => join(driver.directory, name)),
    ...listFiles(join(driver.directory, 'src', 'main'))
  ];
  const hash = createHash('sha256');
  for (const file of files.sort()) {
    hash.update(relative(root, file).split(sep).join('/')).update('\0');
    hash.update(readFileSync(file)).update('\0');
  }
  return hash.digest('hex');
}

export async function inspectHar(file, expected, expectedExports, moduleDefinition = {
  name: 'mysql', type: 'har', requestPermissions: [{ name: 'ohos.permission.INTERNET' }]
}) {
  const info = await stat(file);
  if (!info.isFile() || info.size === 0 || info.size > MAX_HAR_BYTES) {
    throw new Error('HAR must be a nonempty regular file within the 32 MiB package bound.');
  }
  const entries = new Map();
  const names = new Set();
  let unpackedBytes = 0;
  let entryCount = 0;
  await new Promise((resolve, reject) => {
    const input = createReadStream(file, { highWaterMark: 64 * 1024 });
    const parser = new Parser({ strict: true, maxDecompressionRatio: 1000, maxMetaEntrySize: 64 * 1024 });
    let settled = false;
    function stop(error) {
      if (settled) return;
      settled = true;
      input.unpipe(parser);
      input.destroy();
      // abort also destroys tar's internal decompressor instead of merely deferring rejection.
      parser.abort(error);
      reject(error);
    }
    function fail(message) {
      stop(new Error(message));
    }
    parser.on('error', stop);
    parser.on('abort', stop);
    input.on('error', stop);
    parser.on('end', () => {
      if (settled) return;
      settled = true;
      input.unpipe(parser);
      input.destroy();
      resolve();
    });
    parser.on('ignoredEntry', () => fail('Unsupported or oversized HAR metadata entry.'));
    parser.on('meta', (value) => {
      entryCount++;
      unpackedBytes += Buffer.byteLength(value);
      if (entryCount > 1024) fail('HAR exceeds its 1024-entry bound.');
      else if (unpackedBytes > MAX_UNPACKED_BYTES) fail('HAR exceeds the unpacked size bound.');
    });
    parser.on('entry', (entry) => {
      if (++entryCount > 1024) return fail('HAR exceeds its 1024-entry bound.');
      const path = entry.path.replace(/\/$/, '');
      const pieces = path.split('/');
      if (pieces[0] !== 'package' || pieces.some((piece) => piece === '..' || piece === '.' ||
        piece === '') || /[\\:\0]/.test(path) || names.has(path.toLowerCase())) {
        return fail(`Unsafe or duplicate HAR entry: ${entry.path}`);
      }
      names.add(path.toLowerCase());
      if (!['File', 'Directory'].includes(entry.type)) {
        return fail(`Unsupported HAR entry: ${entry.path}`);
      }
      if (entry.type !== 'File') {
        entry.resume();
        return;
      }
      unpackedBytes += entry.size;
      if (unpackedBytes > MAX_UNPACKED_BYTES) return fail('HAR exceeds the unpacked size bound.');
      if (!/^package\/(?:[^/]+|ets\/(?:modules\.abc|sourceMaps\.map)|src\/main\/module\.json|src\/main\/ets\/.+\.d\.ets)$/.test(path) ||
        /(?:^|\/)(?:\.ohpmrc|\.npmrc|local\.properties|src\/test|src\/mock)(?:\/|$)/.test(path) ||
        /\.(?:p12|pfx|p7b|jks|keystore|cer)$/i.test(path)) {
        return fail(`Unexpected file in the release HAR: ${path}`);
      }
      const hash = createHash('sha256');
      const chunks = [];
      const collectText = TEXT_FILES.has(path) && entry.size <= 1024 * 1024;
      if (TEXT_FILES.has(path) && !collectText) return fail(`Oversized package metadata: ${path}`);
      entry.on('error', stop);
      entry.on('data', (chunk) => {
        hash.update(chunk);
        if (collectText) chunks.push(chunk);
      });
      entry.on('end', () => {
        if (settled) return;
        entries.set(path, {
          size: entry.size, sha256: hash.digest('hex'),
          bytes: collectText ? Buffer.concat(chunks) : undefined
        });
      });
      entry.resume();
    });
    input.pipe(parser);
  });
  function text(path) {
    const bytes = entries.get(path)?.bytes;
    if (!bytes || bytes.length === 0) throw new Error(`Missing or empty HAR file: ${path}`);
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }
  const manifest = JSON5.parse(text('package/oh-package.json5'));
  if (manifest.name !== expected.name || manifest.version !== expected.version ||
    manifest.license !== expected.license ||
    JSON.stringify(manifest.dependencies ?? {}) !== JSON.stringify(expected.dependencies ?? {})) {
    throw new Error('HAR package identity or dependencies differ from the source manifest.');
  }
  if (manifest.types !== 'Index.d.ets' || manifest.metadata?.byteCodeHar !== true ||
    manifest.metadata?.debug !== false || manifest.metadata?.useNormalizedOHMUrl !== true ||
    manifest.compatibleSdkVersion !== 24 || manifest.compatibleSdkType !== 'HarmonyOS' ||
    !(entries.get('package/ets/modules.abc')?.size > 0)) {
    throw new Error('Expected a release bytecode HAR with normalized OHM URLs for HarmonyOS API 24.');
  }
  const barrel = text('package/Index.d.ets');
  const actualExports = exportedNames(barrel);
  if (actualExports.length === 0 || (expectedExports !== undefined &&
    JSON.stringify(actualExports) !== JSON.stringify([...expectedExports].sort()))) {
    throw new Error('Packaged public exports differ from the source entry.');
  }
  for (const specifier of importSpecifiers(barrel)) {
    const target = posix.join('package', `${specifier}.d.ets`);
    if (!specifier.startsWith('.') || !entries.has(target)) {
      throw new Error(`Unresolved packaged public declaration: ${specifier}`);
    }
  }
  for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) text(`package/${name}`);
  const module = JSON5.parse(text('package/src/main/module.json')).module;
  const permissionNames = (definition) => (definition.requestPermissions ?? []).map((permission) => permission.name).sort();
  if (module.name !== moduleDefinition.name || module.type !== 'har' ||
    JSON.stringify(permissionNames(module)) !== JSON.stringify(permissionNames(moduleDefinition))) {
    throw new Error('Packaged module identity or permission declarations differ from the source module.');
  }
  return { manifest, entries, publicExports: actualExports };
}

export async function packageHar(root = ROOT, id = 'mysql') {
  const { manifest, exports, driver } = checkPackage(root, id);
  const fingerprint = sourceFingerprint(root, id);
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  const sourceClean = execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'],
    { cwd: root, encoding: 'utf8' }).trim().length === 0;
  const result = runHvigor([
    '--mode', 'module', '-p', `module=${driver.id}@default`, '-p', 'product=default',
    '-p', 'buildMode=release', 'clean', 'assembleHar', '--no-daemon'
  ], { cwd: root });
  if (result.status !== 0 || /hvigor ERROR/.test(result.output) || !/BUILD SUCCESSFUL/.test(result.output)) {
    throw new Error('Release HAR compilation failed; no new artifact was prepared.');
  }
  if (sourceFingerprint(root, id) !== fingerprint) throw new Error('Source changed during the release build.');
  const built = join(driver.directory, 'build', 'default', 'outputs', 'default', `${driver.id}.har`);
  const inspected = await inspectHar(built, manifest, exports, driver.definition);
  for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
    const source = await readFile(join(driver.directory, name));
    if (inspected.entries.get(`package/${name}`).sha256 !== sha256(source)) {
      throw new Error(`Packaged ${name} differs from its reviewed source.`);
    }
  }
  const dist = join(root, 'dist');
  await mkdir(dist, { recursive: true });
  const stem = packageStem(manifest);
  const name = `${stem}.har`;
  const bytes = await readFile(built);
  const identity = {
    schemaVersion: 1, packageName: manifest.name, version: manifest.version,
    driver: driver.id, modulePath: driver.sourcePath,
    sourceCommit: sourceClean ? sourceCommit : null, checkoutHead: sourceCommit, sourceClean,
    file: name, sha256: sha256(bytes), byteLength: bytes.length, sourceFingerprint: fingerprint,
    format: 'bytecode-har', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
    useNormalizedOHMUrl: true, buildMode: 'release', published: false
  };
  await copyFile(built, join(dist, name));
  if (sha256(await readFile(join(dist, name))) !== identity.sha256 ||
    sourceFingerprint(root, id) !== fingerprint ||
    execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim() !== sourceCommit ||
    (sourceClean && execFileSync('git', ['status', '--porcelain', '--untracked-files=normal'],
      { cwd: root, encoding: 'utf8' }).trim().length !== 0)) {
    throw new Error('Artifact or source changed while preparing the package.');
  }
  await writeFile(join(dist, `${stem}.manifest.json`),
    `${JSON.stringify(identity, null, 2)}\n`);
  await writeFile(join(dist, `${name}.sha256`), `${identity.sha256}  ${name}\n`);
  console.log(`Prepared ${name} (${bytes.length} bytes, SHA-256 ${identity.sha256}). Not published.`);
  return identity;
}

export async function verifiedArtifact(root = ROOT, id = 'mysql') {
  const { manifest, exports, driver } = checkPackage(root, id);
  const stem = packageStem(manifest);
  const dist = join(root, 'dist');
  const artifact = join(dist, `${stem}.har`);
  const identity = JSON.parse(await readFile(join(dist, `${stem}.manifest.json`), 'utf8'));
  const bytes = await readFile(artifact);
  if (identity.schemaVersion !== 1 || identity.driver !== id || identity.modulePath !== driver.sourcePath ||
    identity.packageName !== manifest.name || identity.version !== manifest.version ||
    identity.file !== `${stem}.har` || identity.byteLength !== bytes.length ||
    identity.sha256 !== sha256(bytes) || identity.sourceFingerprint !== sourceFingerprint(root, id)) {
    throw new Error(`Release HAR identity is missing, stale, or inconsistent. Run npm run pack -- --driver ${id}.`);
  }
  await inspectHar(artifact, manifest, exports, driver.definition);
  return { manifest, driver, stem, dist, artifact, identity };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await packageHar(ROOT, driverArgument(process.argv.slice(2)));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
