# @arkdb/mysql

A headless, pure-ArkTS MySQL driver for HarmonyOS. This is a Harmony Archive (HAR), not a separately running system driver. It requires HarmonyOS networking and crypto Kits; it does not run in Node.js or a browser.

**Source status:** `1.0.2` is engineering-preview release source. Core 1.0.0 remains independently maintained in source and is compiled into **one self-contained MySQL HAR**; users do not install a core HAR. ArkTS/native contracts and exact-archive consumption have separate local gates below. Device interoperability remains unverified. The published `1.0.1` engineering preview remains unchanged. Consult [official releases](https://github.com/OrcaSQL-Workbench/ArkDB/releases) for actual downloads; a source version is not publication. The target remains HarmonyOS 6.1.1 / API 24, tablet and 2in1. MariaDB is experimental.

The public entry retains the 1.0.1 MySQL connection/factory interface and native data shapes. Shared core does not require existing callers to adopt a generic factory or replace native calls with feature lookups. See [shared contracts](../docs/driver-contracts.md) for the distinct `Core...` interfaces and additive optional features. The examples below describe 1.0.2, not retroactive changes to the packaged 1.0.1 guide.

## Install

For 1.0.2, select `arkdb-mysql-1.0.2.har` and its matching checksum/manifest from
the official releases above. After checking the checksum, install it from your
application's module directory:

```powershell
ohpm install C:\Downloads\arkdb-mysql-1.0.2.har
```

For the existing **standalone 1.0.1** preview, download its HAR, checksum and manifest from the same reviewed release, verify the checksum, and install it from your application's module directory:

```powershell
ohpm install C:\Downloads\arkdb-mysql-1.0.1.har
```

This source does not rebuild or overwrite that version. Build local candidates with the documented API-24 toolchain:

```powershell
npm ci --ignore-scripts
npm run restore
npm run pack -- --driver mysql
```

The local output is `build\mysql-v1.0.2\arkdb-mysql-1.0.2-local.har`, with `.har.sha256` and `.manifest.json`. Compare the SHA-256 before installing. `-local` labels the filename, not the package version or import: the HAR contains `@arkdb/mysql@1.0.2`. The manifest records the local artifact channel, original source dependencies and embedded source fingerprints; the HAR itself has no external core dependency. OHPM registry publication is not required for local-file installation.

Maintainers build on their existing development computer, then separately authorize upload of the verified bytes to GitHub Releases. A version tag does not trigger a cloud build, and GitHub Actions does not install a HarmonyOS SDK. Ordinary consumers install the HAR in a compatible HarmonyOS project without cloning ArkDB or copying its driver source.

Put that one HAR under `MyApp\libs`. The `MyApp\entry\oh-package.json5` configuration is:

```json5
{
  "dependencies": {
    "@arkdb/mysql": "file:../libs/arkdb-mysql-1.0.2-local.har"
  }
}
```

Paths are relative to the module manifest. No core dependency or project-level core override is needed. Restore dependencies and rebuild after an upgrade; replace the deliberately selected HAR and matching checksum together. Do not register ArkDB source modules in the application.

The distribution is an API-24 **bytecode HAR** with normalized OHM URLs. Import implementation, shared contracts and errors from `@arkdb/mysql`, never internal source paths. `@arkdb/core` is a source-workspace interface, not a required consumer import. The driver declares `ohos.permission.INTERNET`; verify it in the final merged application. The host owns credential storage and certificate access. Registry installation is separate and requires actual publication.

## Public MySQL compatibility

`DbConnection` retains `ping`, `queryStream`, context changes, autocommit,
commit/rollback and native session/server information. The non-generic
`DbDriverFactory` retains `createConnection(config, password)` and provider
creation; `DbExecutionController` retains handle-based `cancel(handle)`.
Existing provider implementations do not acquire new required methods.

`SqlValue`, column metadata, buffered results and streaming callbacks retain
their MySQL types. Native stream summaries keep the established numeric warning
and bigint insert-id defaults; zero alone is not proof that a server reported an
identifier. The portable `features.streaming` interface instead preserves
unreported observations as optional fields. Shared errors keep one constructor:
`code` remains numeric, while `nativeCode` can retain numeric or textual codes.
New fields on existing data shapes are optional.

Use `CoreDbConnection`, `CoreDbDriverFactory`, `CoreQueryResultSink` and the other
`Core...` exports when writing portable integrations. Core remains engine-neutral.
The reserved `ServerFamily.PostgreSQL` value is retained only for source
compatibility; it does not mean a PostgreSQL driver exists.

## Connect, query, close

Run connection work in a host-owned Worker, not in an ArkUI callback. This function uses only the public package interface; the runnable sample below supplies the Worker and page.

<!-- arkts-example: quickstart -->
```typescript
import {
  ConnectionConfig, DbConnection, DbDriverFactory, MySqlDriverFactory,
  QueryResult, SslMode
} from '@arkdb/mysql';

export async function readVersion(host: string, user: string, password: string): Promise<QueryResult> {
  const config = new ConnectionConfig();
  config.host = host;
  config.user = user;
  config.ssl.mode = SslMode.VERIFY_IDENTITY;

  const issues = config.validate();
  if (issues.length > 0) {
    throw issues[0];
  }

  const factory: DbDriverFactory = new MySqlDriverFactory();
  const connection: DbConnection = factory.createConnection(config, password);
  try {
    await connection.connect();
    return await connection.query('SELECT VERSION() AS version');
  } finally {
    await connection.close();
  }
}
```

Passwords are passed separately and must not be stored in `ConnectionConfig` or logged. `SslMode.VERIFY_IDENTITY` requires both certificate-chain and hostname verification. The preserved configuration default is `PREFERRED`, which can fall back to plaintext; choose your TLS policy explicitly.

`close()` can itself fail. The simple function above propagates that failure; applications that must preserve both an operation error and a cleanup error should retain them separately, as the runnable sample and transaction example do. Do not automatically reconnect and replay SQL after an uncertain outcome.

## Runnable Worker sample

Source: [examples/mysql-client](https://github.com/OrcaSQL-Workbench/ArkDB/tree/main/examples/mysql-client). It is a complete Stage-model HAP with an ArkUI page, registered Worker entry, bounded output, typed error handling, and explicit connection cleanup. It uses the built HAR, not a source dependency.

From an ArkDB source checkout:

```powershell
npm ci --ignore-scripts
npm run restore
npm run pack
npm run example:prepare
npm run example:build
```

Open `examples\mysql-client` as a project in DevEco Studio. Select a compatible API-24 tablet/2in1 target and configure your own local debug signing there; no signing identity is shipped. Run the `entry` module, enter a test server hostname, port, user, and password, and press **Connect, read, and close**. The fixed read-only statement returns server version, exact BIGINT/DECIMAL examples, and SQL NULL. Passwords are never persisted and the page clears its password field after submission.

The sample always verifies TLS identity. Use the certificate's DNS hostname. An optional CA path must already refer to a PEM file readable in the application's sandbox; the sample does not grant arbitrary filesystem access or provide a certificate picker. Device installation and server interoperability have not been exercised by the repository's local checks.

For an existing Stage application, declare its Worker in the module's `build-profile.json5`:

```json5
{
  "buildOption": {
    "sourceOption": {
      "workers": ["./src/main/ets/workers/mysql.worker.ets"]
    }
  }
}
```

The host creates `new worker.ThreadWorker('entry/ets/workers/mysql.worker.ets')` from `@kit.ArkTS`. Its Worker imports the driver and owns connect/query/close. Exchange small flat DTOs, not connections, errors, `QueryResult` objects, or UI references. The sample uses `@Sendable` request/response classes, allows one operation at a time, and closes its Worker after cleanup. When leaving the page, it first requests shutdown and uses forced termination only as a bounded fallback; forced termination is not proof of server-side cancellation.

Huawei's [Worker guide](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/worker-introduction) documents Worker paths, lifecycle, and messaging. Worker files must not export declarations; put shared DTOs in a separate module.

## Connection options

| Field | Default | Meaning |
| --- | --- | --- |
| `host` | empty; required | Server hostname/IP; verified TLS must match the certificate identity |
| `port` | `3306` | Integer from 1 to 65535 |
| `user` | empty; required | MySQL account name |
| `defaultSchema` | unset | Default database selected during authentication |
| `ssl` | `new SslConfig()` | TLS policy and optional certificate paths |
| `connectTimeoutMs` | `10000` | Positive integer; total connection-opening deadline |
| `autocommit` | `true` | Requested initial autocommit state |

`validate()` returns typed errors; `validateIssues()` additionally identifies the field. Neither opens a connection. `clone()` copies the options and isolates nested TLS configuration.

Profile IDs, names, grouping, and credential storage belong to the host. Select the driver through its factory, not a tag inside connection options. The client uses `utf8mb4`; ignored charset/compression/SQL-mode/connection-attribute switches, file-engine paths, and generic future-option bags are not exposed.

## Reading typed results

`columns[i]` describes `rows[rowIndex][i]`. SQL NULL is not the string `"NULL"`. BIGINT is `bigint`, DECIMAL and temporal fields remain strings, and binary values are `Uint8Array`; numbers are not a lossless replacement for BIGINT/DECIMAL. JSON cannot directly serialize `bigint`, so convert values deliberately for your own message format.

<!-- arkts-example: rows -->
```typescript
import { ArkDbError, QueryResult, SqlValue } from '@arkdb/mysql';

export function displayCell(value: SqlValue): string {
  if (value === null) return 'NULL';
  if (value instanceof Uint8Array) {
    return '0x' + Array.from(value).map((byte: number): string =>
      byte.toString(16).padStart(2, '0')).join('');
  }
  return value.toString();
}

export function displayRow(result: QueryResult, rowIndex: number): string[] {
  if (!Number.isSafeInteger(rowIndex) || rowIndex < 0 || rowIndex >= result.rows.length) {
    throw ArkDbError.validation('Row index is outside the loaded result.');
  }
  return result.rows[rowIndex].map(displayCell);
}
```

Check `result.truncated` / `truncationReason` before treating loaded rows as complete. `additionalResults` contains subsequent result sets; `affectedRows`, `lastInsertId` and `warningCount` describe execution. Portable streaming summaries leave `lastInsertId` absent when an EOF row terminator reports no identifier and preserve the value when an OK packet reports one. The native buffered result retains its historical zero default. Use session flags only when `statusKnown` / `sessionStatus.known` is true. Bound presentation separately; converting a whole result to a giant string defeats streaming. Historical MySQL `ColumnDef`/`ServerInfo` imports retain native subclasses; portable versions live in core.

## Errors and diagnostics

Catch `ArkDbError` on the thread where it was thrown. Use `kind`, optional server `code`, and optional `sqlState` for decisions. Do not classify errors by matching English messages, and do not expose raw errors in logs: server messages may contain SQL, usernames, or other sensitive data.

<!-- arkts-example: errors -->
```typescript
import { ArkDbError, ArkDbErrorKind } from '@arkdb/mysql';

export function publicErrorText(error: Object): string {
  if (!(error instanceof ArkDbError)) return 'Unexpected failure; no operation was replayed.';
  let text = 'Database error: ' + error.kind;
  if (error.code !== undefined) text += ', code=' + error.code;
  if (error.sqlState !== undefined) text += ', SQLSTATE=' + error.sqlState;
  if (error.kind === ArkDbErrorKind.Tls) text += '. Check hostname, trust chain, and certificate access.';
  if (error.kind === ArkDbErrorKind.Auth) text += '. Check the account and authentication settings.';
  return text;
}
```

Kinds include `Network`, `Tls`, `Auth`, `Protocol`, `Server`, `Timeout`, `Cancelled`, `Validation` and `Unsupported`. MySQL retains numeric `code` values; the same shared error's `nativeCode` also preserves textual codes for other adapters, independently of SQLSTATE. An ordinary SQL error can leave the connection open but its session status unknown. Check lifecycle, known status and execution outcome before reuse. Do not replay writes.

`Logger.setLevel(LogLevel.OFF)` disables driver logging; custom `LogSink` implementations are opt-in per thread. Built-in identifier tokens are pseudonymous, not anonymization, and passwords/authentication material must never be passed to a logger.

## TLS and custom certificates

| Mode | Policy |
| --- | --- |
| `DISABLED` | Plain TCP; use only when explicitly acceptable |
| `PREFERRED` | Negotiate TLS when offered, otherwise plaintext; the compatibility default |
| `REQUIRED` | Require encryption, without the identity guarantee of verified modes |
| `VERIFY_CA` | Require TLS and validate the certificate chain |
| `VERIFY_IDENTITY` | Validate the chain and hostname; recommended for new integrations |

`SslConfig` accepts `caCertPath`, paired `clientCertPath` / `clientKeyPath`, `tlsVersions` (`TLSv1.2` / `TLSv1.3`), and optional `cipherSuites`. Unset CA uses the platform trust policy. Material paths are interpreted by the HarmonyOS process, not your desktop; the host owns file selection, sandbox copying, access grants, and secure private-key storage.

<!-- arkts-example: tls -->
```typescript
import { ConnectionConfig, SslMode } from '@arkdb/mysql';

export function configureVerifiedTls(config: ConnectionConfig, caPemPath: string,
  clientCertificatePath: string, clientPrivateKeyPath: string): void {
  config.ssl.mode = SslMode.VERIFY_IDENTITY;
  config.ssl.caCertPath = caPemPath;
  config.ssl.tlsVersions = ['TLSv1.2', 'TLSv1.3'];
  config.ssl.clientCertPath = clientCertificatePath;
  config.ssl.clientKeyPath = clientPrivateKeyPath;
  const errors = config.validate();
  if (errors.length > 0) throw errors[0];
}
```

For server-only TLS, leave both client fields unset. A successful local compile or mock-certificate test does not certify a real platform trust chain, hostname rejection, or mutual TLS.

## Bounded streaming

Use an awaited sink to process each chunk without retaining every row. Omitting `onTruncation` selects bounded synchronization draining rather than pretending cancellation occurred. Sink callbacks must settle; awaiting a sink does not pause incoming socket delivery.

<!-- arkts-example: streaming -->
```typescript
import {
  ArkDbError, DbStreamingConnection, QueryExecutionSummary, QueryOptions,
  QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk
} from '@arkdb/mysql';

export class CountingSink implements QueryResultSink {
  loadedRows: number = 0;
  truncated: boolean = false;

  async onResultStart(_meta: QueryResultMeta): Promise<void> {}
  async onRows(chunk: QueryRowChunk): Promise<void> {
    this.loadedRows += chunk.rows.length;
  }
  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    this.truncated = this.truncated || summary.truncated;
  }
}

export async function countBoundedRows(connection: DbStreamingConnection, trustedSql: string,
  sink: CountingSink): Promise<QueryExecutionSummary> {
  const options = new QueryOptions();
  options.maxRows = 10000;
  options.maxResultBytes = 4 * 1024 * 1024;
  const summary = await connection.queryStream(trustedSql, options, sink);
  if (!summary.statusKnown) throw ArkDbError.protocol('The session status is unknown.');
  return summary;
}
```

| Option | Default | Meaning |
| --- | --- | --- |
| `maxRows` | `0` | No row-count cap; byte/result/drain limits still apply |
| `maxChunkRows` | `200` | Maximum rows per awaited chunk |
| `maxChunkBytes` | `262144` | Chunk byte budget |
| `maxResultBytes` | `33554432` | Decoded result byte budget |
| `maxResultSets` | `64` | Protocol result-set safety limit |
| `maxDrainBytes` | `33554432` | Synchronization-drain byte budget after truncation |
| `maxDrainTimeMs` | `5000` | Synchronization-drain time budget |
| `statementTimeoutMs` | `0` | Validated value only; this low-level driver does **not** start a cancellation timer |

Byte accounting is a driver estimate, not total application heap size. Exhausted drain/transport budgets fail closed. `query()` is a bounded convenience collector, not an unlimited alternative.

## Transactions

Use a dedicated connection and transactional tables. MySQL DDL can implicitly commit; a common connection interface does not change server SQL semantics. The example accepts only application-owned statements, preserves primary/rollback/close failures, and never replays work.

<!-- arkts-example: transactions -->
```typescript
import { ConnectionConfig, ConnectionState, MySqlDriverFactory } from '@arkdb/mysql';

export class TransactionFailure extends Error {
  primaryFailure: Object | null;
  rollbackFailure: Object | null;
  cleanupFailure: Object | null;
  rollbackAttempted: boolean;

  constructor(primary: Object | null, rollback: Object | null,
    cleanup: Object | null, attempted: boolean) {
    super('Transaction or cleanup failed; inspect the retained failures without logging secrets.');
    this.primaryFailure = primary;
    this.rollbackFailure = rollback;
    this.cleanupFailure = cleanup;
    this.rollbackAttempted = attempted;
  }
}

export async function runTransaction(config: ConnectionConfig, password: string,
  trustedStatements: string[]): Promise<void> {
  const options = config.clone();
  options.autocommit = false;
  const errors = options.validate();
  if (errors.length > 0) throw errors[0];
  const connection = new MySqlDriverFactory().createConnection(options, password);
  let primary: Object | null = null;
  let rollback: Object | null = null;
  let cleanup: Object | null = null;
  let rollbackAttempted = false;
  try {
    await connection.connect();
    for (const sql of trustedStatements) await connection.query(sql);
    await connection.commit();
  } catch (error) {
    primary = error as Object;
    if (connection.state === ConnectionState.Ready) {
      rollbackAttempted = true;
      try { await connection.rollback(); } catch (error) { rollback = error as Object; }
    }
  } finally {
    try { await connection.close(); } catch (error) { cleanup = error as Object; }
  }
  if (primary !== null || rollback !== null || cleanup !== null) {
    throw new TransactionFailure(primary, rollback, cleanup, rollbackAttempted);
  }
}
```

If a commit response is lost, a rollback attempt does not prove the commit did not happen. A successful rollback also does not undo nontransactional-table writes or external side effects.

## Cancellation and deadlines

The generic `features.cancellation` interface is bound to this connection's current execution. MySQL owns a separate control connection to the same server and its cleanup; another driver need not use SQL control sessions. Attach a rejection handler immediately and await **both** the request and the original query. A `Requested` result is not proof of interruption or reusable session state.

This finite `SLEEP(10)` demonstration cancels one read. A race can complete normally rather than report interruption. Unexpected query or cancellation errors retain both failure paths instead of being converted into successful cancellation.

<!-- arkts-example: cancellation -->
```typescript
import { ArkDbError, ConnectionState, DbConnection } from '@arkdb/mysql';

export class CancellationFailure extends Error {
  queryFailure: Object | null;
  controlFailure: Object | null;

  constructor(query: Object | null, control: Object | null) {
    super('Query or cancellation failed; the execution outcome must be checked.');
    this.queryFailure = query;
    this.controlFailure = control;
  }
}

export class QueryObservation {
  failure: Object | null = null;
}

export async function demonstrateCancellation(queryConnection: DbConnection): Promise<string> {
  if (queryConnection.state !== ConnectionState.Ready) throw ArkDbError.validation('Connection is not ready.');
  const controller = queryConnection.features?.cancellation;
  if (controller === undefined) throw ArkDbError.unsupported('Cancellation is not available.');
  const query = new QueryObservation();
  let controlFailure: Object | null = null;
  const observed = queryConnection.query('SELECT SLEEP(10)').then(
    (): void => {},
    (error: Object): void => { query.failure = error; }
  );
  try {
    await controller.cancel();
  } catch (error) {
    controlFailure = error as Object;
  }
  await observed;
  const queryFailure = query.failure;
  const interrupted = queryFailure instanceof ArkDbError && controller.isInterruptionError(queryFailure);
  if (controlFailure !== null || (queryFailure !== null && !interrupted)) {
    throw new CancellationFailure(queryFailure, controlFailure);
  }
  return interrupted ? 'interrupted' : 'completed before cancellation took effect';
}
```

The returned `QueryCancellationResult` distinguishes not running/requested and reports not-ready/ready/awaiting-completion/requires-synchronization/closed reuse state. Inspect the final connection/session state after the original query settles; MySQL can refresh invalidated status with `ping()`. While a request is pending, a later command is rejected. If a dispatched `KILL` times out or loses its outcome, the target connection is closed and permanently retired before that guard is released: closing only the control socket cannot rule out a delayed server-side `KILL`. Create a new connection instance rather than reopening the retired one, and never replay writes automatically. A definite server rejection of `KILL` does not retire an otherwise usable target.

The native `createExecutionController(controlConnection).cancel(connectionHandle)` helper is retained for callers explicitly managing their own control session and execution lifetime. Handles are opaque; never concatenate untrusted input into `KILL QUERY`. Control failures may leave a query running. Host timers and forced cleanup remain necessary for statement deadlines; `Promise.race` alone does not cancel server execution. These live races remain unverified.

## Metadata, metrics, and database context

Providers borrow an already-open connection. Serialize their work with every other command on that connection. Metrics collection may need additional server privileges and returns explicit availability/error states; MariaDB metrics are unsupported.

<!-- arkts-example: providers -->
```typescript
import {
  DatabaseContext, DbConnection, DbObjectInfo, DbObjectKind,
  MySqlDriverFactory, ServerMetricsCategory, ServerOverviewSnapshot
} from '@arkdb/mysql';

export async function listTables(connection: DbConnection, database: string): Promise<DbObjectInfo[]> {
  const context = new DatabaseContext();
  context.schema = database;
  return await new MySqlDriverFactory().createMetadataProvider(connection)
    .listObjects(context, DbObjectKind.Table);
}

export async function readMetrics(connection: DbConnection):
  Promise<ServerMetricsCategory<ServerOverviewSnapshot>> {
  return await new MySqlDriverFactory().createServerMetricsProvider(connection).readOverview();
}
```

MySQL also exposes these through `features.metadata` and `features.metrics`; generic metrics return named measurements, not InnoDB models. The MySQL `ServerMetricsProvider` compatibility alias remains vendor-specific. Context features explicitly declare that catalog/schema are aliases: either selects the database, but conflicting values are rejected. Other engines can require reconnection for a catalog change and permit independent schema changes.

## Execution contract

- **One connection, serialized operations.** The driver does not create a Worker, queue concurrent requests, or reconnect/replay SQL. Use one connection per Worker session and serialize all commands. Live connection objects do not cross Worker messages.
- **Typed values.** Rows are arrays aligned with `columns`. SQL NULL is `null`; BIGINT is `bigint`; DECIMAL and temporal values remain strings; binary values are `Uint8Array`. Preserve these types when designing your own Worker DTOs.
- **Bounded results.** `query()` uses the bounded streaming implementation and exposes `truncated`, `truncationReason`, and `additionalResults`. It is not an unlimited collector.
- **Streaming.** `queryStream(sql, options, sink)` awaits each `QueryResultSink` callback. Set row/chunk/result/drain budgets in `QueryOptions`, handle truncation and unknown status explicitly, and avoid accumulating every chunk. Awaiting a sink does not pause socket delivery; the separate receive queue remains bounded and fails closed on overflow.
- **Timeouts.** `connectTimeoutMs` covers connection opening. The low-level driver validates `QueryOptions.statementTimeoutMs` but does **not** start a statement-cancellation timer. Callers must own statement deadlines, cancellation orchestration, and cleanup; `Promise.race` alone does not cancel server execution.
- **Transactions.** Generic features expose `begin`, `commit`, `rollback` and known session status. MySQL also retains native `setAutocommit`. Failure can invalidate status or leave an unknown execution outcome; never replay writes.
- **Cancellation.** The generic connection feature owns its MySQL control-session lifetime. The retained handle-based factory helper does not. Await the original query and request, then inspect reuse/status before another command.
- **Errors.** `ArkDbError` and `ArkDbErrorKind` expose common categories and server error code/SQLSTATE. No Workbench-name compatibility aliases are exported. Server messages can contain sensitive data; do not copy them into public logs.
- **Logging.** `Logger`, `LogSink`, and the five `ArkDB.*` subsystem tags describe driver activity only. Host UI, storage, and RPC logging stay outside the driver. File output remains an explicit opt-in convenience.

The factory also exposes capability flags and metadata/server-metrics providers. SQL is not portable between engines. MariaDB metrics are explicitly unsupported. Prepared statements, parameter placeholders/binding, pooling, a managed Worker client, and PostgreSQL are not implemented. Never interpolate untrusted input into SQL.

## Verification limits

Local validation includes actual ArkTS compilation and the core/MySQL native contract suites, including deterministic protocol, cancellation and metrics fixtures. The exact-archive consumer gate restores one HAR with no core file, source override or available registry, then compiles the packaged examples and unsigned sample HAP. It separately restores test-only dependencies and executes offline lifecycle/error-identity cases. SDK-free fakes are separate tooling evidence, not substitutes for native checks. Candidate manifests and consumer records bind results to exact bytes and source fingerprints.

The historical published 1.0.1 verification remains recorded in [releasing](../docs/releasing.md), not as evidence for 1.0.2/core. A future release verifier must consume its exact single-HAR download and cannot fall back to local source or stale `dist`.

Network, certificate and crypto replacements used by local Hypium tests are not real-device tests. Local preparation, public GitHub download availability, OHPM registry availability, and actual device interoperability are separate states.

Before treating a release as production-ready, verify real MySQL TCP/TLS and certificate failures, authentication paths, streamed/truncated/multiple results, transactions, ordinary server errors, cancellation races, and connection reuse on the documented target devices. MariaDB requires its own compatibility evidence.

## License

Apache-2.0; see `LICENSE`. `README.OpenSource` contains the retained mysqljs/mysql and sidorares/node-mysql2 MIT licenses and immutable upstream revisions. This filename is included by the HarmonyOS HAR packager.
