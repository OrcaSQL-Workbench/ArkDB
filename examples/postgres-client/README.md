# ArkDB PostgreSQL consumer

Independent HarmonyOS exact-HAR consumer of `@arkdb/postgres` (`dependency\pgsql.har`), with no core dependency or repository-source imports. A host-owned `ThreadWorker` runs one fixed read-only streaming query using `VERIFY_FULL` TLS.

Offline local Hypium `PublicInterface.test.ets` and `SampleRunner.test.ets` cover consumer contracts and sample behavior. Consumer verification proves self-contained HAR compilation, packaging, and contracts without claiming live physical-hardware certification.
