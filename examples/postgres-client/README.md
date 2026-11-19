# ArkDB PostgreSQL Example Application

Independent HarmonyOS 6.1.1 / API 24 Stage-model application consuming `@arkdb/postgres` solely via `dependency\pgsql.har`, with no `@arkdb/core` dependency/override and no repository source imports.

## Prepare And Build From Repository Root

```powershell
npm ci --ignore-scripts
npm run restore
node tools/package-har.mjs --driver pgsql
node tools/test-consumer.mjs --driver pgsql --prepare
node tools/test-consumer.mjs --driver pgsql --example
```

`--prepare` copies the built HAR to `examples\postgres-client\dependency\pgsql.har` and runs `ohpm install` in `examples\postgres-client`, ready to open in DevEco Studio for an API 24 tablet/2in1 target.

## Runtime Behavior And Verification Boundary

- Host-owned `ThreadWorker` (`entry\src\main\ets\workers\postgres.worker.ets`) and `SampleRunner` (`entry\src\main\ets\sample\SampleRunner.ets`) paired with shared `@Sendable` DTOs (`Messages.ets`) and Stage UI (`pages\Index.ets`).
- Clears the UI password field on submit and scrubs `SampleRequest.password` before awaiting network I/O and on every Worker termination path.
- Enforces `PostgresSslMode.VERIFY_FULL` TLS (with optional sandbox CA PEM), applies optional `changeContext` schema, and streams one fixed read-only query (`SELECT version(), 9007199254740993::bigint, 12.34::numeric(10,2), NULL::text`) with bounded `QueryOptions` (`statementTimeoutMs = 15000`, `maxRows = 20`, `maxResultBytes = 16384`).
- Always closes the connection in `finally`, never replays SQL automatically, and bounds Worker stop/termination (`2000ms` grace timer on `Stop` or `aboutToDisappear`).
- `node tools/test-consumer.mjs --driver pgsql` runs offline Hypium `PublicInterface.test.ets` + `SampleRunner.test.ets` and verifies self-contained HAR compilation, `ohos.permission.INTERNET` HAP/Worker packaging, and contracts; it does not claim public OHPM acquisition or live physical-hardware certification.
