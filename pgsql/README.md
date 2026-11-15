# @arkdb/postgres

A headless ArkTS PostgreSQL HAR for HarmonyOS 6.1.1 / API 24, tablet and
2in1.

**Source status:** The 1.0.0 package provides PostgreSQL 3.0 startup/TLS
connection lifecycle (`connect()`, `ping()`, `close()`), simple-query execution
and result streaming (`query()`, `queryStream()`), and parameterized
extended-query execution and `PortalSuspended` streaming via
`connection.postgresFeatures.prepared` (`execute()` and `queryStream()`, with
`supportsSsl`, `supportsMultipleResults`, `supportsStreamingResults`, and
`supportsPreparedStatements` enabled). Context changes, explicit transactions,
cancellation, metadata, server metrics, and statement deadlines are not yet
implemented and reject with `ArkDbErrorKind.Unsupported`.

The package depends on `@arkdb/core` 1.1.0 in the source workspace. Driver
delivery will compile the selected source dependency closure into one
self-contained `@arkdb/postgres` HAR. Consumers do not install a separate core
HAR.

`PostgresConnectionConfig` defaults to port 5432, application name `arkdb`,
10-second connection timeout, and `PostgresSslMode.VERIFY_FULL`. Passwords are
passed separately through transient `PostgresConnectionOptions`.

## Compile-only skeleton usage

The factory constructs an idle connection that can be closed offline; calling
querying, streaming, prepared execution, or health checks before `connect()`
rejects with `ArkDbErrorKind.Protocol`, while unimplemented context changes,
transactions, or cancellation reject with `ArkDbErrorKind.Unsupported`.

<!-- arkts-example: skeleton -->
```typescript
import {
  PostgresConnection, PostgresConnectionConfig, PostgresConnectionOptions,
  PostgresDriverFactory
} from '@arkdb/postgres';

export function createPostgresSkeleton(host: string, user: string,
  password: string): PostgresConnection {
  const config = new PostgresConnectionConfig();
  config.host = host;
  config.user = user;
  return new PostgresDriverFactory().create(
    new PostgresConnectionOptions(config, password));
}
```

The module is registered in the root workspace with an independent
`examples/postgres-client` consumer. That consumer verifies package compilation,
the shared `ArkDbError` identity and the canonical Unsupported result without
performing network I/O.
