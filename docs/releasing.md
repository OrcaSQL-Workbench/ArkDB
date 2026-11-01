# Local HAR releases

**Build on the maintainer's existing development computer, then publish the verified HAR through GitHub Releases.** No permanent build server, self-hosted runner, cloud SDK download, or automatic tag-triggered HAR build is required. GitHub Actions continues to run SDK-free package/tool checks only.

ArkDB is independent of OrcaSQL Workbench. The initial supported release module is `mysql` / `@arkdb/mysql`, targeting HarmonyOS 6.1.1 / API 24, tablet and 2in1, as a bytecode HAR with normalized OHM URLs. PostgreSQL is not implemented. Real-device networking, TLS/authentication and cancellation evidence remain deferred, so the initial release is an **engineering preview**, not a production certification.

**Current engineering-preview release source:** MySQL 1.0.2 depends on
core 1.0.0 in source and compiles both into one self-contained HAR. Local native tests and exact-archive consumer checks
are distinct from publication and real-device validation. Uncommitted local
candidates are not reviewed-source releases. The 1.0.1 evidence below is
historical and remains unchanged, not evidence for the split. Publication
commands use 1.0.2; do
not recreate the existing 1.0.1 tag/assets from new source.

## Published engineering preview

The first public HAR release is [mysql-v1.0.1](https://github.com/OrcaSQL-Workbench/ArkDB/releases/tag/mysql-v1.0.1), published on 2026-10-23. The earlier local `mysql-v1.0.0` candidate tag was not rewritten, pushed, or published.

| Identity / check | Recorded result |
| --- | --- |
| Source commit | `27d4095575ca56ff4f1b9d38221e610034f3a049` |
| Annotated tag object | `dfdf0952c9b22206cac5e1e84a6710c8752153ac` |
| HAR | [arkdb-mysql-1.0.1.har](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/arkdb-mysql-1.0.1.har), 114,127 bytes |
| HAR SHA-256 | `5bbf36425405392c4b18b3d11a8a891c8be765d9d9ef4f292e8a310863ae884e` |
| Sealed identities | [release-set.json](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/release-set.json) |
| Clean local preparation | 94 tooling cases, 183 local driver cases, eight packaged README modules, six local sample cases and OHPM prepublish passed |
| SDK-free hosted source checks | [Run 39882217929](https://github.com/OrcaSQL-Workbench/ArkDB/actions/runs/39882217929) succeeded at the release source commit |
| Actual public download acceptance | Downloaded all six real assets, verified their source/tag/digests, installed the remote HAR and compiled the independent sample/README examples; six local sample cases passed |
| Not established | OHPM registry publication and real-device networking/TLS/cancellation |

The real download verifier completed on 2026-10-23 at 01:14 UTC. Its receipt was originally `dist\mysql-v1.0.1.download.json` and is now preserved unchanged at `build\mysql-v1.0.1\evidence\mysql-v1.0.1.download.json`. The publication receipt is `build\mysql-v1.0.1\evidence\mysql-v1.0.1.publication.json`; the sealed six-file bundle is `dist\mysql-v1.0.1\`. The immutable Release's preparation records are not replaced by these later receipts. Folder organization does not move its tag or overwrite any asset.

## Prerequisites and source identity

- Use Node.js >=22.19.0 and the installed compatible DevEco Studio / HarmonyOS API-24 toolchain. Explicit Hvigor/OHPM/SDK paths are supported as described in the [root README](../README.md).
- Select the driver/package version and changelog, review the public source and legal notices, then commit through the owner's approved workflow.
- After separate approval, create the matching **annotated** local tag `mysql-v1.0.2` at that exact commit. Preparation never creates tags, changes versions or commits.
- The checkout must remain clean. An uncommitted local candidate, or a HAR built before its source was committed, cannot become a release merely by changing its metadata.
- Have GitHub CLI `gh` installed and authenticated locally before actual publication. The publisher is scoped to the official `OrcaSQL-Workbench/ArkDB` repository and verifies both its origin and public remote identity. It does not use OHPM credentials or create GitHub tokens.

Commits, pushes, tag creation and publication each remain explicit owner-controlled actions. Running checks or implementing release tooling does not grant permission to perform them.

## Develop and check a candidate

```powershell
npm ci --ignore-scripts
npm run restore
npm run verify -- --driver mysql
```

This local-only gate uses the selected driver's `arkdb-package.json` declaration:
tooling/package checks, the declared native module dependency suites, clean
release builds of one selected driver HAR with shared source included, the driver's own exact-archive
README/sample compilation and local lifecycle tests, and **OHPM `prepublish`**
for each archive. It does not upload. Local candidate checks do not authorize
source commits, tags, uploads or registry publication.

Each HAR's current BuildProfile is generated before unit compilation; an ignored IDE-generated profile is not a prerequisite. Hypium's generated `.test` workspace is refreshed at the registered module source path to avoid stale normalized mock record IDs. The gate checks completed result records against the native summary, with no failures/errors/ignored cases. SDK case-name headers can be duplicated or interleaved; they are not completed verdicts. A green `BUILD SUCCESSFUL` alone is not a passed native suite.

`build\<driver>-v<version>\` holds the current `-local.har`, checksum and manifest. Its `evidence\` contains matching verification records; `work\` contains owned temporary SDK projects that are removed after use. Historical outputs are retained under that version's `history\` and are never build fallbacks. `dist\<driver>-v<version>\` holds only the sealed ready bundle. A `sourceClean:false` / `sourceCommit:null` candidate is useful for development, not a source release.

`-local` is an artifact filename label, not a package prerelease version. The SDK manifest/HAR keeps numeric version `1.0.2`, and the import stays `@arkdb/mysql`. This corrects the earlier unreleased major-version candidate after preserving the published MySQL interface through adapter-owned contracts and distinct `Core...` exports. Only actual PR builds should use a PR-specific label; the local builder does not invent a PR number.

The earlier SDK accepted 1.0.1; neither that fact nor the next source version
certifies stability. Include nonempty README, changelog, license and
`README.OpenSource` in each package. MySQL retains its upstream MIT notices;
core has its own applicable notice. Review OHPM warnings rather than hiding
them.

## Prepare one sealed local release set

After the clean reviewed commit and matching annotated tag exist:

```powershell
npm run release:prepare -- --driver mysql --tag mysql-v1.0.2
```

Preparation validates the driver, package/tag version, annotated tag object and current clean source commit **before building**, runs the full local MySQL gate, then rechecks the source, tag, artifact and verification bindings. No Git reference or remote state is changed.

Intended next-version output after full authorized verification:

```text
dist\mysql-v1.0.2\
  arkdb-mysql-1.0.2.har
  arkdb-mysql-1.0.2.har.sha256
  arkdb-mysql-1.0.2.manifest.json
  arkdb-mysql-1.0.2.consumer.json
  arkdb-mysql-1.0.2.readiness.json
  release-set.json
```

The single-HAR release set binds the selected driver, embedded source packages,
exact source versions/fingerprints, reviewed public exports, annotated tag,
source commit, platform and asset digests/sizes. Consumer/readiness evidence
requires registry-independent runtime verification. Historical schema-1 standalone
and schema-2 dependency-set records remain readable; local records are not device,
registry-publication or remote-download evidence.

Only these named, matching regular files are sealed, collected from `build\<driver>-v<version>\` and its `evidence\`. Preparation removes `-local` from release filenames without changing HAR bytes, rewrites the checksum basename, marks the sealed manifest's `artifactChannel` as `release`, and normalizes any historical external-dependency filenames in manifests and evidence. The local records remain unchanged. The ready `dist` directory contains no loose test outputs or publication receipts. Extra files inside a sealed bundle invalidate it. Linked paths, stale receipts, missing assets, byte changes and source/tag changes fail explicitly.

An existing versioned destination is never silently overwritten. If an attempt was interrupted, inspect and deliberately move the old local attempt aside before rebuilding. This command does not delete prior work. Once sealed, do not run another build to replace the bytes for that release.

Future real drivers can reuse module discovery/packaging, but must provide their own complete validation/consumer adapter before release preparation succeeds. Choosing a nonexistent `pgsql` is an error, not an empty artifact.

## Publish the same bytes from this computer

First, the owner must explicitly authorize the source/tag push and public release. Push the reviewed commit and exact annotated tag using the approved Git workflow; the publication script never pushes or creates/moves remote tags.

With the matching remote tag present:

```powershell
npm run release:publish -- --driver mysql --tag mysql-v1.0.2 --confirm-publish
```

**This command performs remote writes.** `--confirm-publish` acknowledges authorization to create/upload and make the verified engineering preview publicly downloadable. Omitting it cannot publish.

The publisher:

1. Reads the immutable local bundle and rechecks the current clean source/tag, public repository, remote annotated tag, HAR declarations and legal/documentation bytes.
2. Creates an identical draft prerelease, never a stable/latest release. It adopts only a release with its exact sealed identity marker.
3. Uploads the original byte snapshots, without invoking a compiler, and verifies GitHub's returned asset size/digest and API identity. Drafts can have temporary `untagged-...` download URLs; those are accepted only for the same repository/asset while the release is still draft.
4. Checks the full asset set and source/tag again before publishing the prerelease.
5. Reads back public state/assets, requires final version-tagged URLs, and writes the selected version's receipt (for example `build\mysql-v1.0.2\evidence\mysql-v1.0.2.publication.json`). A temporary draft URL cannot enter a successful receipt.

The local preparation manifests continue to say `published:false`; they describe the original local preparation, not mutable remote state. The separate receipt describes the verified remote publication. Do not edit sealed files to flip status flags.

### Reruns and uncertain writes

An identical complete release can be verified/reused without remote writes. For a matching draft with partial uploads, only missing assets may be added. Any same-name asset with a different digest/size, unexpected asset, changed release marker, moved tag or source mismatch fails; the tool never uses clobber or deletes conflicting assets.

On a timeout or uncertain creation/upload/publication response, the tool reads live state once before deciding whether that write completed. If it cannot confirm the result, it stops and asks you to inspect the existing draft/release. Do not repeatedly publish blindly, rebuild the HAR to fit an existing version, or overwrite a conflicting asset. Existing identical local receipts can be reused; a conflicting local receipt is preserved.

Contract tests cover these paths with synthetic GitHub responses; the 1.0.1 publication and download acceptance above additionally exercised the real service. The first live upload returned HTTP 400 `Bad Content-Length` with no asset created. After inspecting the empty draft, upload resumed with the required byte length through the transport dependency seam, without changing the sealed source/tag/HAR. The normal GitHub CLI adapter now sets `Content-Length` from the exact stdin bytes and has a regression covering UTF-8 JSON and binary payloads.

## Verify the public download

After an actual GitHub prerelease exists:

```powershell
npm run release:verify-download -- --driver mysql --tag mysql-v1.0.1
```

The verifier reads the public release and immutable marker, checks its remote
tag and downloads the exact allowlisted bytes. New self-contained releases use
one HAR without a core file or override; historical schema-2 dependency sets
remain supported by their recorded exact archive graph. No source, stale local
artifact or registry fallback is allowed. The verifier compiles packaged examples
and the driver's own sample, then runs local tests. The 1.0.1 command above selects
that historical standalone release.

Download redirects are limited to GitHub's public asset hosts, bounded by size/time, and receive no account credential headers. Signed CDN parameters are not persisted. Results are stored at `build\<driver>-v<version>\evidence\<tag>.download.json`, with owned temporary workspaces under that version's `work\`, separately from sealed releases. The requested tag determines this version directory, not the current source version.

Before a public version exists this command must fail. A download/consumer pass still does not establish actual device networking/TLS or stable production readiness. The release archive identity remains immutable even if a newer local source checkout is used to run the consumer verifier.

For end users, the [build/download guide](building-drivers.md) explains ordinary checksum verification and `ohpm install <local.har>`. They do not run the maintainer scripts or need a publisher account.

## Capture post-seal device evidence

Device evidence is separate from the immutable release set. Do not rewrite
`release-set.json`, its `realDeviceVerified:false` preparation fact or any
published asset after a device run.

With the exact sealed bundle and matching source checkout:

```powershell
npm run device:prepare -- --driver mysql --bundle dist\mysql-v1.0.2
```

This requires clean `HEAD` at the sealed source commit, copies the sample and
exact sealed HAR into an isolated workspace, generates one Ed25519 key pair,
embeds the private key, and compiles an unsigned HAP. It records the HAP
SHA-256/size, removes the generated source/private key, and only then commits
the pending challenge. The retained work directory contains the HAP,
`receipt-context.json` and the `arkdb_device_acceptance` provisioning record.
The staging/work directory is restricted to the preparing account (plus
Windows SYSTEM/Administrators), because the HAP contains the one-time private
key until verification removes the workspace. Permission hardening is
fail-closed. Those retained files and their staging directory are synced before
the work directory is atomically published.
The canonical UTC issue/expiry timestamps are exactly 24 hours apart. The
challenge binds source, HAR, sample, release-set, fixed case manifest, platform,
HAP, nonce and public-key identities. It contains no database credential or
endpoint.

The external operator must then:

1. Use G02/G03-approved infrastructure to create the isolated challenge row and
   read-only account; administrator credentials never enter the sample.
2. Configure owner distribution/debug signing for the exact generated unsigned
   HAP without rebuilding it, then install it on a supported physical tablet or
   2in1.
3. Record an operator evidence ID for the build/sign/install record, hash the
   actual signed HAP, and enter that digest, the approved release profile,
   optional M4 feature keys and TLS-mismatch hostname; then run all fixed cases.
4. Use **Copy exact signed receipt JSON**, save that exact clipboard text as the
   receipt file, and clear the clipboard and transient credential material.
5. Verify it once:

```powershell
npm run device:verify -- `
  --receipt C:\Evidence\device-receipt.json `
  --manifest dist\mysql-v1.0.2\arkdb-mysql-1.0.2.manifest.json `
  --consumer dist\mysql-v1.0.2\arkdb-mysql-1.0.2.consumer.json `
  --hap C:\Evidence\entry-default-signed.hap `
  --profile M1 `
  --out C:\Evidence\device-verified.json
```

The verifier requires the exact Ed25519 signature and
release/source/HAR/sample/profile identities, recomputes the actual signed HAP
digest, and requires API/device class, verified TLS mode, negotiated auth
plugin, run timestamps, operator evidence ID, every ordered case ID/duration
and zero failed or ignored cases. It rejects extra receipt fields, so endpoint,
account, password, schema, CA path, result rows and raw errors cannot be
persisted. It atomically renames `pending` to `verifying`; the generated HAP
workspace must be removed before the state can be atomically renamed
`accepted` or `rejected`. Cleanup failure remains recoverable and a
record-write interruption can resume without creating conflicting terminal
states. The external result states that operator attestation is the trust
boundary and keeps hardware attestation, read-only privilege verification and
production certification false.

`--out` is canonicalized through existing parent directories and must remain
outside the secret challenge workspace, verifier state directory and sealed
release bundle; ancestor junction/symlink aliases cannot bypass those
boundaries. A fresh challenge requires an unused destination. Recovery accepts
an existing destination only when its exact bytes match the frozen claim.

All challenge, claim, evidence-record and terminal files are published through
a synced temporary sibling followed by an atomic filesystem operation; the
owning directory is synced where the platform supports it. The hard-link
publication path unlinks its temporary sibling and syncs the directory again.
On restart, linked siblings are removed only when inode and content match the
destination; typed replacement siblings complete the frozen replacement when
their content digest agrees, while conflicting siblings are rejected.
Preparation journals remove secret-bearing orphan workspaces left before
pending publication and preserve the matching workspace once pending has been
linked. A per-release process lock prevents an active preparation from being
mistaken for an orphan. Stale claim-lock recovery uses an exclusive recovery
owner/snapshot guard so only one process can replace a dead owner. A
receipt-bound exclusive
claim records the chosen verification/rejection timestamp, full canonical
record, receipt/payload/decision/record digests before cleanup. Concurrent
verification is rejected, a restart may continue only with that same receipt
and reuses the stored decision/time/record even after expiry, partial temporary
records are removed, and terminal state is trusted only after its exact
referenced record digest validates.

The generated HAP workspace is secret-bearing because it embeds the one-time
private key. Before evidence or terminal publication it is atomically renamed
to a tombstone, the parent directory is synced, the tombstone is recursively
removed, and the parent is synced again. Recovery completes known tombstones
before proceeding and never publishes accepted evidence while either the
workspace or a tombstone remains.

An accepted receipt's signature proves possession of the one-time key embedded
in the exact prepared harness; it is not hardware attestation. Operator
confirmations remain responsible for physical-device and schema authorization.
The evidence does not prove the account lacks write permissions, certify every
server patch or convert the engineering preview into production certification.
This source tree contains no captured device receipt and makes no live MySQL or
MariaDB acceptance claim.

The local Harmony unit runtime compiles the Ed25519 API but returns no signature
bytes. The signer treats that as unavailable and emits no receipt. G03 therefore
includes a physical-device Ed25519 proof for the exact generated HAP; this is a
runtime evidence gate, not permission to substitute a fake signature or weaken
the Node verifier.

## Optional later OHPM publication

OHPM is a separate distribution route, not a blocker for GitHub HAR downloads. Only after the owner elects to publish there:

1. Sign in to the [public OHPM registry](https://ohpm.openharmony.cn/) and complete its current eligibility requirements.
2. Confirm permission to publish in the `arkdb` group/scope. GitHub organization rights and a `NOTFOUND` package response do not establish OHPM scope rights.
3. Register a dedicated SSH **public** key and obtain its bound registry publish ID, following [official publication guidance](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-ohpm-publish). Never upload/paste the private key into this repository or chat.
4. Privately merge the owner's publish settings into `%USERPROFILE%\.ohpm\.ohpmrc`, not a project file; see [ohpmrc](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-ohpmrc).

```ini
publish_registry=https://ohpm.openharmony.cn/ohpm/
publish_id=<registry-issued-publish-id>
key_path=C:\Private\ArkDB\registry-private-key
```

These are placeholders, not credentials provisioned by ArkDB. No tool here generates keys, accepts account terms, grants rights or stores publisher credentials. Keep secret values out of command arguments/logs and source. Check the official supported key/passphrase requirements before generating a key.

Separate owner authorization is required to publish the selected sealed
self-contained HAR. There is no prerequisite public core package. Never replace
published bytes under the same version. An illustrative command for the
MySQL package, initially using `preview`, is:

```powershell
node .\tools\run-ohpm.mjs publish `
  .\dist\mysql-v1.0.2\arkdb-mysql-1.0.2.har `
  --tag preview --ensure_dependency_include --disallow_nested_package
```

Package versions cannot be casually replaced. Reconcile uncertain uploads or review states rather than blindly retrying. After availability in the public registry, `npm run verify:registry` verifies exact-version acquisition with an empty package cache and the sample; it is not the GitHub-download verifier.

## Deferred hosted automation

Historical [CLI acquisition research](hosted-toolchain.md) remains recorded, including a known local archive and HTTP 403 observations. It is outside the local-release critical path. No SDK downloader/mirror, self-hosted runner, cloud HAR-build workflow or tag-triggered publication has been introduced.
