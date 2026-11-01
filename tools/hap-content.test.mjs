import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { deflateRawSync } from 'node:zlib';
import test from 'node:test';
import { hapContentFingerprint } from './hap-content.mjs';

test('two HAP builds with different timestamps and order have one content fingerprint', () => {
  const files = new Map([
    ['module.json', Buffer.from('{"name":"entry"}')],
    ['ets/modules.abc', Buffer.from([1, 2, 3, 4])],
    ['resources.index', Buffer.from('stable content')]
  ]);
  const first = buildHap(files, {
    time: 0x4100, date: 0x579f, reverse: false, stored: new Set(['resources.index'])
  });
  const second = buildHap(files, {
    time: 0x7bde, date: 0x5a21, reverse: true, stored: new Set(['resources.index'])
  });
  assert.notDeepEqual(first, second);
  assert.equal(hapContentFingerprint(first), hapContentFingerprint(second));
});

test('HAP content changes alter the canonical fingerprint', () => {
  const original = buildHap(new Map([['ets/modules.abc', Buffer.from([1, 2, 3])]]),
    { time: 1, date: 1, reverse: false });
  const tampered = buildHap(new Map([['ets/modules.abc', Buffer.from([1, 2, 4])]]),
    { time: 2, date: 2, reverse: false });
  assert.notEqual(hapContentFingerprint(original), hapContentFingerprint(tampered));
});

test('composed and decomposed UTF-8 names sort bytewise independent of archive order', () => {
  const files = new Map([
    ['é.txt', Buffer.from('composed')],
    ['e\u0301.txt', Buffer.from('decomposed')]
  ]);
  const first = buildHap(files, { time: 1, date: 1, reverse: false });
  const second = buildHap(files, { time: 2, date: 2, reverse: true });
  assert.equal(hapContentFingerprint(first), hapContentFingerprint(second));
});

test('duplicate byte names and unsupported data descriptors are rejected', () => {
  const duplicate = buildHapEntries([
    ['same.txt', Buffer.from('first')],
    ['same.txt', Buffer.from('second')]
  ], { time: 1, date: 1 });
  assert.throws(() => hapContentFingerprint(duplicate), /Duplicate|colliding/i);
  const descriptor = buildHap(new Map([['file.txt', Buffer.from('value')]]),
    { time: 1, date: 1, reverse: false });
  descriptor.writeUInt16LE(descriptor.readUInt16LE(6) | 0x0008, 6);
  const central = descriptor.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  descriptor.writeUInt16LE(descriptor.readUInt16LE(central + 8) | 0x0008, central + 8);
  assert.throws(() => hapContentFingerprint(descriptor), /data descriptors|unsupported flags/i);
});

test('a real Hvigor HAP CRC field tamper is rejected', () => {
  const fixture = readFileSync(join(import.meta.dirname, 'test-fixtures', 'mysql-client-real.hap'));
  assert.match(hapContentFingerprint(fixture), /^[0-9a-f]{64}$/);
  const tampered = Buffer.from(fixture);
  const central = tampered.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  assert.ok(central >= 0);
  tampered.writeUInt32LE((tampered.readUInt32LE(central + 16) ^ 1) >>> 0, central + 16);
  assert.throws(() => hapContentFingerprint(tampered), /CRC|local\/central/i);
});

function buildHap(files, options) {
  return buildHapEntries([...files], options);
}

function buildHapEntries(files, { time, date, reverse = false, stored = new Set() }) {
  const entries = [...files].map(([name, content]) => {
    const nameBytes = Buffer.from(name);
    const method = stored.has(name) ? 0 : 8;
    const compressed = method === 0 ? content : deflateRawSync(content);
    return { name, nameBytes, content, compressed, method, crc: crc32(content), localOffset: 0 };
  });
  if (reverse) entries.reverse();
  const locals = [];
  let offset = 0;
  for (const entry of entries) {
    entry.localOffset = offset;
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x0800, 6);
    header.writeUInt16LE(entry.method, 8);
    header.writeUInt16LE(time, 10);
    header.writeUInt16LE(date, 12);
    header.writeUInt32LE(entry.crc, 14);
    header.writeUInt32LE(entry.compressed.length, 18);
    header.writeUInt32LE(entry.content.length, 22);
    header.writeUInt16LE(entry.nameBytes.length, 26);
    locals.push(header, entry.nameBytes, entry.compressed);
    offset += header.length + entry.nameBytes.length + entry.compressed.length;
  }
  const centralOffset = offset;
  const centrals = [];
  for (const entry of entries) {
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE(0x0314, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(0x0800, 8);
    header.writeUInt16LE(entry.method, 10);
    header.writeUInt16LE(time, 12);
    header.writeUInt16LE(date, 14);
    header.writeUInt32LE(entry.crc, 16);
    header.writeUInt32LE(entry.compressed.length, 20);
    header.writeUInt32LE(entry.content.length, 24);
    header.writeUInt16LE(entry.nameBytes.length, 28);
    header.writeUInt32LE(entry.localOffset, 42);
    centrals.push(header, entry.nameBytes);
    offset += header.length + entry.nameBytes.length;
  }
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(offset - centralOffset, 12);
  end.writeUInt32LE(centralOffset, 16);
  return Buffer.concat([...locals, ...centrals, end]);
}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}
