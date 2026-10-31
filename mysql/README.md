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
identifier. Native results and summaries retain the legacy numeric `affectedRows`
and add optional `affectedRowsExact` when an OK packet reports the exact bigint;
row results that report no affected count leave it undefined. Core remains
engine-neutral and does not acquire this MySQL field. The portable
`features.streaming` interface instead preserves unreported observations as
optional fields. Shared errors keep one constructor: `code` remains numeric,
while `nativeCode` can retain numeric or textual codes. New fields on existing
data shapes are optional.

Use `CoreDbConnection`, `CoreDbDriverFactory`, `CoreQueryResultSink` and the other
`Core...` exports when writing portable integrations. Core remains engine-neutral.
The reserved `ServerFamily.PostgreSQL` value is retained only for source
compatibility; it does not mean a PostgreSQL driver exists.

## Optional typed prepared statements

Built-in connections expose `mysqlFeatures.prepared`; the factory's
`supportsPreparedStatements` hint is true. The native `DbConnection` adds only an
optional `mysqlFeatures` property: old custom connections and capability literals
need no new fields or methods. Core's minimal connection stays unchanged.
`requireMySqlFeatures(connection)` throws the same public `ArkDbError` with
`Unsupported` when the container is absent. Check `prepared` separately because
an available container need not provide every optional feature.

Discovering the feature does not connect or prepare anything. Call it only after
`connect()` completes; `prepare`, `execute` and `executeStream` still reject a
not-ready or busy connection. Saving the feature does not bypass those checks or
transfer a statement to another physical connection or session generation.
There is one command owner, no hidden queue and no automatic replay.

The compiled quickstart module below also exports `selectBoundValue` for an
already-connected connection. It combines a typed UInt64 value with identifier
quoting and positional placeholders without interpolating the value into SQL.

`MySqlParameter` is input-only; it does not widen the native result `SqlValue`
union. Choose an explicit `MySqlParameterType`: Null, Boolean, Int32, Int64,
UInt64, Float64, Decimal, Text, Binary, Date, DateTime, Timestamp, Time or Json.
Int64/UInt64 use `bigint`; Decimal uses a canonical decimal string with at most
65 total digits and 30 fractional digits; floating-point values must be finite.
Temporal values use validated MySQL strings, not `Date` or implicit timezone
conversion. Json accepts validated JSON text, not arbitrary objects. Every type
can carry SQL NULL; Binary snapshots its `Uint8Array`. Invalid types and values
fail before PREPARE. The command payload is bounded to 16 MiB and 65535
parameters. A binding-count mismatch can follow PREPARE but never sends EXECUTE.

By default, `execute(sql, parameters, options?)` prepares, consumes or synchronizes
the results, and closes its statement without caching. Set
`config.preparedCacheSize` to an integer from 1 to 256 before constructing the
connection to retain a bounded, private LRU of convenience statements on that
physical connection. Missing or zero keeps the uncached path. Neither path adds
fingerprint probes or other hidden SQL. Consecutive cached convenience calls can
reuse a handle for the exact SQL in the same physical session and private reuse
context. Enabling caching accepts that handle's prepare-time semantics: it does
not promise fresh-prepare equivalence for arbitrary SQL or routines that
indirectly change session state within a cached sequence. Use cache size zero or
a new explicit `prepare` when the current server context must be parsed afresh.

Any non-cache operation that successfully reserves the command scope ends this
reuse context, including text queries/streams, portable streaming, explicit
prepare/execute/stream/close, ping, context/transaction control, and the metadata
or metrics operations using those paths. This retirement does not inspect SQL
keywords or compare returned session values; even a raw command whose context
appears unchanged retires retained entries. Busy or prevalidation-failed calls
that did not obtain a scope do not retire an in-flight borrow. No SESSION_TRACK
support or transparent tracking of arbitrary session changes is implied.

Live-session retirement keeps handles accounted for, closing idle retired entries
under the next cache owner's scope rather than forgetting them or inserting an
implicit command queue. Borrowed retired entries still count toward capacity and
close only after their owner settles. The cache evicts only unborrowed LRU entries. If every retained entry is in use,
the call uses a temporary statement instead of stealing a handle or exceeding
retained capacity. Failed, retired or disconnected ownership is not returned;
stream completion includes all results, drain, consumer acknowledgements and
cancellation settlement. `executeStream` uses the same
budgets and awaited native `QueryResultSink` callbacks as text streaming; results
retain exact BIGINT/DECIMAL/temporal/binary mappings and native summary defaults.
The portable `features.streaming` interface remains the separate text-stream
adapter with optional unreported observations.

For explicit reuse, `prepare(sql)` returns a `MySqlPreparedStatement` with
`parameterCount`, defensive prepare-time `columns`, `closed`, `execute`,
`executeStream` and idempotent `close()`. Close it when finished. Execution
metadata can differ from prepare-time metadata, and handles remain bound to their
original physical session. Explicit handles never enter or borrow from the
convenience cache. Close does not invent a server acknowledgement.

### SQL-mode-aware named parameters

Built-in connections expose `requireMySqlFeatures(connection).named` as an
optional MySQL feature. `MySqlNamedParameter` pairs a case-sensitive ASCII name
matching `[A-Za-z_][A-Za-z0-9_]*` with an existing typed `MySqlParameter`.
`execute(sql, parameters, options?)` and `executeStream(sql, parameters, options,
sink)` accept only `:name` value markers. Repeating one name in SQL emits the
same typed value at every positional occurrence. Input names must be unique;
missing, duplicate and unused inputs are rejected.

Each named call owns one command scope and deliberately reads the current
session fingerprint first to obtain `@@SESSION.sql_mode`. It then scans the
template, converts executable `:name` markers to positional `?`, prepares that
SQL, binds binary-protocol values, consumes or synchronizes the result, and
closes the statement. SQL mode, compiled templates and statements are not
cached, so a completed `SET SESSION sql_mode = ...` affects the next named call.
The probe and prepared operation cannot be interleaved with another command on
the connection. A named call also ends any positional convenience-cache reuse
context.

The scanner treats single quotes, backticks, double quotes under both ordinary
and `ANSI_QUOTES` modes, `#` comments, ordinary `/* ... */` comments and MySQL
`--` comments followed by whitespace/control as opaque. It honors
`NO_BACKSLASH_ESCAPES`, preserves source text including newlines, NUL and
Unicode, rejects executable `?` markers, and rejects executable/version
comments and optimizer-hint comments. Named and positional markers cannot be
mixed in executable SQL. Values are never interpolated into SQL and named
markers never quote identifiers; use `quoteMySqlIdentifier` separately for
trusted identifier segments.

Named streaming uses the same bounded results, awaited native sink callbacks,
drain behavior, cancellation settlement and error outcomes as positional
prepared streaming. Discovering the feature performs no I/O, but execution
requires the connection to be Ready.

Prepared batches are available from the optional
`requireMySqlFeatures(connection).batch` feature. The facade can be discovered
before connect, but a nonempty `execute(sql, rows, options?)` requires a ready
connection; empty rows return no results without network dispatch. One call owns
one command scope, executes rows serially through one internally reused prepared
statement and stops on the first failure. `maxItems` defaults to 1000 and accepts
1..1000; `maxBufferedBytes` defaults to 33554432 and accepts 1..33554432, with
all result sets sharing the remaining cumulative buffer budget.

Successful items retain their native `MySqlQueryResult` values. A failure throws
`MySqlBatchError` with `completedResults`, zero-based `failedIndex` and
`failedOutcome`; completed writes are not retried or rolled back, and an
`Unknown` outcome is never replayed automatically. Batch execution does not
start, commit or roll back a transaction, and invocation inside an active
transaction is rejected.

Built-in connections also expose the optional
`requireMySqlFeatures(connection).transactions` runner. Check that member
separately. `MySqlTransactionOptions` defaults to
`MySqlTransactionIsolation.Default`, leaves `readOnly` unset and sets
`consistentSnapshot=false`. Entry requires a Ready connection, known session
status, no existing transaction and `autocommit=true`; rejection occurs before
transaction SQL. Explicit isolation/read-only characteristics use
`SET TRANSACTION` before `START TRANSACTION`, while a consistent snapshot is a
`START TRANSACTION` option. The helper does not change the caller's autocommit
setting or retry SQL.

The callback receives a scoped `MySqlSession`. Its query/stream and
savepoint/rollback-to/release operations share one physical command owner. The
facade expires as soon as the callback settles, waits for owned
cancellation/control cleanup before later child commands or final settlement,
and omits root prepared, batch and nested-transaction executors. The root
connection's savepoint methods reject because only the callback facade may use
that scope.

Successful callbacks commit. Callback failures roll back when the target is
synchronized and Ready, including after a consumed server error. A plain
callback error is rethrown by identity after successful rollback. DDL can
implicitly end and commit the transaction; that case is reported as completed
rather than pretending rollback occurred. Unknown command, commit or
cancellation outcomes remain `Unknown`. Rollback and control-cleanup failures
are retained without replacing the original primary failure.

No pool, server cursor or long-data upload is exposed. Opt-in buffered
text-query and prepared-execute deadlines are available through
`mysqlFeatures.deadlines`; legacy `QueryOptions.statementTimeoutMs` remains
validation-only.

Built-in root connections also expose `mysqlFeatures.session`.
`MySqlSessionController.reset()` sends `COM_RESET_CONNECTION` (`0x1f`) through
the same single-command gate; it never queues behind an active query, pending
cancellation or external cursor. Success advances the physical-session
generation, invalidates every explicit prepared handle and private cached
statement, first restores `SET NAMES utf8mb4 COLLATE utf8mb4_general_ci`, then
reapplies `defaultSchema`, `autocommit`, `session.timeZone` and
`session.sqlMode`. Before success it reads the owned session fingerprint and
requires `character_set_client=utf8mb4` plus the exact configured database, or
no selected database when `defaultSchema` is unset/empty. A residual tenant
database, charset mismatch or failed fingerprint closes the physical
connection; it is never returned for reuse. `ROLLBACK` does not reset the
generation. Servers that reject the command as unsupported produce
`ArkDbErrorKind.Unsupported`; callers or pools may destroy that connection, but
the driver does not fall back to `CHANGE_USER`, reconnect or replay SQL. A
timeout, malformed response, network uncertainty or failed post-reset
initialization closes the physical connection and retains cleanup failures.

`MySqlSession` is a restricted borrowing interface with read-only feature,
server-info and session-status properties plus native `query`/`queryStream` and
transaction-scoped savepoint methods. It does not own connection
creation/closure, implement a pool lease or enforce read-only SQL. Savepoint
methods reject on a root connection or an expired callback facade.
`quoteMySqlIdentifier(parts)` quotes each nonempty identifier segment;
`mysqlPlaceholders(count)` returns comma-separated `?` markers for 1..65535
values. Neither interpolates values or implements text-protocol binding.

## Connect, query, close

Run connection work in a host-owned Worker, not in an ArkUI callback. This function uses only the public package interface; the runnable sample below supplies the Worker and page.

<!-- arkts-example: quickstart -->
```typescript
import {
  ArkDbError, ConnectionConfig, DbConnection, DbDriverFactory, MySqlDriverFactory,
  MySqlParameter, MySqlParameterType, MySqlSessionOptions, QueryResult, SslMode, mysqlPlaceholders,
  quoteMySqlIdentifier, requireMySqlFeatures
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

export async function selectBoundValue(connection: DbConnection, value: bigint): Promise<QueryResult> {
  const prepared = requireMySqlFeatures(connection).prepared;
  if (prepared === undefined) throw ArkDbError.unsupported('Prepared statements are unavailable.');
  const sql = 'SELECT ' + mysqlPlaceholders(1) + ' AS ' + quoteMySqlIdentifier(['value']);
  return prepared.execute(sql, [new MySqlParameter(MySqlParameterType.UInt64, value)]);
}

export function configureOptionalSession(config: ConnectionConfig): void {
  const session = new MySqlSessionOptions();
  session.timeZone = '+00:00';
  session.sqlMode = 'ANSI_QUOTES';
  config.session = session;
}
```

Passwords are passed separately and must not be stored in `ConnectionConfig` or logged. `SslMode.VERIFY_IDENTITY` requires both certificate-chain and hostname verification. The preserved configuration default is `PREFERRED`, which can fall back to plaintext; choose your TLS policy explicitly.

`close()` can itself fail. The simple function above propagates that failure;
applications that must preserve both an operation error and a later
connection-close error should retain them separately. Transaction callback
rollback/control cleanup is already retained by the native transaction runner.
Do not automatically reconnect and replay SQL after an uncertain outcome.

When an idle connection sends QUIT, a failed or timed-out write now rejects `close()` even if socket shutdown succeeds. Socket shutdown is still attempted, and subsequent cleanup failures are retained with the original QUIT failure. Successful close and repeated calls remain idempotent.

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
| `connectTimeoutMs` | `10000` | Positive integer; total connection-opening or session-reset deadline |
| `autocommit` | `true` | Requested initial autocommit state |
| `session` | unset | Optional `MySqlSessionOptions`; `timeZone` and `sqlMode` are individually unset by default |
| `preparedCacheSize` | unset; off | Integer from 0 to 256; 0 disables the private convenience-statement cache |

`validate()` returns typed errors; `validateIssues()` additionally identifies the field. Neither opens a connection. `clone()` copies the options and isolates nested TLS and session configuration. A connection snapshots these options when constructed; later caller mutations do not change that connection.

The quickstart's optional `configureOptionalSession(config)` helper can be called before creating the connection. Omitted fields leave the server's settings unchanged; `sqlMode = ''` explicitly requests an empty SQL mode. Empty options keep the no-extra-initialization-command path. Charset remains fixed to `utf8mb4`.

Session containers must be non-null, non-array objects, and present fields must be primitive, well-formed UTF-16 strings. Invalid new session inputs produce canonical `Validation` errors from `validateIssues()`/`validate()` and `clone()`, with field ids `session`, `session.timeZone`, or `session.sqlMode`. Existing non-session clone validation behavior is unchanged. Values are not trimmed, normalized, coerced, defaulted, or limited by the metadata identifier's 512-byte bound. Unknown object keys do not become driver settings.

Invalid `preparedCacheSize` values are rejected by `validateIssues()`/`validate()`
and `clone()` with the `preparedCacheSize` field id; values are not rounded or
coerced. The connection snapshots the capacity with its other options.

Timezone and SQL-mode semantics belong to the server: local validation accepts empty and unknown names without checking a local timezone list. A server may reject a timezone name, for example when its timezone tables are unavailable; that error propagates without a local-timezone fallback. Configured values use checked UTF-8 byte expressions, not raw SQL interpolation or backslash-escaping assumptions. Initialization completes within the existing opening deadline before `connect()` reports Ready. Failure rejects connection opening and cleans up the partial connection, retaining primary and cleanup errors.

Neither ordinary commands nor enabled convenience-statement cache lookups add hidden session-fingerprint probes, restore previous-statement counters with SQL, or replay SQL. Named execution is the explicit exception: every call uses the internal four-field fingerprint SQL to obtain the current session mode before scanning its template. The utility is not a transparent cache guard or a new public connection method. Non-cache command admission retires the private prepared reuse context; disconnect, physical retirement and a new session invalidate physical ownership. Failed or uncertain SQL is never replayed. Cancellation control connections retain authentication, TLS, and transport policy but skip the default database, `autocommit=false`, user session initialization, and recursive control creation.

Profile IDs, names, grouping, and credential storage belong to the host. Select the driver through its factory, not a tag inside connection options. Top-level SQL-mode/charset/compression/connection-attribute switches, file-engine paths, and generic future-option bags are not exposed; use only the typed `session.sqlMode` option described above for SQL mode.

## Reading typed results

`columns[i]` describes `rows[rowIndex][i]`. SQL NULL is not the string `"NULL"`. BIGINT is `bigint`, DECIMAL and temporal fields remain strings, and binary values are `Uint8Array`; numbers are not a lossless replacement for BIGINT/DECIMAL. JSON cannot directly serialize `bigint`, so convert values deliberately for your own message format.

`mapMySqlRows(result, mapper)` projects a buffered native result without
coercion. The mapper receives the original positional row, the original columns
array and the zero-based row index. Duplicate column names remain distinguishable
by position, JSON text remains text, SQL NULL remains `null`, bytes remain
`Uint8Array`, and mapper exceptions propagate unchanged.

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

Check `result.truncated` / `truncationReason` before treating loaded rows as complete. `additionalResults` contains subsequent result sets; `affectedRows`, `lastInsertId` and `warningCount` describe execution. `affectedRows` remains the legacy number and can lose precision above the safe integer range; use optional `affectedRowsExact` when the server reported an OK-packet count and exactness matters. Portable streaming summaries leave `lastInsertId` absent when an EOF row terminator reports no identifier and preserve the value when an OK packet reports one. The native buffered result retains its historical zero defaults. Use session flags only when `statusKnown` / `sessionStatus.known` is true. Bound presentation separately; converting a whole result to a giant string defeats streaming. Historical MySQL `ColumnDef`/`ServerInfo` imports retain native subclasses; portable versions live in core.

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

Driver-owned cleanup preserves the primary error's kind, `nativeCode`/`code` and SQLSTATE alongside cleanup failures. A stream callback throwing a `Server`-kind error is not a consumed server rejection: its original cause is retained, and the connection fails closed rather than assuming the remaining response was consumed. Error category alone is not proof of synchronization.

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

A failing `onTruncation` hook still permits bounded fallback draining, but does not become a successful stream: the hook's original cause and any cancellation/cleanup failures are reported after draining. A fully synchronized drain can leave the connection reusable while the stream rejects; an incomplete drain fails closed.

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
| `statementTimeoutMs` | `0` | Validated legacy value only; it never activates `mysqlFeatures.deadlines` or starts a timer |

Byte accounting is a driver estimate, not total application heap size. Exhausted drain/transport budgets fail closed. `query()` is a bounded convenience collector, not an unlimited alternative.

## Transactions

Use a dedicated connection and transactional tables. MySQL DDL can implicitly
commit; the callback runner does not change server SQL semantics or replay
work. The example uses the optional native feature, an explicit isolation
option and the callback-scoped session.

<!-- arkts-example: transactions -->
```typescript
import {
  ArkDbError, ConnectionConfig, MySqlDriverFactory, MySqlSession,
  MySqlTransactionIsolation, MySqlTransactionOptions, requireMySqlFeatures
} from '@arkdb/mysql';

export class TransactionAndCloseFailure extends Error {
  transactionFailure: Object;
  closeFailure: Object;

  constructor(transactionFailure: Object, closeFailure: Object) {
    super('Transaction and connection close both failed.');
    this.transactionFailure = transactionFailure;
    this.closeFailure = closeFailure;
  }
}

export async function runTransaction(config: ConnectionConfig, password: string,
  trustedStatements: string[]): Promise<void> {
  const connectionConfig = config.clone();
  const errors = connectionConfig.validate();
  if (errors.length > 0) throw errors[0];
  const connection = new MySqlDriverFactory().createConnection(connectionConfig, password);
  let transactionFailure: Object | null = null;
  let closeFailure: Object | null = null;
  try {
    await connection.connect();
    const transactions = requireMySqlFeatures(connection).transactions;
    if (transactions === undefined) {
      throw ArkDbError.unsupported('Transaction callbacks are unavailable.');
    }
    const options = new MySqlTransactionOptions();
    options.isolation = MySqlTransactionIsolation.ReadCommitted;
    await transactions.run(options, async (session: MySqlSession): Promise<void> => {
      await session.savepoint('application_work');
      for (const sql of trustedStatements) await session.query(sql);
      await session.releaseSavepoint('application_work');
    });
  } catch (error) {
    transactionFailure = error as Object;
  }
  try { await connection.close(); } catch (error) { closeFailure = error as Object; }
  if (transactionFailure !== null && closeFailure !== null) {
    throw new TransactionAndCloseFailure(transactionFailure, closeFailure);
  }
  if (transactionFailure !== null) throw transactionFailure as Error;
  if (closeFailure !== null) throw closeFailure as Error;
}
```

The callback facade is invalid after `run` settles. Root savepoint methods and
the callback's scoped prepared/batch/transaction features are intentionally
unavailable. If a commit response is lost, rollback does not prove the commit
did not happen. A successful rollback also does not undo implicit DDL commits,
nontransactional-table writes or external side effects.

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

The optional `mysqlFeatures.deadlines` feature is the only statement interface
that starts cancellation timers. `MySqlDeadlineOptions.timeoutMs` defaults to
zero (disabled), `cancellationGraceMs` defaults to 2000, and `queryOptions`
retains the existing result budgets. On expiry, the feature keeps command
ownership until the original operation and every cancellation attempt registered
for that owned scope converge, including a later public `cancel()` after the
deadline's first request settles. The grace period remains active through all
recorded attempts. Timeout and grace budgets above the platform timer maximum
are scheduled in chunks no larger than `2147483647` ms and re-armed against one
monotonic absolute expiry, so the first chunk cannot expire the full budget. If
grace expires, the feature starts target transport abort before waiting for
control cleanup and permanently retires the connection. Any unknown attempt or
retirement forces final outcome `Unknown`, even when the original SQL consumed
an OK response, and its failure is retained. After abort and cancellation, one
bounded zero-delay event-loop turn collects prompt operation cleanup; a
genuinely unsettled operation is still observed but never blocks public
settlement forever. Closing an expired prepared handle remains idempotent and
need not add a separate `Protocol` cleanup.
`QueryOptions.statementTimeoutMs` is still validation-only and never arms this
timer.

The native `createExecutionController(controlConnection).cancel(connectionHandle)` helper is retained for callers explicitly managing their own control session and execution lifetime. Handles are opaque; never concatenate untrusted input into `KILL QUERY`. Control failures may leave a query running. Callers using this lower-level helper still own any host timer and forced cleanup; `Promise.race` alone does not cancel server execution. These live races remain unverified.

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

- **One connection, serialized operations.** The driver does not create a Worker, queue concurrent requests, or reconnect/replay SQL. Query/stream, ping, context and transaction commands reject overlap with a `Protocol` error. Await each operation; stream callbacks must not reenter the same connection, and the coarse `Ready` lifecycle state is not an ownership permit. Use one connection per Worker session. Live connection objects do not cross Worker messages.
- **Typed values.** Rows are arrays aligned with `columns`. SQL NULL is `null`; BIGINT is `bigint`; DECIMAL and temporal values remain strings; binary values are `Uint8Array`. Preserve these types when designing your own Worker DTOs.
- **Bounded results.** `query()` uses the bounded streaming implementation and exposes `truncated`, `truncationReason`, and `additionalResults`. It is not an unlimited collector.
- **Streaming.** `queryStream(sql, options, sink)` awaits each `QueryResultSink` callback. Set row/chunk/result/drain budgets in `QueryOptions`, handle truncation and unknown status explicitly, and avoid accumulating every chunk. Awaiting a sink does not pause socket delivery; the separate receive queue remains bounded and fails closed on overflow.
- **Timeouts.** `connectTimeoutMs` covers connection opening and root session reset. Only the optional `mysqlFeatures.deadlines` query/execute interface starts a statement-cancellation timer and owns its convergence/grace cleanup. It joins every cancellation attempt registered for the owned scope, including later public calls, and keeps grace active until the operation and all recorded attempts settle. Timeout and grace delays are chunked to at most `2147483647` ms and re-armed from monotonic absolute expiry. Any unknown attempt or retirement has priority over an original OK result and retains its failure; grace starts target abort before control cleanup, then allows one bounded event-loop turn for prompt unwind. The low-level driver still validates `QueryOptions.statementTimeoutMs` without activating it.
- **Transactions.** Generic features expose `begin`, `commit`, `rollback` and known session status. MySQL also retains native `setAutocommit` and the optional `mysqlFeatures.transactions` callback runner with typed options and scoped savepoints. The callback facade expires at settlement and does not expose root prepared/batch/nested transaction executors. Failure can invalidate status or leave an unknown execution outcome; never replay writes.
- **Cancellation.** The generic connection feature owns its MySQL control-session lifetime. The retained handle-based factory helper does not. Ownership is retained until required cancellation/close cleanup settles. Only the wire-query phase can be killed, not an interrupted-result end callback or an internal status-refresh ping. Status refresh waits for any pending control request and its cleanup; an unknown KILL outcome retires the target and keeps final execution outcome `Unknown`, even after an original OK response. Await the original query and request, then inspect reuse/status before another command.
- **Errors.** `ArkDbError` and `ArkDbErrorKind` expose common categories and server error code/SQLSTATE. No Workbench-name compatibility aliases are exported. Server messages can contain sensitive data; do not copy them into public logs.
- **Logging.** `Logger`, `LogSink`, and the five `ArkDB.*` subsystem tags describe driver activity only. Host UI, storage, and RPC logging stay outside the driver. File output remains an explicit opt-in convenience.

The factory also exposes capability flags and metadata/server-metrics providers. SQL is not portable between engines. MariaDB metrics are explicitly unsupported. Typed prepared binding is available through the optional MySQL feature above; text-query interpolation, pooling, a managed Worker client and PostgreSQL are not implemented. Never interpolate untrusted input into SQL.

## Verification limits

Local validation includes actual ArkTS compilation and the core/MySQL native contract suites, including deterministic protocol, cancellation and metrics fixtures. The exact-archive consumer gate restores one HAR with no core file, source override or available registry, then compiles the packaged examples and unsigned sample HAP. It separately restores test-only dependencies and executes offline lifecycle/error-identity cases. SDK-free fakes are separate tooling evidence, not substitutes for native checks. Candidate manifests and consumer records bind results to exact bytes and source fingerprints.

The historical published 1.0.1 verification remains recorded in [releasing](../docs/releasing.md), not as evidence for 1.0.2/core. A future release verifier must consume its exact single-HAR download and cannot fall back to local source or stale `dist`.

Network, certificate and crypto replacements used by local Hypium tests are not real-device tests. Local preparation, public GitHub download availability, OHPM registry availability, and actual device interoperability are separate states.

Before treating a release as production-ready, verify real MySQL TCP/TLS and certificate failures, authentication paths, streamed/truncated/multiple results, transactions, ordinary server errors, cancellation races, and connection reuse on the documented target devices. MariaDB requires its own compatibility evidence.

## License

Apache-2.0; see `LICENSE`. `README.OpenSource` contains the retained mysqljs/mysql and sidorares/node-mysql2 MIT licenses and immutable upstream revisions. This filename is included by the HarmonyOS HAR packager.
