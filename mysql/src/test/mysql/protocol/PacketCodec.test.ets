import { describe, it, expect } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '../../../main/ets/core/model/ArkDbError';
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
  });
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
