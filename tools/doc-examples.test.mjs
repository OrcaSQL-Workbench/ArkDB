import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { ROOT } from './check-package.mjs';
import { extractExamples } from './doc-examples.mjs';

test('extracts self-contained ArkTS examples without modifying their code', () => {
  const code = "export const value: string = 'unchanged';\n";
  assert.deepEqual(extractExamples(`<!-- arkts-example: read -->\n\`\`\`typescript\n${code}\`\`\``),
    [{ name: 'read', source: code }]);
});

test('rejects duplicate example IDs and uncompiled documentation', () => {
  const example = '<!-- arkts-example: read -->\n```typescript\nexport const n = 1;\n```';
  assert.throws(() => extractExamples(`${example}\n${example}`), /Duplicate/);
  assert.throws(() => extractExamples('No tagged examples.'), /No compilable/);
});

test('the packaged guide covers all advertised execution examples', () => {
  const examples = extractExamples(readFileSync(join(ROOT, 'mysql', 'README.md'), 'utf8'));
  for (const name of ['quickstart', 'rows', 'errors', 'tls', 'streaming', 'transactions', 'cancellation', 'providers']) {
    assert.ok(examples.some((example) => example.name === name), `Missing compiled usage example: ${name}`);
  }
});

test('packaged transaction example uses native transaction runner', () => {
  const examples = extractExamples(readFileSync(join(ROOT, 'mysql', 'README.md'), 'utf8'));
  const transaction = examples.find((example) => example.name === 'transactions');
  assert.ok(transaction, 'Missing compiled transactions example.');
  assert.match(transaction.source, /\brequireMySqlFeatures\b/);
  assert.match(transaction.source, /\bMySqlTransactionOptions\b/);
  assert.match(transaction.source, /\.transactions\b/);
  assert.match(transaction.source, /\.run\s*\(/);
  assert.match(transaction.source, /\bsession\.query\s*\(/);
  assert.match(transaction.source, /\bsession\.(?:savepoint|rollbackTo|releaseSavepoint)\s*\(/);
  assert.doesNotMatch(transaction.source, /\.autocommit\s*=\s*false/);
  assert.doesNotMatch(transaction.source, /\bconnection\.(?:commit|rollback)\s*\(/);
});

test('packaged transaction example preserves primary and close failures', () => {
  const examples = extractExamples(readFileSync(join(ROOT, 'mysql', 'README.md'), 'utf8'));
  const transaction = examples.find((example) => example.name === 'transactions');
  assert.ok(transaction, 'Missing compiled transactions example.');
  assert.match(transaction.source, /\btransactionFailure\b/);
  assert.match(transaction.source, /\bcloseFailure\b/);
  assert.match(transaction.source,
    /\bnew TransactionAndCloseFailure\s*\(\s*transactionFailure,\s*closeFailure\s*\)/);
  assert.doesNotMatch(transaction.source, /finally\s*\{\s*await connection\.close\(\);\s*\}/);
});
