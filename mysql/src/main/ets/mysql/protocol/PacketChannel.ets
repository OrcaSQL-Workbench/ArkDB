import { PacketByteTransport } from '../transport/TcpTransport';
import { PacketReader } from './PacketReader';
import { Logger, LogTag, ArkDbError, monotonicNowMs } from '@arkdb/core';

const MAX_FRAME_PAYLOAD_BYTES = 0xffffff;
export const MAX_LOGICAL_PACKET_BYTES: number = 64 * 1024 * 1024;

/** One logical protocol packet: 1-byte sequence id + payload. */
export class MysqlPacket {
  seq: number;
  payload: Uint8Array;

  constructor(seq: number, payload: Uint8Array) {
    this.seq = seq;
    this.payload = payload;
  }

  reader(): PacketReader {
    return new PacketReader(this.payload);
  }
}

export interface MysqlPacketSource {
  readPacket(timeoutMs?: number): Promise<MysqlPacket>;
  runWhileOpen?<T>(operation: () => Promise<T>): Promise<T>;
}

/**
 * MySQL packet framing over a byte-stream transport.
 * Frame = [3-byte LE length][1-byte sequence][payload]. Reassembles 0xFFFFFF-chunked
 * large packets and tracks the running sequence id (reset per command/handshake).
 */
export class PacketChannel implements MysqlPacketSource {
  private transport: PacketByteTransport;
  private maximumLogicalPacketBytes: number;
  private seq: number = 0;

  constructor(transport: PacketByteTransport,
    maximumLogicalPacketBytes: number = MAX_LOGICAL_PACKET_BYTES) {
    if (!Number.isSafeInteger(maximumLogicalPacketBytes) ||
      maximumLogicalPacketBytes < MAX_FRAME_PAYLOAD_BYTES) {
      throw ArkDbError.validation(
        'maximumLogicalPacketBytes must be a safe integer of at least 16777215');
    }
    this.transport = transport;
    this.maximumLogicalPacketBytes = maximumLogicalPacketBytes;
  }

  resetSequence(): void {
    this.seq = 0;
  }

  setSequence(v: number): void {
    this.seq = v & 0xff;
  }

  get sequence(): number {
    return this.seq;
  }

  runWhileOpen<T>(operation: () => Promise<T>): Promise<T> {
    if (this.transport.runWhileOpen !== undefined) {
      return this.transport.runWhileOpen<T>(operation);
    }
    return operation();
  }

  async readPacket(timeoutMs: number = 0): Promise<MysqlPacket> {
    const startedAtMs = monotonicNowMs();
    const header = await this.readBytes(4, timeoutMs, startedAtMs);
    let len = header[0] | (header[1] << 8) | (header[2] << 16);
    const firstSeq = header[3];
    this.assertSequence(firstSeq);
    let logicalLength = this.checkedLogicalLength(0, len);
    let payload = await this.readBytes(len, timeoutMs, startedAtMs);

    // A payload of exactly 0xFFFFFF means more chunks follow; reassemble them.
    if (len === MAX_FRAME_PAYLOAD_BYTES) {
      Logger.d(LogTag.Proto, 'reassembling multi-packet payload seq=' + firstSeq);
    }
    while (len === MAX_FRAME_PAYLOAD_BYTES) {
      const moreHeader = await this.readBytes(4, timeoutMs, startedAtMs);
      const moreLen = moreHeader[0] | (moreHeader[1] << 8) | (moreHeader[2] << 16);
      const moreSeq = moreHeader[3];
      this.assertSequence(moreSeq);
      const nextLogicalLength = this.checkedLogicalLength(logicalLength, moreLen);
      const chunk = await this.readBytes(moreLen, timeoutMs, startedAtMs);
      payload = concat(payload, chunk, nextLogicalLength);
      logicalLength = nextLogicalLength;
      len = moreLen;
    }
    return new MysqlPacket(firstSeq, payload);
  }

  private assertSequence(actual: number): void {
    const expected = this.seq;
    if (actual !== expected) {
      Logger.w(LogTag.Proto, 'packet sequence gap expected=' + expected + ' actual=' + actual);
      throw ArkDbError.protocol('Unexpected packet sequence');
    }
    this.seq = (expected + 1) & 0xff;
  }

  private checkedLogicalLength(currentBytes: number, nextFrameBytes: number): number {
    if (!Number.isSafeInteger(currentBytes) || !Number.isSafeInteger(nextFrameBytes) ||
      currentBytes < 0 || nextFrameBytes < 0 ||
      currentBytes > this.maximumLogicalPacketBytes ||
      nextFrameBytes > this.maximumLogicalPacketBytes - currentBytes) {
      Logger.w(LogTag.Proto, 'logical packet limit current=' + currentBytes +
        ' next=' + nextFrameBytes + ' maximum=' + this.maximumLogicalPacketBytes);
      throw ArkDbError.protocol('Logical packet exceeds client limit');
    }
    return currentBytes + nextFrameBytes;
  }

  private readBytes(length: number, timeoutMs: number, startedAtMs: number): Promise<Uint8Array> {
    if (timeoutMs <= 0) return this.transport.read(length);
    const remaining = timeoutMs - (monotonicNowMs() - startedAtMs);
    if (remaining <= 0) {
      return Promise.reject(ArkDbError.protocol(
        'Truncated result exceeded synchronization drain time budget'));
    }
    return this.transport.read(length, remaining);
  }

  async writePacket(payload: Uint8Array, timeoutMs: number = 0): Promise<void> {
    const startedAtMs = monotonicNowMs();
    if (payload.length < MAX_FRAME_PAYLOAD_BYTES) {
      await this.writeFrame(this.frame(payload, 0, payload.length), timeoutMs, startedAtMs);
      this.seq = (this.seq + 1) & 0xff;
      return;
    }
    // Large payload: split into 0xFFFFFF chunks (rare in v1).
    let offset = 0;
    while (offset < payload.length) {
      const chunkLen = Math.min(MAX_FRAME_PAYLOAD_BYTES, payload.length - offset);
      await this.writeFrame(this.frame(payload, offset, chunkLen), timeoutMs, startedAtMs);
      this.seq = (this.seq + 1) & 0xff;
      offset += chunkLen;
    }
    if (payload.length % MAX_FRAME_PAYLOAD_BYTES === 0) {
      await this.writeFrame(this.frame(payload, 0, 0), timeoutMs, startedAtMs); // trailing empty packet
      this.seq = (this.seq + 1) & 0xff;
    }
  }

  private writeFrame(frame: Uint8Array, timeoutMs: number, startedAtMs: number): Promise<void> {
    if (timeoutMs <= 0) return this.transport.write(frame);
    const remaining = remainingPacketWriteTimeMs(timeoutMs, startedAtMs, monotonicNowMs());
    if (remaining <= 0) {
      return Promise.reject(ArkDbError.protocol(
        'Truncated result exceeded synchronization drain time budget'));
    }
    return this.transport.write(frame, remaining);
  }

  private frame(payload: Uint8Array, offset: number, len: number): Uint8Array {
    const out = new Uint8Array(4 + len);
    out[0] = len & 0xff;
    out[1] = (len >>> 8) & 0xff;
    out[2] = (len >>> 16) & 0xff;
    out[3] = this.seq & 0xff;
    out.set(payload.subarray(offset, offset + len), 4);
    return out;
  }
}

export function remainingPacketWriteTimeMs(timeoutMs: number,
  startedAtMs: number, nowMs: number): number {
  return timeoutMs - (nowMs - startedAtMs);
}

function concat(a: Uint8Array, b: Uint8Array, length: number): Uint8Array {
  const out = new Uint8Array(length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}
