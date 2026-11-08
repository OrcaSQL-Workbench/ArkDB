# @arkdb/postgres

A headless ArkTS PostgreSQL HAR for HarmonyOS 6.1.1 / API 24, tablet and
2in1.

**Source status:** The 1.0.0 package currently exposes its stable public
configuration, result, error, connection, and factory skeleton. Protocol,
transport, authentication, metadata, prepared execution, and transactions are
not implemented. Runtime operations reject with the shared
`ArkDbErrorKind.Unsupported`; capability flags remain false.

The package depends on `@arkdb/core` 1.1.0 in the source workspace. Driver
delivery will compile the selected source dependency closure into one
self-contained `@arkdb/postgres` HAR. Consumers do not install a separate core
HAR.

`PostgresConnectionConfig` defaults to port 5432, application name `arkdb`,
10-second connection timeout, and `PostgresSslMode.VERIFY_FULL`. Passwords are
passed separately through transient `PostgresConnectionOptions`.

The module is intentionally not registered in the root workspace until its
consumer and verification declaration are added.
