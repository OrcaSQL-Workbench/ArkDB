import { ArkDbError } from '@arkdb/core';
import { PacketByteTransport } from '../../../main/ets/mysql/transport/TcpTransport';

export class PacketTransportFixture implements PacketByteTransport {
  readonly requestedLengths: number[] = [];
  readonly requestedTimeouts: number[] = [];
  readonly writes: Uint8Array[] = [];
  readonly writeTimeouts: number[] = [];

  private incomingChunks: Uint8Array[];
  private chunkIndex: number = 0;
  private chunkOffset: number = 0;

  constructor(incomingChunks: Uint8Array[] = []) {
    this.incomingChunks = incomingChunks;
  }

  async read(length: number, timeoutMs: number = 0): Promise<Uint8Array> {
    this.requestedLengths.push(length);
    this.requestedTimeouts.push(timeoutMs);
    if (length < 0) throw ArkDbError.protocol('Fixture read length must not be negative');

    const bytes = new Uint8Array(length);
    let written = 0;
    while (written < length) {
      if (this.chunkIndex >= this.incomingChunks.length) {
        throw ArkDbError.protocol('Packet transport fixture bytes exhausted');
      }
      const chunk = this.incomingChunks[this.chunkIndex];
      const available = chunk.length - this.chunkOffset;
      if (available === 0) {
        this.chunkIndex += 1;
        this.chunkOffset = 0;
        continue;
      }
      const take = Math.min(available, length - written);
      bytes.set(chunk.subarray(this.chunkOffset, this.chunkOffset + take), written);
      written += take;
      this.chunkOffset += take;
    }
    return bytes;
  }

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    const copy = new Uint8Array(data.length);
    copy.set(data);
    this.writes.push(copy);
    this.writeTimeouts.push(timeoutMs);
  }
}
