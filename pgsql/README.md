# @arkdb/postgres

Native ArkTS PostgreSQL driver source for HarmonyOS 6.1.1 / API 24, tablet
and 2in1. Version 1.0.0 is unreleased; a local HAR or passing local tests do
not establish publication, production readiness, live compatibility, or
physical-device certification.

The source implements PostgreSQL protocol 3.0 connection startup, TCP/TLS,
authentication, simple and parameterized queries, bounded streaming,
transactions, schema context, cancellation and catalog metadata. Server
metrics and pooling are not implemented. See [operational limits](#operational-limits)
before integrating.

## Packaging and execution

The `pgsql` build selector produces one self-contained `@arkdb/postgres` HAR
with core 1.1.0 embedded; consumers do not install a separate core HAR.
Build and verify a local candidate with:

```powershell
npm run pack -- --driver pgsql
npm run test:consumer -- --driver pgsql
```

The candidate is `build\pgsql-v1.0.0\arkdb-postgres-1.0.0-local.har`.
Install the selected HAR in the application and import from
`@arkdb/postgres`. The host must declare `ohos.permission.INTERNET` and own
its Worker and lifecycle; the driver does not create or manage a Worker.
The [independent sample](../examples/postgres-client/README.md) compiles
against the exact HAR and uses a host-owned Worker. The dedicated
[dual-HAR consumer](../examples/dual-har-client/README.md) compiles the exact
local MySQL and PostgreSQL HARs together, runs deterministic offline
package-identity tests, and provides a dual-Worker isolation harness. The
standalone [device acceptance harness](../examples/postgres-device-acceptance/README.md)
defines the release-bound PostgreSQL acceptance suite.
Each HAR embeds its own core constructors, so constructor identity is
package-local; offline checks do not establish live server or physical-device compatibility.

## Connect and query

Use a server name matching its certificate. `VERIFY_FULL` is the default;
set `caCertPath` to a trusted CA PEM path when needed. The options carry the
password separately, and the connection snapshots the configuration. If
`database` is omitted or empty, it defaults to the user name.

<!-- arkts-example: connect-query -->
```typescript
import {
  PostgresConnectionConfig, PostgresConnectionOptions, PostgresDriverFactory,
  PostgresQueryResult, PostgresSslMode
} from '@arkdb/postgres';

export class QueryAndCloseFailure extends Error {
  operationFailure: Object;
  closeFailure: Object;
  constructor(operationFailure: Object, closeFailure: Object) {
    super('Query and connection cleanup both failed.');
    this.operationFailure = operationFailure;
    this.closeFailure = closeFailure;
  }
}

export async function readVersion(host: string, user: string, password: string,
  database: string, caPath: string): Promise<PostgresQueryResult> {
  const config = new PostgresConnectionConfig();
  config.host = host;
  config.user = user;
  config.database = database;
  config.ssl.mode = PostgresSslMode.VERIFY_FULL;
  if (caPath.length > 0) config.ssl.caCertPath = caPath;
  const errors = config.validate();
  if (errors.length > 0) throw errors[0];
  const connection = new PostgresDriverFactory().create(
    new PostgresConnectionOptions(config, password));
  let result: PostgresQueryResult | null = null;
  let operationFailure: Object | null = null;
  let closeFailure: Object | null = null;
  try {
    await connection.connect();
    result = await connection.query('SELECT version()');
  } catch (error) {
    operationFailure = error as Object;
  }
  try { await connection.close(); } catch (error) { closeFailure = error as Object; }
  if (operationFailure !== null && closeFailure !== null) {
    throw new QueryAndCloseFailure(operationFailure, closeFailure);
  }
  if (operationFailure !== null) throw operationFailure as Error;
  if (closeFailure !== null) throw closeFailure as Error;
  if (result === null) throw new Error('Query completed without a result.');
  return result;
}
```

`query()` accepts SQL text, not parameters. Use prepared execution for
untrusted values; placeholders are `$1`, `$2`, etc. Identifiers cannot be
bound as values: use `quotePostgresIdentifier()` for identifier components.

<!-- arkts-example: prepared-stream -->
```typescript
import {
  ArkDbError, PostgresConnection, PostgresParameter, PostgresParameterType,
  QueryExecutionSummary, QueryOptions, QueryResultSink
} from '@arkdb/postgres';

export async function streamById(connection: PostgresConnection, id: number,
  sink: QueryResultSink): Promise<QueryExecutionSummary> {
  const prepared = connection.postgresFeatures.prepared;
  if (prepared === undefined) throw ArkDbError.unsupported('Prepared execution unavailable.');
  const options = new QueryOptions();
  options.maxRows = 100;
  options.maxChunkRows = 20;
  options.maxChunkBytes = 64 * 1024;
  options.maxResultBytes = 1024 * 1024;
  options.statementTimeoutMs = 15000;
  return prepared.queryStream('SELECT $1::int4 AS id',
    [new PostgresParameter(PostgresParameterType.Int4, id)], options, sink);
}
```

The caller supplies a sink and owns connection setup and cleanup. Sink callbacks
are awaited; avoid retaining unbounded rows. Inspect truncation and execution
summaries rather than assuming all rows were delivered.

## Transactions

The scoped runner commits on success and rolls back on failure. Use the
provided session inside the callback, and do not retain it after the callback.
The caller remains responsible for closing the connection.

<!-- arkts-example: transaction -->
```typescript
import {
  ArkDbError, PostgresConnection, PostgresSession, PostgresTransactionOptions
} from '@arkdb/postgres';

export async function runReadOnly(connection: PostgresConnection): Promise<void> {
  const transactions = connection.postgresFeatures.transactions;
  if (transactions === undefined) throw ArkDbError.unsupported('Transactions unavailable.');
  const options = new PostgresTransactionOptions();
  options.readOnly = true;
  await transactions.run<void>(options, async (session: PostgresSession): Promise<void> => {
    await session.query('SELECT 1');
  });
}
```

## Operational limits

- TLS defaults to `VERIFY_FULL`, verifying the certificate chain and hostname.
  `VERIFY_CA` verifies the chain without hostname verification; `REQUIRED`
  encrypts without authenticating the server; `DISABLED` is plaintext. There
  is no silent TLS downgrade. Client certificate and key must be supplied
  together. TCP/TLS and certificate-file failures preserve platform codes in
  `nativeCode` (and `code` when numeric); peer hostname mismatches set
  `nativeCode` to `'TLS_HOSTNAME_MISMATCH'`. Cleartext-password authentication
  requires explicit opt-in and active `VERIFY_FULL` TLS; use trusted
  credentials and avoid logging them.
- Simple query and prepared execution return PostgreSQL-native results and
  columns. `int8` values are `bigint`, `numeric` and temporal values remain
  text, and `bytea` is bytes. Multiple simple-query results appear in
  `additionalResults`. Query columns do not automatically include enriched
  catalog metadata.
- A connection serializes command ownership; do not overlap queries. Simple
  streaming drains remaining server messages after truncation within configured
  limits; prepared streaming may close its portal early. Early portal close
  limits delivered rows, not server-side DML effects. Unknown synchronization
  retires the connection rather than making it reusable.
- `cancel()` dispatches a separate PostgreSQL CancelRequest; dispatch alone
  does not prove that the server interrupted the original operation. Await the
  original operation and inspect its error and connection state. A nonzero
  `statementTimeoutMs` applies to streaming and prepared execution, not
  `query()`; timeout and cancellation can leave an unknown outcome.
- `changeContext()` changes schema search path; changing databases requires a
  new connection. Metadata covers catalogs, schemas, tables/views, columns,
  routines, triggers, indexes and foreign keys, subject to server privileges;
  events and server metrics are unsupported.
- Local mock tests and exact-HAR compilation do not establish PostgreSQL
  version compatibility, live TLS/cancellation behavior, signed-device
  validation, or physical hardware certification.
