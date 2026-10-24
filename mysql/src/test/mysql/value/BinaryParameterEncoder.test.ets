import { describe, it, expect } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { MySqlParameter, MySqlParameterType, MySqlParameterValue } from '../../../main/ets/mysql/model/MySqlParameter';
import { encodeBinaryParameters } from '../../../main/ets/mysql/value/BinaryParameterEncoder';

export default function binaryParameterEncoderTest(): void {
  describe('BinaryParameterEncoder', () => {
    it('encodesUnsigned64WithoutNumber', 0, () => {
      const encoded = encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.UInt64, 18446744073709551615n)
      ]);
      assertBytes(encoded.nullBitmap, [0x00]);
      assertBytes(encoded.types, [0x08, 0x80]);
      assertBytes(encoded.values, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
    });

    it('rejectsNonFiniteAndOutOfRange', 0, () => {
      assertValidation(() => { new MySqlParameter(MySqlParameterType.Float64, NaN); });
      assertValidation(() => { new MySqlParameter(MySqlParameterType.Float64, Infinity); });
      assertValidation(() => { new MySqlParameter(MySqlParameterType.Int32, 2147483648); });
    });

    it('preservesDecimalScale', 0, () => {
      const encoded = encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.Decimal, '12.3400')
      ]);
      assertBytes(encoded.types, [0xf6, 0x00]);
      assertBytes(encoded.values, [0x07, 0x31, 0x32, 0x2e, 0x33, 0x34, 0x30, 0x30]);
    });

    it('encodesEveryTypedNullWithoutValueBytes', 0, () => {
      const types: MySqlParameterType[] = [
        MySqlParameterType.Null, MySqlParameterType.Boolean, MySqlParameterType.Int32,
        MySqlParameterType.Int64, MySqlParameterType.UInt64, MySqlParameterType.Float64,
        MySqlParameterType.Decimal, MySqlParameterType.Text, MySqlParameterType.Binary,
        MySqlParameterType.Date, MySqlParameterType.DateTime, MySqlParameterType.Timestamp,
        MySqlParameterType.Time, MySqlParameterType.Json
      ];
      const parameters: MySqlParameter[] = [];
      for (const type of types) parameters.push(new MySqlParameter(type, null));
      const encoded = encodeBinaryParameters(parameters);
      assertBytes(encoded.nullBitmap, [0xff, 0x3f]);
      assertBytes(encoded.types, [
        0x06, 0, 0x01, 0, 0x03, 0, 0x08, 0, 0x08, 0x80, 0x05, 0, 0xf6, 0,
        0xfd, 0, 0xfc, 0, 0x0a, 0, 0x0c, 0, 0x07, 0, 0x0b, 0, 0xfd, 0
      ]);
      assertBytes(encoded.values, []);
    });

    it('distinguishesNullEmptyBytesEmptyTextEmojiAndBooleans', 0, () => {
      const encoded = encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.Null, null),
        new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
        new MySqlParameter(MySqlParameterType.Text, ''),
        new MySqlParameter(MySqlParameterType.Text, '\uD83D\uDE00'),
        new MySqlParameter(MySqlParameterType.Boolean, false),
        new MySqlParameter(MySqlParameterType.Boolean, true),
        new MySqlParameter(MySqlParameterType.Json, 'null'),
        new MySqlParameter(MySqlParameterType.UInt64, null),
        new MySqlParameter(MySqlParameterType.Text, null)
      ]);
      assertBytes(encoded.nullBitmap, [0x81, 0x01]);
      assertBytes(encoded.types, [
        0x06, 0, 0xfc, 0, 0xfd, 0, 0xfd, 0, 0x01, 0, 0x01, 0, 0xfd, 0, 0x08, 0x80, 0xfd, 0
      ]);
      assertBytes(encoded.values, [0, 0, 4, 0xf0, 0x9f, 0x98, 0x80, 0, 1, 4, 0x6e, 0x75, 0x6c, 0x6c]);
    });

    it('snapshotsBytesAtConstructionAndEncoding', 0, () => {
      const input = new Uint8Array([0xee, 1, 2, 0xee]);
      const parameter = new MySqlParameter(MySqlParameterType.Binary, input.subarray(1, 3));
      input[1] = 9;
      const exposed = parameter.value;
      if (!(exposed instanceof Uint8Array)) throw new Error('Binary snapshot must remain bytes');
      exposed[0] = 8;
      const encoded = encodeBinaryParameters([parameter]);
      assertBytes(encoded.values, [2, 1, 2]);
      input[2] = 7;
      exposed[1] = 6;
      assertBytes(encoded.values, [2, 1, 2]);
      assertBytes(encodeBinaryParameters([parameter]).values, [2, 1, 2]);
    });

    it('preservesSignedIntegersAndDoubleWireTypes', 0, () => {
      const encoded = encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.Int32, -2147483648),
        new MySqlParameter(MySqlParameterType.Int64, 9007199254740993n),
        new MySqlParameter(MySqlParameterType.Int64, -9223372036854775808n),
        new MySqlParameter(MySqlParameterType.Float64, 1.5),
        new MySqlParameter(MySqlParameterType.Float64, -0)
      ]);
      assertBytes(encoded.types, [3, 0, 8, 0, 8, 0, 5, 0, 5, 0]);
      assertBytes(encoded.values, [
        0, 0, 0, 0x80,
        1, 0, 0, 0, 0, 0, 0x20, 0,
        0, 0, 0, 0, 0, 0, 0, 0x80,
        0, 0, 0, 0, 0, 0, 0xf8, 0x3f,
        0, 0, 0, 0, 0, 0, 0, 0x80
      ]);
    });

    it('requiresExactInputKindsAndIntegerRanges', 0, () => {
      assertInvalid(MySqlParameterType.Null, 'NULL');
      assertInvalid(MySqlParameterType.Boolean, 1);
      assertInvalid(MySqlParameterType.Boolean, 'false');
      assertInvalid(MySqlParameterType.Int32, 1n);
      assertInvalid(MySqlParameterType.Int32, 1.5);
      assertInvalid(MySqlParameterType.Int32, -2147483649);
      assertInvalid(MySqlParameterType.Int64, 1);
      assertInvalid(MySqlParameterType.Int64, '1');
      assertInvalid(MySqlParameterType.Int64, -9223372036854775809n);
      assertInvalid(MySqlParameterType.Int64, 9223372036854775808n);
      assertInvalid(MySqlParameterType.UInt64, 1);
      assertInvalid(MySqlParameterType.UInt64, -1n);
      assertInvalid(MySqlParameterType.UInt64, 18446744073709551616n);
      assertInvalid(MySqlParameterType.Float64, 1n);
      assertInvalid(MySqlParameterType.Float64, -Infinity);
      assertInvalid(MySqlParameterType.Decimal, 12.34);
      assertInvalid(MySqlParameterType.Text, true);
      assertInvalid(MySqlParameterType.Binary, '00');
      assertInvalid(MySqlParameterType.Date, 20240101);
      assertInvalid(MySqlParameterType.DateTime, 0);
      assertInvalid(MySqlParameterType.Timestamp, 0);
      assertInvalid(MySqlParameterType.Time, 0);
      assertInvalid(MySqlParameterType.Json, true);
      assertInvalid('unknown' as MySqlParameterType, null);
    });

    it('enforcesCanonicalDecimalPrecisionAndScaleWithoutRounding', 0, () => {
      for (const invalid of ['', '01', '-01', '+1', '.1', '1.', '1e3', ' 1', '1 ', '1\n', '1,000']) {
        assertInvalid(MySqlParameterType.Decimal, invalid);
      }
      assertBytes(encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.Decimal, '-0.00')
      ]).values, [5, 0x2d, 0x30, 0x2e, 0x30, 0x30]);
      const precision65 = '9'.repeat(65);
      expect(encodeBinaryParameters([new MySqlParameter(MySqlParameterType.Decimal, precision65)])
        .values.length).assertEqual(66);
      const scale30 = '9'.repeat(35) + '.' + '1'.repeat(30);
      expect(encodeBinaryParameters([new MySqlParameter(MySqlParameterType.Decimal, scale30)])
        .values.length).assertEqual(67);
      assertInvalid(MySqlParameterType.Decimal, '9'.repeat(66));
      assertInvalid(MySqlParameterType.Decimal, '0.' + '1'.repeat(31));
      assertInvalid(MySqlParameterType.Decimal, '9'.repeat(36) + '.' + '1'.repeat(30));
    });

    it('validatesJsonSyntaxButBindsOriginalUtf8AsVarString', 0, () => {
      const encoded = encodeBinaryParameters([new MySqlParameter(MySqlParameterType.Json, '{"a":1}')]);
      assertBytes(encoded.types, [0xfd, 0]);
      assertBytes(encoded.values, [7, 0x7b, 0x22, 0x61, 0x22, 0x3a, 0x31, 0x7d]);
      for (const valid of ['null', 'true', '1e2', '"text"', '[]', ' \n{"a": 1}\t']) {
        expect(new MySqlParameter(MySqlParameterType.Json, valid).value === valid).assertTrue();
      }
      for (const invalid of ['', 'undefined', 'NaN', 'Infinity', '{"a":}', '[1,]', 'null x']) {
        assertInvalid(MySqlParameterType.Json, invalid);
      }
    });

    it('encodesZeroTemporalsWithoutInventingDatesOrTimezones', 0, () => {
      const encoded = encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.Date, '0000-00-00'),
        new MySqlParameter(MySqlParameterType.DateTime, '0000-00-00 00:00:00.000000'),
        new MySqlParameter(MySqlParameterType.Timestamp, '0000-00-00 00:00:00'),
        new MySqlParameter(MySqlParameterType.Time, '-000:00:00.000000')
      ]);
      assertBytes(encoded.types, [0x0a, 0, 0x0c, 0, 0x07, 0, 0x0b, 0]);
      assertBytes(encoded.values, [0, 0, 0, 0]);
    });

    it('encodesGregorianDatesAndDatetimeLengthVariants', 0, () => {
      const encoded = encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.Date, '2024-02-29'),
        new MySqlParameter(MySqlParameterType.DateTime, '2000-01-02 00:00:00'),
        new MySqlParameter(MySqlParameterType.Timestamp, '2026-07-20 09:30:45'),
        new MySqlParameter(MySqlParameterType.DateTime, '2026-07-20 09:30:45.123456')
      ]);
      assertBytes(encoded.values, [
        4, 0xe8, 7, 2, 0x1d,
        4, 0xd0, 7, 1, 2,
        7, 0xea, 7, 7, 0x14, 9, 0x1e, 0x2d,
        11, 0xea, 7, 7, 0x14, 9, 0x1e, 0x2d, 0x40, 0xe2, 1, 0
      ]);
    });

    it('encodesNegativeMultiDayAndMaximumTimeMicroseconds', 0, () => {
      const encoded = encodeBinaryParameters([
        new MySqlParameter(MySqlParameterType.Time, '-25:02:03'),
        new MySqlParameter(MySqlParameterType.Time, '-838:59:59.000001'),
        new MySqlParameter(MySqlParameterType.Time, '838:59:59.999999'),
        new MySqlParameter(MySqlParameterType.Time, '0:00:00.1')
      ]);
      assertBytes(encoded.values, [
        8, 1, 1, 0, 0, 0, 1, 2, 3,
        12, 1, 0x22, 0, 0, 0, 0x16, 0x3b, 0x3b, 1, 0, 0, 0,
        12, 0, 0x22, 0, 0, 0, 0x16, 0x3b, 0x3b, 0x3f, 0x42, 0x0f, 0,
        12, 0, 0, 0, 0, 0, 0, 0, 0, 0xa0, 0x86, 1, 0
      ]);
    });

    it('rejectsInvalidGregorianPartialZeroAndNonWallClockInputs', 0, () => {
      for (const value of [
        '2024-00-01', '2024-01-00', '0000-01-01', '2024-02-30', '2023-02-29',
        '1900-02-29', '10000-01-01', '2024-1-01', '2024-01-01\n'
      ]) {
        assertInvalid(MySqlParameterType.Date, value);
      }
      for (const value of [
        '0000-00-00 00:00:01', '0000-00-00 00:00:00.000001', '2024-00-01 00:00:00',
        '2024-01-01 24:00:00', '2024-01-01 00:60:00', '2024-01-01 00:00:60',
        '2024-01-01T00:00:00', '2024-01-01 00:00:00Z', '2024-01-01 00:00:00+00:00',
        '2024-01-01 00:00:00.', '2024-01-01 00:00:00.0000001', '2024-01-01 00:00:00\n'
      ]) {
        assertInvalid(MySqlParameterType.DateTime, value);
        assertInvalid(MySqlParameterType.Timestamp, value);
      }
      expect(new MySqlParameter(MySqlParameterType.Date, '2000-02-29').value === '2000-02-29').assertTrue();
      expect(new MySqlParameter(MySqlParameterType.Date, '0001-01-01').value === '0001-01-01').assertTrue();
      expect(new MySqlParameter(MySqlParameterType.Date, '9999-12-31').value === '9999-12-31').assertTrue();
    });

    it('rejectsInvalidTimeMagnitudeComponentsAndFractions', 0, () => {
      for (const value of [
        '839:00:00', '-839:00:00', '838:60:00', '1:00:60', '+1:00:00', '1000:00:00',
        '1:2:03', '1:02:3', '1:00:00.', '1:00:00.0000001', ' 1:00:00', '1:00:00\n'
      ]) {
        assertInvalid(MySqlParameterType.Time, value);
      }
    });

    it('usesLengthEncodedBinaryBoundaries', 0, () => {
      const lengths: number[] = [250, 251, 65535, 65536];
      const prefixes: number[][] = [[250], [0xfc, 0xfb, 0], [0xfc, 0xff, 0xff], [0xfd, 0, 0, 1]];
      for (let index = 0; index < lengths.length; index += 1) {
        const encoded = encodeBinaryParameters([
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(lengths[index]))
        ]);
        assertBytes(encoded.values.subarray(0, prefixes[index].length), prefixes[index]);
        expect(encoded.values.length).assertEqual(lengths[index] + prefixes[index].length);
      }
    });

    it('enforcesTheExact16MiBCommandBudgetIncludingMetadata', 0, () => {
      const input = new Uint8Array(16777198);
      input[0] = 0x11;
      input[input.length - 1] = 0x22;
      const encoded = encodeBinaryParameters([new MySqlParameter(MySqlParameterType.Binary, input)]);
      expect(encoded.values.length).assertEqual(16777202);
      expect(10 + encoded.nullBitmap.length + 1 + encoded.types.length + encoded.values.length)
        .assertEqual(16777216);
      assertBytes(encoded.values.subarray(0, 5), [0xfd, 0xee, 0xff, 0xff, 0x11]);
      expect(encoded.values[encoded.values.length - 1]).assertEqual(0x22);
      assertValidation(() => {
        encodeBinaryParameters([new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(16777199))]);
      });
    });

    it('budgetsAggregateValuesAndActualUtf8BytesBeforeEncoding', 0, () => {
      const half = new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(8388597));
      assertValidation(() => { encodeBinaryParameters([half, half]); });
      assertValidation(() => {
        encodeBinaryParameters([new MySqlParameter(MySqlParameterType.Text, '\uD83D\uDE00'.repeat(4194304))]);
      });
    });

    it('enforces65535ParametersAndThePreparedCount', 0, () => {
      const parameters: MySqlParameter[] = [];
      const nullValue = new MySqlParameter(MySqlParameterType.Null, null);
      for (let index = 0; index < 65535; index += 1) parameters.push(nullValue);
      const encoded = encodeBinaryParameters(parameters, 65535);
      expect(encoded.nullBitmap.length).assertEqual(8192);
      expect(encoded.nullBitmap[8191]).assertEqual(0x7f);
      expect(encoded.types.length).assertEqual(131070);
      expect(encoded.values.length).assertEqual(0);
      parameters.push(nullValue);
      assertValidation(() => { encodeBinaryParameters(parameters); });
      assertValidation(() => { encodeBinaryParameters([nullValue], 0); });
      assertValidation(() => { encodeBinaryParameters([nullValue], 2); });
      for (const invalid of [-1, 0.5, NaN, Infinity, 65536]) {
        assertValidation(() => { encodeBinaryParameters([], invalid); });
      }
      const empty = encodeBinaryParameters([], 0);
      assertBytes(empty.nullBitmap, []);
      assertBytes(empty.types, []);
      assertBytes(empty.values, []);
    });

    it('revalidatesValuesAndRejectsSparseInputsAtExecutionPreflight', 0, () => {
      assertValidation(() => { encodeBinaryParameters([new InvalidatedInt32Parameter()]); });
      assertValidation(() => { encodeBinaryParameters(new Array<MySqlParameter>(1)); });
    });

    it('capturesParameterListBeforeAValueGetterAppends', 0, () => {
      const parameters: MySqlParameter[] = [];
      parameters.push(new ListMutatingTextParameter('A', (): void => {
        parameters.push(new MySqlParameter(MySqlParameterType.Null, null));
      }));
      const encoded = encodeBinaryParameters(parameters, 1);
      expect(parameters.length).assertEqual(2);
      assertBytes(encoded.nullBitmap, [0]);
      assertBytes(encoded.types, [0xfd, 0]);
      assertBytes(encoded.values, [1, 0x41]);
    });

    it('ignoresGetterAppendsThatCross65535Parameters', 0, () => {
      const parameters: MySqlParameter[] = [];
      const appended = new MySqlParameter(MySqlParameterType.Null, null);
      parameters.push(new ListMutatingTextParameter('A', (): void => {
        for (let index = 0; index < 65535; index += 1) parameters.push(appended);
      }));
      const encoded = encodeBinaryParameters(parameters, 1);
      expect(parameters.length).assertEqual(65536);
      assertBytes(encoded.nullBitmap, [0]);
      assertBytes(encoded.types, [0xfd, 0]);
      assertBytes(encoded.values, [1, 0x41]);
    });

    it('preservesCapturedEntriesWhenAValueGetterReplacesTheOriginalList', 0, () => {
      const parameters: MySqlParameter[] = [];
      const replacement = new MySqlParameter(MySqlParameterType.Null, null);
      parameters.push(new ListMutatingTextParameter('A', (): void => {
        parameters[0] = replacement;
        parameters[1] = replacement;
      }));
      parameters.push(new MySqlParameter(MySqlParameterType.Int32, 7));
      const encoded = encodeBinaryParameters(parameters, 2);
      expect(parameters[0] === replacement && parameters[1] === replacement).assertTrue();
      assertBytes(encoded.nullBitmap, [0]);
      assertBytes(encoded.types, [0xfd, 0, 3, 0]);
      assertBytes(encoded.values, [1, 0x41, 7, 0, 0, 0]);
    });

    it('preservesCapturedEntriesWhenAValueGetterShrinksTheOriginalList', 0, () => {
      const parameters: MySqlParameter[] = [];
      parameters.push(new ListMutatingTextParameter('A', (): void => { parameters.length = 0; }));
      parameters.push(new MySqlParameter(MySqlParameterType.Int64, 9007199254740993n));
      parameters.push(new MySqlParameter(MySqlParameterType.Text, null));
      const encoded = encodeBinaryParameters(parameters, 3);
      expect(parameters.length).assertEqual(0);
      assertBytes(encoded.nullBitmap, [4]);
      assertBytes(encoded.types, [0xfd, 0, 8, 0, 0xfd, 0]);
      assertBytes(encoded.values, [1, 0x41, 1, 0, 0, 0, 0, 0, 0x20, 0]);
    });

    it('usesOnlyCapturedParametersForTheExact16MiBTextBudget', 0, () => {
      const parameters: MySqlParameter[] = [];
      parameters.push(new ListMutatingTextParameter('x'.repeat(16777198), (): void => {
        parameters.push(new MySqlParameter(MySqlParameterType.Null, null));
      }));
      const encoded = encodeBinaryParameters(parameters, 1);
      expect(parameters.length).assertEqual(2);
      expect(10 + encoded.nullBitmap.length + 1 + encoded.types.length + encoded.values.length)
        .assertEqual(16777216);
      assertBytes(encoded.nullBitmap, [0]);
      assertBytes(encoded.types, [0xfd, 0]);
      expect(encoded.values.length).assertEqual(16777202);
      assertBytes(encoded.values.subarray(0, 5), [0xfd, 0xee, 0xff, 0xff, 0x78]);
      expect(encoded.values[encoded.values.length - 1]).assertEqual(0x78);
      const oversized: MySqlParameter[] = [];
      oversized.push(new ListMutatingTextParameter('x'.repeat(16777199), (): void => {
        oversized.length = 0;
      }));
      assertValidation(() => { encodeBinaryParameters(oversized, 1); });
    });
  });
}

class ListMutatingTextParameter extends MySqlParameter {
  private readonly text: string;
  private readonly mutateList: () => void;

  constructor(text: string, mutateList: () => void) {
    super(MySqlParameterType.Text, text);
    this.text = text;
    this.mutateList = mutateList;
  }

  get value(): MySqlParameterValue {
    this.mutateList();
    return this.text;
  }
}

class InvalidatedInt32Parameter extends MySqlParameter {
  constructor() {
    super(MySqlParameterType.Int32, 0);
  }

  get value(): MySqlParameterValue {
    return 'not-an-integer';
  }
}

function assertInvalid(type: MySqlParameterType, value: MySqlParameterValue): void {
  assertValidation(() => { new MySqlParameter(type, value); });
}

function assertValidation(action: () => void): void {
  let caught: ArkDbError | null = null;
  try {
    action();
  } catch (error) {
    caught = error as ArkDbError;
  }
  expect(caught instanceof ArkDbError).assertTrue();
  expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
