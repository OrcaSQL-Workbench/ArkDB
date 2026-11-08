import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresByteReader, PostgresByteWriter
} from '../../../main/ets/pgsql/protocol/PostgresByteCodec';
import {
  PostgresByteTransport, PostgresMessageChannel
} from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresProtocolTest(): void {
  describe('PostgresProtocol', () => {
    it('roundTripsSignedAndUnsignedBigEndianWidths', 0, () => {
      const bytes = new PostgresByteWriter()
        .writeUInt8(0xfe).writeInt8(-2)
        .writeUInt16(0x1234).writeInt16(-2)
        .writeUInt32(0x89abcdef).writeInt32(-2)
        .writeUInt64(0x0123456789abcdefn).writeInt64(-2n)
        .toUint8Array();
      assertBytes(bytes, [
        0xfe, 0xfe, 0x12, 0x34, 0xff, 0xfe,
        0x89, 0xab, 0xcd, 0xef, 0xff, 0xff, 0xff, 0xfe,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe
      ]);
      const reader = new PostgresByteReader(bytes);
      expect(reader.readUInt8()).assertEqual(254);
      expect(reader.readInt8()).assertEqual(-2);
      expect(reader.readUInt16()).assertEqual(0x1234);
      expect(reader.readInt16()).assertEqual(-2);
      expect(reader.readUInt32()).assertEqual(0x89abcdef);
      expect(reader.readInt32()).assertEqual(-2);
      expect(reader.readUInt64() === 0x0123456789abcdefn).assertTrue();
      expect(reader.readInt64() === -2n).assertTrue();
      expect(reader.remaining).assertEqual(0);
    });

    it('copiesWriterChunksIntoPreallocatedFrameStorage', 0, () => {
      const frame = new Uint8Array([0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa]);
      new PostgresByteWriter()
        .writeUInt8(0x11)
        .writeUInt16(0x2233)
        .copyTo(frame, 2);
      assertBytes(frame, [0xaa, 0xaa, 0x11, 0x22, 0x33, 0xaa]);
    });

    it('rejectsInvalidWritesAndTruncatedReadsWithoutMutation', 0, () => {
      assertTruncated(1, (reader: PostgresByteReader): void => { reader.readUInt8(); });
      assertTruncated(1, (reader: PostgresByteReader): void => { reader.readInt8(); });
      assertTruncated(2, (reader: PostgresByteReader): void => { reader.readUInt16(); });
      assertTruncated(2, (reader: PostgresByteReader): void => { reader.readInt16(); });
      assertTruncated(4, (reader: PostgresByteReader): void => { reader.readUInt32(); });
      assertTruncated(4, (reader: PostgresByteReader): void => { reader.readInt32(); });
      assertTruncated(8, (reader: PostgresByteReader): void => { reader.readUInt64(); });
      assertTruncated(8, (reader: PostgresByteReader): void => { reader.readInt64(); });
      assertRejectedWrite((writer: PostgresByteWriter): void => { writer.writeUInt8(-1); });
      assertRejectedWrite((writer: PostgresByteWriter): void => { writer.writeInt8(128); });
      assertRejectedWrite((writer: PostgresByteWriter): void => { writer.writeUInt16(65536); });
      assertRejectedWrite((writer: PostgresByteWriter): void => { writer.writeInt16(-32769); });
      assertRejectedWrite((writer: PostgresByteWriter): void => {
        writer.writeUInt32(4294967296);
      });
      assertRejectedWrite((writer: PostgresByteWriter): void => {
        writer.writeInt32(2147483648);
      });
      assertRejectedWrite((writer: PostgresByteWriter): void => { writer.writeUInt64(-1n); });
      assertRejectedWrite((writer: PostgresByteWriter): void => {
        writer.writeInt64(9223372036854775808n);
      });
      assertRejectedWrite((writer: PostgresByteWriter): void => { writer.writeUtf8('é'); }, 1);
      assertRejectedWrite((writer: PostgresByteWriter): void => { writer.writeCString('a'); }, 1);
      assertProtocol((): void => {
        new PostgresByteReader(new Uint8Array(2), 1);
      });
      assertRejectedWrite((writer: PostgresByteWriter): void => {
        writer.writeUInt16(1);
      }, 1);
    });

    it('keepsUtf8AndCStringParsingStrictAndAtomic', 0, () => {
      const bytes = new PostgresByteWriter().writeUtf8('A€').writeCString('pg')
        .toUint8Array();
      assertBytes(bytes, [0x41, 0xe2, 0x82, 0xac, 0x70, 0x67, 0x00]);
      const reader = new PostgresByteReader(bytes);
      expect(reader.readUtf8(4)).assertEqual('A€');
      expect(reader.readCString()).assertEqual('pg');
      expect(reader.remaining).assertEqual(0);

      const invalid = new PostgresByteReader(new Uint8Array([0xc0, 0xaf]));
      assertProtocol((): void => { invalid.readUtf8(2); });
      expect(invalid.offset).assertEqual(0);
      const surrogate = new PostgresByteReader(new Uint8Array([0xed, 0xa0, 0x80]));
      assertProtocol((): void => { surrogate.readUtf8(3); });
      expect(surrogate.offset).assertEqual(0);
      assertProtocol((): void => {
        new PostgresByteReader(new Uint8Array([0x80])).readUtf8(1);
      });
      assertProtocol((): void => {
        new PostgresByteReader(new Uint8Array([0xe2, 0x82])).readUtf8(2);
      });
      const missing = new PostgresByteReader(new Uint8Array([0x61]));
      assertProtocol((): void => { missing.readCString(); });
      expect(missing.offset).assertEqual(0);
      assertRejectedWrite((writer: PostgresByteWriter): void => {
        writer.writeCString('bad\u0000value');
      });
      assertRejectedWrite((writer: PostgresByteWriter): void => {
        writer.writeUtf8(String.fromCharCode(0xD800));
      });
    });

    it('readsEveryHeaderSplitAndOneByteFragmentation', 0, async () => {
      const frame = new Uint8Array([0x44, 0x00, 0x00, 0x00, 0x07, 0xaa, 0xbb, 0xcc]);
      for (let split = 1; split < 5; split += 1) {
        const message = await new PostgresMessageChannel(new ChunkTransport([
          frame.subarray(0, split), frame.subarray(split)
        ])).readMessage();
        expect(message.type).assertEqual(0x44);
        assertBytes(message.payload, [0xaa, 0xbb, 0xcc]);
      }
      const chunks: Uint8Array[] = [];
      for (let index = 0; index < frame.length; index += 1) {
        chunks.push(frame.subarray(index, index + 1));
      }
      assertBytes((await new PostgresMessageChannel(
        new ChunkTransport(chunks)).readMessage()).payload, [0xaa, 0xbb, 0xcc]);
    });

    it('retainsCoalescedFramesForTheNextRead', 0, async () => {
      const transport = new ChunkTransport([new Uint8Array([
        0x41, 0, 0, 0, 5, 0x11,
        0x42, 0, 0, 0, 6, 0x10, 0x20
      ])]);
      const channel = new PostgresMessageChannel(transport);
      const first = await channel.readMessage();
      expect(first.payload.buffer.byteLength).assertEqual(1);
      new Uint8Array(first.payload.buffer)[0] = 0x77;
      const second = await channel.readMessage();
      expect(first.type).assertEqual(0x41);
      assertBytes(first.payload, [0x77]);
      expect(second.type).assertEqual(0x42);
      assertBytes(second.payload, [0x10, 0x20]);
    });

    it('rejectsInvalidAndTruncatedFramesThenFailsClosed', 0, async () => {
      await assertReadFailure([new Uint8Array([0x41, 0xff, 0xff, 0xff, 0xff])]);
      await assertReadFailure([new Uint8Array([0x41, 0, 0, 0, 0])]);
      await assertReadFailure([new Uint8Array([0x41, 0, 0, 0, 3])]);
      const oversized = new ChunkTransport([
        new Uint8Array([0x41, 0x02, 0x00, 0x00, 0x01])
      ]);
      await assertChannelFailsClosed(new PostgresMessageChannel(oversized));
      expect(oversized.readCalls).assertEqual(1);
      await assertReadFailure([new Uint8Array([0x41, 0, 0])]);
      await assertReadFailure([new Uint8Array([0x41, 0, 0, 0, 6, 0xaa])]);
      await assertReadFailure([new Uint8Array(0)]);
    });

    it('acceptsTheExactMessageCap', 0, async () => {
      const wire = new Uint8Array(33554434);
      wire[0] = 0x44;
      wire[1] = 0x02;
      wire[5] = 0x11;
      wire[33554432] = 0x22;
      wire[33554433] = 0x45;
      const channel = new PostgresMessageChannel(new ChunkTransport([wire]));
      const message = await channel.readMessage();
      expect(message.payload.length).assertEqual(33554428);
      expect(message.payload[0]).assertEqual(0x11);
      expect(message.payload[message.payload.length - 1]).assertEqual(0x22);
    });

    it('writesTypedAndUntypedFramesWithExactLengths', 0, async () => {
      const transport = new ChunkTransport();
      const channel = new PostgresMessageChannel(transport);
      await channel.writeMessage(0x51, new Uint8Array([0xaa, 0xbb]));
      await channel.writeUntypedMessage(new Uint8Array([0xcc]));
      assertBytes(transport.writes[0], [0x51, 0, 0, 0, 6, 0xaa, 0xbb]);
      assertBytes(transport.writes[1], [0, 0, 0, 5, 0xcc]);
    });

    it('writesTheExactMessageCapWithoutCapturingTheFrame', 0, async () => {
      const transport = new ChunkTransport();
      transport.captureWrites = false;
      await new PostgresMessageChannel(transport)
        .writeMessage(0x51, new Uint8Array(33554428));
      expect(transport.lastWriteLength).assertEqual(33554433);
      assertBytes(transport.lastWriteHeader, [0x51, 0x02, 0, 0, 0]);
    });

    it('rejectsOversizedAndPartialWritesThenFailsClosed', 0, async () => {
      const untouched = new ChunkTransport();
      const channel = new PostgresMessageChannel(untouched);
      const oversized = await asyncFailure((): Promise<void> =>
        channel.writeMessage(0x51, new Uint8Array(33554429)));
      expect(oversized.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(untouched.writes.length).assertEqual(0);

      const partial = new ChunkTransport();
      partial.writeResult = 3;
      const failed = new PostgresMessageChannel(partial);
      expect((await asyncFailure((): Promise<void> =>
        failed.writeMessage(0x51, new Uint8Array([1])))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFailure((): Promise<void> =>
        failed.writeMessage(-1, new Uint8Array(0)))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(partial.writes.length).assertEqual(1);
    });

    it('failsClosedAfterTransportExceptions', 0, async () => {
      const readFailure = new ChunkTransport();
      readFailure.throwRead = true;
      await assertChannelFailsClosed(new PostgresMessageChannel(readFailure));
      const writeFailure = new ChunkTransport();
      writeFailure.throwWrite = true;
      const channel = new PostgresMessageChannel(writeFailure);
      expect((await asyncFailure((): Promise<void> =>
        channel.writeMessage(0x51, new Uint8Array(0)))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect((await asyncFailure((): Promise<void> =>
        channel.writeUntypedMessage(new Uint8Array(0)))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
    });

    it('rejectsOverlappingOperationsWithoutLosingTheFirstFrame', 0, async () => {
      const channel = new PostgresMessageChannel(new ChunkTransport([
        new Uint8Array([0x41, 0, 0, 0, 4, 0x42, 0, 0, 0, 4])
      ]));
      const first = channel.readMessage();
      expect((await asyncFailure(async (): Promise<void> => {
        await channel.readMessage();
      })).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await first).type).assertEqual(0x41);
      expect((await channel.readMessage()).type).assertEqual(0x42);
    });
  });
}

class ChunkTransport implements PostgresByteTransport {
  readonly writes: Uint8Array[] = [];
  readonly requestedMaximums: number[] = [];
  readCalls: number = 0;
  writeResult: number = -1;
  captureWrites: boolean = true;
  throwRead: boolean = false;
  throwWrite: boolean = false;
  lastWriteLength: number = 0;
  lastWriteHeader: Uint8Array = new Uint8Array(0);
  private readonly chunks: Uint8Array[];
  private index: number = 0;
  private offset: number = 0;

  constructor(chunks: Uint8Array[] = []) {
    this.chunks = chunks;
  }

  async read(maximumBytes: number): Promise<Uint8Array | null> {
    this.readCalls += 1;
    this.requestedMaximums.push(maximumBytes);
    if (this.throwRead) throw ArkDbError.protocol('synthetic read failure');
    if (this.index >= this.chunks.length) return null;
    const chunk = this.chunks[this.index];
    const count = Math.min(maximumBytes, chunk.length - this.offset);
    const value = chunk.subarray(this.offset, this.offset + count);
    this.offset += count;
    if (this.offset === chunk.length) {
      this.index += 1;
      this.offset = 0;
    }
    return value;
  }

  async write(data: Uint8Array): Promise<number> {
    if (this.throwWrite) throw ArkDbError.protocol('synthetic write failure');
    this.lastWriteLength = data.length;
    this.lastWriteHeader = data.slice(0, Math.min(5, data.length));
    if (this.captureWrites) this.writes.push(data);
    return this.writeResult < 0 ? data.length : this.writeResult;
  }
}

async function assertReadFailure(chunks: Uint8Array[]): Promise<void> {
  await assertChannelFailsClosed(new PostgresMessageChannel(new ChunkTransport(chunks)));
}

async function assertChannelFailsClosed(channel: PostgresMessageChannel): Promise<void> {
  expect((await asyncFailure(async (): Promise<void> => {
    await channel.readMessage();
  })).kind).assertEqual(ArkDbErrorKind.Protocol);
  expect((await asyncFailure(async (): Promise<void> => {
    await channel.readMessage();
  })).kind).assertEqual(ArkDbErrorKind.Protocol);
}

async function asyncFailure(operation: () => Promise<void>): Promise<ArkDbError> {
  let failure: ArkDbError | null = null;
  try {
    await operation();
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  return failure!;
}

function assertTruncated(width: number, read: (reader: PostgresByteReader) => void): void {
  for (let length = 0; length < width; length += 1) {
    const reader = new PostgresByteReader(new Uint8Array(length));
    assertProtocol((): void => { read(reader); });
    expect(reader.offset).assertEqual(0);
  }
}

function assertRejectedWrite(write: (writer: PostgresByteWriter) => void,
  maximumBytes: number = 33554432): void {
  const writer = new PostgresByteWriter(maximumBytes);
  let failure: ArkDbError | null = null;
  try {
    write(writer);
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
  expect(writer.length).assertEqual(0);
}

function assertProtocol(action: () => void): void {
  let failure: ArkDbError | null = null;
  try {
    action();
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
