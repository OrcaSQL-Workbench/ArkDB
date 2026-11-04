# Worker-based MySQL sample

This HarmonyOS Stage-model application is the ordinary `@arkdb/mysql` release
consumer. It installs the inspected self-contained HAR, compiles the HAP and
Worker, runs offline lifecycle tests, and consumes the published interfaces
without importing repository source.

Device acceptance is intentionally separate. The one-time release-bound UI,
Worker path, manifest, binding, signer, clipboard exporter, and acceptance tests
live in [`../mysql-device-acceptance`](../mysql-device-acceptance/README.md).
Changes to that harness do not change this sample's release-consumer fingerprint.

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
`dependency\mysql.har`, and restores this workspace. `example:build` targets
`entry\build\default\outputs\default\entry-default-unsigned.hap`.

Open this directory in DevEco Studio 6.1.1 / API 24. Select a compatible
tablet/2in1 target and configure local debug signing through the IDE. Do not
commit signing material or generated signing configuration.

Enter an isolated server hostname, port, account, and password. Optionally supply
a default database and sandbox-readable CA PEM path. Press **Connect, read, and
close**. The fixed read-only query returns server version, exact BIGINT and
DECIMAL examples, and SQL NULL through a bounded stream. TLS always uses
`VERIFY_IDENTITY`; there is no certificate-error bypass.

Credentials remain in memory, the page clears the password after dispatch, and
the Worker clears its request reference after execution. Each run owns one
connection, rejects overlap, and closes the connection in `finally`. Page exit
requests graceful Worker shutdown before bounded forced termination.

## Source layout

| File | Responsibility |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | Connection inputs, bounded output, and one in-flight Worker request |
| `entry/src/main/ets/workers/mysql.worker.ets` | Ordinary read request dispatch and shutdown |
| `entry/src/main/ets/sample/Messages.ets` | Small `@Sendable` request/response DTOs |
| `entry/src/main/ets/sample/SampleRunner.ets` | Validate, connect, execute the bounded stream, report typed errors, and close |
| `entry/src/test/SampleRunner.test.ets` | Offline lifecycle, overlap, cleanup, redaction, and exact-value behavior |
| `entry/src/test/LegacyPublicInterface.test.ets` | R00A-compatible published interface consumption |
| `entry/src/test/PreparedPublicInterface.test.ets` | Current additive MySQL public interface consumption |

## Repository verification

`npm run test:consumer -- --driver mysql` copies only this ordinary sample into a
fresh workspace, supplies the inspected HAR, compiles packaged README examples,
builds the HAP/Worker, and runs its local Hypium suites. Consumer evidence keeps
the existing `sampleFingerprint` field for this ordinary `mysql-client` source.
The acceptance harness has a separate tooling fingerprint used only by device
evidence preparation and verification.

The same compatibility tests also cover the immutable 1.0.1 HAR. Current
portable interfaces use distinct `Core...` names; the MySQL package does not
replace its historical public contracts.
