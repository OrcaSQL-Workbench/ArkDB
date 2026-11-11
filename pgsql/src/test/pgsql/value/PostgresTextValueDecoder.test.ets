import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, DbValueKind, SqlValue } from '@arkdb/core';
import {
  PostgresDataRow, PostgresRowDescription, PostgresRowDescriptionColumn
} from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';
import { resolvePostgresTypeMetadata } from '../../../main/ets/pgsql/value/PostgresTypeOids';
import {
  decodePostgresColumnValue, decodePostgresDataRow, decodePostgresTextValue,
  toPostgresColumnDef, toPostgresColumnDefs
} from '../../../main/ets/pgsql/value/PostgresTextValueDecoder';

export default function postgresTextValueDecoderTest(): void {
  describe('PostgresTextValueDecoder', () => {
    it('mapsOfficialCatalogOidsAndRowDescriptionColumnsWithoutHiddenEnrichment', 0, () => {
      const scalarMappings: Array<[number, string, DbValueKind]> = [
        [16, 'bool', DbValueKind.Boolean], [17, 'bytea', DbValueKind.Binary],
        [18, 'char', DbValueKind.Text], [19, 'name', DbValueKind.Text],
        [20, 'int8', DbValueKind.BigInteger], [21, 'int2', DbValueKind.Integer],
        [23, 'int4', DbValueKind.Integer], [25, 'text', DbValueKind.Text],
        [26, 'oid', DbValueKind.Integer], [114, 'json', DbValueKind.Json],
        [142, 'xml', DbValueKind.Text], [700, 'float4', DbValueKind.FloatingPoint],
        [701, 'float8', DbValueKind.FloatingPoint], [790, 'money', DbValueKind.Text],
        [1042, 'bpchar', DbValueKind.Text], [1043, 'varchar', DbValueKind.Text],
        [1082, 'date', DbValueKind.Date], [1083, 'time', DbValueKind.Time],
        [1114, 'timestamp', DbValueKind.DateTime], [1184, 'timestamptz', DbValueKind.DateTime],
        [1186, 'interval', DbValueKind.Text], [1266, 'timetz', DbValueKind.Time],
        [1560, 'bit', DbValueKind.Text], [1562, 'varbit', DbValueKind.Text],
        [1700, 'numeric', DbValueKind.Decimal], [2950, 'uuid', DbValueKind.Uuid],
        [3802, 'jsonb', DbValueKind.Json]
      ];
      for (const entry of scalarMappings) assertOid(entry[0], entry[1], entry[2]);
      const arrayMappings: Array<[number, string]> = [
        [143, '_xml'], [199, '_json'], [791, '_money'], [1000, '_bool'], [1001, '_bytea'],
        [1002, '_char'], [1003, '_name'], [1005, '_int2'], [1007, '_int4'], [1009, '_text'],
        [1014, '_bpchar'], [1015, '_varchar'], [1016, '_int8'], [1021, '_float4'],
        [1022, '_float8'], [1028, '_oid'], [1115, '_timestamp'], [1182, '_date'],
        [1183, '_time'], [1185, '_timestamptz'], [1187, '_interval'], [1231, '_numeric'],
        [1270, '_timetz'], [1561, '_bit'], [1563, '_varbit'], [2951, '_uuid'], [3807, '_jsonb']
      ];
      for (const pair of arrayMappings) assertOid(pair[0], pair[1], DbValueKind.Array);
      for (const unknownOid of [0, 600, 16384, 4294967295]) assertOid(unknownOid, '', DbValueKind.Unknown);
      for (const badOid of [-1, 4294967296, 1.5, Number.NaN]) {
        assertThrowsKind(() => { resolvePostgresTypeMetadata(badOid); }, ArkDbErrorKind.Protocol);
      }

      const description = new PostgresRowDescription([
        new PostgresRowDescriptionColumn('amount', 16400, 2, 1700, -1, 786438, 0),
        new PostgresRowDescriptionColumn('custom_val', 0, 0, 24576, 8, -1, 1)
      ]);
      const columns = toPostgresColumnDefs(description);
      const c0 = columns[0];
      expect(columns.length === 2 && c0.name === 'amount' && c0.tableOid === 16400 &&
        c0.columnAttributeNumber === 2 && c0.typeOid === 1700 && c0.typeSize === -1 &&
        c0.typeModifier === 786438 && c0.formatCode === 0 && c0.nativeTypeId === '1700' &&
        c0.nativeTypeName === 'numeric' && c0.valueKind === DbValueKind.Decimal &&
        c0.sourceSchema === '' && c0.sourceTable === '' && c0.nullable).assertTrue();
      expect(columns[1].nativeTypeId === '24576' && columns[1].nativeTypeName === '' &&
        columns[1].valueKind === DbValueKind.Unknown && columns[1].formatCode === 1).assertTrue();
    });

    it('preservesSqlNullAndFailsClosedOnNonTextFormatsOrMalformedUtf8', 0, () => {
      expect(decodePostgresTextValue(23, 0, null)).assertNull();
      expect(decodePostgresTextValue(23, 1, null)).assertNull();
      expect(decodePostgresTextValue(16384, 99, null)).assertNull();
      for (const formatCode of [1, -1, 2]) {
        assertDecodeKind(23, formatCode, new Uint8Array([0, 0, 0, 1]), ArkDbErrorKind.Unsupported);
        assertDecodeKind(25, formatCode, new Uint8Array(0), ArkDbErrorKind.Unsupported);
      }
      const framed = new Uint8Array([
        0x00, 0xc3, 0xa9, 0xe4, 0xb8, 0xad, 0xf0, 0x9f, 0x98, 0x80, 0xef, 0xbf, 0xbd, 0xff
      ]);
      expect(decodePostgresTextValue(25, 0, framed.subarray(1, 13))).assertEqual('é中😀\uFFFD');
      for (const badBytes of [
        [0x00], [0x61, 0x00, 0x62], [0x80], [0xc0, 0xaf], [0xe0, 0x80, 0xaf],
        [0xed, 0xa0, 0x80], [0xf0, 0x80, 0x80, 0xaf], [0xf4, 0x90, 0x80, 0x80],
        [0xf5, 0x80, 0x80, 0x80], [0xc3], [0xe4, 0xb8], [0xf0, 0x9f, 0x98]
      ]) {
        assertDecodeKind(25, 0, new Uint8Array(badBytes), ArkDbErrorKind.Protocol);
      }
    });

    it('decodesBooleansAndCanonicalIntegersStrictly', 0, () => {
      expect(decodeText(16, 't')).assertEqual(true);
      expect(decodeText(16, 'f')).assertEqual(false);
      assertTextRejectsAll(16, ['', 'true', 'false', '1', '0', 'T', 'F', ' t', 't ']);
      expect(decodeText(21, '-32768')).assertEqual(-32768);
      expect(decodeText(21, '0')).assertEqual(0);
      expect(decodeText(21, '32767')).assertEqual(32767);
      assertTextRejectsAll(21, ['', '-32769', '32768', '+1', '01', '-0', ' 1', '1 ', '1.0', '1e2']);
      expect(decodeText(23, '-2147483648')).assertEqual(-2147483648);
      expect(decodeText(23, '0')).assertEqual(0);
      expect(decodeText(23, '2147483647')).assertEqual(2147483647);
      assertTextRejectsAll(23, ['', '-2147483649', '2147483648', '+7', '00', '-0', '7.0']);
      expect(decodeText(26, '0')).assertEqual(0);
      expect(decodeText(26, '4294967295')).assertEqual(4294967295);
      assertTextRejectsAll(26, ['', '-1', '-0', '4294967296', '+1', '01', ' 5']);
      expect(decodeText(20, '-9223372036854775808')).assertEqual(-9223372036854775808n);
      expect(decodeText(20, '0')).assertEqual(0n);
      expect(decodeText(20, '9007199254740993')).assertEqual(9007199254740993n);
      expect(decodeText(20, '9223372036854775807')).assertEqual(9223372036854775807n);
      assertTextRejectsAll(20, [
        '', '-9223372036854775809', '9223372036854775808', '+1', '01', '-0', '1.5', ' 9'
      ]);
    });

    it('decodesNumericAndFloatingPointValuesWithSpecialTokensAndOverflowChecks', 0, () => {
      for (const validNumeric of [
        '0', '0.0000', '-0.0050', '123456789012345678901234567890.000000000100',
        '1.25e-12', '-9e+24', 'NaN', 'Infinity', '-Infinity'
      ]) {
        expect(decodeText(1700, validNumeric)).assertEqual(validNumeric);
      }
      assertTextRejectsAll(1700, [
        '', ' 1.0', '1.0 ', '+1.23', '+Infinity', 'nan', '.5', '5.', '00.5', '1e', '1e+', 'abc'
      ]);

      for (const oid of [700, 701]) {
        expect(decodeText(oid, 'NaN')).assertEqual('NaN');
        expect(decodeText(oid, 'Infinity')).assertEqual('Infinity');
        expect(decodeText(oid, '-Infinity')).assertEqual('-Infinity');
        expect(decodeText(oid, '0')).assertEqual(0);
        expect(decodeText(oid, '0e+309')).assertEqual(0);
        expectNegZero(decodeText(oid, '-0'));
        expectNegZero(decodeText(oid, '-0.0e+500'));
        expect(decodeText(oid, '-12.5')).assertEqual(-12.5);
        assertTextRejectsAll(oid, [
          '', '+Infinity', 'nan', 'inf', '+1.5', '+', '-', '0x10', ' 1.5', '1.5 ', '.5', '5.', '01.5'
        ]);
      }
      const exact700Bits: Array<[string, number, number]> = [
        ['0.1', 0x3fb99999, 0xa0000000], ['0.10000001', 0x3fb99999, 0xc0000000],
        ['1e-45', 0x36a00000, 0x00000000], ['7e-46', 0x00000000, 0x00000000],
        ['-7e-46', 0x80000000, 0x00000000], ['3.4028234663852886e+38', 0x47efffff, 0xe0000000],
        ['3.4028235e+38', 0x47efffff, 0xe0000000], ['3.4028235677973365e+38', 0x47efffff, 0xe0000000],
        ['-3.4028235677973365e+38', 0xc7efffff, 0xe0000000]
      ];
      for (const vec of exact700Bits) assertFloat64Bits(decodeText(700, vec[0]), vec[1], vec[2]);
      const exact701Bits: Array<[string, number, number]> = [
        ['0.1', 0x3fb99999, 0x9999999a], ['1.0000000000000001106', 0x3ff00000, 0x00000000],
        ['1.00000000000000011102230246251565404236316680908203125', 0x3ff00000, 0x00000000],
        ['0.' + '0'.repeat(350) + '1000000000000000111022302462515654042363166809082031251e+351', 0x3ff00000, 0x00000001],
        ['1.9430538399282263e-44', 0x36dbbb70, 0xe036180f], ['4.501222173364241e-13', 0x3d5facae, 0x56160c35],
        ['2.4703282292062327e-324', 0x00000000, 0x00000000], ['2.4703282292062328e-324', 0x00000000, 0x00000001],
        ['-2.4703282292062328e-324', 0x80000000, 0x00000001], ['7.410984687618698e-324', 0x00000000, 0x00000001],
        ['7.410984687618699e-324', 0x00000000, 0x00000002], ['8.988465674311579e+307', 0x7fdfffff, 0xffffffff],
        ['9.999999999999999e+307', 0x7fe1ccf3, 0x85ebc89f], ['9.99999999999999999e+307', 0x7fe1ccf3, 0x85ebc8a0],
        ['1.7976931348623155e+308', 0x7fefffff, 0xfffffffe], ['-1.7976931348623155e+308', 0xffefffff, 0xfffffffe],
        ['1.7976931348623157e+308', 0x7fefffff, 0xffffffff], ['-1.7976931348623157e+308', 0xffefffff, 0xffffffff],
        ['1.7976931348623157e+' + '0'.repeat(4096) + '308', 0x7fefffff, 0xffffffff]
      ];
      for (const vec of exact701Bits) assertFloat64Bits(decodeText(701, vec[0]), vec[1], vec[2]);
      assertTextRejectsAll(700, [
        '3.40282356779733662e+38', '-3.40282356779733662e+38',
        '340282356779733662e+21', '3.4028235677973367e+38', '1e+39', '-1e+39'
      ]);
      assertTextRejectsAll(701, [
        '1.79769313486231585e+308', '-1.79769313486231585e+308',
        '1.7976931348623159e+308', '-1.7976931348623159e+308', '1e+309', '-1e+309',
        '1e' + '9'.repeat(4096)
      ]);
    });

    it('decodesByteaHexAndLegacyEscapeFormatsAndRejectsMalformedPayloads', 0, () => {
      assertBytes(decodeText(17, '\\x') as Uint8Array, []);
      assertBytes(decodeText(17, '\\x00ff41aB') as Uint8Array, [0x00, 0xff, 0x41, 0xab]);
      assertBytes(decodeText(17, '') as Uint8Array, []);
      assertBytes(
        decodeText(17, 'Hi\\\\!\\000\\007\\177\\200\\377\'') as Uint8Array,
        [0x48, 0x69, 0x5c, 0x21, 0x00, 0x07, 0x7f, 0x80, 0xff, 0x27]
      );
      assertTextRejectsAll(17, [
        '\\x0', '\\xabc', '\\xzz', '\\x00 ', ' \\x00', '\\', '\\0', '\\00', '\\n', '\\400',
        '\\777', '\\080'
      ]);
      for (const rawInvalid of [[0x00], [0x0a], [0x7f], [0x80], [0xc3, 0xa9]]) {
        assertDecodeKind(17, 0, new Uint8Array(rawInvalid), ArkDbErrorKind.Protocol);
      }
    });

    it('decodesUuidTemporalJsonArrayTextUnknownOidsAndFullDataRows', 0, () => {
      const canonicalUuid = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
      expect(decodeText(2950, canonicalUuid)).assertEqual(canonicalUuid);
      assertTextRejectsAll(2950, [
        '', 'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11', '{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}',
        'a0eebc999c0b4ef8bb6d6bb9bd380a11', 'a0eebc9-99c0b-4ef8-bb6d-6bb9bd380a11',
        'g0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'
      ]);
      const temporalCases: Array<[number, string]> = [
        [1082, '2026-11-11'], [1082, '0042-03-15 BC'], [1083, '21:13:17.123456'],
        [1266, '21:13:17.123456+08:30'], [1114, '2026-11-11 21:13:17.123456'],
        [1184, 'infinity'], [1184, '-infinity'], [1186, '1 year 2 mons -03:04:05.6789']
      ];
      for (const entry of temporalCases) {
        expect(decodeText(entry[0], entry[1])).assertEqual(entry[1]);
        assertTextRejectsAll(entry[0], ['', '   ']);
      }
      const rawJson = '{"id":9007199254740993,"dup":1,"dup":2}';
      expect(decodeText(114, rawJson)).assertEqual(rawJson);
      expect(decodeText(3802, rawJson)).assertEqual(rawJson);
      expect(decodeText(25, '')).assertEqual('');
      expect(decodeText(790, '$1,234.56')).assertEqual('$1,234.56');
      expect(decodeText(1560, '10101')).assertEqual('10101');
      expect(decodeText(1007, '{1,2,3}')).assertEqual('{1,2,3}');
      expect(decodeText(16384, '(1,2)')).assertEqual('(1,2)');

      const cols = [
        toPostgresColumnDef(new PostgresRowDescriptionColumn('flag', 0, 1, 16, 1, -1, 0)),
        toPostgresColumnDef(new PostgresRowDescriptionColumn('big', 0, 2, 20, 8, -1, 0)),
        toPostgresColumnDef(new PostgresRowDescriptionColumn('raw', 0, 3, 17, -1, -1, 0)),
        toPostgresColumnDef(new PostgresRowDescriptionColumn('missing', 0, 4, 23, 4, 0, 1)),
        toPostgresColumnDef(new PostgresRowDescriptionColumn('custom', 0, 5, 32768, -1, -1, 0))
      ];
      const row = new PostgresDataRow([
        ascii('t'), ascii('9007199254740995'), ascii('\\xdead'), null, ascii('opaque')
      ]);
      const values = decodePostgresDataRow(row, cols);
      expect(values.length).assertEqual(5);
      expect(values[0]).assertEqual(true);
      expect(values[1]).assertEqual(9007199254740995n);
      assertBytes(values[2] as Uint8Array, [0xde, 0xad]);
      expect(values[3]).assertNull();
      expect(values[4]).assertEqual('opaque');
      expect(decodePostgresColumnValue(cols[0], ascii('f'))).assertEqual(false);
      expect(decodePostgresDataRow(new PostgresDataRow([]), []).length).assertEqual(0);
      assertThrowsKind(() => { decodePostgresDataRow(new PostgresDataRow([ascii('t')]), cols); },
        ArkDbErrorKind.Protocol);
      assertThrowsKind(() => {
        decodePostgresDataRow(new PostgresDataRow([ascii('t'), ascii('f')]), [cols[0]]);
      }, ArkDbErrorKind.Protocol);
    });
  });
}

function assertOid(oid: number, expectedName: string, expectedKind: DbValueKind): void {
  const metadata = resolvePostgresTypeMetadata(oid);
  expect(metadata.typeOid).assertEqual(oid);
  expect(metadata.nativeTypeId).assertEqual(String(oid));
  expect(metadata.nativeTypeName).assertEqual(expectedName);
  expect(metadata.valueKind).assertEqual(expectedKind);
}

function ascii(text: string): Uint8Array {
  const bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index += 1) bytes[index] = text.charCodeAt(index);
  return bytes;
}

function decodeText(typeOid: number, text: string): SqlValue {
  return decodePostgresTextValue(typeOid, 0, ascii(text));
}

function assertTextRejects(typeOid: number, text: string): void {
  assertDecodeKind(typeOid, 0, ascii(text), ArkDbErrorKind.Protocol);
}

function assertTextRejectsAll(typeOid: number, values: string[]): void {
  for (const value of values) assertTextRejects(typeOid, value);
}

function assertDecodeKind(typeOid: number, formatCode: number, raw: Uint8Array,
  expectedKind: ArkDbErrorKind): void {
  assertThrowsKind(() => { decodePostgresTextValue(typeOid, formatCode, raw); }, expectedKind);
}

function assertThrowsKind(action: () => void, expectedKind: ArkDbErrorKind): void {
  let caught: ArkDbError | null = null;
  try {
    action();
  } catch (error) {
    if (error instanceof ArkDbError) caught = error;
    else throw error as Error;
  }
  expect(caught !== null && caught!.kind === expectedKind).assertTrue();
}

function expectNegZero(value: SqlValue): void {
  assertFloat64Bits(value, 0x80000000, 0x00000000);
}

function assertFloat64Bits(value: SqlValue, expectedHigh: number, expectedLow: number): void {
  expect(typeof value).assertEqual('number');
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, value as number, false);
  expect(view.getUint32(0, false)).assertEqual(expectedHigh);
  expect(view.getUint32(4, false)).assertEqual(expectedLow);
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
