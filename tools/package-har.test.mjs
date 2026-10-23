import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { create, Header, Parser } from 'tar';
import { gzipSync } from 'node:zlib';
import { randomFillSync } from 'node:crypto';
import { inspectHar, sha256, sourceFingerprint } from './package-har.mjs';

const expected = { name: '@arkdb/mysql', version: '1.0.0', license: 'Apache-2.0', dependencies: {} };
const fixtureExports = ['SyntheticDeclaration'];

test('inspects the actual bytecode-HAR shape, public declarations and legal files', async (t) => {
  const file = await fixture(t);
  const result = await inspectHar(file, expected, fixtureExports);
  assert.equal(result.manifest.version, expected.version);
  assert.equal(result.publicExports.length, fixtureExports.length);
  assert.ok(result.entries.get('package/README.OpenSource').size > 0);
});

test('rejects debug builds and incompatible bytecode formats', async (t) => {
  const file = await fixture(t, { metadata: { byteCodeHar: true, debug: true, useNormalizedOHMUrl: true } });
  await assert.rejects(inspectHar(file, expected, fixtureExports), /release bytecode HAR/);
});

test('rejects a different package version', async (t) => {
  const file = await fixture(t, { version: '9.9.9' });
  await assert.rejects(inspectHar(file, expected, fixtureExports), /identity/);
});

test('missing license or upstream attribution blocks packaging', async (t) => {
  for (const missing of ['LICENSE', 'README.OpenSource']) {
    const file = await fixture(t, {}, missing);
    await assert.rejects(inspectHar(file, expected, fixtureExports), /Missing or empty HAR file/);
  }
});

test('rejects missing public symbols and unresolved declarations', async (t) => {
  const file = await fixture(t);
  await assert.rejects(inspectHar(file, expected, [...fixtureExports, 'Missing']), /public exports/);
  const unresolved = await fixture(t, {}, 'public.d.ets');
  await assert.rejects(inspectHar(unresolved, expected, fixtureExports), /Unresolved packaged/);
});

test('rejects test fixtures accidentally included in a release', async (t) => {
  const file = await fixture(t, {}, undefined, 'src/test/Private.test.ets');
  await assert.rejects(inspectHar(file, expected, fixtureExports), /Unexpected file/);
});

test('inspects a selected driver module instead of hard-coding MySQL into every HAR', async (t) => {
  const postgres = { ...expected, name: '@arkdb/postgres', version: '2.0.0' };
  const definition = { name: 'pgsql', type: 'har', requestPermissions: [] };
  const file = await fixture(t, postgres, undefined, undefined, definition);
  const inspected = await inspectHar(file, postgres, fixtureExports, definition);
  assert.equal(inspected.manifest.name, postgres.name);
  await assert.rejects(inspectHar(file, postgres, fixtureExports), /module identity/);
});

test('source fingerprints and artifact digests are stable full SHA-256 identities', () => {
  assert.equal(sourceFingerprint(), sourceFingerprint());
  assert.match(sourceFingerprint(), /^[0-9a-f]{64}$/);
  assert.equal(sha256(Buffer.from('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('entry-count limits abort the real parser before subsequent entries are consumed', async (t) => {
  const observed = watchParser(t);
  const records = [];
  for (let index = 0; index < 1100; index++) {
    records.push(tarHeader(`package/src/main/ets/limit-${index}.d.ets`, 0));
  }
  records.push(Buffer.alloc(1024));
  const file = await rawArchive(t, Buffer.concat(records));
  await assert.rejects(inspectHar(file, expected, fixtureExports), /entry|entries|bound/i);
  assert.ok(observed.entries <= 1025, `Parser consumed ${observed.entries} entries after its 1024-entry limit.`);
});

test('an excessive declared payload is rejected before its body is decompressed and hashed', async (t) => {
  const observed = watchParser(t);
  const block = Buffer.alloc(64 * 1024);
  randomFillSync(block.subarray(0, 1024));
  const body = Buffer.alloc(65 * 1024 * 1024);
  for (let offset = 0; offset < body.length; offset += block.length) block.copy(body, offset);
  const file = await rawArchive(t, Buffer.concat([
    tarHeader('package/ets/modules.abc', body.length), body, Buffer.alloc(1024)
  ]));
  await assert.rejects(inspectHar(file, expected, fixtureExports), /unpacked|expanded|size bound/i);
  assert.equal(observed.bodyBytes, 0, 'The oversized entry body must not be processed after its header is rejected.');
});

function watchParser(t) {
  const observed = { entries: 0, bodyBytes: 0 };
  const emit = Parser.prototype.emit;
  t.mock.method(Parser.prototype, 'emit', function (event, ...args) {
    if (event === 'entry') {
      observed.entries++;
      args[0].on('data', (chunk) => { observed.bodyBytes += chunk.length; });
    }
    return Reflect.apply(emit, this, [event, ...args]);
  });
  return observed;
}

function tarHeader(path, size) {
  const header = new Header({ path, size, mode: 0o644, type: 'File', mtime: new Date(0) });
  header.encode();
  return header.block;
}

async function rawArchive(t, bytes) {
  const directory = await mkdtemp(join(tmpdir(), 'arkdb-limit-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'limit.har');
  await writeFile(file, gzipSync(bytes, { level: 1 }));
  return file;
}

async function fixture(t, overrides = {}, missing, extra, definition = {
  name: 'mysql', type: 'har', requestPermissions: [{ name: 'ohos.permission.INTERNET' }]
}) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-har-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const files = {
    'oh-package.json5': JSON.stringify({
      ...expected, types: 'Index.d.ets', compatibleSdkVersion: 24, compatibleSdkType: 'HarmonyOS',
      metadata: { byteCodeHar: true, debug: false, useNormalizedOHMUrl: true }, ...overrides
    }),
    'Index.d.ets': `export { ${fixtureExports.join(', ')} } from './public';\n`,
    'public.d.ets': 'export declare class SyntheticDeclaration {}\n',
    'src/main/module.json': JSON.stringify({ module: definition }),
    'ets/modules.abc': 'Synthetic bytecode fixture, not an executable module.',
    'README.md': 'Synthetic readme', 'CHANGELOG.md': 'Synthetic changelog',
    LICENSE: 'Synthetic license', 'README.OpenSource': 'Synthetic upstream notice'
  };
  if (extra) files[extra] = 'Must not be published';
  for (const [name, contents] of Object.entries(files)) {
    if (name === missing) continue;
    const path = join(root, 'package', name);
    await mkdir(join(path, '..'), { recursive: true });
    await writeFile(path, contents);
  }
  const file = join(root, 'fixture.har');
  await create({ file, cwd: root, gzip: true, portable: true }, ['package']);
  return file;
}
