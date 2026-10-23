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
