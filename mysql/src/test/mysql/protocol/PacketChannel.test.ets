import { describe, it, expect } from '@ohos/hypium';
import { Logger, LogLevel, LogSink, ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { MAX_LOGICAL_PACKET_BYTES, PacketChannel } from '../../../main/ets/mysql/protocol/PacketChannel';
import { PacketTransportFixture } from './PacketTransportFixture';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { socket } from '../../../mock/NetworkKit.mock';

const MAX_FRAME_PAYLOAD = 0xffffff;

class RecordingLogSink implements LogSink {
  messages: string[] = [];

  write(level: LogLevel, tag: string, message: string, timestampMs: number): void {
    this.messages.push(message);
  }
}

export default function packetChannelTest(): void {
  describe('PacketChannel', () => {
    it('readsCoalescedPacketsAcrossEverySocketDeliverySplit', 0, async () => {
      const frames = new Uint8Array([3, 0, 0, 0, 0xaa, 0xbb, 0xcc, 2, 0, 0, 1, 0xdd, 0xee]);
      for (let split = 1; split < frames.length; split++) {
        const transport = new TcpTransport(null, 32);
        await transport.connect('synthetic.invalid', 3306, 1000);
        try {
          const channel = new PacketChannel(transport);
          const first = channel.readPacket(100);
          socket.latestTcp!.emitMessage(frames.subarray(0, split));
          socket.latestTcp!.emitMessage(frames.subarray(split));
          assertBytes((await first).payload, [0xaa, 0xbb, 0xcc]);
          assertBytes((await channel.readPacket(100)).payload, [0xdd, 0xee]);
        } finally {
          await transport.close();
        }
      }
    });

    it('readsAnExact64MiBLogicalPacketThroughTheBoundedTransport', 0, async () => {
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      try {
        const channel = new PacketChannel(transport);
        const pending = channel.readPacket(5000);
        for (let sequence = 0; sequence < 4; sequence++) {
          const frame = fullFrameWithSequence(sequence);
          frame[4] = sequence + 1;
          frame[frame.length - 1] = sequence + 11;
          peer.emitMessage(frame.subarray(0, 3));
          peer.emitMessage(frame.subarray(3));
          await nextTask();
        }
        peer.emitMessage(new Uint8Array([4, 0, 0, 4, 0xaa, 0xbb, 0xcc, 0xdd]));
        const packet = await pending;
        expect(packet.payload.length).assertEqual(64 * 1024 * 1024);
        for (let sequence = 0; sequence < 4; sequence++) {
          expect(packet.payload[sequence * MAX_FRAME_PAYLOAD]).assertEqual(sequence + 1);
          expect(packet.payload[(sequence + 1) * MAX_FRAME_PAYLOAD - 1]).assertEqual(sequence + 11);
        }
        expect(packet.payload[packet.payload.length - 4]).assertEqual(0xaa);
        expect(packet.payload[packet.payload.length - 1]).assertEqual(0xdd);
        expect(channel.sequence).assertEqual(5);
        expect(peer.closeCalls).assertEqual(0);
      } finally {
        await transport.close();
      }
    });

    it('rejectsLogicalOverflowBeforeConsumingItsSocketBufferedPayload', 0, async () => {
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      try {
        const channel = new PacketChannel(transport, MAX_FRAME_PAYLOAD);
        const pending = channel.readPacket(5000).then((): ArkDbError | null => null,
          (caught: Object): ArkDbError | null => caught as ArkDbError);
        peer.emitMessage(fullFrameWithSequence(0));
        await nextTask();
        peer.emitMessage(new Uint8Array([1, 0, 0, 1, 0xa5]));
        const error = await pending;
        expect(error !== null).assertTrue();
        expect(error!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(error!.message).assertEqual('Logical packet exceeds client limit');
        assertBytes(await transport.read(1, 100), [0xa5]);
      } finally {
        await transport.close();
      }
    });

    it('reassemblesEverySmallFrameSplitBoundary', 0, async () => {
      const frame = new Uint8Array([0x03, 0x00, 0x00, 0x07, 0xaa, 0xbb, 0xcc]);
      for (let split = 1; split < frame.length; split += 1) {
        await assertReadFrame([
          frame.subarray(0, split),
          frame.subarray(split)
        ]);
      }

      const oneByteChunks: Uint8Array[] = [];
      for (let index = 0; index < frame.length; index += 1) {
        oneByteChunks.push(frame.subarray(index, index + 1));
      }
      await assertReadFrame(oneByteChunks);
    });

    it('resetsAndWrapsThePacketSequence', 0, async () => {
      const transport = new PacketTransportFixture();
      const channel = new PacketChannel(transport);
      channel.setSequence(42);
      channel.resetSequence();
      expect(channel.sequence).assertEqual(0);

      channel.setSequence(255);
      await channel.writePacket(new Uint8Array(0));
      expect(transport.writes.length).assertEqual(1);
      expect(transport.writes[0][3]).assertEqual(255);
      expect(channel.sequence).assertEqual(0);
    });

    it('incrementsSequenceOncePerWrittenFrame', 0, async () => {
      const transport = new PacketTransportFixture();
      const channel = new PacketChannel(transport);
      await channel.writePacket(new Uint8Array([0xaa]));
      await channel.writePacket(new Uint8Array([0xbb]));

      expect(transport.writes.length).assertEqual(2);
      expect(transport.writes[0][3]).assertEqual(0);
      expect(transport.writes[1][3]).assertEqual(1);
      expect(channel.sequence).assertEqual(2);
    });

    it('writesEmptyAndOneBytePayloadsAsSingleFrames', 0, async () => {
      await assertSingleFrameWrite(new Uint8Array(0), 0);
      await assertSingleFrameWrite(new Uint8Array([0xa5]), 1);
    });

    it('writesTheLargestShortPayloadAsOneFrame', 0, async () => {
      const payload = boundaryPayload(MAX_FRAME_PAYLOAD - 1);
      const transport = new PacketTransportFixture();
      const channel = new PacketChannel(transport);
      await channel.writePacket(payload);

      expect(transport.writes.length).assertEqual(1);
      assertFrame(transport.writes[0], MAX_FRAME_PAYLOAD - 1, 0, 0x11, 0x22);
      expect(channel.sequence).assertEqual(1);
    });

    it('terminatesAnExactFullPayloadWithAnEmptyFrame', 0, async () => {
      const payload = boundaryPayload(MAX_FRAME_PAYLOAD);
      const transport = new PacketTransportFixture();
      const channel = new PacketChannel(transport);
      await channel.writePacket(payload);

      expect(transport.writes.length).assertEqual(2);
      assertFrame(transport.writes[0], MAX_FRAME_PAYLOAD, 0, 0x11, 0x22);
      assertBytes(transport.writes[1], [0x00, 0x00, 0x00, 0x01]);
      expect(channel.sequence).assertEqual(2);
    });

    it('splitsA16MiBPayloadIntoAFullAndOneByteFrame', 0, async () => {
      const payload = boundaryPayload(MAX_FRAME_PAYLOAD + 1);
      payload[MAX_FRAME_PAYLOAD] = 0x33;
      const transport = new PacketTransportFixture();
      const channel = new PacketChannel(transport);
      await channel.writePacket(payload);

      expect(transport.writes.length).assertEqual(2);
      assertFrame(transport.writes[0], MAX_FRAME_PAYLOAD, 0, 0x11, 0x00);
      assertBytes(transport.writes[1], [0x01, 0x00, 0x00, 0x01, 0x33]);
      expect(channel.sequence).assertEqual(2);
    });

    it('reassemblesAFragmentedFullContinuationAndTracksItsLastSequence', 0, async () => {
      const fullFrame = new Uint8Array(MAX_FRAME_PAYLOAD + 4);
      fullFrame[0] = 0xff;
      fullFrame[1] = 0xff;
      fullFrame[2] = 0xff;
      fullFrame[3] = 0xfe;
      fullFrame[4] = 0x11;
      fullFrame[fullFrame.length - 1] = 0x22;
      const finalFrame = new Uint8Array([0x03, 0x00, 0x00, 0xff, 0xaa, 0xbb, 0xcc]);
      const transport = new PacketTransportFixture([
        fullFrame.subarray(0, 1),
        fullFrame.subarray(1, 3),
        fullFrame.subarray(3, 5),
        fullFrame.subarray(5, 4097),
        fullFrame.subarray(4097),
        finalFrame.subarray(0, 1),
        finalFrame.subarray(1, 2),
        finalFrame.subarray(2, 3),
        finalFrame.subarray(3, 4),
        finalFrame.subarray(4, 5),
        finalFrame.subarray(5, 6),
        finalFrame.subarray(6)
      ]);
      const channel = new PacketChannel(transport);
      channel.setSequence(254);
      const packet = await channel.readPacket();

      expect(packet.seq).assertEqual(254);
      expect(packet.payload.length).assertEqual(MAX_FRAME_PAYLOAD + 3);
      expect(packet.payload[0]).assertEqual(0x11);
      expect(packet.payload[MAX_FRAME_PAYLOAD - 1]).assertEqual(0x22);
      expect(packet.payload[MAX_FRAME_PAYLOAD]).assertEqual(0xaa);
      expect(packet.payload[MAX_FRAME_PAYLOAD + 1]).assertEqual(0xbb);
      expect(packet.payload[MAX_FRAME_PAYLOAD + 2]).assertEqual(0xcc);
      expect(channel.sequence).assertEqual(0);
      assertNumbers(transport.requestedLengths, [4, MAX_FRAME_PAYLOAD, 4, 3]);
    });

    it('rejectsAnUnexpectedFirstFrameSequenceWithNumericDiagnostics', 0, async () => {
      const sink = new RecordingLogSink();
      const previousLevel = Logger.level;
      Logger.addSink(sink);
      Logger.setLevel(LogLevel.DEBUG);
      const transport = new PacketTransportFixture([
        new Uint8Array([0x01, 0x00, 0x00, 0x01]),
        new Uint8Array([0xaa])
      ]);
      let caught: ArkDbError | null = null;
      try {
        const channel = new PacketChannel(transport);
        try {
          await channel.readPacket();
        } catch (error) {
          caught = error as ArkDbError;
        }
      } finally {
        Logger.removeSink(sink);
        Logger.setLevel(previousLevel);
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
      assertNumbers(transport.requestedLengths, [4]);
      expect(sink.messages.length).assertEqual(1);
      expect(sink.messages[0]).assertEqual(
        'packet sequence gap expected=0 actual=1');
    });

    it('rejectsAContinuationSequenceGapBeforeReadingItsPayload', 0, async () => {
      const fullFrame = fullFrameWithSequence(0);
      const transport = new PacketTransportFixture([
        fullFrame,
        new Uint8Array([0x00, 0x00, 0x00, 0x02])
      ]);
      const channel = new PacketChannel(transport);
      let caught: ArkDbError | null = null;
      try {
        await channel.readPacket();
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
      assertNumbers(transport.requestedLengths, [4, MAX_FRAME_PAYLOAD, 4]);
    });

    it('acceptsAContinuationSequenceThatWrapsFrom255ToZero', 0, async () => {
      const transport = new PacketTransportFixture([
        fullFrameWithSequence(255),
        new Uint8Array([0x00, 0x00, 0x00, 0x00])
      ]);
      const channel = new PacketChannel(transport);
      channel.setSequence(255);
      const packet = await channel.readPacket();

      expect(packet.seq).assertEqual(255);
      expect(packet.payload.length).assertEqual(MAX_FRAME_PAYLOAD);
      expect(channel.sequence).assertEqual(1);
      assertNumbers(transport.requestedLengths, [4, MAX_FRAME_PAYLOAD, 4, 0]);
    });

    it('usesTheDocumentedProductionLogicalPacketLimit', 0, () => {
      expect(MAX_LOGICAL_PACKET_BYTES).assertEqual(64 * 1024 * 1024);
    });

    it('rejectsInvalidLogicalPacketLimits', 0, () => {
      expectInvalidMaximum(0);
      expectInvalidMaximum(-1);
      expectInvalidMaximum(MAX_FRAME_PAYLOAD + 0.5);
      expectInvalidMaximum(MAX_FRAME_PAYLOAD - 1);
    });

    it('acceptsALogicalPayloadExactlyAtTheConfiguredMaximum', 0, async () => {
      const transport = new PacketTransportFixture([
        fullFrameWithSequence(0),
        new Uint8Array([0x00, 0x00, 0x00, 0x01])
      ]);
      const channel = new PacketChannel(transport, MAX_FRAME_PAYLOAD);
      const packet = await channel.readPacket();

      expect(packet.payload.length).assertEqual(MAX_FRAME_PAYLOAD);
      expect(channel.sequence).assertEqual(2);
      assertNumbers(transport.requestedLengths, [4, MAX_FRAME_PAYLOAD, 4, 0]);
    });

    it('rejectsAnOversizedContinuationBeforeReadingItsPayload', 0, async () => {
      const sink = new RecordingLogSink();
      const previousLevel = Logger.level;
      Logger.addSink(sink);
      Logger.setLevel(LogLevel.WARN);
      const transport = new PacketTransportFixture([
        fullFrameWithSequence(0),
        new Uint8Array([0x01, 0x00, 0x00, 0x01]),
        new Uint8Array([0xaa])
      ]);
      let caught: ArkDbError | null = null;
      try {
        const channel = new PacketChannel(transport, MAX_FRAME_PAYLOAD);
        try {
          await channel.readPacket();
        } catch (error) {
          caught = error as ArkDbError;
        }
      } finally {
        Logger.removeSink(sink);
        Logger.setLevel(previousLevel);
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
      assertNumbers(transport.requestedLengths, [4, MAX_FRAME_PAYLOAD, 4]);
      expect(sink.messages.length).assertEqual(1);
      expect(sink.messages[0]).assertEqual(
        'logical packet limit current=16777215 next=1 maximum=16777215');
    });

    it('rejectsWhenFixtureBytesAreExhausted', 0, async () => {
      const channel = new PacketChannel(new PacketTransportFixture([
        new Uint8Array([0x01, 0x00])
      ]));
      let rejected = false;
      try {
        await channel.readPacket();
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}

async function assertReadFrame(chunks: Uint8Array[]): Promise<void> {
  const transport = new PacketTransportFixture(chunks);
  const channel = new PacketChannel(transport);
  channel.setSequence(7);
  const packet = await channel.readPacket();

  expect(packet.seq).assertEqual(7);
  assertBytes(packet.payload, [0xaa, 0xbb, 0xcc]);
  expect(channel.sequence).assertEqual(8);
  assertNumbers(transport.requestedLengths, [4, 3]);
}

function nextTask(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 0);
  });
}

async function assertSingleFrameWrite(payload: Uint8Array, expectedLength: number): Promise<void> {
  const transport = new PacketTransportFixture();
  const channel = new PacketChannel(transport);
  await channel.writePacket(payload);

  expect(transport.writes.length).assertEqual(1);
  expect(transport.writes[0].length).assertEqual(expectedLength + 4);
  expect(transport.writes[0][0]).assertEqual(expectedLength);
  expect(transport.writes[0][1]).assertEqual(0);
  expect(transport.writes[0][2]).assertEqual(0);
  expect(transport.writes[0][3]).assertEqual(0);
  if (expectedLength === 1) expect(transport.writes[0][4]).assertEqual(0xa5);
  expect(channel.sequence).assertEqual(1);
}

function boundaryPayload(length: number): Uint8Array {
  const payload = new Uint8Array(length);
  payload[0] = 0x11;
  payload[length - 1] = 0x22;
  return payload;
}

function fullFrameWithSequence(sequence: number): Uint8Array {
  const frame = new Uint8Array(MAX_FRAME_PAYLOAD + 4);
  frame[0] = 0xff;
  frame[1] = 0xff;
  frame[2] = 0xff;
  frame[3] = sequence;
  frame[4] = 0x11;
  frame[frame.length - 1] = 0x22;
  return frame;
}

function expectInvalidMaximum(maximumLogicalPacketBytes: number): void {
  let caught: ArkDbError | null = null;
  try {
    new PacketChannel(new PacketTransportFixture(), maximumLogicalPacketBytes);
  } catch (error) {
    caught = error as ArkDbError;
  }
  expect(caught !== null).assertTrue();
  expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
}

function assertFrame(frame: Uint8Array, payloadLength: number, sequence: number,
  firstPayloadByte: number, lastPayloadByte: number): void {
  expect(frame.length).assertEqual(payloadLength + 4);
  expect(frame[0]).assertEqual(payloadLength & 0xff);
  expect(frame[1]).assertEqual((payloadLength >>> 8) & 0xff);
  expect(frame[2]).assertEqual((payloadLength >>> 16) & 0xff);
  expect(frame[3]).assertEqual(sequence);
  expect(frame[4]).assertEqual(firstPayloadByte);
  expect(frame[frame.length - 1]).assertEqual(lastPayloadByte);
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function assertNumbers(actual: number[], expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
