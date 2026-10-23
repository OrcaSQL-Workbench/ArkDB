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
