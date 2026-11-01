import { createHash } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';

const EOCD = 0x06054b50;
const CENTRAL = 0x02014b50;
const LOCAL = 0x04034b50;
const MAX_ENTRIES = 4096;
const MAX_ENTRY_BYTES = 64 * 1024 * 1024;
const MAX_TOTAL_BYTES = 128 * 1024 * 1024;

function findEnd(bytes) {
  const start = Math.max(0, bytes.length - 65557);
  for (let offset = bytes.length - 22; offset >= start; offset--) {
    if (bytes.readUInt32LE(offset) === EOCD &&
      offset + 22 + bytes.readUInt16LE(offset + 20) === bytes.length) return offset;
  }
  throw new Error('HAP ZIP end record is missing or malformed.');
}

function entryName(bytes, flags) {
  if ((flags & 0x0800) === 0 && bytes.some((value) => value > 0x7f)) {
    throw new Error('HAP entry names must be UTF-8 or ASCII.');
  }
  const name = bytes.toString('utf8');
  if (Buffer.from(name, 'utf8').compare(bytes) !== 0 || name.length === 0 ||
    name.startsWith('/') || /^[A-Za-z]:/.test(name) || name.includes('\\') ||
    name.includes('\0') || name.split('/').some((part) => part === '.' || part === '..')) {
    throw new Error(`Unsafe HAP entry name: ${name}`);
  }
  return { name, nameBytes: Buffer.from(bytes) };
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

function decodeEntry(archive, entry) {
  const offset = entry.localOffset;
  if (offset < 0 || offset + 30 > archive.length || archive.readUInt32LE(offset) !== LOCAL) {
    throw new Error(`HAP local entry is missing: ${entry.name}`);
  }
  const flags = archive.readUInt16LE(offset + 6);
  const method = archive.readUInt16LE(offset + 8);
  const checksum = archive.readUInt32LE(offset + 14);
  const compressedSize = archive.readUInt32LE(offset + 18);
  const uncompressedSize = archive.readUInt32LE(offset + 22);
  const nameLength = archive.readUInt16LE(offset + 26);
  const extraLength = archive.readUInt16LE(offset + 28);
  const nameStart = offset + 30;
  const dataStart = nameStart + nameLength + extraLength;
  const localName = entryName(archive.subarray(nameStart, nameStart + nameLength), flags);
  if (dataStart + entry.compressedSize > archive.length ||
    Buffer.compare(localName.nameBytes, entry.nameBytes) !== 0 ||
    flags !== entry.flags || method !== entry.method ||
    checksum !== entry.checksum || compressedSize !== entry.compressedSize ||
    uncompressedSize !== entry.uncompressedSize) {
    throw new Error(`HAP local/central entry identity differs: ${entry.name}`);
  }
  const compressed = archive.subarray(dataStart, dataStart + entry.compressedSize);
  let content;
  if (method === 0) content = Buffer.from(compressed);
  else if (method === 8) content = inflateRawSync(compressed, { maxOutputLength: MAX_ENTRY_BYTES });
  else throw new Error(`Unsupported HAP compression method ${method}: ${entry.name}`);
  if (content.length !== entry.uncompressedSize) {
    throw new Error(`HAP entry size differs after decompression: ${entry.name}`);
  }
  if (crc32(content) !== entry.checksum) {
    throw new Error(`HAP entry CRC-32 differs from its uncompressed content: ${entry.name}`);
  }
  return content;
}

function fingerprint(input, prefix, excludeSigningMetadata) {
  const bytes = Buffer.isBuffer(input) ? input : Buffer.from(input);
  const end = findEnd(bytes);
  if (bytes.readUInt16LE(end + 4) !== 0 || bytes.readUInt16LE(end + 6) !== 0) {
    throw new Error('Multi-disk HAP ZIP files are unsupported.');
  }
  const entries = bytes.readUInt16LE(end + 10);
  const centralSize = bytes.readUInt32LE(end + 12);
  const centralOffset = bytes.readUInt32LE(end + 16);
  if (entries <= 0 || entries > MAX_ENTRIES || entries === 0xffff ||
    centralSize === 0xffffffff || centralOffset === 0xffffffff ||
    centralOffset + centralSize !== end) {
    throw new Error('HAP ZIP central directory is invalid or oversized.');
  }
  const records = [];
  const byteNames = new Set();
  const portableNames = new Set();
  let offset = centralOffset;
  let total = 0;
  for (let index = 0; index < entries; index++) {
    if (offset + 46 > end || bytes.readUInt32LE(offset) !== CENTRAL) {
      throw new Error('HAP ZIP central entry is missing or truncated.');
    }
    const flags = bytes.readUInt16LE(offset + 8);
    const method = bytes.readUInt16LE(offset + 10);
    const checksum = bytes.readUInt32LE(offset + 16);
    const compressedSize = bytes.readUInt32LE(offset + 20);
    const uncompressedSize = bytes.readUInt32LE(offset + 24);
    const nameLength = bytes.readUInt16LE(offset + 28);
    const extraLength = bytes.readUInt16LE(offset + 30);
    const commentLength = bytes.readUInt16LE(offset + 32);
    const disk = bytes.readUInt16LE(offset + 34);
    const localOffset = bytes.readUInt32LE(offset + 42);
    const recordEnd = offset + 46 + nameLength + extraLength + commentLength;
    if (recordEnd > end || disk !== 0 || (flags & ~0x0806) !== 0 ||
      compressedSize === 0xffffffff || uncompressedSize === 0xffffffff ||
      uncompressedSize > MAX_ENTRY_BYTES) {
      throw new Error('HAP ZIP entry uses encryption, data descriptors, ZIP64, unsupported flags, or oversized data.');
    }
    const entryIdentity = entryName(bytes.subarray(offset + 46, offset + 46 + nameLength), flags);
    const byteKey = entryIdentity.nameBytes.toString('hex');
    const portableKey = entryIdentity.name.toLowerCase();
    if (byteNames.has(byteKey) || portableNames.has(portableKey)) {
      throw new Error(`Duplicate or portable-name-colliding HAP entry: ${entryIdentity.name}`);
    }
    byteNames.add(byteKey);
    portableNames.add(portableKey);
    total += uncompressedSize;
    if (total > MAX_TOTAL_BYTES) throw new Error('HAP uncompressed content exceeds its bound.');
    records.push({
      ...entryIdentity, flags, method, checksum, compressedSize, uncompressedSize, localOffset
    });
    offset = recordEnd;
  }
  if (offset !== end) throw new Error('HAP ZIP central directory has trailing records.');
  const hash = createHash('sha256').update(`${prefix}\0`);
  let included = 0;
  for (const entry of records.sort((left, right) => Buffer.compare(left.nameBytes, right.nameBytes))) {
    const content = decodeEntry(bytes, entry);
    if (excludeSigningMetadata &&
      (entry.name === 'META-INF/' || entry.name.startsWith('META-INF/'))) {
      continue;
    }
    included++;
    const metadata = Buffer.alloc(13);
    metadata.writeUInt32BE(entry.nameBytes.length, 0);
    metadata.writeUInt32BE(content.length, 4);
    metadata.writeUInt8(entry.name.endsWith('/') ? 1 : 0, 8);
    metadata.writeUInt32BE(content.length, 9);
    hash.update(metadata).update(entry.nameBytes).update(content);
  }
  if (included === 0) throw new Error('HAP has no application content entries.');
  return hash.digest('hex');
}

export function hapContentFingerprint(input) {
  return fingerprint(input, 'arkdb-hap-content-v1', false);
}

export function hapSigningContentFingerprint(input) {
  return fingerprint(input, 'arkdb-hap-signing-content-v1', true);
}
