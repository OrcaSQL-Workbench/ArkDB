import { describe, it, expect } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { MySqlColumnDef, MySqlValue } from '../../../main/ets/mysql/model/MySqlQueryResult';
import { ColumnType, FieldFlag } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { BinaryRowDecoder } from '../../../main/ets/mysql/value/BinaryRowDecoder';

export default function binaryRowDecoderTest(): void {
  describe('BinaryRowDecoder', () => {
    it('binaryHeaderZeroIsNotOk', 0, () => {
      const row = decodeRow(new Uint8Array([0, 0, 42, 0, 0, 0]), [column(ColumnType.LONG)]);
      expect(row.length).assertEqual(1);
      expect(row[0]).assertEqual(42);
    });

    it('resultNullBitmapStartsAtBitTwo', 0, () => {
      const columns: MySqlColumnDef[] = [
        column(ColumnType.TINY), column(ColumnType.LONGLONG, FieldFlag.UNSIGNED),
        column(ColumnType.TINY), column(ColumnType.TINY), column(ColumnType.TINY),
        column(ColumnType.TINY), column(ColumnType.TINY), column(ColumnType.TINY),
        column(ColumnType.TINY)
      ];
      const row = decodeRow(new Uint8Array([
        0, 0x84, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 3, 4, 7, 8
      ]), columns);
      expect(row.length).assertEqual(9);
      expect(row[0] === null).assertTrue();
      expect(row[1] === 18446744073709551615n).assertTrue();
      expect(row[2]).assertEqual(-2);
      expect(row[3]).assertEqual(3);
      expect(row[4]).assertEqual(4);
      expect(row[5] === null).assertTrue();
      expect(row[6] === null).assertTrue();
      expect(row[7]).assertEqual(7);
      expect(row[8]).assertEqual(8);
    });

    it('preservesTemporalPrecision', 0, () => {
      const payload = new PacketWriter().writeBytes(new Uint8Array([
        0, 0,
        12, 1, 34, 0, 0, 0, 22, 59, 59, 1, 0, 0, 0,
        11, 0xea, 7, 10, 24, 22, 23, 24, 0x40, 0xe2, 1, 0
      ])).writeLenEncString('12345678901234567890.1234567890').toUint8Array();
      const row = decodeRow(payload, [
        column(ColumnType.TIME, 0, 6), column(ColumnType.DATETIME, 0, 6),
        column(ColumnType.NEWDECIMAL)
      ]);
      expect(row.length).assertEqual(3);
      expect(row[0]).assertEqual('-838:59:59.000001');
      expect(row[1]).assertEqual('2026-10-24 22:23:24.123456');
      expect(row[2]).assertEqual('12345678901234567890.1234567890');
    });

    it('readsEveryIntegerWidthUsingSignedAndUnsignedMetadata', 0, () => {
      expect(scalar(ColumnType.TINY, [0x80])).assertEqual(-128);
      expect(scalar(ColumnType.TINY, [0xff], FieldFlag.UNSIGNED)).assertEqual(255);
      expect(scalar(ColumnType.TINY, [1])).assertEqual(1);
      expect(typeof scalar(ColumnType.TINY, [1])).assertEqual('number');
      expect(scalar(ColumnType.SHORT, [0, 0x80])).assertEqual(-32768);
      expect(scalar(ColumnType.SHORT, [0xff, 0xff], FieldFlag.UNSIGNED)).assertEqual(65535);
      expect(scalar(ColumnType.LONG, [0, 0, 0, 0x80])).assertEqual(-2147483648);
      expect(scalar(ColumnType.LONG, [0xff, 0xff, 0xff, 0xff],
        FieldFlag.UNSIGNED)).assertEqual(4294967295);
      expect(scalar(ColumnType.INT24, [0, 0, 0x80, 0xff])).assertEqual(-8388608);
      expect(scalar(ColumnType.INT24, [0xff, 0xff, 0xff, 0],
        FieldFlag.UNSIGNED)).assertEqual(16777215);
      expect(scalar(ColumnType.LONGLONG, [0, 0, 0, 0, 0, 0, 0, 0x80]) ===
        -9223372036854775808n).assertTrue();
      expect(scalar(ColumnType.LONGLONG, [1, 0, 0, 0, 0, 0, 0x20, 0]) ===
        9007199254740993n).assertTrue();
      expect(scalar(ColumnType.LONGLONG, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        FieldFlag.UNSIGNED) === 18446744073709551615n).assertTrue();
      expect(scalar(ColumnType.YEAR, [0xea, 7])).assertEqual(2026);
    });

    it('readsFloatAndDoubleWithoutChangingTheirNumericShape', 0, () => {
      expect(scalar(ColumnType.FLOAT, [0, 0, 0xc0, 0x3f])).assertEqual(1.5);
      expect(scalar(ColumnType.DOUBLE, [0, 0, 0, 0, 0, 0, 2, 0xc0])).assertEqual(-2.25);
      const negativeZero = scalar(ColumnType.DOUBLE, [0, 0, 0, 0, 0, 0, 0, 0x80]);
      expect(typeof negativeZero).assertEqual('number');
      if (typeof negativeZero !== 'number') throw new Error('Expected a numeric double');
      expect(1 / negativeZero).assertEqual(-Infinity);
    });

    it('rejectsBinaryFloatNaN', 0, () => {
      for (const value of [
        [0, 0, 0xc0, 0x7f], [1, 0, 0x80, 0x7f],
        [0, 0, 0xc0, 0xff], [1, 0, 0x80, 0xff]
      ]) {
        assertProtocol(new Uint8Array([0, 0].concat(value)), [column(ColumnType.FLOAT)]);
      }
    });

    it('rejectsBinaryFloatPositiveInfinity', 0, () => {
      assertProtocol(new Uint8Array([0, 0, 0, 0, 0x80, 0x7f]), [column(ColumnType.FLOAT)]);
    });

    it('rejectsBinaryFloatNegativeInfinity', 0, () => {
      assertProtocol(new Uint8Array([0, 0, 0, 0, 0x80, 0xff]), [column(ColumnType.FLOAT)]);
    });

    it('rejectsBinaryDoubleNaN', 0, () => {
      for (const value of [
        [0, 0, 0, 0, 0, 0, 0xf8, 0x7f], [1, 0, 0, 0, 0, 0, 0xf0, 0x7f],
        [0, 0, 0, 0, 0, 0, 0xf8, 0xff], [1, 0, 0, 0, 0, 0, 0xf0, 0xff]
      ]) {
        assertProtocol(new Uint8Array([0, 0].concat(value)), [column(ColumnType.DOUBLE)]);
      }
    });

    it('rejectsBinaryDoublePositiveInfinity', 0, () => {
      assertProtocol(new Uint8Array([0, 0, 0, 0, 0, 0, 0, 0, 0xf0, 0x7f]),
        [column(ColumnType.DOUBLE)]);
    });

    it('rejectsBinaryDoubleNegativeInfinity', 0, () => {
      assertProtocol(new Uint8Array([0, 0, 0, 0, 0, 0, 0, 0, 0xf0, 0xff]),
        [column(ColumnType.DOUBLE)]);
    });

    it('preservesFiniteFloatExtremaSubnormalsAndSignedZero', 0, () => {
      expect(numberScalar(ColumnType.FLOAT, [0xff, 0xff, 0x7f, 0x7f]))
        .assertEqual(3.4028234663852886e38);
      expect(numberScalar(ColumnType.FLOAT, [0xff, 0xff, 0x7f, 0xff]))
        .assertEqual(-3.4028234663852886e38);
      expect(numberScalar(ColumnType.FLOAT, [0, 0, 0x80, 0])).assertEqual(1.1754943508222875e-38);
      expect(numberScalar(ColumnType.FLOAT, [0, 0, 0x80, 0x80])).assertEqual(-1.1754943508222875e-38);
      expect(numberScalar(ColumnType.FLOAT, [1, 0, 0, 0])).assertEqual(1.401298464324817e-45);
      expect(numberScalar(ColumnType.FLOAT, [1, 0, 0, 0x80])).assertEqual(-1.401298464324817e-45);
      expect(numberScalar(ColumnType.FLOAT, [0xff, 0xff, 0x7f, 0]))
        .assertEqual(1.1754942106924411e-38);
      expect(numberScalar(ColumnType.FLOAT, [0xff, 0xff, 0x7f, 0x80]))
        .assertEqual(-1.1754942106924411e-38);
      expect(1 / numberScalar(ColumnType.FLOAT, [0, 0, 0, 0])).assertEqual(Infinity);
      expect(1 / numberScalar(ColumnType.FLOAT, [0, 0, 0, 0x80])).assertEqual(-Infinity);
    });

    it('preservesFiniteDoubleExtremaSubnormalsAndSignedZero', 0, () => {
      expect(numberScalar(ColumnType.DOUBLE, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xef, 0x7f]))
        .assertEqual(1.7976931348623157e308);
      expect(numberScalar(ColumnType.DOUBLE, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xef, 0xff]))
        .assertEqual(-1.7976931348623157e308);
      expect(numberScalar(ColumnType.DOUBLE, [0, 0, 0, 0, 0, 0, 0x10, 0]))
        .assertEqual(2.2250738585072014e-308);
      expect(numberScalar(ColumnType.DOUBLE, [0, 0, 0, 0, 0, 0, 0x10, 0x80]))
        .assertEqual(-2.2250738585072014e-308);
      expect(numberScalar(ColumnType.DOUBLE, [1, 0, 0, 0, 0, 0, 0, 0])).assertEqual(5e-324);
      expect(numberScalar(ColumnType.DOUBLE, [1, 0, 0, 0, 0, 0, 0, 0x80])).assertEqual(-5e-324);
      expect(numberScalar(ColumnType.DOUBLE, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f, 0]))
        .assertEqual(2.225073858507201e-308);
      expect(numberScalar(ColumnType.DOUBLE, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x80]))
        .assertEqual(-2.225073858507201e-308);
      expect(1 / numberScalar(ColumnType.DOUBLE, [0, 0, 0, 0, 0, 0, 0, 0])).assertEqual(Infinity);
      expect(1 / numberScalar(ColumnType.DOUBLE, [0, 0, 0, 0, 0, 0, 0, 0x80])).assertEqual(-Infinity);
    });

    it('keepsLengthEncodedScalarsAndBinaryJsonAsExactStrings', 0, () => {
      const types: number[] = [
        ColumnType.DECIMAL, ColumnType.NEWDECIMAL, ColumnType.VARCHAR, ColumnType.VAR_STRING,
        ColumnType.STRING, ColumnType.ENUM, ColumnType.SET, ColumnType.BLOB
      ];
      const encoded = new PacketWriter().writeLenEncString('12.3400').toUint8Array();
      for (const type of types) {
        expect(scalar(type, Array.from(encoded))).assertEqual('12.3400');
      }
      const json = new PacketWriter().writeLenEncString('{"n":18446744073709551615}').toUint8Array();
      expect(scalar(ColumnType.JSON, Array.from(json), 0, 0, 63))
        .assertEqual('{"n":18446744073709551615}');
      expect(scalar(ColumnType.NEWDECIMAL, Array.from(encoded), 0, 0, 63)).assertEqual('12.3400');
      expect(scalar(ColumnType.VAR_STRING, [4, 0xf0, 0x9f, 0x98, 0x80])).assertEqual('\uD83D\uDE00');
    });

    it('keepsBitGeometryAndBinaryCollationsAsBytes', 0, () => {
      const types: number[] = [
        ColumnType.BIT, ColumnType.GEOMETRY, ColumnType.TINY_BLOB, ColumnType.MEDIUM_BLOB,
        ColumnType.LONG_BLOB, ColumnType.BLOB, ColumnType.VARCHAR, ColumnType.VAR_STRING,
        ColumnType.STRING
      ];
      for (const type of types) {
        assertBytes(scalar(type, [3, 0, 0xfe, 0xff], 0, 0, 63), [0, 0xfe, 0xff]);
      }
      assertBytes(scalar(ColumnType.BIT, [1, 0x80]), [0x80]);
      assertBytes(scalar(ColumnType.GEOMETRY, [1, 0xff]), [0xff]);
    });

    it('distinguishesSqlNullEmptyTextAndEmptyBytes', 0, () => {
      const binary = column(ColumnType.BLOB);
      binary.charset = 63;
      const row = decodeRow(new Uint8Array([0, 4, 0, 0]), [
        column(ColumnType.VAR_STRING), column(ColumnType.VAR_STRING), binary
      ]);
      expect(row[0] === null).assertTrue();
      expect(row[1]).assertEqual('');
      assertBytes(row[2], []);
      expect(scalar(ColumnType.NULL, []) === null).assertTrue();
    });

    it('padsZeroTemporalFractionsToEveryDeclaredPrecision', 0, () => {
      const times: string[] = [
        '00:00:00', '00:00:00.0', '00:00:00.00', '00:00:00.000',
        '00:00:00.0000', '00:00:00.00000', '00:00:00.000000'
      ];
      const dateTimes: string[] = [
        '0000-00-00 00:00:00', '0000-00-00 00:00:00.0', '0000-00-00 00:00:00.00',
        '0000-00-00 00:00:00.000', '0000-00-00 00:00:00.0000',
        '0000-00-00 00:00:00.00000', '0000-00-00 00:00:00.000000'
      ];
      expect(scalar(ColumnType.DATE, [0])).assertEqual('0000-00-00');
      expect(scalar(ColumnType.NEWDATE, [0])).assertEqual('0000-00-00');
      for (let decimals = 0; decimals <= 6; decimals += 1) {
        expect(scalar(ColumnType.TIME, [0], 0, decimals)).assertEqual(times[decimals]);
        expect(scalar(ColumnType.DATETIME, [0], 0, decimals)).assertEqual(dateTimes[decimals]);
        expect(scalar(ColumnType.TIMESTAMP, [0], 0, decimals)).assertEqual(dateTimes[decimals]);
      }
    });

    it('keepsDateAndTimestampWireLengthsAsWallClockStrings', 0, () => {
      expect(scalar(ColumnType.DATE, [4, 0xe8, 7, 2, 29])).assertEqual('2024-02-29');
      expect(scalar(ColumnType.NEWDATE, [4, 0xe8, 7, 0, 1])).assertEqual('2024-00-01');
      expect(scalar(ColumnType.DATETIME, [4, 0xe8, 7, 2, 29], 0, 6))
        .assertEqual('2024-02-29 00:00:00.000000');
      expect(scalar(ColumnType.TIMESTAMP, [7, 0xe8, 7, 2, 29, 23, 59, 58]))
        .assertEqual('2024-02-29 23:59:58');
      expect(scalar(ColumnType.TIMESTAMP, [11, 0xe8, 7, 2, 29, 23, 59, 58, 0xa0, 0x86, 1, 0],
        0, 3)).assertEqual('2024-02-29 23:59:58.100');
    });

    it('preservesNegativeMultiDayTimeAndPaddedMicroseconds', 0, () => {
      expect(scalar(ColumnType.TIME, [8, 1, 1, 0, 0, 0, 1, 2, 3])).assertEqual('-25:02:03');
      expect(scalar(ColumnType.TIME, [8, 0, 1, 0, 0, 0, 1, 2, 3], 0, 6))
        .assertEqual('25:02:03.000000');
      expect(scalar(ColumnType.TIME, [12, 0, 34, 0, 0, 0, 22, 59, 59, 0x3f, 0x42, 0x0f, 0],
        0, 6)).assertEqual('838:59:59.999999');
      expect(scalar(ColumnType.TIME, [12, 0, 0, 0, 0, 0, 0, 0, 0, 0xa0, 0x86, 1, 0],
        0, 6)).assertEqual('00:00:00.100000');
    });

    it('honorsPayloadViewsWithNonzeroByteOffsets', 0, () => {
      const backing = new Uint8Array([0xaa, 0xbb, 0, 0, 42, 0, 0, 0, 0xcc]);
      const row = decodeRow(backing.subarray(2, 8), [column(ColumnType.LONG)]);
      expect(row[0]).assertEqual(42);
    });

    it('rejectsInvalidHeadersMissingBitmapAndTrailingBytes', 0, () => {
      for (const payload of [
        new Uint8Array(0), new Uint8Array([0]), new Uint8Array([0xfe, 0]),
        new Uint8Array([0xfb, 0]), new Uint8Array([0xff, 0]),
        new Uint8Array([0, 0, 42, 0, 0, 0, 1])
      ]) {
        assertProtocol(payload, [column(ColumnType.LONG)]);
      }
      assertProtocol(new Uint8Array([0, 0, 1]), [column(ColumnType.NULL)]);
      const columns: MySqlColumnDef[] = [];
      for (let index = 0; index < 7; index += 1) columns.push(column(ColumnType.NULL));
      assertProtocol(new Uint8Array([0, 0]), columns);
    });

    it('rejectsEveryTruncatedFixedWidthWithoutRangeError', 0, () => {
      const types: number[] = [
        ColumnType.TINY, ColumnType.SHORT, ColumnType.LONG, ColumnType.INT24,
        ColumnType.LONGLONG, ColumnType.YEAR, ColumnType.FLOAT, ColumnType.DOUBLE
      ];
      const widths: number[] = [1, 2, 4, 4, 8, 2, 4, 8];
      for (let index = 0; index < types.length; index += 1) {
        for (let length = 0; length < widths[index]; length += 1) {
          assertProtocol(new Uint8Array(length + 2), [column(types[index])]);
          assertProtocol(new Uint8Array(length + 2), [column(types[index], FieldFlag.UNSIGNED)]);
        }
      }
    });

    it('rejectsMalformedLengthEncodedValuesAndUnexpectedNullSentinels', 0, () => {
      const values: number[][] = [
        [], [0xfb], [0xff], [2, 1], [0xfc], [0xfc, 1], [0xfc, 2, 0, 1],
        [0xfd, 1, 0], [0xfe, 1, 0, 0, 0, 0, 0, 0],
        [0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
      ];
      for (const value of values) {
        assertProtocol(new Uint8Array([0, 0].concat(value)), [column(ColumnType.VAR_STRING)]);
      }
    });

    it('rejectsMalformedTemporalLengthsAndTruncatedBodies', 0, () => {
      for (const length of [1, 2, 3, 5, 6, 8, 9, 10, 12]) {
        assertProtocol(new Uint8Array([0, 0, length]), [column(ColumnType.DATETIME)]);
      }
      assertProtocol(new Uint8Array([0, 0, 7, 0, 0, 0, 0, 0, 0, 0]), [column(ColumnType.DATE)]);
      assertProtocol(new Uint8Array([0, 0, 4, 0, 0, 0, 0]), [column(ColumnType.TIME)]);
      const dateTime: number[] = [11, 0xe8, 7, 2, 29, 23, 59, 58, 0, 0, 0, 0];
      const time: number[] = [12, 0, 1, 0, 0, 0, 1, 2, 3, 0, 0, 0, 0];
      for (let length = 0; length < dateTime.length; length += 1) {
        assertProtocol(new Uint8Array([0, 0].concat(dateTime.slice(0, length))),
          [column(ColumnType.DATETIME, 0, 6)]);
      }
      for (let length = 0; length < time.length; length += 1) {
        assertProtocol(new Uint8Array([0, 0].concat(time.slice(0, length))),
          [column(ColumnType.TIME, 0, 6)]);
      }
    });

    it('rejectsInvalidTemporalComponentsAndPrecisionWithoutRounding', 0, () => {
      const dates: number[][] = [
        [4, 0x10, 0x27, 1, 1], [4, 0xe8, 7, 13, 1], [4, 0xe8, 7, 1, 32],
        [7, 0xe8, 7, 1, 1, 24, 0, 0], [7, 0xe8, 7, 1, 1, 0, 60, 0],
        [7, 0xe8, 7, 1, 1, 0, 0, 60], [11, 0xe8, 7, 1, 1, 0, 0, 0, 0x40, 0x42, 0x0f, 0]
      ];
      for (const value of dates) {
        assertProtocol(new Uint8Array([0, 0].concat(value)), [column(ColumnType.DATETIME, 0, 6)]);
      }
      const times: number[][] = [
        [8, 2, 0, 0, 0, 0, 0, 0, 0], [8, 0, 35, 0, 0, 0, 0, 0, 0],
        [8, 0, 0, 0, 0, 0, 24, 0, 0], [8, 0, 0, 0, 0, 0, 0, 60, 0],
        [8, 0, 0, 0, 0, 0, 0, 0, 60], [12, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x42, 0x0f, 0]
      ];
      for (const value of times) {
        assertProtocol(new Uint8Array([0, 0].concat(value)), [column(ColumnType.TIME, 0, 6)]);
      }
      const precise = new Uint8Array([0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]);
      assertProtocol(precise, [column(ColumnType.TIME, 0, 0)]);
      for (const decimals of [-1, 7, 1.5]) {
        assertProtocol(new Uint8Array([0, 0, 0]), [column(ColumnType.TIME, 0, decimals)]);
      }
    });

    it('rejectsUnknownTypesEvenWhenTheirNullBitmapBitIsSet', 0, () => {
      for (const type of [0x11, 0x12, 0x13, 0xf4, 0x100]) {
        assertProtocol(new Uint8Array([0, 0]), [column(type)]);
        assertProtocol(new Uint8Array([0, 4]), [column(type)]);
      }
    });
  });
}

function column(type: number, flags: number = 0, decimals: number = 0): MySqlColumnDef {
  const result = new MySqlColumnDef();
  result.type = type;
  result.flags = flags;
  result.charset = 45;
  result.decimals = decimals;
  return result;
}

function decodeRow(payload: Uint8Array, columns: MySqlColumnDef[]): MySqlValue[] {
  let row: MySqlValue[] = [];
  let failure: Object | null = null;
  try {
    row = new BinaryRowDecoder().decode(payload, columns);
  } catch (error) {
    failure = error as Object;
  }
  expect(failure === null).assertTrue();
  return row;
}

function scalar(type: number, value: number[], flags: number = 0,
  decimals: number = 0, charset: number = 45): MySqlValue {
  const metadata = column(type, flags, decimals);
  metadata.charset = charset;
  return decodeRow(new Uint8Array([0, 0].concat(value)), [metadata])[0];
}

function numberScalar(type: number, value: number[]): number {
  const result = scalar(type, value);
  expect(typeof result).assertEqual('number');
  if (typeof result !== 'number') throw new Error('Expected a numeric binary result');
  return result;
}

function assertBytes(value: MySqlValue, expected: number[]): void {
  expect(value instanceof Uint8Array).assertTrue();
  if (!(value instanceof Uint8Array)) throw new Error('Expected binary result bytes');
  expect(value.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(value[index]).assertEqual(expected[index]);
  }
}

function assertProtocol(payload: Uint8Array, columns: MySqlColumnDef[]): void {
  let failure: Object | null = null;
  try {
    new BinaryRowDecoder().decode(payload, columns);
  } catch (error) {
    failure = error as Object;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  if (!(failure instanceof ArkDbError)) throw new Error('Expected a checked protocol failure');
  expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
}
