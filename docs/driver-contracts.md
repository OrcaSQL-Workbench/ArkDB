# Shared driver contracts

## Status and ownership

This is the engineering-preview source architecture for `@arkdb/mysql` 1.0.2 with
`@arkdb/core` 1.0.0. The published `mysql-v1.0.1` preview remains a standalone HAR
from source commit `27d4095575ca56ff4f1b9d38221e610034f3a049`; its tag and bytes are
not changed by this migration. PostgreSQL is not implemented.

| Module | Owns |
| --- | --- |
| `core` / `@arkdb/core` | One runtime error identity, portable results and server information, minimal connections, optional capability interfaces, deadlines and HarmonyOS diagnostics |
| `mysql` / `@arkdb/mysql` | MySQL options/TLS posture, wire protocol, authentication, native columns/server information, SQL, context aliases, control-session cancellation, opt-in statement deadlines and vendor metrics |
| Driver-local `arkdb-package.json` | Tooling-only shared/driver classification and driver-owned verification declaration; not an OHPM schema extension |
| `tools` | Dependency discovery, source/import constraints and exact-archive verification/distribution |

The maintained source dependency direction is driver to core. Drivers import the
core public entry, not another driver's internals or a relative path into core
source. Core is maintained once, not copied into each driver's source tree.
Delivery stages core plus the selected driver as one temporary SDK module and
compiles one HAR; consumers do not install the development core package.

## Connection and creation interface

Core's `DbConnection` requires connect/query/close, lifecycle state and portable server
information. A query-only engine can implement it without fake transaction,
metadata, metrics, context, ping or streaming methods.

Optional `features` expose typed interfaces for streaming, health, context,
transactions, cancellation, metadata and metrics. An absent interface is
unsupported. Driver capability flags are discovery hints, default false, and do
not replace checking the connection's actual feature availability.

Core's `DbDriverFactory<TOptions, TConnection>` has `create(options)`. Options and
credentials are adapter-owned, not a common MySQL configuration or arbitrary
object/JSON bag. The MySQL request is `MySqlConnectionOptions(config, password)`;
it is transient and must not be serialized as a saved profile.

```typescript
import { DbDriverRegistry, ConnectionConfig, MySqlConnection, MySqlConnectionOptions, MySqlDriverFactory } from '@arkdb/mysql';

export function createSession(host: string, user: string, password: string): MySqlConnection {
  const registry = new DbDriverRegistry();
  const mysql = registry.register(new MySqlDriverFactory());
  const config = new ConnectionConfig();
  config.host = host;
  config.user = user;
  return mysql.create(new MySqlConnectionOptions(config, password));
}
```

The registry uses open string identifiers, rejects duplicates and returns the
typed factory handle. `describe(id)` is discovery only; it does not erase the
configuration type to offer unsafe arbitrary-engine construction.

MySQL retains `createConnection(config, password)` and
`createMySqlConnection(config, password)` as native convenience interfaces.
Its native provider and handle-based cancellation helpers remain available.
The established `@arkdb/mysql` names `DbConnection`, `DbDriverFactory`,
`DbExecutionController` and `MetadataProvider` are adapter-owned interfaces
compatible with 1.0.1, not replacements by their minimal/generic core counterparts.
Portable consumers use the distinct `CoreDbConnection`, `CoreDbDriverFactory`,
`CoreDbExecutionController` and `CoreMetadataProvider` exports from the same HAR.

MySQL-specific prepared statements use the separate optional
`mysqlFeatures.prepared` interface. `requireMySqlFeatures` reports a missing
container with the canonical `Unsupported` error; callers still check the
individual feature. The built-in factory advertises prepared support, but old
custom connections and capability literals need no new required members.
Typed input parameters, prepared interfaces and identifier/placeholder helpers
are exported by `@arkdb/mysql`, not core. The public facade resolves the existing
ready-only executor for each call instead of constructing or retaining a
physical-session executor while disconnected. Native prepared streams retain
native callback types; portable `features.streaming` remains text streaming.

MySQL's optional `mysqlFeatures.procedures` interface performs stored procedure
calls only through prepared binary execution. `MySqlProcedureArgument` and
`MySqlParameterDirection` model typed `In`, `Out` and `InOut` arguments using
the existing `MySqlParameter` value contract. Pure `Out` is normalized to a
typed NULL placeholder; `In` and `InOut` retain their input values. The driver
negotiates `CLIENT_PS_MULTI_RESULTS` when offered and identifies the single-row
OUT/INOUT result through `SERVER_PS_OUT_PARAMS` status on either the classic
metadata EOF or the deprecated-EOF row terminator. For classic OUT results, the
metadata EOF's `SERVER_MORE_RESULTS_EXISTS` remains the continuation signal when
the row EOF omits it. `MySqlProcedureResult.results` preserves ordinary results,
the marked OUT result and final OK in complete wire order; `outResultIndex`
identifies the marked entry and `outValues` preserves its declaration-ordered
values. Output validation is positional with strict count, type-family and
signedness checks; SQL NULL remains null. Text/byte validation shares the binary
decoder's classification: charset 63 and intrinsic BIT/GEOMETRY values are
byte-valued, while `FieldFlag.BINARY` alone does not change a nonbinary-charset
string into bytes. The marked OUT result must report exactly one known total row
and a nontruncated payload; row limits, cumulative byte limits or prior ordinary
truncation cannot be mistaken for successful output cardinality. There are no
session variables, text `CALL` fallbacks or positional guesses.

MySQL's optional `mysqlFeatures.insertRows` interface is a restricted prepared
multi-row INSERT builder, not a general SQL rewrite interface. It accepts a
one- or two-segment table identifier, individual column identifier segments and
typed `MySqlParameter` rows, then generates only quoted
`INSERT INTO ... VALUES` syntax with positional placeholders. It exposes no raw
SQL, expressions, suffixes, `INSERT IGNORE`, `REPLACE` or server-upsert clause.
`MySqlInsertRowsOptions` retains the batch item/result budgets and adds a
16777216-byte prepared-packet ceiling. Planning happens before dispatch and
greedily groups consecutive rows while both exact UTF-8 PREPARE payload bytes
and exact binary EXECUTE payload bytes fit that ceiling and the flattened
parameter count stays at or below 65535. Empty rows validate the request and
return without connection use.

Every emitted INSERT is one prepared statement and one native result under the
same command scope. `MySqlBatchError` reuses the existing partial-outcome
contract: completed statement results are retained, `failedIndex` points to the
first source row in the failed statement, and Unknown writes are not retried.
The interface can execute inside a caller-owned manual transaction and has an
explicit callback-scoped adapter that reuses the transaction runner's owner
without exposing root prepared, generic batch, named, procedure or nested
transaction executors. It never begins, commits or rolls back itself. Accepted
`COM_RESET_CONNECTION` invalidates its physical executor together with the
other prepared-generation state while preserving the stable optional feature
facade. Callback-scoped execution joins every transaction-owned cancellation
attempt after each emitted statement and before statement close or later group
dispatch. The transaction join counter makes final settlement idempotent.
Known cleanup failure is returned at the `insertRows` interface as a partial
`MySqlBatchError`; uncertain retirement retains any already decoded statement
result while preserving final `Unknown` and prohibiting replay.
The callback-scoped method returns the exact promise registered with the
transaction session. Pre-command snapshot failures are converted to one
observed rejected promise and returned unchanged, preserving exact error
identity for awaiting callers without leaking an unhandled rejection when a
caller ignores it.

MySQL also exposes the optional `mysqlFeatures.deadlines` interface for buffered
text queries and prepared execution. `MySqlDeadlineOptions` defaults to
`timeoutMs = 0` and `cancellationGraceMs = 2000`, clones its `QueryOptions`, and
keeps command ownership until execution and cancellation cleanup converge.
Every cancellation attempt registered for that owned scope is joined, including
later public cancellation after an earlier Requested attempt clears, and grace
remains active until the operation plus all recorded attempts settle. Any
unknown attempt or retirement forces final `Unknown` even after an original OK
response and retains its failure. Timeout and grace delays above the platform
timer range are split into chunks of at most `2147483647` ms and re-armed from
one monotonic absolute expiry. Grace expiry starts target abort before waiting
for control cleanup; after abort and cancellation, one zero-delay event-loop
turn boundedly observes prompt unwind without waiting forever. Expired prepared
close remains idempotent and does not add a synthetic `Protocol` failure. This
driver-local feature is the only statement interface that starts cancellation
timers; core `QueryOptions.statementTimeoutMs` remains validation-only.

The optional root `mysqlFeatures.session` interface exposes
`MySqlSessionController.reset()`. It uses `COM_RESET_CONNECTION`, shares the
connection's single command owner, and is unavailable from callback-scoped
transaction sessions. A successful reset advances the physical-session
generation, invalidates every explicit and cached prepared statement, restores
`utf8mb4`/`utf8mb4_general_ci`, the configured default database, autocommit and
session options, then verifies an owned session fingerprint before returning
with known status. The fingerprint must report `character_set_client=utf8mb4`
and either the exact configured database or no database when no default is
configured; a residual or mismatched database closes the physical connection.
An unsupported server reports the canonical
`Unsupported` error without falling back to `CHANGE_USER`, reconnecting or
replaying SQL. A timeout, malformed response or uncertain transport outcome
closes the physical connection instead of returning it for reuse. The feature
is additive: core and old custom MySQL connections acquire no required method.

MySQL also exposes the optional `mysqlFeatures.transactions`
`MySqlTransactionRunner`. It accepts `MySqlTransactionOptions`, owns one
connection command scope across setup, callback query/stream/savepoint commands
and commit/rollback, and returns a callback-scoped `MySqlSession`.

The base `MySqlSession` borrowing view retains read-only
feature/server/status properties and native query/stream methods. The
transaction callback intentionally extends that public interface with
`savepoint`, `rollbackTo` and `releaseSavepoint`. The facade expires when the
callback settles, and its feature view omits root prepared, batch and nested
transaction executors that cannot reuse the occupied scope. Root connection
savepoint methods reject instead of borrowing the callback owner.

Adding those required savepoint methods is an
intentional source-compatibility impact for existing `MySqlSession` implementers. It does not change core's
minimal connection or require custom `MySqlDbConnection` implementations to
provide the optional `mysqlFeatures.transactions` member. `MySqlSession` remains
neither a read-only SQL policy nor a pool lease.

## Semantics that must not become MySQL assumptions

Catalog and schema are independent fields. `DatabaseContextPolicy` reports
in-place, reconnect-required or unsupported changes for each. MySQL explicitly
declares catalog/schema aliases, accepts either, and rejects conflicting values.
Its metadata queries follow the same alias rule. An adapter with one catalog per
connection can require reconnecting for catalog changes while changing schemas
in place; it need not emulate `USE`.

Transactions expose begin/commit/rollback and session status. Configurable
autocommit is a MySQL convenience, not a required transaction interface.
`DatabaseSessionStatus.known` and result `statusKnown` must be explicitly true before
using session flags. Default or invalidated status is not evidence of autocommit
or transaction state. MySQL invalidates status after a failed command and can
refresh it with its health check.

The native transaction runner requires a Ready connection, known status, no
existing transaction and `autocommit=true`. Explicit isolation/read-only
characteristics precede `START TRANSACTION`; a consistent snapshot is a start
option. Successful callbacks commit. Callback failures roll back while the
target remains synchronized and Ready. DDL implicit commit is reported as
completed, unknown commit/cancellation outcomes remain Unknown, and
rollback/control cleanup failures remain attached to the original primary. The
callback scope settles cancellation/control cleanup before later child commands
or public completion, preventing stale cancellation from targeting a later
child.

Cancellation is connection-bound and targets only the execution current at the
call. `Requested` means a request was accepted, not that the query was interrupted.
Await the original operation as well. `ConnectionReuse` distinguishes not ready,
ready, awaiting completion, requiring synchronization and closed.

MySQL's generic cancellation feature owns a separate control connection,
waits for query dispatch, suppresses a stale request if the execution completed,
and blocks a subsequent command until the request settles. Closing waits for
control cleanup. The control operation uses the MySQL `connectTimeoutMs` budget,
does not select an initial database, and does not open an autocommit-disabled
control session. Control failures are surfaced, not converted to successful
cancellation. This is an adapter decision: another engine can send a protocol
cancel message without implementing a SQL control connection or `KILL QUERY`.
The old handle-based helper is lower-level and still leaves lifetime management
to its caller.

After an uncertain dispatched MySQL cancellation, the target is closed and
permanently retired, even if its original operation already completed; the
reported execution outcome remains `Unknown`. Closing the control socket alone
does not acknowledge the server-side `KILL`. At deadline grace expiry, target
abort begins before control cleanup. Deadline settlement joins all cancellation
attempts recorded for the owned scope; any unknown attempt is retained and keeps
the final result `Unknown`. A definite server rejection is distinguishable and
does not require retirement.

Portable `ServerInfo` has no engine enum, handshake version, connection number,
authentication plugin or capability bitmask. Portable `ColumnDef` has no wire
type number, flags or collation. Native details remain typed driver-owned
subclasses. Native type identifiers and logical value kinds are available to
generic callers. Scalars include boolean, bigint and lossless text/bytes; no
automatic conversion of exact decimals or structured values to JSON is required.
MySQL's public `mapMySqlRows` helper is a native positional projection: it passes
the original row, columns and row index to the caller without coercion, so
duplicate names remain distinguishable by position and mapper failures retain
their original identity.
Generated insert identifiers and warning counts are optional observations, not
invented zero values for an engine that did not report them. MySQL's native
result retains its established numeric warning and bigint insert-id fields. It
also retains the legacy numeric `affectedRows` while optionally exposing
`affectedRowsExact` directly from an OK packet; row results with no affected-count
observation leave the exact field undefined. Core result and stream types do not
acquire this MySQL-specific field.

`ArkDbError` has one owner inside a delivery, so its public entry and driver
implementation use the same constructor. Separately assembled standalone driver
HARs do not automatically share constructors; their coexistence is not established
by a single-driver build. A source composition includes core once for all selected
adapters. Native codes may
be numeric or textual in `nativeCode`, and SQLSTATE is independent. The numeric
`code` compatibility field is retained on the same error constructor. MySQL
preserves its numeric error codes and SQLSTATE. Unsupported operations use an explicit missing
feature or `Unsupported` error, never a success-shaped no-op.

Generic metrics are named gauge/counter measurements with units, exact values
and explicit availability. MySQL adapts its overview to that interface. InnoDB,
Performance Schema and replication-thread models remain MySQL extensions; a new
engine does not implement dummy InnoDB methods.

## Adding a driver

1. Add its real HAR implementation, typed creation options, public entry,
   package/legal/usage files and native contract suites. Depend on the exact
   `@arkdb/core` version; do not import `@arkdb/mysql`.
2. Register the build module in root `build-profile.json5` and add its own
   `arkdb-package.json`. Declare `kind: "driver"` and, for full verification, its
   consumer path, native module dependency closure and Internet requirement.
3. Register its typed factory in the consuming application's registry. No core
   engine enum or MySQL implementation change is needed.
4. Supply independent behavior tests for its supported optional features and its
   own consumer. A missing verification declaration fails explicitly before a
   release build; the MySQL sample is not evidence for another driver.

For example, a driver declaration has this shape; it does not create that driver:

```json
{
  "kind": "driver",
  "verification": {
    "consumer": "examples/new-driver-client",
    "nativeModules": ["core", "new_driver"],
    "requiresInternet": true
  }
}
```

The test-only in-memory catalog adapter under `core/src/test` accepts test
commands, preserves separate catalog/schema semantics, has no transaction or
metrics stubs, uses textual native error codes, and cancels without SQL control
connections. It is not a production PostgreSQL driver.

## Source and HAR dependency graph

`discoverDrivers` excludes shared HARs. Dependency closure is ordered before the
selected driver, rejects cycles, unregistered/version-mismatched dependencies
and shared-to-driver dependencies. Core changes affect dependent build plans and
source fingerprints without modifying those implementations.

The MySQL source manifest declares `@arkdb/core: "1.0.0"` and the development
project overrides it to local source. That is not the consumer dependency model.
The delivery workspace keeps the chosen package name and public entry, copies
each selected source package once, and rewrites only actual module specifiers
through an AST. The normal API24 SDK then generates bytecode and declarations
for that one module. No prebuilt HAR is patched or manually merged.

The emitted MySQL package has no core dependency. Its provenance manifest records
`sourceDependencies` and `embeddedPackages`, including exact versions and source
fingerprints. Source changes in core still invalidate dependent artifacts.
One-HAR release sets seal that artifact and its consumer/readiness evidence;
historical schema-1 standalone and schema-2 dependency-set records remain readable.
Download verification supplies only the sealed bytes, without source, stale
artifact or registry fallback. See [building drivers](building-drivers.md).

## Compatibility and verification limits

The generic core factory needs type arguments and uses `create(options)`;
the old MySQL `DbDriverFactory` remains non-generic with its provider helpers.
Core's minimal connection and optional features do not remove methods from the
native MySQL `DbConnection`. Core server/column types remain portable; MySQL
`ServerInfo`, `ColumnDef`, `QueryResult`, scalar values and stream callbacks retain
native types and defaults. Optional additions preserve existing data literals.
The numeric error field and one shared error constructor are retained, with
textual identifiers available through `nativeCode`.

Native streaming converts portable events at the adapter seam: MySQL callbacks
retain required warning/insert-id defaults, while `features.streaming` leaves
unreported identifiers absent. The `ServerMetricsProvider` alias remains
MySQL-specific. `ServerFamily.PostgreSQL` is a reserved compatibility value,
not a database implementation or a core engine enum. Consumer applications
must still restore and rebuild dependencies when replacing their HAR;
source compatibility is not a claim of binary interchangeability.

Validation is split by evidence type. Node regressions check registration,
dependency graphs and synthetic archive/release handling. Actual native suites
compile and exercise the shared adapter and MySQL protocol/lifecycle behavior.
The isolated consumer restores one exact HAR with an empty cache and unavailable
registry, compiles packaged examples and the sample HAP, then separately restores
test-only dependencies and checks driver-created error identity.
The compatibility consumer exercises the published factory/connection/provider
signatures, native scalar/column/stream types, numeric codes, defaults and old
data literals against the original 1.0.1 HAR and the new one-file candidate.
Native test launching first generates each HAR's current BuildProfile and refreshes the
registered source directory's unit cache; it does not depend on IDE leftovers.
Neither local mock networking nor these artifact checks establishes device
interoperability, PostgreSQL support or a three-HAR MySQL/PostgreSQL application.
Do not reuse published 1.0.1 evidence as evidence for this architecture.
