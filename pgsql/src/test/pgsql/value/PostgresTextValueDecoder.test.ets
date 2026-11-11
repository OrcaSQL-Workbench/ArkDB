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
      expect(columns.length).assertEqual(2);
      expect(columns[0].name).assertEqual('amount');
      expect(columns[0].tableOid).assertEqual(16400);
      expect(columns[0].columnAttributeNumber).assertEqual(2);
      expect(columns[0].typeOid).assertEqual(1700);
      expect(columns[0].typeSize).assertEqual(-1);
      expect(columns[0].typeModifier).assertEqual(786438);
      expect(columns[0].formatCode).assertEqual(0);
      expect(columns[0].nativeTypeId).assertEqual('1700');
      expect(columns[0].nativeTypeName).assertEqual('numeric');
      expect(columns[0].valueKind).assertEqual(DbValueKind.Decimal);
      expect(columns[0].sourceSchema).assertEqual('');
      expect(columns[0].sourceTable).assertEqual('');
      expect(columns[0].nullable).assertTrue();
      expect(columns[1].nativeTypeId).assertEqual('24576');
      expect(columns[1].nativeTypeName).assertEqual('');
      expect(columns[1].valueKind).assertEqual(DbValueKind.Unknown);
      expect(columns[1].formatCode).assertEqual(1);
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
        expect(decodeText(
          oid, '0.' + '0'.repeat(350) + '1000000000000000111022302462515654042363166809082031251e+351'
        )).assertEqual(1.0000000000000002);
        expectNegZero(decodeText(oid, '-0'));
        expectNegZero(decodeText(oid, '-0.0e+500'));
        expect(decodeText(oid, '-12.5')).assertEqual(-12.5);
        assertTextRejectsAll(oid, [
          '', '+Infinity', 'nan', 'inf', '+1.5', '+', '-', '0x10', ' 1.5', '1.5 ', '.5', '5.', '01.5'
        ]);
      }
      expect(typeof decodeText(700, '3.4028235e+38')).assertEqual('number');
      expect(typeof decodeText(700, '3.4028235677973365e+38')).assertEqual('number');
      expect(typeof decodeText(700, '-3.4028235677973365e+38')).assertEqual('number');
      const nearMax = decodeText(701, '1.7976931348623155e+308') as number;
      const nearMax5 = decodeText(701, '1.7976931348623147e+308') as number;
      expect(Number.isFinite(nearMax) && nearMax < Number.MAX_VALUE && nearMax5 < nearMax)
        .assertTrue();
      expect(decodeText(701, '-1.7976931348623155e+308')).assertEqual(-nearMax);
      expect(decodeText(701, '1.7976931348623157e+308')).assertEqual(Number.MAX_VALUE);
      expect(decodeText(701, '-1.7976931348623157e+308')).assertEqual(-Number.MAX_VALUE);
      expect(decodeText(701, '1.7976931348623157e+' + '0'.repeat(4096) + '308'))
        .assertEqual(Number.MAX_VALUE);
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
      for (const badUuid of [
        '', 'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11', '{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}',
        'a0eebc999c0b4ef8bb6d6bb9bd380a11', 'a0eebc9-99c0b-4ef8-bb6d-6bb9bd380a11',
        'g0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'
      ]) {
        assertTextRejects(2950, badUuid);
      }

      const temporalCases: Array<[number, string]> = [
        [1082, '2026-11-11'], [1082, '0042-03-15 BC'], [1083, '21:13:17.123456'],
        [1266, '21:13:17.123456+08:30'], [1114, '2026-11-11 21:13:17.123456'],
        [1184, 'infinity'], [1184, '-infinity'], [1186, '1 year 2 mons -03:04:05.6789']
      ];
      for (const entry of temporalCases) {
        expect(decodeText(entry[0], entry[1])).assertEqual(entry[1]);
        assertTextRejects(entry[0], '');
        assertTextRejects(entry[0], '   ');
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

      assertThrowsKind(() => {
        decodePostgresDataRow(new PostgresDataRow([ascii('t')]), cols);
      }, ArkDbErrorKind.Protocol);
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
  expect(typeof value === 'number' && (value as number) === 0 &&
    1 / (value as number) === Number.NEGATIVE_INFINITY).assertTrue();
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
