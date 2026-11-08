import { buffer } from '@kit.ArkTS';
import { ArkDbError } from '@arkdb/core';
import { MAX_POSTGRES_MESSAGE_BYTES } from './PostgresProtocolConstants';

export class PostgresByteReader {
  private readonly bytes: Uint8Array;
  private readonly view: DataView;
  private position: number = 0;

  constructor(bytes: Uint8Array, maximumBytes: number = MAX_POSTGRES_MESSAGE_BYTES) {
    requireMaximum(maximumBytes);
    if (bytes.length > maximumBytes) {
      throw ArkDbError.protocol('PostgreSQL byte input exceeds the configured limit');
    }
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  get offset(): number { return this.position; }
  get remaining(): number { return this.bytes.length - this.position; }
  readUInt8(): number { return this.view.getUint8(this.take(1)); }
  readInt8(): number { return this.view.getInt8(this.take(1)); }
  readUInt16(): number { return this.view.getUint16(this.take(2), false); }
  readInt16(): number { return this.view.getInt16(this.take(2), false); }
  readUInt32(): number { return this.view.getUint32(this.take(4), false); }
  readInt32(): number { return this.view.getInt32(this.take(4), false); }

  readUInt64(): bigint {
    const offset = this.take(8);
    return (BigInt(this.view.getUint32(offset, false)) << 32n) |
      BigInt(this.view.getUint32(offset + 4, false));
  }

  readInt64(): bigint {
    const value = this.readUInt64();
    return value >= 0x8000000000000000n ? value - 0x10000000000000000n : value;
  }

  readBytes(length: number): Uint8Array {
    const offset = this.take(length);
    return this.bytes.subarray(offset, offset + length);
  }

  readUtf8(length: number): string {
    const offset = this.checkedOffset(length);
    const value = decodeUtf8(this.bytes.subarray(offset, offset + length));
    this.position += length;
    return value;
  }

  readCString(): string {
    let end = this.position;
    while (end < this.bytes.length && this.bytes[end] !== 0) end += 1;
    if (end === this.bytes.length) {
      throw ArkDbError.protocol('PostgreSQL C string is missing its terminator');
    }
    const value = decodeUtf8(this.bytes.subarray(this.position, end));
    this.position = end + 1;
    return value;
  }

  private take(length: number): number {
    const offset = this.checkedOffset(length);
    this.position += length;
    return offset;
  }

  private checkedOffset(length: number): number {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.remaining) {
      throw ArkDbError.protocol('Invalid or truncated PostgreSQL byte read');
    }
    return this.position;
  }
}

export class PostgresByteWriter {
  private readonly chunks: Uint8Array[] = [];
  private readonly maximumBytes: number;
  private total: number = 0;

  constructor(maximumBytes: number = MAX_POSTGRES_MESSAGE_BYTES) {
    requireMaximum(maximumBytes);
    this.maximumBytes = maximumBytes;
  }

  get length(): number { return this.total; }

  writeUInt8(value: number): PostgresByteWriter {
    return this.writeNumber(value, 0, 255, 1, false, 'UInt8');
  }

  writeInt8(value: number): PostgresByteWriter {
    return this.writeNumber(value, -128, 127, 1, true, 'Int8');
  }

  writeUInt16(value: number): PostgresByteWriter {
    return this.writeNumber(value, 0, 65535, 2, false, 'UInt16');
  }

  writeInt16(value: number): PostgresByteWriter {
    return this.writeNumber(value, -32768, 32767, 2, true, 'Int16');
  }

  writeUInt32(value: number): PostgresByteWriter {
    return this.writeNumber(value, 0, 4294967295, 4, false, 'UInt32');
  }

  writeInt32(value: number): PostgresByteWriter {
    return this.writeNumber(value, -2147483648, 2147483647, 4, true, 'Int32');
  }

  writeUInt64(value: bigint): PostgresByteWriter {
    if (value < 0n || value > 0xffffffffffffffffn) {
      throw ArkDbError.validation('UInt64 is outside the unsigned 64-bit range');
    }
    return this.writeBigInt(value);
  }

  writeInt64(value: bigint): PostgresByteWriter {
    if (value < -0x8000000000000000n || value > 0x7fffffffffffffffn) {
      throw ArkDbError.validation('Int64 is outside the signed 64-bit range');
    }
    return this.writeBigInt(value < 0n ? value + 0x10000000000000000n : value);
  }

  writeBytes(value: Uint8Array): PostgresByteWriter {
    this.reserve(value.length);
    const copy = new Uint8Array(value.length);
    copy.set(value);
    this.store(copy);
    return this;
  }

  writeUtf8(value: string): PostgresByteWriter {
    const length = checkedUtf8Length(value);
    this.reserve(length);
    const encoded = rawUtf8(value);
    if (encoded.length !== length) throw ArkDbError.validation('UTF-8 length mismatch');
    this.store(encoded);
    return this;
  }

  writeCString(value: string): PostgresByteWriter {
    if (value.indexOf('\u0000') >= 0) {
      throw ArkDbError.validation('PostgreSQL C strings cannot contain NUL');
    }
    const length = checkedUtf8Length(value);
    this.reserve(length + 1);
    const encoded = rawUtf8(value);
    if (encoded.length !== length) throw ArkDbError.validation('UTF-8 length mismatch');
    const terminator = new Uint8Array(1);
    this.store(encoded);
    this.store(terminator);
    return this;
  }

  toUint8Array(): Uint8Array {
    const output = new Uint8Array(this.total);
    let offset = 0;
    for (const chunk of this.chunks) {
      output.set(chunk, offset);
      offset += chunk.length;
    }
    return output;
  }

  private writeNumber(value: number, minimum: number, maximum: number,
    width: number, signed: boolean, name: string): PostgresByteWriter {
    if (!Number.isInteger(value) || value < minimum || value > maximum) {
      throw ArkDbError.validation(name + ' is outside its integer range');
    }
    this.reserve(width);
    const bytes = new Uint8Array(width);
    const view = new DataView(bytes.buffer);
    if (width === 1) {
      if (signed) view.setInt8(0, value); else view.setUint8(0, value);
    } else if (width === 2) {
      if (signed) view.setInt16(0, value, false); else view.setUint16(0, value, false);
    } else {
      if (signed) view.setInt32(0, value, false); else view.setUint32(0, value, false);
    }
    this.store(bytes);
    return this;
  }

  private writeBigInt(value: bigint): PostgresByteWriter {
    this.reserve(8);
    const bytes = new Uint8Array(8);
    for (let index = 0; index < 8; index += 1) {
      bytes[index] = Number((value >> BigInt((7 - index) * 8)) & 0xffn);
    }
    this.store(bytes);
    return this;
  }

  private reserve(length: number): void {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.maximumBytes - this.total) {
      throw ArkDbError.validation('PostgreSQL byte output exceeds the configured limit');
    }
  }

  private store(value: Uint8Array): void {
    this.chunks.push(value);
    this.total += value.length;
  }
}

function requireMaximum(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0 || value > MAX_POSTGRES_MESSAGE_BYTES + 1) {
    throw ArkDbError.validation('PostgreSQL byte limit is invalid');
  }
}

function checkedUtf8Length(value: string): number {
  const length = utf8Length(value);
  if (length < 0) throw ArkDbError.validation('String is not valid Unicode for UTF-8 encoding');
  return length;
}

function utf8Length(value: string): number {
  let length = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) length += 1;
    else if (code <= 0x7ff) length += 2;
    else if (code >= 0xD800 && code <= 0xDBFF) {
      if (++index >= value.length) return -1;
      const next = value.charCodeAt(index);
      if (next < 0xDC00 || next > 0xDFFF) return -1;
      length += 4;
    } else if (code >= 0xDC00 && code <= 0xDFFF) return -1;
    else length += 3;
  }
  return length;
}

function decodeUtf8(value: Uint8Array): string {
  const decoded = rawUtf8Text(value);
  if (utf8Length(decoded) < 0 || !sameBytes(value, rawUtf8(decoded))) {
    throw ArkDbError.protocol('PostgreSQL string contains invalid UTF-8');
  }
  return decoded;
}

function rawUtf8(value: string): Uint8Array {
  try {
    const encoded = buffer.from(value, 'utf8');
    const bytes = new Uint8Array(encoded.length);
    encoded.copy(bytes);
    return bytes;
  } catch (_error) {
    throw ArkDbError.validation('UTF-8 encoding failed');
  }
}

function rawUtf8Text(value: Uint8Array): string {
  try {
    return buffer.from(value).toString('utf8');
  } catch (_error) {
    throw ArkDbError.protocol('UTF-8 decoding failed');
  }
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}
