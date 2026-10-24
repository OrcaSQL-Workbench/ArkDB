import { ArkDbError } from '@arkdb/core';
import { utf8Encode } from './Charsets';

/**
 * Builds a packet payload (little-endian). Accumulates into a number[] and emits a
 * Uint8Array; the framing layer prepends the 4-byte header.
 */
export class PacketWriter {
  private bytes: number[] = [];

  get length(): number {
    return this.bytes.length;
  }

  writeUInt8(v: number): PacketWriter {
    this.bytes.push(v & 0xff);
    return this;
  }

  writeUInt16(v: number): PacketWriter {
    this.bytes.push(v & 0xff);
    this.bytes.push((v >>> 8) & 0xff);
    return this;
  }

  writeUInt24(v: number): PacketWriter {
    this.bytes.push(v & 0xff);
    this.bytes.push((v >>> 8) & 0xff);
    this.bytes.push((v >>> 16) & 0xff);
    return this;
  }

  writeUInt32(v: number): PacketWriter {
    this.bytes.push(v & 0xff);
    this.bytes.push((v >>> 8) & 0xff);
    this.bytes.push((v >>> 16) & 0xff);
    this.bytes.push((v >>> 24) & 0xff);
    return this;
  }

  writeInt32(v: number): PacketWriter {
    if (!Number.isInteger(v) || v < -2147483648 || v > 2147483647) {
      throw ArkDbError.validation('Int32 must be an integer in the signed 32-bit range');
    }
    return this.writeUInt32(v);
  }

  writeInt64(v: bigint): PacketWriter {
    if (typeof v !== 'bigint' || v < -9223372036854775808n || v > 9223372036854775807n) {
      throw ArkDbError.validation('Int64 must be a bigint in the signed 64-bit range');
    }
    return this.writeUInt64(v < 0n ? v + 0x10000000000000000n : v);
  }

  writeUInt64(v: bigint): PacketWriter {
    if (typeof v !== 'bigint' || v < 0n || v > 18446744073709551615n) {
      throw ArkDbError.validation('UInt64 must be a bigint in the unsigned 64-bit range');
    }
    let remaining = v;
    for (let index = 0; index < 8; index += 1) {
      this.bytes.push(Number(remaining & 0xffn));
      remaining >>= 8n;
    }
    return this;
  }

  writeFloat64(v: number): PacketWriter {
    if (!Number.isFinite(v)) {
      throw ArkDbError.validation('Float64 must be finite');
    }
    const bytes = new Uint8Array(8);
    new DataView(bytes.buffer).setFloat64(0, v, true);
    return this.writeBytes(bytes);
  }

  /** Fill n zero bytes (e.g. the 23-byte filler in HandshakeResponse41). */
  writeZeroes(n: number): PacketWriter {
    for (let i = 0; i < n; i++) {
      this.bytes.push(0);
    }
    return this;
  }

  writeBytes(data: Uint8Array): PacketWriter {
    for (let i = 0; i < data.length; i++) {
      this.bytes.push(data[i]);
    }
    return this;
  }

  writeLenEncInt(v: number): PacketWriter {
    if (v < 0xfb) {
      this.writeUInt8(v);
    } else if (v <= 0xffff) {
      this.writeUInt8(0xfc);
      this.writeUInt16(v);
    } else if (v <= 0xffffff) {
      this.writeUInt8(0xfd);
      this.writeUInt24(v);
    } else {
      this.writeUInt8(0xfe);
      this.writeUInt32(v >>> 0);
      this.writeUInt32(Math.floor(v / 0x100000000));
    }
    return this;
  }

  writeLenEncBytes(data: Uint8Array): PacketWriter {
    this.writeLenEncInt(data.length);
    this.writeBytes(data);
    return this;
  }

  writeString(s: string): PacketWriter {
    return this.writeBytes(utf8Encode(s));
  }

  writeNulString(s: string): PacketWriter {
    this.writeBytes(utf8Encode(s));
    this.writeUInt8(0x00);
    return this;
  }

  writeLenEncString(s: string): PacketWriter {
    return this.writeLenEncBytes(utf8Encode(s));
  }

  toUint8Array(): Uint8Array {
    return new Uint8Array(this.bytes);
  }
}
