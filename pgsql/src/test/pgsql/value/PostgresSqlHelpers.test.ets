import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  MAX_POSTGRES_IDENTIFIER_BYTES, postgresPlaceholders, quotePostgresIdentifier
} from '../../../main/ets/pgsql/value/PostgresSqlHelpers';

export default function postgresSqlHelpersTest(): void {
  describe('PostgresSqlHelpers', () => {
    it('quotesSegmentsEscapesDoubleQuotesAndPreservesInput', 0, () => {
      expect(MAX_POSTGRES_IDENTIFIER_BYTES).assertEqual(63);
      expect(quotePostgresIdentifier(['public'])).assertEqual('"public"');
      expect(quotePostgresIdentifier(['$user'])).assertEqual('"$user"');
      expect(quotePostgresIdentifier(['public', 'my"tbl'])).assertEqual('"public"."my""tbl"');
      expect(quotePostgresIdentifier(['"', 'a""b', '""'])).assertEqual('""""."a""""b".""""""');
      expect(quotePostgresIdentifier(['*', 'a.b', 'x"; DROP TABLE users --']))
        .assertEqual('"*".' + '"a.b".' + '"x""; DROP TABLE users --"');
      const parts: string[] = [' public ', '\n\t', 'c.d'];
      expect(quotePostgresIdentifier(parts)).assertEqual('" public "."\n\t"."c.d"');
      expect(parts.length === 3 && parts[0] === ' public ' && parts[1] === '\n\t' && parts[2] === 'c.d')
        .assertTrue();
    });

    it('enforcesExact63Utf8ByteIdentifierSegmentLimitAcrossUnicodeWidths', 0, () => {
      const ascii63 = 'a'.repeat(63);
      expect(quotePostgresIdentifier([ascii63])).assertEqual('"' + ascii63 + '"');
      const quoted63 = 'a'.repeat(62) + '"';
      expect(quotePostgresIdentifier([quoted63])).assertEqual('"' + 'a'.repeat(62) + '"""');
      const twoByte63 = '\u00E9'.repeat(31) + 'z';
      expect(quotePostgresIdentifier([twoByte63])).assertEqual('"' + twoByte63 + '"');
      const cjk63 = '\u4E2D'.repeat(21);
      expect(quotePostgresIdentifier([cjk63])).assertEqual('"' + cjk63 + '"');
      const emoji63 = '\uD83D\uDE00'.repeat(15) + 'abc';
      expect(quotePostgresIdentifier([emoji63])).assertEqual('"' + emoji63 + '"');

      for (const overlong of [
        ['a'.repeat(64)],
        ['public', 'a'.repeat(64)],
        ['\u00E9'.repeat(32)],
        ['\u4E2D'.repeat(22)],
        ['\uD83D\uDE00'.repeat(16)],
        ['\uD83D\uDE00'.repeat(15) + 'abcd']
      ]) {
        expectValidationError((): void => { quotePostgresIdentifier(overlong); });
      }
    });

    it('rejectsEmptyNullNulAndUnpairedSurrogateIdentifierSegments', 0, () => {
      expectValidationError((): void => { quotePostgresIdentifier([]); });
      const nullParts: string[] | null = null;
      const undefParts: string[] | undefined = undefined;
      expectValidationError((): void => { quotePostgresIdentifier(nullParts!); });
      expectValidationError((): void => { quotePostgresIdentifier(undefParts!); });
      for (const badParts of [
        [''], ['', 'tbl'], ['public', ''], ['db', '', 'tbl'],
        ['\u0000'], ['\u0000tbl'], ['tbl\u0000'], ['public', 'my\u0000tbl'],
        [String.fromCharCode(0xD800)],
        [String.fromCharCode(0xD800) + 'a'],
        [String.fromCharCode(0xDC00)],
        [String.fromCharCode(0xDC00) + String.fromCharCode(0xD800)],
        ['public', 'bad' + String.fromCharCode(0xDBFF)]
      ]) {
        expectValidationError((): void => { quotePostgresIdentifier(badParts); });
      }
    });

    it('generatesIndexedPostgresPlaceholdersAndValidatesBounds', 0, () => {
      expect(postgresPlaceholders(1)).assertEqual('$1');
      expect(postgresPlaceholders(3)).assertEqual('$1,$2,$3');
      expect(postgresPlaceholders(2, 4)).assertEqual('$4,$5');
      expect(postgresPlaceholders(3, 65533)).assertEqual('$65533,$65534,$65535');
      expect(postgresPlaceholders(1, 65535)).assertEqual('$65535');

      const maxAll = postgresPlaceholders(65535);
      const tokens = maxAll.split(',');
      expect(tokens.length === 65535 && tokens[0] === '$1' && tokens[65534] === '$65535').assertTrue();

      const badCases: number[][] = [
        [0, 1], [-0, 1], [-1, 1], [65536, 1], [1.5, 1], [Number.NaN, 1],
        [Number.POSITIVE_INFINITY, 1], [Number.NEGATIVE_INFINITY, 1], [Number.MAX_SAFE_INTEGER + 1, 1],
        [1, 0], [1, -1], [1, 65536], [1, 1.5], [1, Number.NaN],
        [1, Number.POSITIVE_INFINITY], [1, Number.NEGATIVE_INFINITY],
        [2, 65535], [65535, 2], [10, 65527]
      ];
      for (const bad of badCases) {
        expectValidationError((): void => { postgresPlaceholders(bad[0], bad[1]); });
      }
    });
  });
}

function expectValidationError(action: () => void): void {
  let caught: Object | null = null;
  try {
    action();
  } catch (error) {
    caught = error as Object;
  }
  expect(caught instanceof ArkDbError && caught.kind === ArkDbErrorKind.Validation &&
    caught.message.length > 0).assertTrue();
}
