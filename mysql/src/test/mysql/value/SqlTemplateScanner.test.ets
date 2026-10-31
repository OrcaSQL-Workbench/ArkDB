import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { describe, expect, it } from '@ohos/hypium';
import { SqlTemplateScanner } from '../../../main/ets/mysql/value/SqlTemplateScanner';

export default function sqlTemplateScannerTest(): void {
  describe('MySQL SQL template scanner', () => {
    it('doesNotBindNamesInsideQuotesOrComments', 0, () => {
      const sql = "SELECT :live, ':single', \":double\", `:tick`, # :hash\n" +
        "-- :dash\n/* :block */ :live";
      const expected = "SELECT ?, ':single', \":double\", `:tick`, # :hash\n" +
        "-- :dash\n/* :block */ ?";
      const scanner = new SqlTemplateScanner();

      const ordinary = scanner.compile(sql, '');
      const ansi = scanner.compile(sql, ' ANSI_QUOTES ');

      expect(ordinary.sql).assertEqual(expected);
      expect(ordinary.parameterNames.join(',')).assertEqual('live,live');
      expect(ansi.sql).assertEqual(expected);
      expect(ansi.parameterNames.join(',')).assertEqual('live,live');
    });

    it('honorsNoBackslashEscapesWithoutCachingModes', 0, () => {
      const sql = "SELECT 'a\\':first \\'x', :second";
      const scanner = new SqlTemplateScanner();

      const escaped = scanner.compile(sql, '');
      const ordinary = scanner.compile(sql, 'strict_trans_tables, no_backslash_escapes');
      const escapedAgain = scanner.compile(sql, 'ANSI_QUOTES');

      expect(escaped.sql).assertEqual("SELECT 'a\\':first \\'x', ?");
      expect(escaped.parameterNames.join(',')).assertEqual('second');
      expect(ordinary.sql).assertEqual("SELECT 'a\\'? \\'x', ?");
      expect(ordinary.parameterNames.join(',')).assertEqual('first,second');
      expect(escapedAgain.sql).assertEqual(escaped.sql);
      expect(escapedAgain.parameterNames.join(',')).assertEqual('second');
    });

    it('doesNotTreatBackslashAsAnIdentifierQuoteEscape', 0, () => {
      const scanner = new SqlTemplateScanner();

      const backtick = scanner.compile('SELECT `identifier\\`, :p', '');
      const ansi = scanner.compile('SELECT "identifier\\", :p', 'ANSI_QUOTES');

      expect(backtick.sql).assertEqual('SELECT `identifier\\`, ?');
      expect(backtick.parameterNames.join(',')).assertEqual('p');
      expect(ansi.sql).assertEqual('SELECT "identifier\\", ?');
      expect(ansi.parameterNames.join(',')).assertEqual('p');
    });

    it('usesTheMySqlDashCommentWhitespaceRule', 0, () => {
      const sql = 'SELECT :a--x :b\n,:c-- \t:hidden\n,:d--\u0000:hidden\n,:e';
      const compiled = new SqlTemplateScanner().compile(sql, '');

      expect(compiled.sql).assertEqual('SELECT ?--x ?\n,?-- \t:hidden\n,?--\u0000:hidden\n,?');
      expect(compiled.parameterNames.join(',')).assertEqual('a,b,c,d,e');
    });

    it('endsLineCommentsOnlyAtLineFeed', 0, () => {
      const scanner = new SqlTemplateScanner();

      const hashCr = scanner.compile('# ignored\r:hidden\n :live', '');
      const dashCr = scanner.compile('-- ignored\r:hidden\n :live', '');
      const hashCrlf = scanner.compile('# ignored\r\n :live', '');
      const dashCrlf = scanner.compile('-- ignored\r\n :live', '');

      expect(hashCr.sql).assertEqual('# ignored\r:hidden\n ?');
      expect(hashCr.parameterNames.join(',')).assertEqual('live');
      expect(dashCr.sql).assertEqual('-- ignored\r:hidden\n ?');
      expect(dashCr.parameterNames.join(',')).assertEqual('live');
      expect(hashCrlf.sql).assertEqual('# ignored\r\n ?');
      expect(hashCrlf.parameterNames.join(',')).assertEqual('live');
      expect(dashCrlf.sql).assertEqual('-- ignored\r\n ?');
      expect(dashCrlf.parameterNames.join(',')).assertEqual('live');
    });

    it('preservesNewlinesNulEmojiAndLiteralColons', 0, () => {
      const sql = 'SELECT :_first9, :1, :=, :\uD83D\uDC2C, ' +
        "'\u0000:inside\uD83D\uDC2C'\r\n,:last_\uD83D\uDC2C";
      const compiled = new SqlTemplateScanner().compile(sql, '');

      expect(compiled.sql).assertEqual('SELECT ?, :1, :=, :\uD83D\uDC2C, ' +
        "'\u0000:inside\uD83D\uDC2C'\r\n,?\uD83D\uDC2C");
      expect(compiled.parameterNames.join(',')).assertEqual('_first9,last_');
    });

    it('rejectsExecutableCommentsAndPositionalMarkersOnlyInCode', 0, () => {
      const scanner = new SqlTemplateScanner();
      const invalid = [
        'SELECT ?', 'SELECT /*! :value */ 1', 'SELECT /*+ BKA(t) */ :value',
        'SELECT /*M! :value */ 1', 'SELECT /*m! :value */ 1'
      ];
      for (const sql of invalid) expectValidation((): void => { scanner.compile(sql, ''); });

      const valid = scanner.compile("SELECT '?', \"?\", `?`, # ?\n/* ? */ :value", '');
      expect(valid.sql).assertEqual("SELECT '?', \"?\", `?`, # ?\n/* ? */ ?");
      expect(valid.parameterNames.join(',')).assertEqual('value');
    });
  });
}

function expectValidation(action: () => void): void {
  let failure: Object | null = null;
  try { action(); } catch (error) { failure = error as Object; }
  expect(failure instanceof ArkDbError).assertTrue();
  if (!(failure instanceof ArkDbError)) throw new Error('Expected an ArkDbError validation failure.');
  expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
}
