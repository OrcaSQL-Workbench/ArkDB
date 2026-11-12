import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresParameter, PostgresParameterType as T, PostgresParameterValue
} from '../../../../main/ets/pgsql/features/prepared/PostgresParameter';
import {
  encodePostgresParameters, encodePostgresPreparedFrames
} from '../../../../main/ets/pgsql/features/prepared/PostgresParameterEncoder';

type InvalidTestInput = PostgresParameterValue | Object | undefined;

export default function postgresParameterEncoderTest(): void {
  describe('PostgresParameterEncoder', () => {
    it('encodesAllScalarParameterTypesAndPreservesNullFormats', 0, () => {
      const jsonRaw = ' { "b" : 1e0 , "a" : "\\u0000" } ';
      const jsonbRaw = '[true, -0, 1.50]';
      const uuidRaw = '550E8400-e29b-41d4-a716-446655440000';
      const cases: Array<[T, PostgresParameterValue, number, number, number[] | null]> = [
        [T.Unspecified, '', 0, 0, []],
        [T.Unspecified, 'π😀', 0, 0, [0xcf, 0x80, 0xf0, 0x9f, 0x98, 0x80]],
        [T.Unspecified, null, 0, 0, null],
        [T.Boolean, true, 16, 0, ascii('true')], [T.Boolean, false, 16, 0, ascii('false')],
        [T.Boolean, null, 16, 0, null],
        [T.Int2, -32768, 21, 0, ascii('-32768')], [T.Int2, 32767, 21, 0, ascii('32767')],
        [T.Int2, -0, 21, 0, ascii('0')], [T.Int2, null, 21, 0, null],
        [T.Int4, -2147483648, 23, 0, ascii('-2147483648')],
        [T.Int4, 2147483647, 23, 0, ascii('2147483647')],
        [T.Int4, -0, 23, 0, ascii('0')], [T.Int4, null, 23, 0, null],
        [T.Int8, -9223372036854775808n, 20, 0, ascii('-9223372036854775808')],
        [T.Int8, 9223372036854775807n, 20, 0, ascii('9223372036854775807')],
        [T.Int8, 0n, 20, 0, ascii('0')], [T.Int8, null, 20, 0, null],
        [T.Numeric, ' -12345678901234567890.0010 ', 1700, 0,
          ascii(' -12345678901234567890.0010 ')],
        [T.Numeric, 'NaN', 1700, 0, ascii('NaN')], [T.Numeric, null, 1700, 0, null],
        [T.Float4, 1.5, 700, 0, ascii('1.5')], [T.Float4, -0, 700, 0, ascii('-0')],
        [T.Float4, 0, 700, 0, ascii('0')], [T.Float4, Number.NaN, 700, 0, ascii('NaN')],
        [T.Float4, Number.POSITIVE_INFINITY, 700, 0, ascii('Infinity')],
        [T.Float4, Number.NEGATIVE_INFINITY, 700, 0, ascii('-Infinity')],
        [T.Float4, 3.4028234663852886e+38, 700, 0, ascii('3.4028234663852886e+38')],
        [T.Float4, 1e-46, 700, 0, ascii('0')], [T.Float4, -1e-46, 700, 0, ascii('-0')],
        [T.Float4, 16777219 / 16777216, 700, 0, ascii('1.000000238418579')],
        [T.Float4, null, 700, 0, null],
        [T.Float8, -2.25, 701, 0, ascii('-2.25')], [T.Float8, -0, 701, 0, ascii('-0')],
        [T.Float8, 0, 701, 0, ascii('0')], [T.Float8, Number.NaN, 701, 0, ascii('NaN')],
        [T.Float8, Number.POSITIVE_INFINITY, 701, 0, ascii('Infinity')],
        [T.Float8, Number.NEGATIVE_INFINITY, 701, 0, ascii('-Infinity')],
        [T.Float8, Number.MAX_VALUE, 701, 0, ascii(String(Number.MAX_VALUE))],
        [T.Float8, null, 701, 0, null],
        [T.Text, '', 25, 0, []],
        [T.Text, 'héllo 中', 25, 0, [0x68, 0xc3, 0xa9, 0x6c, 0x6c, 0x6f, 0x20, 0xe4, 0xb8, 0xad]],
        [T.Text, null, 25, 0, null],
        [T.Bytea, new Uint8Array([0x00, 0x80, 0xff]), 17, 1, [0x00, 0x80, 0xff]],
        [T.Bytea, new Uint8Array(0), 17, 1, []], [T.Bytea, null, 17, 1, null],
        [T.Uuid, uuidRaw, 2950, 0, ascii(uuidRaw)], [T.Uuid, null, 2950, 0, null],
        [T.Json, jsonRaw, 114, 0, ascii(jsonRaw)], [T.Json, null, 114, 0, null],
        [T.Jsonb, jsonbRaw, 3802, 0, ascii(jsonbRaw)], [T.Jsonb, null, 3802, 0, null],
        [T.Date, '2026-11-12', 1082, 0, ascii('2026-11-12')], [T.Date, null, 1082, 0, null],
        [T.Time, '05:44:41.477123', 1083, 0, ascii('05:44:41.477123')],
        [T.Time, null, 1083, 0, null],
        [T.Timestamp, '2026-11-12 05:44:41.477', 1114, 0, ascii('2026-11-12 05:44:41.477')],
        [T.Timestamp, null, 1114, 0, null],
        [T.TimestampTz, '2026-11-12 05:44:41.477+08:00', 1184, 0,
          ascii('2026-11-12 05:44:41.477+08:00')],
        [T.TimestampTz, null, 1184, 0, null]
      ];
      const encoded = encodePostgresParameters(cases.map((c) => new PostgresParameter(c[0], c[1])));
      expect(encoded.parameterTypeOids.length).assertEqual(cases.length);
      for (let i = 0; i < cases.length; i += 1) {
        expect(encoded.parameterTypeOids[i]).assertEqual(cases[i][2]);
        expect(encoded.parameterFormats[i]).assertEqual(cases[i][3]);
        const expected = cases[i][4];
        const actual = encoded.parameterValues[i];
        if (expected === null) expect(actual).assertNull();
        else { expect(actual !== null).assertTrue(); assertBytes(actual!, expected); }
      }
    });

    it('rejectsInvalidTypesAndMismatchedValuesAtConstructionAndEncode', 0, () => {
      const loneHigh = String.fromCharCode(0xd800);
      const loneLow = String.fromCharCode(0xdc00);
      const reversed = String.fromCharCode(0xdc00, 0xd800);
      const groups: Array<[T, InvalidTestInput[]]> = [
        ['unknown' as T, [null, 'x']],
        [asParamType(undefined), [null]],
        [T.Unspecified, [1, new Uint8Array(1), 'bad\u0000text', loneHigh, loneLow, reversed]],
        [T.Boolean, [1, 'true']],
        [T.Int2, [-32769, 32768, 1.5, Number.NaN, Number.POSITIVE_INFINITY, 1n, '1']],
        [T.Int4, [-2147483649, 2147483648, 0.25, Number.MAX_SAFE_INTEGER, 1n]],
        [T.Int8, [-9223372036854775809n, 9223372036854775808n, 1, '1']],
        [T.Numeric, ['', '   \t\n', '1\u00002', loneHigh, 12.3]],
        [T.Float4, [1e39, -1e39, 3.4028235677973366e+38, Number.MAX_VALUE, '1.5']],
        [T.Float8, ['1.5', 1n]],
        [T.Text, ['a\u0000b', loneHigh, new Date(), undefined]],
        [T.Bytea, ['\\x01', [1, 2], new Int8Array([1])]],
        [T.Uuid, [
          '{550e8400-e29b-41d4-a716-446655440000}', '550e8400e29b41d4a716446655440000',
          ' 550e8400-e29b-41d4-a716-446655440000', '550e8400-e29b-41d4-a716-44665544000g',
          '550e840-0e29b-41d4-a716-446655440000'
        ]],
        [T.Json, ['', '   ', '{bad:1}', '1 2', '{"a":"\u0000"}', '{"a":"' + loneHigh + '"}']],
        [T.Jsonb, ['undefined', 123]],
        [T.Date, ['', '   ', new Date()]],
        [T.Time, ['\t\r\n']],
        [T.Timestamp, ['2026-01-01\u000000:00:00']],
        [T.TimestampTz, [loneLow]]
      ];
      for (const group of groups) {
        for (const bad of group[1]) {
          assertValidation((): void => { new PostgresParameter(group[0], asParamValue(bad)); });
        }
      }
      assertValidation((): void => { encodePostgresParameters(asParamList(null)); });
      assertValidation((): void => { encodePostgresParameters([asParam(null)]); });
      assertValidation((): void => { encodePostgresParameters(new Array<PostgresParameter>(1)); });
      assertValidation((): void => { encodePostgresParameters([new ForgedFloat4Parameter()]); });
      assertValidation((): void => {
        encodePostgresPreparedFrames('SELECT $1', [new ForgedFloat4Parameter()]);
      });
    });

    it('defensivelyCopiesByteaAndSnapshotsParametersBeforeWireSerialization', 0, () => {
      const backing = new Uint8Array([0x11, 0xaa, 0xbb, 0x22]);
      const binary = new PostgresParameter(T.Bytea, backing.subarray(1, 3));
      backing[1] = 0x77;
      const firstRead = binary.value as Uint8Array;
      assertBytes(firstRead, [0xaa, 0xbb]);
      firstRead[0] = 0x99;
      assertBytes(binary.value as Uint8Array, [0xaa, 0xbb]);

      const liveBytes = new Uint8Array([0xde, 0xad]);
      const list: PostgresParameter[] = [];
      const resultFormats: number[] = [0];
      list.push(new PostgresParameter(T.Int4, 42));
      list.push(new LiveByteaParameter(liveBytes, (): void => {
        list.push(new PostgresParameter(T.Int4, 7));
        resultFormats.push(1);
      }));
      list.push(new PostgresParameter(T.Bytea, null));
      const frames = encodePostgresPreparedFrames('SELECT $1, $2, $3', list, '', '', resultFormats);
      expect(list.length).assertEqual(4);
      expect(frames.parameters.parameterTypeOids.length).assertEqual(3);
      liveBytes[0] = 0x00;
      list.pop();
      list[0] = new PostgresParameter(T.Int4, 99);

      assertBytes(frames.parameters.parameterValues[1]!, [0xde, 0xad]);
      assertBytes(frames.parseFrame, [
        0x50, 0x00, 0x00, 0x00, 0x25, 0x00,
        0x53, 0x45, 0x4c, 0x45, 0x43, 0x54, 0x20, 0x24, 0x31, 0x2c,
        0x20, 0x24, 0x32, 0x2c, 0x20, 0x24, 0x33, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x17, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x11
      ]);
      assertBytes(frames.bindFrame, [
        0x42, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x02, 0x34, 0x32,
        0x00, 0x00, 0x00, 0x02, 0xde, 0xad,
        0xff, 0xff, 0xff, 0xff,
        0x00, 0x01, 0x00, 0x00
      ]);
    });

    it('enforcesParameterCountAndMessageByteCapsBeforeDispatch', 0, () => {
      const maxNulls: PostgresParameter[] = [];
      const nullParam = new PostgresParameter(T.Unspecified, null);
      for (let i = 0; i < 65535; i += 1) maxNulls.push(nullParam);
      const maxEncoded = encodePostgresParameters(maxNulls);
      expect(maxEncoded.parameterTypeOids.length).assertEqual(65535);
      expect(maxEncoded.parameterFormats.length).assertEqual(65535);
      expect(maxEncoded.parameterValues.length).assertEqual(65535);

      maxNulls.push(nullParam);
      assertValidation((): void => { encodePostgresParameters(maxNulls); });
      assertValidation((): void => { encodePostgresPreparedFrames('SELECT 1', maxNulls); });

      const chunk17MiB = new PostgresParameter(T.Bytea, new Uint8Array(17 * 1024 * 1024));
      assertValidation((): void => { encodePostgresParameters([chunk17MiB, chunk17MiB]); });
      assertValidation((): void => {
        encodePostgresPreparedFrames('SELECT $1, $2', [chunk17MiB, chunk17MiB]);
      });
      assertValidation((): void => { encodePostgresPreparedFrames('SELECT\u00001', []); });
      assertValidation((): void => { encodePostgresPreparedFrames('SELECT 1', [], 'bad\u0000s'); });
      assertValidation((): void => {
        encodePostgresPreparedFrames('SELECT 1', [], '', 'bad\u0000p');
      });
      assertValidation((): void => { encodePostgresPreparedFrames('SELECT 1', [], '', '', [2]); });
      let paramReads = 0;
      const probe = new LiveByteaParameter(new Uint8Array(0), (): void => { paramReads += 1; });
      assertValidation((): void => {
        encodePostgresPreparedFrames('SELECT $1', [probe], '', '', new Array<number>(65536));
      });
      expect(paramReads).assertEqual(0);
    });
  });
}

function asParamType(value: T | undefined): T { return value as T; }
function asParamValue(value: InvalidTestInput): PostgresParameterValue {
  return value as PostgresParameterValue;
}
function asParamList(value: PostgresParameter[] | null): PostgresParameter[] {
  return value as PostgresParameter[];
}
function asParam(value: PostgresParameter | null): PostgresParameter {
  return value as PostgresParameter;
}

class ForgedFloat4Parameter extends PostgresParameter {
  private reads: number = 0;
  constructor() { super(T.Float4, 1.0); }
  get value(): PostgresParameterValue {
    this.reads += 1;
    return this.reads >= 1 ? 1e39 : 1.0;
  }
}

class LiveByteaParameter extends PostgresParameter {
  private readonly live: Uint8Array;
  private readonly onRead: () => void;
  constructor(live: Uint8Array, onRead: () => void) {
    super(T.Bytea, new Uint8Array(0));
    this.live = live;
    this.onRead = onRead;
  }
  get value(): PostgresParameterValue {
    this.onRead();
    return this.live;
  }
}

function ascii(text: string): number[] {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i += 1) bytes.push(text.charCodeAt(i));
  return bytes;
}

function assertValidation(action: () => void): void {
  let failure: ArkDbError | null = null;
  try { action(); } catch (error) { failure = error as ArkDbError; }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]);
}
