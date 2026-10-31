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

test('shared contracts describe the privacy-safe execution observer', async () => {
  const contracts = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');
  const index = await readFile(join(ROOT, 'mysql', 'Index.ets'), 'utf8');
  const connection = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'MySqlConnection.ets'), 'utf8');
  const factory = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'driver', 'MySqlDriverFactory.ets'), 'utf8');
  const gate = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'execution', 'MySqlCommandGate.ets'), 'utf8');
  const preparedStatement = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'command', 'PreparedStatement.ets'), 'utf8');
  const observer = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'diagnostics', 'MySqlExecutionObserver.ets'), 'utf8');
  assert.match(contracts, /\bMySqlConnectionExtensions\b/);
  assert.match(contracts, /\bMySqlExecutionObserver\.onEvent\b/);
  assert.match(contracts, /\bone start\b/i);
  assert.match(contracts, /\bone terminal\b/i);
  assert.match(contracts, /\bmonotonicTimeMs\b/);
  assert.match(contracts, /\bdurationMs\b/);
  assert.match(contracts, /\bno SQL\b[\s\S]{0,180}\bcredentials\b/i);
  assert.match(contracts, /\bremoved before\b[\s\S]{0,120}\btokenized warning\b/i);
  assert.match(contracts, /\boverridable `createConnection\b/);
  assert.match(contracts, /\bprotected overridable[\s\S]{0,80}`createObservedConnection`/);
  assert.match(contracts, /\bone-shot internal capability\b/i);
  assert.match(contracts, /\bno public or protected observer initializer\b/i);
  assert.match(contracts, /\bwrong capability\b/i);
  assert.match(contracts, /\bserial or generation\b/i);
  assert.match(contracts, /\binstalls gate ownership\b/i);
  assert.match(contracts, /\bshared opening\/reset\/settlement\/close\b/i);
  assert.match(contracts, /\bstart event\b/i);
  assert.match(contracts, /\bMySqlPreparedStatement\.close\(\)`? memoizes\b/);
  assert.match(contracts, /\bpromise and error identity\b/);
  assert.match(contracts, /\bsession\/owned close entry point\b/i);
  assert.match(contracts, /\bhandle-owned deferred\b/i);
  assert.match(contracts, /\blegacy three-argument `runPreparedCommand`/i);
  assert.match(contracts, /\bpending, live and settled-preflight states\b/i);
  assert.match(contracts, /\bnever clears a live operation\b/i);
  assert.match(contracts,
    /\blegacy three-argument `runPreparedCommand` override retains its async\b/i);
  assert.match(contracts, /\brejected Promise rather than throwing before return\b/i);
  assert.match(contracts, /`\.catch\(\)`/i);
  assert.match(contracts, /`\.finally\(\)`/i);
  assert.match(index, /\bMySqlConnectionExtensions\b/);
  assert.match(index, /\bMySqlExecutionObserver\b/);
  assert.match(index, /\bMySqlExecutionEventType\b/);
  assert.match(index, /\bMySqlCommandKind\b/);
  const constructor = connection.match(
    /constructor\(config: ConnectionConfig, password: string,[\s\S]*?createControlConnection\?: \(\) => DbConnection\) \{/);
  assert.notEqual(constructor, null);
  assert.doesNotMatch(constructor[0], /\b(?:extensions|executionClock)\b/);
  assert.doesNotMatch(connection, /\bprotected initializeExecutionObserver\b/);
  assert.match(connection, /class MySqlExecutionObserverCapability/);
  assert.match(connection, /const mysqlExecutionObserverCapability/);
  assert.match(connection, /export function initializeMySqlExecutionObserverInternal\(/);
  assert.match(connection, /export function initializeMySqlExecutionObserverWithCapabilityInternal\(/);
  assert.match(factory,
    /if \(extensions === undefined \|\| extensions\.executionObserver === undefined\)[\s\S]{0,100}return this\.createConnection\(options\.config, options\.password\)/);
  assert.match(factory, /protected createObservedConnection\(/);
  assert.match(factory,
    /initializeMySqlExecutionObserverInternal\([\s\S]{0,160}extensions\.executionObserver[\s\S]{0,80}executionClock\)/);
  assert.match(connection,
    /createDefaultControlConnection\(\): MySqlConnection[\s\S]{0,420}new MySqlConnection\(controlConfig, this\.password/);
  const reserveStart = gate.indexOf('reserve(kind: MySqlCommandKind)');
  const startStart = gate.indexOf('start(scope: MySqlCommandScope)');
  const ownerStart = gate.indexOf('isOwner(scope: MySqlCommandScope)');
  assert.notEqual(reserveStart, -1);
  assert.notEqual(startStart, -1);
  assert.notEqual(ownerStart, -1);
  assert.doesNotMatch(gate.slice(reserveStart, startStart), /\bonStart\(/);
  assert.match(gate.slice(startStart, ownerStart), /\bonStart\(scope\)/);
  const preparedSettlement = connection.indexOf('this.preparedOperation = settlement');
  const preparedStart = connection.indexOf('this.commandGate.start(scope)', preparedSettlement);
  const closingPublish = connection.indexOf('this.closing = closing');
  const closingStart = connection.indexOf(
    'if (ownsScope) this.commandGate.start(scope)', closingPublish);
  const handleDeferred = preparedStatement.indexOf(
    'const bridge = this.beginCloseResult(true)');
  const ownerClose = preparedStatement.indexOf('this.owner.close(this)', handleDeferred);
  const bridgeResult = preparedStatement.indexOf(
    'this.bridgeCloseResult(bridge, task)', ownerClose);
  assert.notEqual(preparedSettlement, -1);
  assert.ok(preparedStart > preparedSettlement);
  assert.notEqual(closingPublish, -1);
  assert.ok(closingStart > closingPublish);
  assert.notEqual(handleDeferred, -1);
  assert.ok(ownerClose > handleDeferred);
  assert.ok(bridgeResult > ownerClose);
  assert.match(preparedStatement,
    /canRetryPreflightRejection\(\): boolean[\s\S]{0,180}this\.handlePreflight[\s\S]{0,80}!this\.started[\s\S]{0,80}this\.settled[\s\S]{0,80}this\.rejected/);
  assert.match(preparedStatement,
    /if \(result !== null\) \{[\s\S]{0,100}!handle\.clearSettledPreflightRejection\(\)[\s\S]{0,40}return result/);
  const preparedRunner = connection.match(
    /protected async runPreparedCommand<T>\(kind: MySqlCommandKind,[\s\S]*?cachedConvenience: boolean = false\): Promise<T>/);
  assert.notEqual(preparedRunner, null);
  assert.doesNotMatch(preparedRunner[0], /\bpublish\b/);
  assert.doesNotMatch(preparedStatement,
    /runCommand\?<T>\([\s\S]{0,180}\bpublish\b/);
  assert.doesNotMatch(index,
    /\b(?:ObservedMySqlConnection|initializeExecutionObserver|initializeMySqlExecutionObserverInternal|MySqlExecutionObserverCapability|MySqlExecutionDispatcher)\b/);
  const eventStart = observer.indexOf('export class MySqlExecutionEvent');
  const observerStart = observer.indexOf('export interface MySqlExecutionObserver');
  const eventShape = observer.slice(eventStart, observerStart);
  assert.doesNotMatch(eventShape,
    /\b(?:sql|parameters?|password|host|user|schema|config|error|message|code|sqlState|metadata)\b/i);
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
