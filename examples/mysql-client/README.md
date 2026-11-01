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

## Bound device acceptance copy

The committed sample is deliberately unbound: **Run bound device acceptance** is
disabled and cannot emit a receipt. After a release has been sealed, a maintainer
can create one challenge:

```powershell
npm run device:prepare -- --driver mysql --bundle dist\mysql-v1.0.2
```

Preparation requires a clean checkout at the sealed source commit and the exact
sealed sample fingerprint. It creates an isolated sample, installs the exact
sealed HAR, generates a one-time Ed25519 key pair, embeds the private key only
in that sample, and compiles `entry-default-unsigned.hap`. It records the exact
HAP SHA-256/size, then removes the generated source and private key before
committing the pending challenge. The retained work directory contains only the
unsigned HAP, schema provisioning JSON and receipt-context JSON. The pending
challenge is written last; a failed preparation removes the staged outputs.

The challenge timestamps are canonical UTC values exactly 24 hours apart.
Neither timestamp may be extended or edited. Configure owner signing without
rebuilding the generated source, record the signed HAP path and SHA-256,
install those exact bytes, and enter that signed identity plus the release
profile and operator build/sign/install evidence ID in the bound page.

The fixed suite requires all of these cases:

| Case | Required observation |
| --- | --- |
| `tls_identity` | The authenticated connection reports active hostname-verified TLS |
| `tls_hostname_mismatch` | A separately approved hostname reaches the endpoint but fails specifically with a TLS identity error |
| `server_error` | The fixed missing-table query returns server code 1146 / SQLSTATE 42S02 |
| `eof_protocol` | A fixed text query succeeds through the server-negotiated legacy/deprecated EOF path |
| `binary_protocol` | A fixed prepared query uses explicit result casts and preserves UInt64, DECIMAL and binary bytes |
| `authorized_schema` | A typed prepared read returns the one-time value from `arkdb_device_acceptance` |
| `cancellation` | `SELECT SLEEP(10), 1` is requested, interrupted with a server error, awaited and followed by a successful ping |
| `cleanup` | Both positive and TLS-negative connections close without cleanup failure |

All four release profiles require the current transport/auth/protocol base
cases. M4 additionally requires an explicit product-feature selection; the
currently implemented selection is `--features sha256`, which also requires
the negotiated `caching_sha2_password` plugin. Other product feature keys fail
closed until their own mandatory device cases are implemented. The current
manifest accepts MySQL only; MariaDB remains experimental and requires a
separate future profile/evidence set rather than reusing MySQL acceptance.

The receipt envelope contains a canonical exact JSON payload and an Ed25519
signature. Its allowlisted payload binds profile/product feature keys, run ID,
clean source commit, sealed HAR SHA-256, sample fingerprint, actual
signed/installed HAP SHA-256, API/device class, server version, verified TLS
mode, negotiated authentication plugin, canonical run times, the operator
evidence ID, the immutable challenge issue/expiry window and ordered case
durations/verdicts. It never contains endpoint,
account, password, schema, CA path, challenge value, result rows or raw server
messages.
Use **Copy exact signed receipt JSON** to place the exact envelope on the local
clipboard for secure transfer to `device:verify`, then clear the clipboard. The
UI displays a receipt candidate, not an acceptance claim.

The signer constructs the message from the exact UTF-8 view using the buffer's
`byteOffset` and `length`; it never signs the entire pooled backing
`ArrayBuffer`. A deterministic multibyte test vector is verified by both the
ArkTS signer seam and Node verifier. The local Harmony unit runtime currently
returns an empty Ed25519 signature, which the app rejects. A signed
physical-device G03 run must produce the real 64-byte signature before this
workflow can yield a receipt.

After an operator has run the generated copy on a physical supported device
against the separately authorized isolated schema, verify the exported receipt:

```powershell
npm run device:verify -- `
  --receipt C:\Evidence\device-receipt.json `
  --manifest dist\mysql-v1.0.2\arkdb-mysql-1.0.2.manifest.json `
  --consumer dist\mysql-v1.0.2\arkdb-mysql-1.0.2.consumer.json `
  --hap C:\Evidence\entry-default-signed.hap `
  --profile M1 `
  --out C:\Evidence\device-verified.json
```

Verification checks the Ed25519 signature over the exact canonical payload
and rejects a receipt whose HAR/sample/profile or signed-HAP digest differs
from the separately supplied sealed files. It also runs
`hap-sign-tool.jar verify-app` (configure `DEVECO_HOME`, or
`HARMONYOS_JAVA` plus `HARMONYOS_HAP_SIGN_TOOL`) and records the verified
certificate-chain/profile digests. A signing-independent HAP content
fingerprint excludes only `META-INF/` signature metadata, so unrelated or
rebuilt application content cannot be endorsed as the prepared harness. The
challenge moves from `pending` to
`verifying`; cleanup must remove the one-time HAP workspace before the state is
atomically renamed `accepted` or `rejected`. A cleanup interruption leaves a
recoverable `verifying` state, while an accepted-state record-write interruption
can be resumed without creating an accepted/rejected ambiguity. Every manifest
case must appear once, in order, with `passed`; the aggregate must contain zero
failures, errors and ignored cases. Terminal challenges cannot be replayed.
The output binds `operatorEvidenceId` and records the operator-attestation trust
boundary explicitly, but does not infer direct physical-device or
authorized-schema attestation; it does not claim hardware remote attestation,
read-only privilege verification or production certification.

The local release evidence uses schema 3. It preserves the exact raw unsigned
HAP digest/size and also records a canonical content fingerprint that ignores
ZIP timestamps and entry order. Download verification compares canonical HAP
content, while the generated one-time device harness continues to bind its exact
raw HAP bytes and retains a signing-independent content identity for the later
owner-signed derivative.

## How it works

| File | Responsibility |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | Inputs and bounded output; one in-flight request; Worker error/exit handling |
| `entry/src/main/ets/workers/mysql.worker.ets` | Registered Worker entry, message dispatch, and shutdown |
| `entry/src/main/ets/sample/Messages.ets` | Flat `@Sendable` DTOs; no connection or UI objects cross threads |
| `entry/src/main/ets/sample/SampleRunner.ets` | Validate, connect, bounded stream, report typed errors, and close; accepts a factory for offline lifecycle tests |
| `entry/src/main/ets/sample/DeviceAcceptanceRunner.ets` | Execute the fixed bound cases and produce the privacy-safe receipt candidate |
| `entry/src/main/ets/sample/DeviceReceiptSigner.ets` | Sign the canonical payload with the generated Ed25519 key embedded in the one-time HAP |
| `entry/src/main/ets/sample/DeviceReceiptClipboard.ets` | Copy the exact signed envelope without reformatting it |
| `entry/src/main/ets/sample/DeviceEvidenceIdentity.ets` | Stable challenge identity contract shared by committed and generated harnesses |
| `entry/src/main/ets/sample/DeviceEvidenceBinding.ets` | Committed disabled values; generated copies replace only the release/challenge values |
| `device-acceptance-cases.json` | Canonical ordered case and runtime-profile manifest included in the sample fingerprint |
| `entry/src/test/SampleRunner.test.ets` | Driver-created error identity plus synthetic lifecycle, overlap, cleanup, redaction and exact-value checks without networking |
| `entry/src/test/DeviceAcceptanceRunner.test.ets` | Synthetic all-pass/failure/unbound receipt behavior; never a live device or server |
| `entry/src/test/DeviceReceiptClipboard.test.ets` | Exact clipboard transfer and invalid/unbounded export rejection |

Each button run has a dedicated Worker and connection; it is not a pool or a managed-client package. Overlapping operations are rejected. On page exit the host requests graceful closure, then uses bounded forced termination if needed. Forced termination is not server-side cancellation proof; the sample executes no writes.

INTERNET is declared in the source module; the native consumer gate checks the
merged output. For certificates and keys, the application owns
sandbox access and secret storage.

## Repository verification

`npm run test:consumer` copies this sample into a fresh directory,
supplies the one inspected HAR, compiles the driver's packaged README examples,
builds the HAP/Worker, and runs local sample lifecycle tests. Records bind
the driver digest, embedded source identity, sample fingerprint and compiled
unsigned HAP digest/size. This
native command is separate from the pure Node checks. It does not recompile
the driver.

The same compatibility tests are also run against the immutable 1.0.1 HAR.
They exercise the published non-generic factory, native connection/provider
assignments, scalar and streaming types, numeric errors, defaults and data
literals. Current portable interfaces use distinct `Core...` names; the MySQL
entry does not replace existing caller contracts with them.

The selected route is maintainer-local builds followed by a separately authorized GitHub Release upload; no SDK is installed in GitHub Actions and no permanent runner is needed. The candidate is `build\mysql-v1.0.2\arkdb-mysql-1.0.2-local.har`; the sample copies those bytes to its own `dependency\mysql.har` without changing the package identity. After publication, `npm run release:verify-download -- --driver mysql --tag mysql-v1.0.2` uses the actual downloaded HAR/README, never source or stale local artifacts. Evidence and temporary workspaces use `build\<driver>-v<version>\evidence` and `work`; `dist\<driver>-v<version>` holds sealed-ready bundles. See the [release procedure](../../docs/releasing.md).

After owner-authorized publication and any registry review, `npm run verify:registry` uses another clean workspace and an empty package cache to install the exact package version from the public registry. It rejects local overrides and records the resolved URL/integrity only after compilation and local sample tests succeed. This command cannot pass before the version exists; it is not run by the offline release-preparation gate.

Real-device networking, TLS, schema authorization and cancellation evidence
remain explicitly unverified in this repository. No captured receipt is included.
