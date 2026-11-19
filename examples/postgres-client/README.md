# ArkDB PostgreSQL Example Application
Independent HarmonyOS 6.1.1 / API 24 Stage-model app using only self-contained `@arkdb/postgres` (`dependency\pgsql.har`), without `@arkdb/core` or repository source imports.

## Prepare
From the repo root run `npm ci --ignore-scripts`, `npm run restore`, `node tools/package-har.mjs --driver pgsql`, then `node tools/test-consumer.mjs --driver pgsql --prepare`; open in DevEco Studio for an API 24 tablet/2in1 target.

## Worker Sample And Verification
The Stage UI dispatches to a host-owned `ThreadWorker` via shared `@Sendable` DTOs. `SampleRunner` scrubs passwords before awaits, uses `PostgresSslMode.VERIFY_FULL` (optional sandbox CA PEM), optionally applies schema via `changeContext`, and streams one fixed read-only query (`SELECT version(), 9007199254740993::bigint, 12.34::numeric(10,2), NULL::text`) with bounded `QueryOptions`; execution/stop/close attempts are bounded, unresolved operations stay latched, and SQL is never replayed automatically.
`node tools/test-consumer.mjs --driver pgsql` compiles the HAR, Worker/HAP and README example and runs offline Hypium `PublicInterface.test.ets` + `SampleRunner.test.ets`. This verifies self-contained HAR packaging/contracts, not public OHPM acquisition or live physical-hardware certification.
