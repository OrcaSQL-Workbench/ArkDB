import { ArkDbError } from '@arkdb/core';
import { PostgresByteReader } from './PostgresByteCodec';
import {
  MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_LENGTH_BYTES, POSTGRES_NORMAL_HEADER_BYTES
} from './PostgresProtocolConstants';

export interface PostgresByteTransport {
  /** Returns 1..maximumBytes owned bytes, or null at end of stream. */
  read(maximumBytes: number): Promise<Uint8Array | null>;
  write(data: Uint8Array): Promise<number>;
}

export interface PostgresMessage {
  type: number;
  payload: Uint8Array;
}

export class PostgresMessageChannel {
  private readonly transport: PostgresByteTransport;
  private synchronized: boolean = true;
  private active: boolean = false;

  constructor(transport: PostgresByteTransport) { this.transport = transport; }

  readMessage(): Promise<PostgresMessage> {
    return this.runExclusive(async (): Promise<PostgresMessage> => {
      const reader = new PostgresByteReader(
        await this.readExact(POSTGRES_NORMAL_HEADER_BYTES), POSTGRES_NORMAL_HEADER_BYTES);
      const type = reader.readUInt8();
      const length = reader.readInt32();
      if (length < POSTGRES_LENGTH_BYTES || length > MAX_POSTGRES_MESSAGE_BYTES) {
        throw this.failure('Invalid PostgreSQL message length');
      }
      return { type: type, payload: await this.readExact(length - POSTGRES_LENGTH_BYTES) };
    });
  }

  writeMessage(type: number, payload: Uint8Array): Promise<void> {
    return this.runExclusive(async (): Promise<void> => {
      if (!Number.isInteger(type) || type < 0 || type > 255) {
        throw ArkDbError.validation('PostgreSQL message type must be one byte');
      }
      this.requirePayload(payload);
      const frame = new Uint8Array(payload.length + POSTGRES_NORMAL_HEADER_BYTES);
      frame[0] = type;
      new DataView(frame.buffer).setInt32(1, payload.length + POSTGRES_LENGTH_BYTES, false);
      frame.set(payload, POSTGRES_NORMAL_HEADER_BYTES);
      await this.writeExact(frame);
    });
  }

  writeUntypedMessage(payload: Uint8Array): Promise<void> {
    return this.runExclusive(async (): Promise<void> => {
      this.requirePayload(payload);
      const frame = new Uint8Array(payload.length + POSTGRES_LENGTH_BYTES);
      new DataView(frame.buffer).setInt32(0, payload.length + POSTGRES_LENGTH_BYTES, false);
      frame.set(payload, POSTGRES_LENGTH_BYTES);
      await this.writeExact(frame);
    });
  }

  private requirePayload(payload: Uint8Array): void {
    if (payload.length > MAX_POSTGRES_MESSAGE_BYTES - POSTGRES_LENGTH_BYTES) {
      throw ArkDbError.validation('PostgreSQL message exceeds the client limit');
    }
  }

  private async readExact(length: number): Promise<Uint8Array> {
    if (!Number.isSafeInteger(length) || length < 0 || length > MAX_POSTGRES_MESSAGE_BYTES) {
      throw this.failure('Invalid PostgreSQL exact read length');
    }
    const output = new Uint8Array(length);
    let offset = 0;
    while (offset < length) {
      let chunk: Uint8Array | null = null;
      try {
        chunk = await this.transport.read(length - offset);
      } catch (_error) {
        throw this.failure('PostgreSQL transport read failed');
      }
      if (chunk === null) throw this.failure('PostgreSQL message is truncated');
      if (chunk.length === 0 || chunk.length > length - offset) {
        throw this.failure('PostgreSQL transport returned an invalid chunk');
      }
      output.set(chunk, offset);
      offset += chunk.length;
    }
    return output;
  }

  private async writeExact(frame: Uint8Array): Promise<void> {
    let written: number = -1;
    try {
      written = await this.transport.write(frame);
    } catch (_error) {
      throw this.failure('PostgreSQL transport write failed');
    }
    if (!Number.isSafeInteger(written) || written !== frame.length) {
      throw this.failure('PostgreSQL transport write was incomplete');
    }
  }

  private async runExclusive<T>(operation: () => Promise<T>): Promise<T> {
    this.requireSynchronized();
    if (this.active) throw ArkDbError.protocol('PostgreSQL channel operation overlaps');
    this.active = true;
    try {
      const result = await operation();
      this.requireSynchronized();
      return result;
    } finally {
      this.active = false;
    }
  }

  private requireSynchronized(): void {
    if (!this.synchronized) {
      throw ArkDbError.protocol('PostgreSQL channel synchronization is unknown');
    }
  }

  private failure(message: string): ArkDbError {
    this.synchronized = false;
    return ArkDbError.protocol(message);
  }
}
