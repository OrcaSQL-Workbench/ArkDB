import { ArkDbError } from '../../core/model/ArkDbError';
import { utf8Decode } from './Charsets';

/**
 * Cursor over a single packet payload. All multi-byte integers are little-endian.
 * Length-encoded helpers follow the MySQL protocol (0xfb = NULL in row context).
 */
export class PacketReader {
  private buf: Uint8Array;
  private view: DataView;
  private pos: number = 0;

  constructor(buf: Uint8Array) {
    this.buf = buf;
    this.view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  }

  get offset(): number {
    return this.pos;
  }

  get remaining(): number {
    return this.buf.length - this.pos;
  }

  hasMore(): boolean {
    return this.pos < this.buf.length;
  }

  peekUInt8(): number {
    return this.view.getUint8(this.pos);
  }

  skip(n: number): void {
    this.pos += n;
  }

  readUInt8(): number {
    const v = this.view.getUint8(this.pos);
    this.pos += 1;
    return v;
  }

  readUInt16(): number {
    const v = this.view.getUint16(this.pos, true);
    this.pos += 2;
    return v;
  }

  readUInt24(): number {
    const b0 = this.buf[this.pos];
    const b1 = this.buf[this.pos + 1];
    const b2 = this.buf[this.pos + 2];
    this.pos += 3;
    return b0 | (b1 << 8) | (b2 << 16);
  }

  readUInt32(): number {
    const v = this.view.getUint32(this.pos, true);
    this.pos += 4;
    return v;
  }

  readUInt64(): bigint {
    const lo = BigInt(this.view.getUint32(this.pos, true));
    const hi = BigInt(this.view.getUint32(this.pos + 4, true));
    this.pos += 8;
    return lo | (hi << 32n);
  }

  /** Length-encoded integer. Returns null only for the 0xfb NULL sentinel. */
  readLenEncInt(): bigint | null {
    const first = this.readUInt8();
    if (first < 0xfb) {
      return BigInt(first);
    }
    if (first === 0xfb) {
      return null;
    }
    if (first === 0xfc) {
      return BigInt(this.readUInt16());
    }
    if (first === 0xfd) {
      return BigInt(this.readUInt24());
    }
    if (first === 0xfe) {
      return this.readUInt64();
    }
    throw ArkDbError.protocol('Invalid length-encoded int prefix 0x' + first.toString(16));
  }

  /** Length-encoded integer known to be non-NULL and within safe JS-number range. */
  readLenEncUInt(): number {
    const v = this.readLenEncInt();
    if (v === null) {
      throw ArkDbError.protocol('Unexpected NULL length-encoded integer');
    }
    return Number(v);
  }

  readBytes(n: number): Uint8Array {
    const out = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }

  /** Length-encoded byte string. null for the NULL sentinel. */
  readLenEncBytes(): Uint8Array | null {
    const len = this.readLenEncInt();
    if (len === null) {
      return null;
    }
    return this.readBytes(Number(len));
  }

  readLenEncString(): string | null {
    const bytes = this.readLenEncBytes();
    return bytes === null ? null : utf8Decode(bytes);
  }

  /** NUL-terminated string (consumes the terminator). */
  readNulString(): string {
    let end = this.pos;
    while (end < this.buf.length && this.buf[end] !== 0x00) {
      end += 1;
    }
    const s = utf8Decode(this.buf.subarray(this.pos, end));
    this.pos = end + 1;
    return s;
  }

  /** Fixed-length string. */
  readFixedString(n: number): string {
    return utf8Decode(this.readBytes(n));
  }

  /** Everything left in the packet, as a UTF-8 string. */
  readEofString(): string {
    const s = utf8Decode(this.buf.subarray(this.pos));
    this.pos = this.buf.length;
    return s;
  }
}
