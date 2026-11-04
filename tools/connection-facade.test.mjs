import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import test from 'node:test';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const MYSQL_ROOT = join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql');
const CONNECTION = join(MYSQL_ROOT, 'MySqlConnection.ets');
const OWNERS = [
  join(MYSQL_ROOT, 'connection', 'MySqlConnectionLifecycle.ets'),
  join(MYSQL_ROOT, 'connection', 'MySqlFeatureFacades.ets'),
  join(MYSQL_ROOT, 'connection', 'MySqlPreparedConnectionHost.ets'),
  join(MYSQL_ROOT, 'connection', 'MySqlTransactionConnectionHost.ets'),
  join(MYSQL_ROOT, 'connection', 'MySqlControlConnectionFactory.ets'),
  join(MYSQL_ROOT, 'execution', 'MySqlSettlements.ets')
];

const MOVED_CLASSES = [
  'MySqlConnectionPreparedExecutor',
  'MySqlConnectionLongDataExecutor',
  'MySqlConnectionCursorExecutor',
  'MySqlConnectionNamedExecutor',
  'MySqlConnectionInsertRowsExecutor',
  'MySqlConnectionProcedureCaller',
  'MySqlConnectionBatchExecutor',
  'TransactionConnectionHost',
  'PreparedConnectionHost',
  'PreparedCommandSettlement',
  'CommandCloseSettlement',
  'OrdinaryCommandSettlement',
  'DeadlineObservation',
  'DeadlineCancellationSettlement',
  'MySqlDeadlineTimer'
];

test('keeps MySqlConnection as the public facade over focused ownership modules', async () => {
  const source = await readFile(CONNECTION, 'utf8');
  await Promise.all(OWNERS.map((owner) => readFile(owner, 'utf8')));

  for (const className of MOVED_CLASSES) {
    assert.doesNotMatch(source, new RegExp(`\\bclass\\s+${className}\\b`));
  }

  const localImports = [...source.matchAll(
    /^import\b[\s\S]*?\bfrom\s+['"](\.[^'"]+)['"];/gm
  )].map((match) => match[1]);
  assert.ok(localImports.length <= 40,
    `MySqlConnection.ets has ${localImports.length} direct local imports; expected at most 40.`);

  const lineCount = source.split(/\r?\n/).length;
  assert.ok(lineCount <= 2200,
    `MySqlConnection.ets has ${lineCount} lines; expected at most 2200.`);
});
