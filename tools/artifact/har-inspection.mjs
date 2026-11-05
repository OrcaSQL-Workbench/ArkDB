import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { posix } from 'node:path';
import { Parser } from 'tar';
import JSON5 from 'json5';
import { exportedNames, importSpecifiers } from '../workspace/check-package.mjs';
import { createSha256 } from '../lib/hash.mjs';

const MAX_HAR_BYTES = 32 * 1024 * 1024;
const MAX_UNPACKED_BYTES = 64 * 1024 * 1024;
const TEXT_FILES = new Set([
  'package/oh-package.json5', 'package/Index.d.ets', 'package/src/main/module.json',
  'package/README.md', 'package/CHANGELOG.md', 'package/LICENSE', 'package/README.OpenSource'
]);

export async function inspectHar(file, expected, expectedExports, moduleDefinition) {
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
      if (!/^package\/(?:[^/]+|ets\/(?:modules\.abc|sourceMaps\.map)|src\/main\/module\.json|src\/main\/ets\/.+\.d\.(?:ets|ts))$/.test(path) ||
        /(?:^|\/)(?:\.ohpmrc|\.npmrc|local\.properties|src\/test|src\/mock)(?:\/|$)/.test(path) ||
        /\.(?:p12|pfx|p7b|jks|keystore|cer)$/i.test(path)) {
        return fail(`Unexpected file in the release HAR: ${path}`);
      }
      const hash = createSha256();
      const chunks = [];
      const declarationText = /\.d\.(?:ets|ts)$/.test(path);
      const collectText = (TEXT_FILES.has(path) || declarationText) &&
        entry.size <= 1024 * 1024;
      if ((TEXT_FILES.has(path) || declarationText) && !collectText) {
        return fail(`Oversized package metadata: ${path}`);
      }
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
  const pendingDeclarations = ['package/Index.d.ets'];
  const visitedDeclarations = new Set();
  while (pendingDeclarations.length > 0) {
    const declaration = pendingDeclarations.shift();
    if (visitedDeclarations.has(declaration)) continue;
    visitedDeclarations.add(declaration);
    for (const specifier of importSpecifiers(text(declaration))) {
      if (Object.hasOwn(manifest.dependencies ?? {}, specifier)) continue;
      if (!specifier.startsWith('.')) {
        throw new Error(`Unresolved packaged public declaration: ${specifier}`);
      }
      const base = posix.normalize(posix.join(posix.dirname(declaration), specifier));
      const exactDeclaration = /\.(?:d\.ets|d\.ts)$/.test(base);
      const runtimeDeclaration = base.match(/\.(?:cjs|mjs|js)$/);
      const candidates = exactDeclaration ? [base] :
        runtimeDeclaration ? [
          base.replace(runtimeDeclaration[0], '.d.ts'),
          base.replace(runtimeDeclaration[0], '.d.ets')
        ] : [
          `${base}.d.ets`,
          `${base}.d.ts`,
          posix.join(base, 'Index.d.ets'),
          posix.join(base, 'Index.d.ts')
        ];
      const target = candidates.find((candidate) =>
        candidate.startsWith('package/') && entries.has(candidate));
      if (target === undefined) {
        throw new Error(`Unresolved packaged public declaration: ${specifier}`);
      }
      if (!visitedDeclarations.has(target)) {
        pendingDeclarations.push(target);
      }
    }
  }
  for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) text(`package/${name}`);
  const module = JSON5.parse(text('package/src/main/module.json')).module;
  const permissionNames = (definition) =>
    (definition.requestPermissions ?? []).map((permission) => permission.name).sort();
  if (!/^[a-z][a-z0-9_-]*$/.test(module.name ?? '') || module.type !== 'har' ||
    (moduleDefinition !== undefined && (module.name !== moduleDefinition.name ||
      JSON.stringify(permissionNames(module)) !== JSON.stringify(permissionNames(moduleDefinition))))) {
    throw new Error('Packaged module identity or permission declarations differ from the source module.');
  }
  return { manifest, entries, publicExports: actualExports };
}
