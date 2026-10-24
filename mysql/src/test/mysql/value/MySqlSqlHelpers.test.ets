import { describe, it, expect } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { mysqlPlaceholders, quoteMySqlIdentifier } from '../../../main/ets/mysql/value/MySqlSqlHelpers';

export default function mySqlSqlHelpersTest(): void {
  describe('MySqlSqlHelpers', () => {
    it('quotesEachIdentifierSegment', 0, () => {
      expect(quoteMySqlIdentifier(['a.b', 'c`d'])).assertEqual('`a.b`.`c``d`');
    });

    it('preservesEmojiAndDotsWithinIdentifierSegments', 0, () => {
      expect(quoteMySqlIdentifier(['db.\uD83D\uDC2C', 'c`\uD83D\uDC2C.d']))
        .assertEqual('`db.\uD83D\uDC2C`.`c``\uD83D\uDC2C.d`');
    });

    it('doublesEveryEmbeddedBacktick', 0, () => {
      expect(quoteMySqlIdentifier(['`', 'a``b', '``'])).assertEqual('````.`a````b`.``````');
    });

    it('quotesWildcardsAndSqlLookingSegmentsLiterally', 0, () => {
      expect(quoteMySqlIdentifier(['*', 'db.*', 'x`; SELECT 1 --']))
        .assertEqual('`*`.`db.*`.`x``; SELECT 1 --`');
    });

    it('preservesWhitespaceWithoutMutatingIdentifierParts', 0, () => {
      const parts = [' a ', '\n\t', 'c.d'];
      expect(quoteMySqlIdentifier(parts)).assertEqual('` a `.`\n\t`.`c.d`');
      expect(parts.length).assertEqual(3);
      expect(parts[0]).assertEqual(' a ');
      expect(parts[1]).assertEqual('\n\t');
      expect(parts[2]).assertEqual('c.d');
    });

    it('leavesObjectSpecificIdentifierLengthLimitsToTheServer', 0, () => {
      expect(quoteMySqlIdentifier(['a'.repeat(65)]).length).assertEqual(67);
    });

    it('rejectsEmptyIdentifierParts', 0, () => {
      expectValidationError(() => { quoteMySqlIdentifier([]); });
    });

    it('rejectsEmptyIdentifierSegmentsAtAnyPosition', 0, () => {
      const invalidParts: string[][] = [[''], ['', 'table'], ['schema', ''], ['schema', '', 'table']];
      for (const parts of invalidParts) {
        expectValidationError(() => { quoteMySqlIdentifier(parts); });
      }
    });

    it('rejectsNulInAnyIdentifierSegment', 0, () => {
      const invalidParts: string[][] = [
        ['\u0000'], ['schema', 'na\u0000me'], ['schema\u0000', 'table'], ['valid', '\u0000table']
      ];
      for (const parts of invalidParts) {
        expectValidationError(() => { quoteMySqlIdentifier(parts); });
      }
    });

    it('generatesCommaSeparatedPlaceholders', 0, () => {
      expect(mysqlPlaceholders(1)).assertEqual('?');
      expect(mysqlPlaceholders(2)).assertEqual('?,?');
      expect(mysqlPlaceholders(3)).assertEqual('?,?,?');
    });

    it('supportsTheMaximumPlaceholderCount', 0, () => {
      const placeholders: string = mysqlPlaceholders(65535);
      expect(placeholders.length).assertEqual(131069);
      const tokens: string[] = placeholders.split(',');
      expect(tokens.length).assertEqual(65535);
      expect(tokens.every((token: string): boolean => token === '?')).assertTrue();
    });

    it('rejectsZeroPlaceholderCounts', 0, () => {
      expectValidationError(() => { mysqlPlaceholders(0); });
      expectValidationError(() => { mysqlPlaceholders(-0); });
    });

    it('rejectsNegativeOrExcessivePlaceholderCounts', 0, () => {
      const counts = [-1, -65535, 65536, Number.MAX_SAFE_INTEGER];
      for (const count of counts) {
        expectValidationError(() => { mysqlPlaceholders(count); });
      }
    });

    it('rejectsFractionalPlaceholderCounts', 0, () => {
      const counts = [-0.5, 0.5, 1.5, 65534.5, 65535.5];
      for (const count of counts) {
        expectValidationError(() => { mysqlPlaceholders(count); });
      }
    });

    it('rejectsNonFinitePlaceholderCounts', 0, () => {
      const counts = [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY];
      for (const count of counts) {
        expectValidationError(() => { mysqlPlaceholders(count); });
      }
    });
  });
}

function expectValidationError(action: () => void): void {
  let caught = false;
  try {
    action();
  } catch (error) {
    if (!(error instanceof ArkDbError)) {
      throw new Error('Expected ArkDbError validation failure, received: ' + String(error));
    }
    expect(error.kind).assertEqual(ArkDbErrorKind.Validation);
    expect(error.message.length > 0).assertTrue();
    caught = true;
  }
  expect(caught).assertTrue();
}
