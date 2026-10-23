# Worker-based MySQL sample

This is a complete HarmonyOS Stage-model application, not a HAR masquerading as a demo. It consumes `@arkdb/mysql` from the inspected release archive, with no source import or OrcaSQL checkout.

## Prepare and run

From the ArkDB repository root:

```powershell
npm ci --ignore-scripts
npm run restore
npm run pack
npm run example:prepare
npm run example:build
```

`example:prepare` verifies the candidate, copies it into the ignored `dependency\mysql.har`, and restores this workspace's packages. The module depends on `file:../dependency/mysql.har`, relative to `entry`, not the repository's driver source. `example:build` produces `entry\build\default\outputs\default\entry-default-unsigned.hap`.

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
| `entry/src/test/SampleRunner.test.ets` | Synthetic lifecycle, overlap, cleanup, redaction, and exact-value checks without networking |

Each button run has a dedicated Worker and connection; it is not a pool or a managed-client package. Overlapping operations are rejected. On page exit the host requests graceful closure, then uses bounded forced termination if needed. Forced termination is not server-side cancellation proof; the sample executes no writes.

INTERNET is present in the application's merged module. For server certificates and optional client keys, a real application must own sandbox access and secret storage.

## Repository verification

`npm run test:consumer` copies only this sample workspace into a fresh temporary directory, supplies the exact inspected HAR, compiles the README examples packaged **inside that archive**, builds this HAP and Worker, and executes synthetic sample lifecycle tests. Its record is bound to the archive, its declared library source identity, and the example source fingerprint. It does not compile the driver's implementation.

The selected distribution route is maintainer-local builds followed by a separately authorized GitHub Release upload; no SDK is installed in GitHub Actions and no permanent runner is needed. After a public version exists, `npm run release:verify-download -- --driver mysql --tag mysql-v1.0.0` invokes the same independent consumer with the actual downloaded HAR/README, never a fallback from local `dist` or driver source. See the [release procedure](../../docs/releasing.md).

After owner-authorized publication and any registry review, `npm run verify:registry` uses another clean workspace and an empty package cache to install the exact package version from the public registry. It rejects local overrides and records the resolved URL/integrity only after compilation and local sample tests succeed. This command cannot pass before the version exists; it is not run by the offline release-preparation gate.

Real-device networking, TLS, and cancellation evidence remain explicitly unverified.
