import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { tmpdir } from 'node:os';
import test from 'node:test';
import JSON5 from 'json5';
import { ROOT } from './check-package.mjs';
import { checkDriverContracts } from './driver-contracts.mjs';
import { affectedDrivers, dependencyClosure, discoverDrivers, discoverPackages,
  driverVerification, resolveDriver } from './driver-packages.mjs';
import { sourceFingerprint } from './package-har.mjs';
import { verificationCommands } from './verify-driver.mjs';

test('core is a real independent shared HAR, not an extra database driver', () => {
  assert.deepEqual(checkDriverContracts(), { sharedPackage: '@arkdb/core', drivers: ['mysql'] });
  assert.deepEqual(discoverPackages().map((entry) => [entry.id, entry.kind]), [['core', 'shared'], ['mysql', 'driver']]);
  assert.deepEqual(dependencyClosure().map((entry) => entry.id), ['core', 'mysql']);
  assert.throws(() => resolveDriver(ROOT, 'core'), /not a database driver/);
  assert.deepEqual(driverVerification().nativeModules, ['core', 'mysql']);
});

test('shared contracts describe callback-scoped transaction sessions', async () => {
  const contracts = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');
  assert.match(contracts, /\bmysqlFeatures\.transactions\b/);
  assert.match(contracts, /\bMySqlTransactionRunner\b/);
  assert.match(contracts, /\bcallback-scoped\b/i);
  assert.match(contracts, /\b(?:savepoint|rollbackTo|releaseSavepoint)\b/);
  assert.match(contracts, /\bintentional source-compatibility impact\b/i);
  assert.match(contracts, /\bexisting `?MySqlSession`? implementers\b/i);
  assert.doesNotMatch(contracts, /\bnot an implemented transaction scope\b/i);
});

test('shared contracts describe additive MySQL session reset', async () => {
  const contracts = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');
  assert.match(contracts, /\bmysqlFeatures\.session\b/);
  assert.match(contracts, /\bMySqlSessionController\.reset\(\)/);
  assert.match(contracts, /\bCOM_RESET_CONNECTION\b/);
  assert.match(contracts, /\binvalidates every explicit and cached prepared statement\b/i);
  assert.match(contracts, /\butf8mb4_general_ci\b/);
  assert.match(contracts, /\bcharacter_set_client=utf8mb4\b/);
  assert.match(contracts, /\bresidual or mismatched database closes the physical connection\b/i);
  assert.match(contracts, /\bwithout falling back[\s\S]{0,100}`CHANGE_USER`[\s\S]{0,100}replaying SQL\b/i);
  assert.match(contracts, /\bcore and old custom MySQL connections acquire no required method\b/i);
});

test('shared contracts describe binary procedure output parameters', async () => {
  const contracts = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');
  const index = await readFile(join(ROOT, 'mysql', 'Index.ets'), 'utf8');
  assert.match(contracts, /\bmysqlFeatures\.procedures\b/);
  assert.match(contracts, /\bMySqlProcedureArgument\b/);
  assert.match(contracts, /\bMySqlParameterDirection\b/);
  assert.match(contracts, /\bCLIENT_PS_MULTI_RESULTS\b/);
  assert.match(contracts, /\bSERVER_PS_OUT_PARAMS\b/);
  assert.match(contracts, /\bSERVER_MORE_RESULTS_EXISTS\b/);
  assert.match(contracts, /\bclassic\s+metadata EOF\b/i);
  assert.match(contracts, /\bdeprecated-EOF\s+row terminator\b/i);
  assert.match(contracts, /\boutResultIndex\b/);
  assert.match(contracts, /\boutValues\b/);
  assert.match(contracts, /\btyped NULL placeholder\b/i);
  assert.match(contracts, /\bFieldFlag\.BINARY\b/);
  assert.match(contracts, /\bexactly one known total row\b/i);
  assert.match(contracts, /\bnontruncated payload\b/i);
  assert.match(contracts, /\bcumulative byte limits\b/i);
  assert.match(contracts, /\bno\s+session variables\b/i);
  assert.match(contracts, /\btext\s+`CALL`\s+fallbacks\b/i);
  assert.match(contracts, /\bSQL NULL remains\s+null\b/i);
  assert.match(index, /\bMySqlProcedureArgument\b/);
  assert.match(index, /\bMySqlParameterDirection\b/);
  assert.doesNotMatch(index, /\bMySqlProcedureParameter\b/);
  assert.doesNotMatch(index, /\bMySqlProcedureParameterDirection\b/);
  assert.doesNotMatch(index, /\bMySqlProcedureOutput\b/);
});

test('shared contracts describe restricted prepared insert rows', async () => {
  const contracts = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');
  const index = await readFile(join(ROOT, 'mysql', 'Index.ets'), 'utf8');
  const source = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'execution', 'MySqlInsertRowsExecutor.ets'), 'utf8');
  assert.match(contracts, /\bmysqlFeatures\.insertRows\b/);
  assert.match(contracts, /\bMySqlInsertRowsOptions\b/);
  assert.match(contracts, /\bINSERT INTO \.\.\. VALUES\b/);
  assert.match(contracts, /\b16777216-byte\b/);
  assert.match(contracts, /\b65535\b/);
  assert.match(contracts, /\bMySqlBatchError\b/);
  assert.match(contracts, /\bmanual transaction\b/i);
  assert.match(contracts, /\bcallback-scoped adapter\b/i);
  assert.match(contracts, /\bafter each emitted statement\b/i);
  assert.match(contracts, /\bjoin counter\b/i);
  assert.match(contracts, /\bpartial\s+`MySqlBatchError`/i);
  assert.match(contracts, /\buncertain retirement retains\b/i);
  assert.match(contracts, /\bvalidated before inner rows are[\s\S]{0,20}touched\b/i);
  assert.match(contracts,
    /\bAfter[\s\S]{0,20}all widths pass[\s\S]{0,100}(?:every )?inner row array is copied\b/i);
  assert.match(contracts, /\bCOM_RESET_CONNECTION\b/);
  assert.match(index, /\bMySqlInsertRowsExecutor\b/);
  assert.match(index, /\bMySqlInsertRowsOptions\b/);
  assert.match(source, /'INSERT INTO '/);
  assert.doesNotMatch(source, /\bON DUPLICATE KEY UPDATE\b/);
  assert.doesNotMatch(source, /\bINSERT IGNORE\b/);
  assert.doesNotMatch(source, /\bREPLACE INTO\b/);
});

test('transaction runner observes the same promise returned to detached callers', async () => {
  const source = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'execution', 'MySqlTransactionRunner.ets'), 'utf8');
  const scopedStart = source.indexOf('class ScopedMySqlTransactionSession');
  const marker = 'runCommand<T>(operation: () => Promise<T>): Promise<T> {';
  const markerIndex = source.indexOf(marker, scopedStart);
  const runCommandStart = source.lastIndexOf('  private ', markerIndex);
  const helperStart = source.indexOf('  private async runSettledCommand<T>', markerIndex);
  assert.notEqual(scopedStart, -1);
  assert.notEqual(markerIndex, -1);
  assert.notEqual(runCommandStart, -1);
  assert.notEqual(helperStart, -1);

  const runCommand = source.slice(runCommandStart, helperStart);
  assert.match(runCommand, /^  private runCommand<T>/);
  assert.doesNotMatch(runCommand, /^  private async runCommand<T>/);
  assert.equal(runCommand.split('this.runSettledCommand<T>(operation)').length - 1, 1);
  assert.match(runCommand, /const task = this\.runSettledCommand<T>\(operation\);/);
  assert.match(runCommand, /const settlement = task\.then\(/);
  assert.match(runCommand, /this\.activeCommand = settlement;/);
  assert.match(runCommand, /task\.catch\(\([^)]*\): void => \{\}\);/);
  assert.match(runCommand, /return task;/);
  assert.doesNotMatch(runCommand, /return task\.catch\(/);

  const waitStart = source.indexOf('  async waitForActiveCommand()', scopedStart);
  const waitEnd = source.indexOf('  takeRetainedCleanup()', waitStart);
  const waitForActiveCommand = source.slice(waitStart, waitEnd);
  assert.match(waitForActiveCommand, /const command = this\.activeCommand;/);
  assert.match(waitForActiveCommand, /await command/);
});

test('transaction-scoped insert rows returns the exact observed promise', async () => {
  const source = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'execution', 'MySqlTransactionRunner.ets'), 'utf8');
  const scopedStart = source.indexOf('class ScopedMySqlInsertRowsExecutor');
  const scopedEnd = source.indexOf('function snapshotTransactionOptions', scopedStart);
  assert.notEqual(scopedStart, -1);
  assert.notEqual(scopedEnd, -1);
  const scoped = source.slice(scopedStart, scopedEnd);
  assert.match(scoped, /\n  execute\(tableParts:/);
  assert.doesNotMatch(scoped, /\n  async execute\(tableParts:/);
  assert.match(scoped, /const task = Promise\.reject<MySqlBatchResult>\(error as Object\);/);
  assert.match(scoped, /task\.catch\(\(_error: Object\): void => \{\}\);/);
  assert.match(scoped, /return task;/);
  assert.match(scoped, /return this\.executeInput\(input\);/);
  assert.doesNotMatch(scoped, /return this\.executeInput\(input\)\.then/);
});

test('restricted insert preserves request validation before row snapshots', async () => {
  const source = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'execution', 'MySqlInsertRowsExecutor.ets'), 'utf8');
  const start = source.indexOf('export function snapshotMySqlInsertRowsInput');
  const end = source.indexOf('function requireIdentifierStrings', start);
  assert.notEqual(start, -1);
  assert.notEqual(end, -1);
  const snapshot = source.slice(start, end);
  const options = snapshot.indexOf('const optionErrors = validateMySqlInsertRowsOptions');
  const table = snapshot.indexOf('const table = tableParts.slice();');
  const columns = snapshot.indexOf('const capturedColumns = columns.slice();');
  const widths = snapshot.indexOf('Each MySQL INSERT row must match the column count.');
  const copies = snapshot.indexOf('capturedRows.push(outerRows[index].slice());');
  const values = snapshot.indexOf('new MySqlParameter(parameter.type, parameter.value)');
  assert.ok(options >= 0 && table > options && columns > table);
  assert.ok(widths > columns && copies > widths && values > copies);
  assert.match(snapshot, /failedIndex = 0;\r?\n    const rowSnapshots:/);
});

test('adding an independently typed adapter changes registration only, not MySQL implementation', async (t) => {
  const root = await fixture(t);
  const mysql = await treeDigest(join(root, 'mysql'));
  const directory = join(root, 'drivers', 'probe');
  await mkdir(join(directory, 'src', 'main', 'ets'), { recursive: true });
  await mkdir(join(directory, 'src', 'test'), { recursive: true });
  for (const name of ['LICENSE', 'README.md', 'README.OpenSource', 'CHANGELOG.md']) {
    await cp(join(root, 'core', name), join(directory, name));
  }
  const probe = (await readFile(join(root, 'core', 'src', 'test', 'ReferenceAdapter.ets'), 'utf8'))
    .replace("from '../../Index'", "from '@arkdb/core'");
  await writeFile(join(directory, 'src', 'main', 'ets', 'Probe.ets'), probe);
  await writeFile(join(directory, 'Index.ets'), "export { ProbeFactory, ProbeOptions } from './src/main/ets/Probe';\n");
  await writeFile(join(directory, 'src', 'main', 'module.json5'), JSON.stringify({
    module: { name: 'probe', type: 'har' }
  }));
  await writeFile(join(directory, 'oh-package.json5'), JSON.stringify({
    name: '@arkdb/probe', version: '1.0.0', main: 'Index.ets', author: 'Test fixture', license: 'Apache-2.0',
    dependencies: { '@arkdb/core': '1.0.0' }
  }));
  await writeFile(join(directory, 'arkdb-package.json'), '{"kind":"driver"}');
  await writeFile(join(directory, 'src', 'test', 'List.test.ets'),
    "import suite from './Probe.test';\nexport default function tests(): void { suite(); }\n");
  await writeFile(join(directory, 'src', 'test', 'Probe.test.ets'), 'export default function suite(): void {}\n');
  const profile = JSON5.parse(await readFile(join(root, 'build-profile.json5'), 'utf8'));
  profile.modules.push({ name: 'probe', srcPath: './drivers/probe' });
  await writeFile(join(root, 'build-profile.json5'), JSON.stringify(profile));
  assert.deepEqual(checkDriverContracts(root).drivers, ['mysql', 'probe']);
  assert.equal(await treeDigest(join(root, 'mysql')), mysql);
  assert.deepEqual(affectedDrivers(discoverDrivers(root), ['core/src/main/ets/model/QueryResult.ets'])
    .map((entry) => entry.id), ['mysql', 'probe']);
  assert.deepEqual(affectedDrivers(discoverDrivers(root), ['drivers/probe/src/main/ets/Probe.ets'])
    .map((entry) => entry.id), ['probe']);
  assert.throws(() => driverVerification(root, 'probe'), /declare its own consumer/);
  const declarationPath = join(directory, 'arkdb-package.json');
  const declaration = JSON.parse(await readFile(declarationPath, 'utf8'));
  declaration.verification = {
    consumer: 'examples/probe-client', nativeModules: ['core', 'probe'], requiresInternet: false
  };
  await mkdir(join(root, 'examples', 'probe-client'), { recursive: true });
  await writeFile(declarationPath, JSON.stringify(declaration));
  const commands = verificationCommands(root, 'probe');
  assert.deepEqual(commands[0].slice(1), ['core', 'probe']);
  for (const command of commands.slice(1)) assert.deepEqual(command.slice(1), ['--driver', 'probe']);
  assert.equal(await treeDigest(join(root, 'mysql')), mysql);
});

test('core changes invalidate dependent source fingerprints without editing their implementations', async (t) => {
  const root = await fixture(t);
  const before = sourceFingerprint(root, 'mysql');
  const mysql = await treeDigest(join(root, 'mysql'));
  const file = join(root, 'core', 'src', 'main', 'ets', 'model', 'QueryResult.ets');
  await writeFile(file, (await readFile(file, 'utf8')) + '\n// Fixture source identity change.\n');
  assert.notEqual(sourceFingerprint(root, 'mysql'), before);
  assert.equal(await treeDigest(join(root, 'mysql')), mysql);
});

test('native wire fields, engine enums, duplicate errors and reverse dependencies are rejected', async (t) => {
  const root = await fixture(t);
  const infoPath = join(root, 'core', 'src', 'main', 'ets', 'model', 'ServerInfo.ets');
  const original = await readFile(infoPath, 'utf8');
  for (const addition of ['export enum ServerFamily { MySQL = "MySQL" }\n',
    'export class WireDetails { charset: number = 45; }\n']) {
    await writeFile(infoPath, original + addition);
    assert.throws(() => checkDriverContracts(root), /engine|native wire/);
  }
  await writeFile(infoPath, original);
  const native = join(root, 'mysql', 'src', 'main', 'ets', 'mysql', 'Duplicate.ets');
  await writeFile(native, 'export class ArkDbError extends Error {}\n');
  assert.throws(() => checkDriverContracts(root), /exactly one runtime identity/);
  await rm(native);
  const manifestPath = join(root, 'core', 'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.dependencies = { '@arkdb/mysql': resolveDriver(root, 'mysql').version };
  await writeFile(manifestPath, JSON.stringify(manifest));
  assert.throws(() => dependencyClosure(root), /Shared HAR|Cyclic/);
});

test('wrong source overrides and missing public contract bindings fail before a native build', async (t) => {
  const root = await fixture(t);
  const path = join(root, 'oh-package.json5');
  const manifest = JSON5.parse(await readFile(path, 'utf8'));
  const original = manifest.overrides['@arkdb/core'];
  manifest.overrides['@arkdb/core'] = 'file:./stale/core.har';
  await writeFile(path, JSON.stringify(manifest));
  assert.throws(() => checkDriverContracts(root), /override must select registered source/);
  manifest.overrides['@arkdb/core'] = original;
  await writeFile(path, JSON.stringify(manifest));
  await writeFile(join(root, 'mysql', 'src', 'main', 'ets', 'mysql', 'Missing.ets'),
    "import { NonexistentCoreContract } from '@arkdb/core';\n");
  assert.throws(() => checkDriverContracts(root), /Unknown core public symbol/);
});

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-contracts-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const ignored = new Set(['build', '.test', '.hvigor', 'oh_modules', 'node_modules', 'BuildProfile.ets']);
  for (const name of ['core', 'mysql', 'build-profile.json5', 'oh-package.json5', 'hvigorfile.ts', 'hvigor', 'AppScope', 'LICENSE']) {
    await cp(join(ROOT, name), join(root, name), { recursive: true, filter: (file) => !ignored.has(basename(file)) });
  }
  return root;
}

async function treeDigest(directory) {
  const { listFiles } = await import('./check-package.mjs');
  const hash = createHash('sha256');
  for (const file of listFiles(directory).sort()) hash.update(file.slice(directory.length))
    .update('\0').update(await readFile(file)).update('\0');
  return hash.digest('hex');
}
