# Changelog

## 1.0.0 - Unreleased

- Add the `@arkdb/postgres` driver and `pgsql` HAR module with embedded core.
- Implement PostgreSQL startup, authentication, TLS, simple and parameterized
  queries, streaming, transactions, schema context, cancellation and metadata.
- Add an independent exact-HAR consumer with a host-owned Worker.
- Server metrics and pooling are not implemented. Live compatibility and
  device validation remain separate from local verification.
