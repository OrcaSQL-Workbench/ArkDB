import { describe, it, expect } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';

export default function packetCodecTest(): void {
  describe('PacketReader and PacketWriter', () => {
    it('roundTripsFixedWidthLittleEndianValues', 0, () => {
      const bytes = new PacketWriter()
        .writeUInt8(0xa5)
        .writeUInt16(0x1234)
        .writeUInt24(0x56789a)
        .writeUInt32(0xbcdef012)
        .toUint8Array();
      assertBytes(bytes, [
        0xa5,
        0x34, 0x12,
        0x9a, 0x78, 0x56,
        0x12, 0xf0, 0xde, 0xbc
      ]);

      const reader = new PacketReader(bytes);
      expect(reader.readUInt8()).assertEqual(0xa5);
      expect(reader.readUInt16()).assertEqual(0x1234);
      expect(reader.readUInt24()).assertEqual(0x56789a);
      expect(reader.readUInt32()).assertEqual(0xbcdef012);
      expect(reader.remaining).assertEqual(0);
    });

    it('readsFixedUnsigned64BitLittleEndianValues', 0, () => {
      const reader = new PacketReader(new Uint8Array([
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11
      ]));
      expect(reader.readUInt64() === 0x1122334455667788n).assertTrue();
      expect(reader.remaining).assertEqual(0);
    });

    it('roundTripsLengthEncodedIntegerBoundaries', 0, () => {
      assertLengthEncodedInteger(0, [0x00]);
      assertLengthEncodedInteger(250, [0xfa]);
      assertLengthEncodedInteger(251, [0xfc, 0xfb, 0x00]);
      assertLengthEncodedInteger(65535, [0xfc, 0xff, 0xff]);
      assertLengthEncodedInteger(65536, [0xfd, 0x00, 0x00, 0x01]);
      assertLengthEncodedInteger(16777215, [0xfd, 0xff, 0xff, 0xff]);
      assertLengthEncodedInteger(16777216, [
        0xfe, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00
      ]);
      assertLengthEncodedInteger(4294967296, [
        0xfe, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00
      ]);
    });

    it('keepsNullEmptyAndUtf8mb4StringsDistinct', 0, () => {
      const nullValue = new PacketReader(new Uint8Array([0xfb])).readLenEncBytes();
      expect(nullValue === null).assertTrue();

      const emptyBytes = new PacketWriter().writeLenEncString('').toUint8Array();
      assertBytes(emptyBytes, [0x00]);
      expect(new PacketReader(emptyBytes).readLenEncString()).assertEqual('');

      const ascii = 'OrcaSQL';
      const asciiBytes = new PacketWriter().writeLenEncString(ascii).toUint8Array();
      expect(new PacketReader(asciiBytes).readLenEncString()).assertEqual(ascii);

      const utf8mb4 = '密码🔒';
      const utf8mb4Bytes = new PacketWriter().writeLenEncString(utf8mb4).toUint8Array();
      expect(new PacketReader(utf8mb4Bytes).readLenEncString()).assertEqual(utf8mb4);
    });

    it('readsNulFixedAndEofStringsAtTheirBoundaries', 0, () => {
      const nulBytes = new PacketWriter().writeNulString('server').toUint8Array();
      assertBytes(nulBytes, [0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0x00]);
      expect(new PacketReader(nulBytes).readNulString()).assertEqual('server');

      const reader = new PacketReader(new Uint8Array([
        0x66, 0x69, 0x78, 0x65, 0x64, 0x2d, 0x65, 0x6f, 0x66
      ]));
      expect(reader.readFixedString(5)).assertEqual('fixed');
      expect(reader.readEofString()).assertEqual('-eof');
      expect(reader.remaining).assertEqual(0);
    });

    it('rejectsInvalidLengthEncodedIntegerPrefixes', 0, () => {
      let caught: ArkDbError | null = null;
      try {
        new PacketReader(new Uint8Array([0xff])).readLenEncInt();
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('truncatedReadIsProtocolError', 0, () => {
      let caught: ArkDbError | null = null;
      try {
        new PacketReader(new Uint8Array([0x01, 0x02, 0x03])).readUInt32();
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught instanceof ArkDbError).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('checksEveryFixedWidthReadBeforeAdvancing', 0, () => {
      assertTruncatedReads(1, (reader: PacketReader): void => { reader.peekUInt8(); });
      assertTruncatedReads(1, (reader: PacketReader): void => { reader.readUInt8(); });
      assertTruncatedReads(2, (reader: PacketReader): void => { reader.readUInt16(); });
      assertTruncatedReads(3, (reader: PacketReader): void => { reader.readUInt24(); });
      assertTruncatedReads(4, (reader: PacketReader): void => { reader.readUInt32(); });
      assertTruncatedReads(8, (reader: PacketReader): void => { reader.readUInt64(); });
    });

    it('rejectsInvalidAndTruncatedVariableLengths', 0, () => {
      const invalidLengths: number[] = [-1, 0.5, NaN, Infinity, 9007199254740992, 4];
      for (const length of invalidLengths) {
        const reader = new PacketReader(new Uint8Array([1, 2, 3]));
        assertProtocol(() => { reader.skip(length); });
        expect(reader.offset).assertEqual(0);
        assertProtocol(() => { reader.readBytes(length); });
        expect(reader.offset).assertEqual(0);
        assertProtocol(() => { reader.readFixedString(length); });
        expect(reader.offset).assertEqual(0);
      }
      const reader = new PacketReader(new Uint8Array(0));
      reader.skip(0);
      expect(reader.readBytes(0).length).assertEqual(0);
      expect(reader.readFixedString(0)).assertEqual('');
      expect(reader.readEofString()).assertEqual('');
      expect(reader.remaining).assertEqual(0);
    });

    it('rejectsTruncatedLengthPrefixesAndUnsafeLengths', 0, () => {
      const prefixes: number[] = [0xfc, 0xfd, 0xfe];
      const widths: number[] = [2, 3, 8];
      for (let index = 0; index < prefixes.length; index += 1) {
        for (let size = 0; size < widths[index]; size += 1) {
          const bytes = new Uint8Array(size + 1);
          bytes[0] = prefixes[index];
          assertProtocol(() => { new PacketReader(bytes).readLenEncInt(); });
        }
      }
      assertProtocol(() => {
        new PacketReader(new Uint8Array([0xfe, 0, 0, 0, 0, 0, 0, 0x20, 0])).readLenEncUInt();
      });
      assertProtocol(() => {
        new PacketReader(new Uint8Array([0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
          .readLenEncBytes();
      });
      assertProtocol(() => { new PacketReader(new Uint8Array([3, 0x61, 0x62])).readLenEncBytes(); });
      assertProtocol(() => { new PacketReader(new Uint8Array([0xfb])).readLenEncUInt(); });
      const safe = new PacketReader(new Uint8Array([0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x1f, 0]));
      expect(safe.readLenEncUInt()).assertEqual(9007199254740991);
    });

    it('requiresNulTerminatorsWithoutReadingPastThePacket', 0, () => {
      const reader = new PacketReader(new Uint8Array([0x61, 0x62]));
      assertProtocol(() => { reader.readNulString(); });
      expect(reader.offset).assertEqual(0);
      expect(reader.remaining).assertEqual(2);
      const empty = new PacketReader(new Uint8Array([0]));
      expect(empty.readNulString()).assertEqual('');
      expect(empty.remaining).assertEqual(0);
      assertProtocol(() => { empty.readNulString(); });
    });

    it('keepsRawUnsignedWriterWrappingSemantics', 0, () => {
      assertBytes(new PacketWriter().writeUInt8(-1).writeUInt16(65536)
        .writeUInt24(0x12345678).writeUInt32(-1).toUint8Array(), [
        0xff, 0, 0, 0x78, 0x56, 0x34, 0xff, 0xff, 0xff, 0xff
      ]);
    });

    it('readsSignedIntegerAndFloatingPointLittleEndianVectors', 0, () => {
      const signed = new PacketReader(new Uint8Array([
        0x80, 0x7f,
        0, 0x80, 0xff, 0x7f,
        0, 0, 0, 0x80, 0xff, 0xff, 0xff, 0x7f,
        0, 0, 0, 0, 0, 0, 0, 0x80,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
      ]));
      expect(signed.readInt8()).assertEqual(-128);
      expect(signed.readInt8()).assertEqual(127);
      expect(signed.readInt16()).assertEqual(-32768);
      expect(signed.readInt16()).assertEqual(32767);
      expect(signed.readInt32()).assertEqual(-2147483648);
      expect(signed.readInt32()).assertEqual(2147483647);
      expect(signed.readInt64() === -9223372036854775808n).assertTrue();
      expect(signed.readInt64() === 9223372036854775807n).assertTrue();
      expect(signed.readInt64() === -1n).assertTrue();
      expect(signed.remaining).assertEqual(0);
      const floats = new PacketReader(new Uint8Array([
        0xee, 0, 0, 0xc0, 0x3f, 0, 0, 0, 0, 0, 0, 0xf8, 0xbf, 0xee
      ]).subarray(1, 13));
      expect(floats.readFloat32()).assertEqual(1.5);
      expect(floats.readFloat64()).assertEqual(-1.5);
      expect(floats.remaining).assertEqual(0);
    });

    it('writesExactSignedUnsignedAndDoubleVectors', 0, () => {
      assertBytes(new PacketWriter().writeInt32(-2147483648).writeInt32(2147483647).toUint8Array(), [
        0, 0, 0, 0x80, 0xff, 0xff, 0xff, 0x7f
      ]);
      assertBytes(new PacketWriter().writeInt64(-9223372036854775808n)
        .writeInt64(9223372036854775807n).writeInt64(-1n).toUint8Array(), [
        0, 0, 0, 0, 0, 0, 0, 0x80,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
      ]);
      assertBytes(new PacketWriter().writeUInt64(0n).writeUInt64(18446744073709551615n).toUint8Array(), [
        0, 0, 0, 0, 0, 0, 0, 0,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
      ]);
      assertBytes(new PacketWriter().writeFloat64(1.5).writeFloat64(-0).toUint8Array(), [
        0, 0, 0, 0, 0, 0, 0xf8, 0x3f,
        0, 0, 0, 0, 0, 0, 0, 0x80
      ]);
    });

    it('checksNewBinaryReadWidthsBeforeAdvancing', 0, () => {
      assertTruncatedReads(1, (reader: PacketReader): void => { reader.readInt8(); });
      assertTruncatedReads(2, (reader: PacketReader): void => { reader.readInt16(); });
      assertTruncatedReads(4, (reader: PacketReader): void => { reader.readInt32(); });
      assertTruncatedReads(8, (reader: PacketReader): void => { reader.readInt64(); });
      assertTruncatedReads(4, (reader: PacketReader): void => { reader.readFloat32(); });
      assertTruncatedReads(8, (reader: PacketReader): void => { reader.readFloat64(); });
    });

    it('rejectsInvalidBinaryWritesBeforeAppending', 0, () => {
      const int32Values: number[] = [-2147483649, 2147483648, 0.5, NaN, Infinity];
      for (const value of int32Values) {
        assertRejectedWrite((writer: PacketWriter): void => { writer.writeInt32(value); });
      }
      assertRejectedWrite((writer: PacketWriter): void => { writer.writeInt64(-9223372036854775809n); });
      assertRejectedWrite((writer: PacketWriter): void => { writer.writeInt64(9223372036854775808n); });
      assertRejectedWrite((writer: PacketWriter): void => { writer.writeUInt64(-1n); });
      assertRejectedWrite((writer: PacketWriter): void => { writer.writeUInt64(18446744073709551616n); });
      for (const value of [NaN, Infinity, -Infinity]) {
        assertRejectedWrite((writer: PacketWriter): void => { writer.writeFloat64(value); });
      }
    });
  });
}

function assertRejectedWrite(write: (writer: PacketWriter) => void): void {
  const writer = new PacketWriter();
  let caught: ArkDbError | null = null;
  try {
    write(writer);
  } catch (error) {
    caught = error as ArkDbError;
  }
  expect(caught instanceof ArkDbError).assertTrue();
  expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
  expect(writer.length).assertEqual(0);
}

function assertProtocol(action: () => void): void {
  let caught: ArkDbError | null = null;
  try {
    action();
  } catch (error) {
    caught = error as ArkDbError;
  }
  expect(caught instanceof ArkDbError).assertTrue();
  expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
}

function assertTruncatedReads(width: number, read: (reader: PacketReader) => void): void {
  for (let size = 0; size < width; size += 1) {
    const reader = new PacketReader(new Uint8Array(size));
    assertProtocol(() => { read(reader); });
    expect(reader.offset).assertEqual(0);
    expect(reader.remaining).assertEqual(size);
  }
}

function assertLengthEncodedInteger(value: number, expectedBytes: number[]): void {
  const bytes = new PacketWriter().writeLenEncInt(value).toUint8Array();
  assertBytes(bytes, expectedBytes);
  const decoded = new PacketReader(bytes).readLenEncInt();
  expect(decoded !== null).assertTrue();
  expect(decoded === BigInt(value)).assertTrue();
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
