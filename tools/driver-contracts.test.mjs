import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import JSON5 from 'json5';
import ts from 'typescript';
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
  const verification = driverVerification();
  assert.deepEqual(verification.nativeModules, ['core', 'mysql']);
  assert.equal(verification.consumer, 'examples/mysql-client');
  assert.equal(verification.deviceConsumer, 'examples/mysql-device-acceptance');
  assert.equal(verification.consumerDirectory, join(ROOT, 'examples', 'mysql-client'));
  assert.equal(verification.deviceConsumerDirectory,
    join(ROOT, 'examples', 'mysql-device-acceptance'));
});

test('compatibility-only MySQL surface stays exported and explicitly deprecated', async () => {
  const index = await readFile(join(ROOT, 'mysql', 'Index.ets'), 'utf8');
  const capabilities = await readFile(join(ROOT, 'core', 'src', 'main', 'ets', 'driver',
    'DriverCapabilities.ets'), 'utf8');
  const serverInfo = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'model', 'MySqlServerInfo.ets'), 'utf8');
  const mysqlContracts = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'api', 'MySqlContracts.ets'), 'utf8');
  const extensions = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'driver', 'MySqlConnectionExtensions.ets'), 'utf8');
  const readme = await readFile(join(ROOT, 'mysql', 'README.md'), 'utf8');
  const contracts = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');

  assert.match(index, /\bServerFamily\b/);
  assert.match(index, /\bDriverCapabilities\b/);
  assert.match(index, /\bDbExecutionController\b/);
  assert.match(index, /\bMySqlConnectionExtensions\b/);
  assert.match(index, /\bMySqlCommandKind\b/);
  assert.match(serverInfo,
    /\/\*\*[\s\S]{0,180}@deprecated[\s\S]{0,180}\*\/\s*PostgreSQL = 'PostgreSQL'/);
  assert.match(capabilities,
    /\/\*\*[\s\S]{0,180}@deprecated[\s\S]{0,180}\*\/\s*supportsExplain: boolean = false/);
  assert.match(mysqlContracts,
    /\/\*\*[\s\S]{0,240}@deprecated[\s\S]{0,240}\*\/\s*export interface MySqlDbExecutionController/);
  assert.match(mysqlContracts,
    /\/\*\*[\s\S]{0,240}@deprecated[\s\S]{0,240}\*\/\s*createExecutionController\(/);
  assert.match(readme, /\bsupportsExplain\b[\s\S]{0,180}\bdeprecated\b[\s\S]{0,180}\bfeature discovery\b/i);
  assert.match(readme,
    /\bcreateExecutionController\b[\s\S]{0,220}\bconnection-bound cancellation\b/i);
  assert.match(contracts,
    /\bMySqlConnectionExtensions\b[\s\S]{0,220}\bobserver-only\b[\s\S]{0,180}\boption bag\b/i);

  assertObserverOnlyConnectionExtensions(extensions);
  assert.throws(() => assertObserverOnlyConnectionExtensions(extensions.replace(
    '  constructor(executionObserver?: MySqlExecutionObserver) {',
    '  futureOption?: string;\n\n  constructor(executionObserver?: MySqlExecutionObserver) {'
  )), /futureOption/);
  assert.throws(() => assertObserverOnlyConnectionExtensions(extensions.replace(
    '  constructor(executionObserver?: MySqlExecutionObserver) {',
    "  get futureOption(): string { return ''; }\n\n" +
    '  constructor(executionObserver?: MySqlExecutionObserver) {'
  )), /futureOption/);
  assert.match(extensions,
    /constructor\(executionObserver\?: MySqlExecutionObserver\)/);
});

test('approved internal surface candidates stay representation-free', async () => {
  const metrics = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'features', 'metrics', 'MySqlServerMetricsProvider.ets'), 'utf8');
  const gate = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'execution', 'MySqlCommandGate.ets'), 'utf8');
  const connection = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'MySqlConnection.ets'), 'utf8');

  assert.doesNotMatch(metrics, /\bclass StatusValues\b/);
  assert.match(metrics,
    /function statusValues\(rows: SqlValue\[\]\[\], names: string\[\]\): bigint\[\] \| null/);
  assert.match(metrics, /const result: bigint\[\] = \[\]/);
  assert.doesNotMatch(metrics, /\.valueAt\(/);
  assert.doesNotMatch(gate, /\bclass CommandOwnerToken\b/);
  assert.match(gate, /readonly ownerToken: Object = new Object\(\)/);
  assert.doesNotMatch(connection, /\bclass MySqlExecutionObserverCapability\b/);
  assert.match(connection,
    /const mysqlExecutionObserverCapability: Object = new Object\(\)/);
});

test('legacy custom connections and sessions remain valid feature-helper inputs', async () => {
  const features = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'api', 'MySqlConnectionFeatures.ets'), 'utf8');
  const contracts = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'api', 'MySqlContracts.ets'), 'utf8');
  const documentation = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');
  assert.match(features,
    /export interface MySqlFeatureConnection \{[\s\S]{0,100}readonly mysqlFeatures\?: MySqlConnectionFeatures/);
  assert.match(features, /export interface MySqlSession extends MySqlFeatureConnection/);
  assert.doesNotMatch(features, /\bfunction requireMySqlFeatures\b/);
  assert.match(contracts,
    /export function requireMySqlFeatures\(connection: MySqlFeatureConnection\): MySqlConnectionFeatures;/);
  assert.match(contracts,
    /export function requireMySqlFeatures\(connection: MySqlDbConnection\): MySqlConnectionFeatures;/);
  assert.match(documentation, /\bfeature-bearing sessions and legacy MySQL\s+connections\b/);
  assert.doesNotMatch(documentation, /\bfeature-bearing sessions and actual core\s+connections\b/);

  const fixture = `
interface CoreDbConnection {
  connect(): Promise<void>;
  query(sql: string): Promise<void>;
  close(): Promise<void>;
  readonly state: string;
  readonly serverInfo: Object;
}
class MySqlConnectionFeatures {}
interface MySqlFeatureConnection {
  readonly mysqlFeatures?: MySqlConnectionFeatures;
}
interface MySqlSession extends MySqlFeatureConnection {
  readonly mysqlFeatures: MySqlConnectionFeatures;
}
interface MySqlDbConnection extends CoreDbConnection, MySqlFeatureConnection {}
function requireMySqlFeatures(connection: MySqlFeatureConnection): MySqlConnectionFeatures;
function requireMySqlFeatures(connection: MySqlDbConnection): MySqlConnectionFeatures;
function requireMySqlFeatures(
  connection: MySqlFeatureConnection | MySqlDbConnection
): MySqlConnectionFeatures {
  if (connection.mysqlFeatures === undefined) throw new Error();
  return connection.mysqlFeatures;
}
class LegacyCustomConnection implements MySqlDbConnection {
  readonly state: string = '';
  readonly serverInfo: Object = new Object();
  async connect(): Promise<void> {}
  async query(_sql: string): Promise<void> {}
  async close(): Promise<void> {}
}
requireMySqlFeatures(new LegacyCustomConnection());
declare const session: MySqlSession;
requireMySqlFeatures(session);
`;
  assert.deepEqual(typeScriptDiagnostics(fixture), []);
});

function assertObserverOnlyConnectionExtensions(source) {
  const parsed = ts.createSourceFile('MySqlConnectionExtensions.ets', source,
    ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  assert.deepEqual(parsed.parseDiagnostics, []);
  const declaration = parsed.statements.find((statement) =>
    ts.isClassDeclaration(statement) &&
    statement.name?.text === 'MySqlConnectionExtensions');
  assert.notEqual(declaration, undefined);
  const fields = declaration.members.filter((member) =>
    ts.isPropertyDeclaration(member) ||
    ts.isGetAccessorDeclaration(member) ||
    ts.isSetAccessorDeclaration(member)).map((member) => member.name.getText(parsed));
  assert.deepEqual(fields, ['executionObserver']);
}

function typeScriptDiagnostics(source) {
  const fileName = 'legacy-feature-connection.ts';
  const options = {
    noEmit: true,
    strict: true,
    target: ts.ScriptTarget.ESNext
  };
  const host = ts.createCompilerHost(options);
  const getSourceFile = host.getSourceFile.bind(host);
  const fileExists = host.fileExists.bind(host);
  const readFileFromHost = host.readFile.bind(host);
  host.getSourceFile = (name, languageVersion, onError, shouldCreateNewSourceFile) =>
    name === fileName
      ? ts.createSourceFile(name, source, languageVersion, true, ts.ScriptKind.TS)
      : getSourceFile(name, languageVersion, onError, shouldCreateNewSourceFile);
  host.fileExists = (name) => name === fileName || fileExists(name);
  host.readFile = (name) => name === fileName ? source : readFileFromHost(name);
  return ts.getPreEmitDiagnostics(ts.createProgram([fileName], options, host))
    .map((diagnostic) => ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n'));
}

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
  const controlFactory = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'connection', 'MySqlControlConnectionFactory.ets'), 'utf8');
  const lifecycle = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'connection', 'MySqlConnectionLifecycle.ets'), 'utf8');
  const gate = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'execution', 'MySqlCommandGate.ets'), 'utf8');
  const preparedStatement = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'features', 'prepared', 'PreparedStatement.ets'), 'utf8');
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
  assert.doesNotMatch(connection, /class MySqlExecutionObserverCapability/);
  assert.match(connection, /const mysqlExecutionObserverCapability: Object = new Object\(\)/);
  assert.match(connection, /export function initializeMySqlExecutionObserverInternal\(/);
  assert.match(connection, /export function initializeMySqlExecutionObserverWithCapabilityInternal\(/);
  assert.match(factory,
    /if \(extensions === undefined \|\| extensions\.executionObserver === undefined\)[\s\S]{0,100}return this\.createConnection\(options\.config, options\.password\)/);
  assert.match(factory, /protected createObservedConnection\(/);
  assert.match(factory,
    /initializeMySqlExecutionObserverInternal\([\s\S]{0,160}extensions\.executionObserver[\s\S]{0,80}executionClock\)/);
  assert.match(connection,
    /createDefaultControlConnection\(\): MySqlConnection[\s\S]{0,120}this\.lifecycle\.createDefaultControlConnection\(\)/);
  assert.match(connection,
    /new MySqlConnection\([\s\S]{0,120}controlConfig, controlPassword[\s\S]{0,120}controlFactory/);
  assert.match(lifecycle,
    /createDefaultControlConnection\(\): T[\s\S]{0,160}createMySqlControlConnection<T>/);
  assert.match(controlFactory,
    /controlConfig\.defaultSchema = undefined[\s\S]{0,160}controlConfig\.autocommit = true/);
  assert.match(controlFactory,
    /controlConfig\.session = undefined[\s\S]{0,120}controlConfig\.multipleStatements = false/);
  assert.match(controlFactory,
    /A MySQL control connection cannot create another control connection/);
  const reserveStart = gate.indexOf('reserve(kind: MySqlCommandKind)');
  const startStart = gate.indexOf('start(scope: MySqlCommandScope)');
  const ownerStart = gate.indexOf('isOwner(scope: MySqlCommandScope)');
  assert.notEqual(reserveStart, -1);
  assert.notEqual(startStart, -1);
  assert.notEqual(ownerStart, -1);
  assert.doesNotMatch(gate.slice(reserveStart, startStart), /\bonStart\(/);
  assert.match(gate.slice(startStart, ownerStart), /\bonStart\(scope\)/);
  const preparedSettlement = connection.indexOf(
    'const settlement = this.lifecycle.createPreparedOperation(scope)');
  const preparedStart = connection.indexOf('this.commandGate.start(scope)', preparedSettlement);
  const closingPublish = lifecycle.indexOf('this.closing = closing');
  const closingStart = lifecycle.indexOf(
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

test('shared contracts describe restricted prepared insert rows', async () => {
  const contracts = await readFile(join(ROOT, 'docs', 'driver-contracts.md'), 'utf8');
  const index = await readFile(join(ROOT, 'mysql', 'Index.ets'), 'utf8');
  const source = await readFile(join(ROOT, 'mysql', 'src', 'main', 'ets', 'mysql',
    'features', 'insert', 'MySqlInsertRowsExecutor.ets'), 'utf8');
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
    'features', 'transaction', 'MySqlTransactionRunner.ets'), 'utf8');
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
    'features', 'transaction', 'MySqlTransactionRunner.ets'), 'utf8');
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
    'features', 'insert', 'MySqlInsertRowsExecutor.ets'), 'utf8');
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
  const probe = (await readFile(
    join(root, 'core', 'src', 'test', 'fixtures', 'ReferenceAdapter.ets'), 'utf8'))
    .replace("from '../../../Index'", "from '@arkdb/core'");
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
  const mysqlIndexPath = join(root, 'mysql', 'Index.ets');
  const mysqlIndex = await readFile(mysqlIndexPath, 'utf8');
  await writeFile(mysqlIndexPath,
    `${mysqlIndex}\nexport { ProbeFactory } from '@arkdb/probe';\n`);
  assert.throws(() => checkDriverContracts(root),
    /Drivers must not import another driver.*@arkdb\/probe/);
  await writeFile(mysqlIndexPath, mysqlIndex);
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

test('ordinary consumers cannot import device acceptance sources', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'ets', 'sample', 'SampleRunner.ets');
  await writeFile(source, (await readFile(source, 'utf8')) +
    "\nimport '../../../../../../mysql-device-acceptance/entry/src/main/ets/" +
    "sample/DeviceAcceptanceRunner';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project sources must not import a sibling project/);
});

test('ordinary consumer manifests cannot depend on device acceptance', async (t) => {
  const root = await fixture(t);
  const manifestPath = join(root, 'examples', 'mysql-client', 'entry',
    'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.dependencies['arkdb-mysql-device-acceptance'] =
    'file:../../mysql-device-acceptance/entry';
  await writeFile(manifestPath, JSON.stringify(manifest));

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project dependencies must not reference a sibling project/);
});

test('ordinary consumer root dev dependencies cannot name device acceptance', async (t) => {
  const root = await fixture(t);
  const manifestPath = join(root, 'examples', 'mysql-client',
    'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.devDependencies['arkdb-mysql-device-acceptance'] = '1.0.0';
  await writeFile(manifestPath, JSON.stringify(manifest));

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project dependencies must not name a sibling project/);
});

test('ordinary consumer Hvigor config cannot depend on device acceptance', async (t) => {
  const root = await fixture(t);
  const configPath = join(root, 'examples', 'mysql-client', 'hvigor',
    'hvigor-config.json5');
  const config = JSON5.parse(await readFile(configPath, 'utf8'));
  config.dependencies['arkdb-mysql-device-acceptance'] = '1.0.0';
  await writeFile(configPath, JSON.stringify(config));

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project dependencies must not name a sibling project/);
});

test('ordinary consumer package imports cannot name device acceptance', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'ets', 'sample', 'SampleRunner.ets');
  await writeFile(source, (await readFile(source, 'utf8')) +
    "\nimport 'arkdb-mysql-device-acceptance';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary consumer modules cannot point at device acceptance', async (t) => {
  const root = await fixture(t);
  const profilePath = join(root, 'examples', 'mysql-client',
    'build-profile.json5');
  const profile = JSON5.parse(await readFile(profilePath, 'utf8'));
  profile.modules[0].srcPath = '../mysql-device-acceptance/entry';
  await writeFile(profilePath, JSON.stringify(profile));

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project modules must remain inside the project/);
});

test('ordinary consumer bundle imports cannot name device acceptance', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'ets', 'sample', 'SampleRunner.ets');
  await writeFile(source, (await readFile(source, 'utf8')) +
    "\nimport '@bundle:dev.arkdb.mysql.deviceacceptance/entry/ets/pages/Index';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary consumer permits unrelated bundle identity prefixes', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'ets', 'sample', 'SampleRunner.ets');
  await writeFile(source, (await readFile(source, 'utf8')) +
    "\nimport '@bundle:dev.arkdb.mysql.deviceacceptance.extra/entry/Index';\n");

  assert.doesNotThrow(() => checkDriverContracts(root));
});

test('ordinary consumer rejects product-specific acceptance bundle identities', async (t) => {
  const root = await fixture(t);
  const profilePath = join(root, 'examples', 'mysql-device-acceptance',
    'build-profile.json5');
  const profile = JSON5.parse(await readFile(profilePath, 'utf8'));
  profile.app.products[0].bundleName =
    'dev.arkdb.mysql.deviceacceptance.product';
  await writeFile(profilePath, JSON.stringify(profile));
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'ets', 'sample', 'SampleRunner.ets');
  await writeFile(source, (await readFile(source, 'utf8')) +
    "\nimport '@bundle:dev.arkdb.mysql.deviceacceptance.product/entry/Index';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary consumer rejects encoded file URL imports', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'ets', 'sample', 'SampleRunner.ets');
  const target = pathToFileURL(join(root, 'examples', 'mysql-device-acceptance',
    'hvigorfile.ts')).href.replace(
    'mysql-device-acceptance', 'mysql%2Ddevice%2Dacceptance');
  await writeFile(source, (await readFile(source, 'utf8')) +
    `\nimport ${JSON.stringify(target)};\n`);

  assert.throws(() => checkDriverContracts(root),
    /Absolute module URLs are not supported in isolated projects/);
});

test('ordinary consumer rejects absolute filesystem imports', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
  const target = join(root, 'examples', 'mysql-device-acceptance',
    'hvigorfile.ts');
  await writeFile(source, (await readFile(source, 'utf8')) +
    `\nimport ${JSON.stringify(target)};\n`);

  assert.throws(() => checkDriverContracts(root),
    /Absolute filesystem imports are not supported in isolated projects/);
});

test('ordinary consumer worker paths cannot point at device acceptance', async (t) => {
  const root = await fixture(t);
  const profilePath = join(root, 'examples', 'mysql-client', 'entry',
    'build-profile.json5');
  const profile = JSON5.parse(await readFile(profilePath, 'utf8'));
  profile.buildOption.sourceOption.workers = [
    '../../mysql-device-acceptance/entry/src/main/ets/workers/device.worker.ets'
  ];
  await writeFile(profilePath, JSON.stringify(profile));

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project build source paths must remain inside the project/);
});

test('ordinary consumer scans project and module Hvigor scripts', async (t) => {
  for (const relativePath of [
    ['hvigorfile.ts'],
    ['entry', 'hvigorfile.ts']
  ]) {
    const root = await fixture(t);
    const source = join(root, 'examples', 'mysql-client', ...relativePath);
    await writeFile(source, (await readFile(source, 'utf8')) +
      "\nimport 'arkdb-mysql-device-acceptance';\n");

    assert.throws(() => checkDriverContracts(root),
      /ArkTS project imports must not name a sibling project/);
  }
});

test('ordinary consumer follows imported Hvigor Node helpers', async (t) => {
  const root = await fixture(t);
  const script = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
  await writeFile(script, (await readFile(script, 'utf8')) +
    "\nimport './hidden.mjs';\n");
  await writeFile(join(script, '..', 'hidden.mjs'),
    "import 'arkdb-mysql-device-acceptance';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary consumer Hvigor scripts allow benign node built-ins', async (t) => {
  const root = await fixture(t);
  const script = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
  await writeFile(script, (await readFile(script, 'utf8')) +
    "\nimport path from 'node:path';\n" +
    "import { readFileSync } from 'node:fs';\n" +
    "import { readFile } from 'node:fs/promises';\n" +
    "import os from 'os';\n" +
    "import sqlitePackage from 'sqlite';\n" +
    'void path;\nvoid readFileSync;\nvoid readFile;\nvoid os;\n');

  assert.doesNotThrow(() => checkDriverContracts(root));
});

test('ordinary consumer Hvigor scripts allow benign module-shaped declarations', async (t) => {
  const root = await fixture(t);
  const script = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
  await writeFile(script, (await readFile(script, 'utf8')) +
    "\ninterface Config { module: string; require?: boolean }\n" +
    'type RequireType = typeof require;\n' +
    'type ModuleType = typeof module;\n' +
    "class Holder { module: string = 'entry'; require(): boolean { return false; } }\n" +
    'const { module: kind, require: needed } = new Holder();\n' +
    'void kind;\nvoid needed;\n');

  assert.doesNotThrow(() => checkDriverContracts(root));
});

test('ordinary consumer Hvigor scripts reject execution-capable node built-ins', async (t) => {
  for (const builtin of [
    'node:child_process',
    'child_process',
    'inspector',
    'node:sea',
    'node:vm',
    'vm',
    'node:worker_threads',
    'worker_threads'
  ]) {
    const root = await fixture(t);
    const script = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
    await writeFile(script, (await readFile(script, 'utf8')) +
      `\nimport ${JSON.stringify(builtin)};\n`);

    assert.throws(() => checkDriverContracts(root),
      /Node built-in import is not allowed in isolated build tooling/);
  }
});

test('ordinary consumer Hvigor scripts reject hidden CommonJS loaders', async (t) => {
  const root = await fixture(t);
  const script = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
  await writeFile(script, (await readFile(script, 'utf8')) +
    "\nimport { createRequire } from 'node:module';\n" +
    "const require = createRequire(import.meta.url);\n" +
    "require('../mysql-device-acceptance/hvigorfile.ts');\n");

  assert.throws(() => checkDriverContracts(root),
    /Node loader imports are not supported in isolated projects/);
});

test('ordinary consumer Hvigor scripts reject reflective Node loaders', async (t) => {
  for (const loader of [
    "import processAlias from 'node:process';\n" +
    "processAlias['getBuiltin' + 'Module']('module')" +
    ".createRequire(import.meta.url)('../mysql-device-acceptance/hvigorfile.ts');\n",
    "Reflect.get(process, 'getBuiltin' + 'Module')('module')" +
    ".createRequire(import.meta.url)('../mysql-device-acceptance/hvigorfile.ts');\n",
    "process['getBuiltin' + 'Module']('module')" +
    ".createRequire(import.meta.url)('../mysql-device-acceptance/hvigorfile.ts');\n",
    "module.require('../mysql-device-acceptance/hvigorfile.ts');\n",
    "Object.getPrototypeOf(async function () {}).constructor(" +
    "\"return import('../mysql-device-acceptance/hvigorfile.ts')\")();\n",
    "const globalAlias = globalThis;\n" +
    "const processAlias = globalAlias['pro' + 'cess'];\n" +
    "processAlias['getBuiltin' + 'Module']('module')" +
    ".createRequire(import.meta.url)('../mysql-device-acceptance/hvigorfile.ts');\n"
  ]) {
    const root = await fixture(t);
    const script = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
    await writeFile(script, (await readFile(script, 'utf8')) + `\n${loader}`);

    assert.throws(() => checkDriverContracts(root),
      /(?:Node loader|CommonJS) imports are not supported in isolated projects/);
  }
});

test('ordinary consumer Hvigor scripts reject dependency mutation APIs', async (t) => {
  for (const api of [
    'getDependenciesOpt',
    'setDependenciesOpt',
    'getDevDependenciesOpt',
    'setDevDependenciesOpt',
    'getDynamicDependenciesOpt',
    'setDynamicDependenciesOpt'
  ]) {
    const root = await fixture(t);
    const script = join(root, 'examples', 'mysql-client', 'hvigorfile.ts');
    await writeFile(script, (await readFile(script, 'utf8')) +
      `\n${api}();\n`);

    assert.throws(() => checkDriverContracts(root),
      /Dependency-mutating Hvigor APIs are not supported/);
  }
});

test('ordinary consumer rejects local source-package dependency indirection', async (t) => {
  const root = await fixture(t);
  const helper = join(root, 'examples', 'mysql-client', 'helper');
  await mkdir(join(helper, 'src'), { recursive: true });
  await writeFile(join(helper, 'oh-package.json5'), JSON.stringify({
    name: 'local-helper',
    version: '1.0.0',
    main: 'src/Leak.ts'
  }));
  await writeFile(join(helper, 'src', 'Leak.ts'),
    "import 'arkdb-mysql-device-acceptance';\n");
  const manifestPath = join(root, 'examples', 'mysql-client',
    'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.dependencies['local-helper'] = 'file:./helper';
  await writeFile(manifestPath, JSON.stringify(manifest));

  assert.throws(() => checkDriverContracts(root),
    /Local source-package dependencies are not supported in isolated projects/);
});

test('ordinary consumer dynamic dependencies cannot name device acceptance', async (t) => {
  const root = await fixture(t);
  const manifestPath = join(root, 'examples', 'mysql-client',
    'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.dynamicDependencies = {
    'arkdb-mysql-device-acceptance': '1.0.0'
  };
  await writeFile(manifestPath, JSON.stringify(manifest));

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project dependencies must not name a sibling project/);
});

test('ordinary consumer rejects parameterized dependency rewriting', async (t) => {
  for (const [field, value] of [
    ['parameterFile', './oh-package-params.json5'],
    ['overrideDependencyMap', { alias: 'arkdb-mysql-device-acceptance' }]
  ]) {
    const root = await fixture(t);
    const manifestPath = join(root, 'examples', 'mysql-client',
      'oh-package.json5');
    const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
    manifest[field] = value;
    await writeFile(manifestPath, JSON.stringify(manifest));

    assert.throws(() => checkDriverContracts(root),
      /Parameterized dependency rewriting is not supported/);
  }
});

test('ordinary consumer scans JavaScript source sets in registered modules', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'js', 'Leak.js');
  await mkdir(join(source, '..'), { recursive: true });
  await writeFile(source, "import 'arkdb-mysql-device-acceptance';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary application sources may use benign module-shaped properties', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'js', 'Benign.ts');
  await mkdir(join(source, '..'), { recursive: true });
  await writeFile(source,
    'interface Config { module: string; require?: boolean }\n' +
    'type RequireType = typeof require;\n' +
    'type ModuleType = typeof module;\n' +
    'class Holder { module: string = \"entry\"; require(): boolean { return false; } }\n' +
    "const config = { module: 'entry' };\n" +
    'const state = { getDependenciesOpt: false };\n' +
    'const { module: kind, require: needed } = new Holder();\n' +
    'export const values = [config.module, state.getDependenciesOpt, ' +
      'Object.constructor, kind, needed];\n');

  assert.doesNotThrow(() => checkDriverContracts(root));
});

test('ordinary application sources cannot import Node built-ins', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'js', 'NodeImport.ts');
  await mkdir(join(source, '..'), { recursive: true });
  await writeFile(source,
    "import { readFileSync } from 'node:fs';\nvoid readFileSync;\n");

  assert.throws(() => checkDriverContracts(root),
    /Node built-in imports are not supported in ordinary application sources/);
});

test('ordinary application sources cannot use CommonJS imports', async (t) => {
  for (const statement of [
    "require('node:fs');\n",
    "const load = require;\nload('./Bridge.js');\n",
    "module.require('./Bridge.js');\n",
    "const load = module.require;\nload('./Bridge.js');\n",
    "const { ['require']: load } = module;\nload('./Bridge.js');\n",
    "const { ['require']: load } = module || {};\nload('./Bridge.js');\n",
    "class Loader extends require {}\n" +
      "Object.getPrototypeOf(Loader)('./Bridge.js');\n",
    "global.require('./Bridge.js');\n",
    "global['require']('./Bridge.js');\n",
    "global.module.require('./Bridge.js');\n",
    "globalThis.require('./Bridge.js');\n",
    "globalThis.module.require('./Bridge.js');\n",
    "const moduleAlias = globalThis.module;\nmoduleAlias.require('./Bridge.js');\n",
    "let moduleAlias;\nmoduleAlias ??= globalThis.module;\n" +
      "moduleAlias.require('./Bridge.js');\n",
    "globalThis.module.createRequire(import.meta.url)('./Bridge.js');\n",
    "const { require: load } = globalThis;\nload('./Bridge.js');\n",
    "Object(globalThis).require('./Bridge.js');\n",
    "const globalAlias = global;\nglobalAlias.require('./Bridge.js');\n",
    "import load = require('./Bridge.js');\n",
    "declare function require(name: string): Object;\n" +
      "export { require as loader };\n"
  ]) {
    const root = await fixture(t);
    const source = join(root, 'examples', 'mysql-client', 'entry', 'src',
      'main', 'js', 'CommonJs.js');
    await mkdir(join(source, '..'), { recursive: true });
    await writeFile(source, statement);

    assert.throws(() => checkDriverContracts(root),
      /CommonJS imports are not supported in isolated projects/);
  }
});

test('ordinary consumer scans a registered module declared entry', async (t) => {
  const root = await fixture(t);
  const manifestPath = join(root, 'examples', 'mysql-client', 'entry',
    'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.main = 'Leak.ts';
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(join(manifestPath, '..', 'Leak.ts'),
    "import 'arkdb-mysql-device-acceptance';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary consumer scans the full reachable source closure', async (t) => {
  const root = await fixture(t);
  const manifestPath = join(root, 'examples', 'mysql-client', 'entry',
    'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.main = 'Leak.ts';
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(join(manifestPath, '..', 'Leak.ts'),
    "import './Bridge';\n");
  await writeFile(join(manifestPath, '..', 'Bridge.ts'),
    "import 'arkdb-mysql-device-acceptance';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary consumer resolves declaration-file imports', async (t) => {
  const root = await fixture(t);
  const directory = join(root, 'examples', 'mysql-client', 'entry', 'src',
    'main', 'js');
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, 'Probe.ts'),
    "import type { ProbeType } from './Types';\n" +
    'export const probe: ProbeType = {};\n');
  await writeFile(join(directory, 'Types.d.ts'),
    'export interface ProbeType {}\n');

  assert.doesNotThrow(() => checkDriverContracts(root));
});

test('ordinary consumer maps JavaScript specifiers to d.ts declarations', async (t) => {
  const root = await fixture(t);
  const directory = join(root, 'examples', 'mysql-client', 'entry', 'src',
    'main', 'js');
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, 'Probe.ts'),
    "import type { ProbeType } from './Types.js';\n" +
    'export const probe: ProbeType = {};\n');
  await writeFile(join(directory, 'Types.d.ts'),
    'export interface ProbeType {}\n');

  assert.doesNotThrow(() => checkDriverContracts(root));
});

test('ordinary consumer scans a declared types entry', async (t) => {
  const root = await fixture(t);
  const manifestPath = join(root, 'examples', 'mysql-client', 'entry',
    'oh-package.json5');
  const manifest = JSON5.parse(await readFile(manifestPath, 'utf8'));
  manifest.types = 'Leak.d.ts';
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(join(manifestPath, '..', 'Leak.d.ts'),
    "import 'arkdb-mysql-device-acceptance';\n");

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports must not name a sibling project/);
});

test('ordinary consumer follows triple-slash declaration references', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'js', 'Probe.ts');
  await mkdir(join(source, '..'), { recursive: true });
  await writeFile(source,
    "/// <reference path='../../../../../mysql-device-acceptance/entry/Leak.d.ts' />\n" +
    'export const probe: number = 1;\n');
  await writeFile(join(root, 'examples', 'mysql-device-acceptance', 'entry',
    'Leak.d.ts'), 'export interface Leak {}\n');

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project sources must not import a sibling project/);
});

test('ordinary consumer imports require exact path case', async (t) => {
  const root = await fixture(t);
  const source = join(root, 'examples', 'mysql-client', 'entry', 'src', 'main',
    'ets', 'sample', 'SampleRunner.ets');
  await writeFile(source, (await readFile(source, 'utf8'))
    .replace("from './Messages'", "from './messages'"));

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project imports require exact path case/);
});

test('ordinary consumer source roots must not be symbolic links', async (t) => {
  const root = await fixture(t);
  const sourceRoot = join(root, 'examples', 'mysql-client', 'entry', 'src',
    'main', 'ets');
  const acceptanceRoot = join(root, 'examples', 'mysql-device-acceptance',
    'entry', 'src', 'main', 'ets');
  await rm(sourceRoot, { recursive: true, force: true });
  await symlink(acceptanceRoot, sourceRoot,
    process.platform === 'win32' ? 'junction' : 'dir');

  assert.throws(() => checkDriverContracts(root),
    /ArkTS project sources must not use symbolic links|Source links are not supported/);
});

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-contracts-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const ignored = new Set(['build', '.test', '.hvigor', 'oh_modules', 'node_modules', 'BuildProfile.ets']);
  for (const name of ['core', 'mysql', 'examples', 'build-profile.json5', 'oh-package.json5', 'hvigorfile.ts', 'hvigor', 'AppScope', 'LICENSE']) {
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
