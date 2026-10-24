# @arkdb/core - shared source

**Shared source architecture; not separately published.** This module is the single owner of ArkDB's
engine-neutral contracts, connection deadlines and HarmonyOS diagnostics. It is
not a database driver or a required user-installed package. Driver delivery
compiles this source into the selected driver's one self-contained HAR.

Database implementations import shared contracts from `@arkdb/core` in this
source workspace; consumers use the selected delivery HAR's public entry.
This module never imports a driver. Configuration, authentication,
SQL, wire fields and vendor metrics belong to their adapter.

`DbConnection` requires only connect/query/close, lifecycle state and portable
server information. Optional `features` expose streaming, health checks, context
changes, transactions, cancellation, metadata and metrics. Missing features are
unsupported, not successful no-ops. Capability flags default to false.

`DbDriverFactory<TOptions, TConnection>` owns a typed `create(options)` interface.
Each adapter defines its own options and credential shape. `DbDriverRegistry`
registers open string identifiers and returns the typed factory handle; discovery
returns descriptors, not an unsafe factory accepting arbitrary configuration.

Catalog and schema are independent. `DatabaseContextPolicy` distinguishes
in-place changes, reconnect requirements and unsupported changes. Transaction
methods do not require a configurable autocommit switch. Session flags are valid
only when `DatabaseSessionStatus.known` / result `statusKnown` is true.

Cancellation is bound to the connection's current execution. A `Requested`
outcome is not proof of interruption: await the original operation too. Reuse is
reported as not ready, ready, awaiting completion, requiring synchronization, or closed.
The contract does not require a second SQL connection.

Portable columns contain logical/native type identifiers and source names, not
wire flags. Native information can be a driver-owned subclass. Errors retain one
shared `ArkDbError` identity within a delivery. `nativeCode` preserves optional
numeric or textual identifiers; `code` remains an optional numeric compatibility
field, with SQLSTATE independent. Scalar values include booleans and lossless bigint/decimal
representations. Structured values without a portable scalar encoding remain
driver-documented text or bytes; no implicit JSON conversion is required.

The generic metrics interface returns named, typed measurements with explicit
availability. InnoDB and replication-thread details are not core contracts.

See [driver contracts](../docs/driver-contracts.md) for extension and migration
rules and [building drivers](../docs/building-drivers.md) for single-HAR delivery.
The test-only catalog adapter in `src/test` proves the intended interface shape;
it is neither PostgreSQL support nor a production implementation. Its native
contract suite is compiled and exercised locally. Exact HAR identity and
registry-independent consumption belong to the isolated consumer gate; device
behavior remains unverified. Separately built standalone driver HARs do not
automatically share runtime constructors; multi-driver coexistence is a separate gate.

The MySQL public entry preserves its 1.0.1 interface through adapter-owned native
types and distinct `Core...` exports for portable integrations. These adaptations
do not add required MySQL methods, configuration or wire fields to core.
