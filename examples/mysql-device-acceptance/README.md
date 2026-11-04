# Bound MySQL device acceptance harness

This dedicated HarmonyOS application is tooling input for one-time,
release-bound device acceptance. It is not the ordinary
[`mysql-client`](../mysql-client/README.md) consumer and is not included in that
sample's fingerprint.

The committed harness is deliberately unbound. **Run bound device acceptance**
is disabled until a maintainer prepares a challenge from an exact sealed release:

```powershell
npm run device:prepare -- --driver mysql --bundle dist\mysql-v1.0.2
```

Preparation requires a clean checkout at the sealed source commit. It verifies
the ordinary consumer fingerprint from the release set, independently captures
this acceptance harness fingerprint, generates a one-time Ed25519 key pair,
injects both fingerprints and the challenge identity into an isolated copy,
installs the exact sealed HAR, and compiles `entry-default-unsigned.hap`.

The private key exists only in the generated source and the HAP compiled from
that source. Preparation records the exact HAP SHA-256/size, removes the
generated source copy, then publishes the pending challenge last. The retained
work directory contains only the unsigned HAP, schema provisioning JSON, and
receipt-context JSON. The retained unsigned HAP still contains the one-time
Ed25519 private key and remains sensitive until challenge consumption and
verification cleanup.

## Fixed acceptance suite

The challenge timestamps are canonical UTC values exactly 24 hours apart.
Neither timestamp may be extended or edited. Configure owner signing without
rebuilding the generated source, record the signed HAP path and SHA-256, install
those exact bytes, and enter the signed identity plus the release profile and
operator build/sign/install evidence ID in the generated app.

| Case | Required observation |
| --- | --- |
| `tls_identity` | The authenticated connection reports active hostname-verified TLS |
| `tls_hostname_mismatch` | A separately approved hostname fails specifically with a TLS identity error |
| `server_error` | The fixed missing-table query returns server code 1146 / SQLSTATE 42S02 |
| `eof_protocol` | A fixed text query succeeds through the negotiated EOF path |
| `binary_protocol` | A fixed prepared query preserves UInt64, DECIMAL, and binary bytes |
| `authorized_schema` | A typed prepared read returns the one-time schema challenge |
| `cancellation` | The fixed sleep query is interrupted, awaited, and followed by a successful ping |
| `cleanup` | Positive and TLS-negative connections close without cleanup failure |

M1, M2, and M3 require the transport/auth/protocol base cases. M4 additionally
requires an explicit product-feature selection; the implemented selection is
`--features sha256` with `caching_sha2_password`. Other feature keys fail closed.
The manifest accepts MySQL only; MariaDB requires separate future evidence.

## Receipt and verification

The canonical signed receipt payload uses schema 2 and binds:

- clean source commit and sealed HAR identity;
- the ordinary `mysql-client` `consumerFingerprint`;
- this harness's independent `acceptanceFingerprint`;
- actual signed/installed HAP SHA-256, runtime identity, release profile, and
  operator evidence ID;
- challenge issue/expiry times and every ordered case verdict.

It never includes endpoint, account, password, schema, CA path, challenge value,
result rows, or raw server messages. Use **Copy exact signed receipt JSON** for
secure transfer, then clear the clipboard. The UI displays a candidate, not an
acceptance claim.

Verify the exported receipt and actual signed HAP:

```powershell
npm run device:verify -- `
  --receipt C:\Evidence\device-receipt.json `
  --manifest dist\mysql-v1.0.2\arkdb-mysql-1.0.2.manifest.json `
  --consumer dist\mysql-v1.0.2\arkdb-mysql-1.0.2.consumer.json `
  --hap C:\Evidence\entry-default-signed.hap `
  --profile M1 `
  --out C:\Evidence\device-verified.json
```

Verification checks the Ed25519 signature, sealed manifest and ordinary consumer
evidence, both challenge fingerprints, selected profile, exact signed HAP, and
the signing certificate/profile evidence returned by `hap-sign-tool.jar
verify-app`. A signing-independent HAP content fingerprint excludes only
`META-INF/` signature metadata.

New pending, verifying, accepted, and rejected states use schema 2 and preserve
both fingerprints. The reader remains versioned: immutable schema-1 states and
receipts keep their original `sampleFingerprint` field and meaning, are
validated against their sealed release exactly, and are never rewritten as
schema 2.

The challenge moves from `pending` to `verifying`; cleanup removes the one-time
workspace before atomic `accepted` or `rejected` publication. Interrupted
cleanup and record publication remain recoverable. Terminal challenges cannot
be replayed.

## Source layout

| File | Responsibility |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | Bound acceptance inputs, verdict output, and exact receipt export |
| `entry/src/main/ets/workers/device.worker.ets` | Acceptance-only Worker request path and shutdown |
| `entry/src/main/ets/sample/Messages.ets` | Small acceptance `@Sendable` DTO contracts |
| `entry/src/main/ets/sample/DeviceAcceptanceManifest.ets` | ArkTS mirror of the canonical case manifest |
| `entry/src/main/ets/sample/DeviceAcceptanceRunner.ets` | Execute fixed cases and construct the privacy-safe schema-2 payload |
| `entry/src/main/ets/sample/DeviceEvidenceIdentity.ets` | Stable generated challenge binding contract |
| `entry/src/main/ets/sample/DeviceEvidenceBinding.ets` | Committed disabled binding replaced in the isolated copy |
| `entry/src/main/ets/sample/DeviceReceiptSigner.ets` | Sign the canonical payload with the one-time Ed25519 key |
| `entry/src/main/ets/sample/DeviceReceiptClipboard.ets` | Copy the exact signed envelope without reformatting |
| `device-acceptance-cases.json` | Canonical ordered cases and runtime profile included in the acceptance fingerprint |
| `entry/src/test/DeviceAcceptanceRunner.test.ets` | Synthetic fixed-case, failure, unbound, and privacy behavior |
| `entry/src/test/DeviceReceiptSigner.test.ets` | Exact UTF-8 view and Ed25519 vector behavior |
| `entry/src/test/DeviceReceiptClipboard.test.ets` | Exact transfer and bounded-input rejection |

The repository does not claim hardware remote attestation, direct read-only
privilege verification, or production certification. Physical-device,
authorized-schema, signing, install, and operator evidence remain explicit
trust boundaries.
