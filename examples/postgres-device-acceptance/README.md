# PostgreSQL device acceptance harness

This standalone HarmonyOS application contains the fixed PostgreSQL device
acceptance runner. The committed source is unbound: the run button is disabled
and cannot produce device evidence.

After preparing a sealed PostgreSQL release on its clean source commit, create
an isolated one-time challenge and bound unsigned HAP:

```powershell
npm run device:prepare -- --driver pgsql --bundle dist\pgsql-v1.0.0
```

The generated HAP contains a one-time private key and is sensitive until the
challenge is consumed and its workspace removed. Sign and install the exact
HAP without rebuilding, provision the authorized schema from the generated
record, and enter the signed HAP digest and operator evidence ID. The policy
requires PostgreSQL profiles P15–P18, matching reported server major versions,
SCRAM-SHA-256 and `verify_full` TLS. The operator must independently establish
that the target is PostgreSQL: its wire-reported version and this driver do not
attest the server family.

Verify the exported exact receipt and signed HAP with the matching sealed
manifest and consumer evidence:

```powershell
npm run device:verify -- `
  --receipt C:\Evidence\device-receipt.json `
  --manifest dist\pgsql-v1.0.0\arkdb-postgres-1.0.0.manifest.json `
  --consumer dist\pgsql-v1.0.0\arkdb-postgres-1.0.0.consumer.json `
  --hap C:\Evidence\entry-default-signed.hap `
  --profile P17 `
  --out C:\Evidence\device-verified.json
```

The application consumes a self-contained PostgreSQL HAR at
`dependency\postgres.har`. It uses a host-owned Worker, clears the password from
page state when starting or hiding, stops an active run when the page is hidden,
and publishes a receipt only after Worker shutdown is confirmed. Copying a
receipt writes its exact JSON to the local-device clipboard; clear the clipboard
after secure transfer.

An API-24 emulator is useful for application and Worker integration checks, but
is not physical-device acceptance evidence. The PostgreSQL 15–18 live matrix
and bound device acceptance remain separate release gates.
