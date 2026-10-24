# Worker-based MySQL sample

This is a complete HarmonyOS Stage-model application, not a HAR masquerading as a demo. It consumes `@arkdb/mysql` from the inspected release archive, with no source import or OrcaSQL checkout.

**Current source consumes one self-contained MySQL 1.0.2 HAR, including core.**
The gate first proves runtime restoration with no core file, override or available
registry, compiles the HAP/Worker and packaged examples, then separately restores
the test framework and runs offline cases including driver-created error identity.
The standalone 1.0.1 release and its historical sample evidence remain unchanged;
use its matching source-version consumer when rechecking that older release.

## Prepare and run

From the ArkDB repository root:

```powershell
npm ci --ignore-scripts
npm run restore
npm run pack
npm run example:prepare
npm run example:build
```

`example:prepare` verifies the candidate, copies its exact bytes into ignored
`dependency\mysql.har`, and restores the workspace's packages. Module dependencies
are relative to `entry`; no separate core dependency or project override is needed.
`example:build` targets
`entry\build\default\outputs\default\entry-default-unsigned.hap`.

Open this directory in DevEco Studio 6.1.1 / API 24. Select a compatible tablet/2in1 device or emulator and configure your own local debug signing through the IDE. Do not commit signing material or generated signing configuration. The repository builds unsigned and does not install or claim a device run.

Enter an isolated server's hostname, port, account, and password. Optionally supply its default database and a sandbox-readable CA PEM path. Use the certificate's hostname. The sample always uses `VERIFY_IDENTITY`; it has no "ignore certificate errors" fallback. It does not select files or grant permission to arbitrary host paths.

Press **Connect, read, and close**. A fixed read-only query returns server version, exact BIGINT and DECIMAL examples, and NULL. Credentials are memory-only, the UI clears the password after submission, and the Worker drops the request's password reference after execution. This is not a promise that immutable strings can be securely erased from memory.

## How it works

| File | Responsibility |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | Inputs and bounded output; one in-flight request; Worker error/exit handling |
| `entry/src/main/ets/workers/mysql.worker.ets` | Registered Worker entry, message dispatch, and shutdown |
| `entry/src/main/ets/sample/Messages.ets` | Flat `@Sendable` DTOs; no connection or UI objects cross threads |
| `entry/src/main/ets/sample/SampleRunner.ets` | Validate, connect, bounded stream, report typed errors, and close; accepts a factory for offline lifecycle tests |
| `entry/src/test/SampleRunner.test.ets` | Driver-created error identity plus synthetic lifecycle, overlap, cleanup, redaction and exact-value checks without networking |

Each button run has a dedicated Worker and connection; it is not a pool or a managed-client package. Overlapping operations are rejected. On page exit the host requests graceful closure, then uses bounded forced termination if needed. Forced termination is not server-side cancellation proof; the sample executes no writes.

INTERNET is declared in the source module; the native consumer gate checks the
merged output. For certificates and keys, the application owns
sandbox access and secret storage.

## Repository verification

`npm run test:consumer` copies this sample into a fresh directory,
supplies the one inspected HAR, compiles the driver's packaged README examples,
builds the HAP/Worker, and runs local sample lifecycle tests. Records bind
the driver digest, embedded source identity and sample fingerprint. This
native command is separate from the pure Node checks. It does not recompile
the driver.

The same compatibility tests are also run against the immutable 1.0.1 HAR.
They exercise the published non-generic factory, native connection/provider
assignments, scalar and streaming types, numeric errors, defaults and data
literals. Current portable interfaces use distinct `Core...` names; the MySQL
entry does not replace existing caller contracts with them.

The selected route is maintainer-local builds followed by a separately authorized GitHub Release upload; no SDK is installed in GitHub Actions and no permanent runner is needed. The candidate is `build\mysql-v1.0.2\arkdb-mysql-1.0.2-local.har`; the sample copies those bytes to its own `dependency\mysql.har` without changing the package identity. After publication, `npm run release:verify-download -- --driver mysql --tag mysql-v1.0.2` uses the actual downloaded HAR/README, never source or stale local artifacts. Evidence and temporary workspaces use `build\<driver>-v<version>\evidence` and `work`; `dist\<driver>-v<version>` holds sealed-ready bundles. See the [release procedure](../../docs/releasing.md).

After owner-authorized publication and any registry review, `npm run verify:registry` uses another clean workspace and an empty package cache to install the exact package version from the public registry. It rejects local overrides and records the resolved URL/integrity only after compilation and local sample tests succeed. This command cannot pass before the version exists; it is not run by the offline release-preparation gate.

Real-device networking, TLS, and cancellation evidence remain explicitly unverified.
