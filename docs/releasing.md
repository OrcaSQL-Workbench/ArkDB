# Local HAR releases

**Build on the maintainer's existing development computer, then publish the verified HAR through GitHub Releases.** No permanent build server, self-hosted runner, cloud SDK download, or automatic tag-triggered HAR build is required. GitHub Actions continues to run SDK-free package/tool checks only.

ArkDB is independent of OrcaSQL Workbench. The initial supported release module is `mysql` / `@arkdb/mysql`, targeting HarmonyOS 6.1.1 / API 24, tablet and 2in1, as a bytecode HAR with normalized OHM URLs. PostgreSQL is not implemented. Real-device networking, TLS/authentication and cancellation evidence remain deferred, so the initial release is an **engineering preview**, not a production certification.

## Prerequisites and source identity

- Use Node.js >=22.19.0 and the installed compatible DevEco Studio / HarmonyOS API-24 toolchain. Explicit Hvigor/OHPM/SDK paths are supported as described in the [root README](../README.md).
- Select the driver/package version and changelog, review the public source and legal notices, then commit through the owner's approved workflow.
- Create a matching **annotated** local tag, for example `mysql-v1.0.0`, at that exact commit. The preparation command does not create tags, change versions or commit source.
- The checkout must remain clean. An uncommitted local candidate, or a HAR built before its source was committed, cannot become a release merely by changing its metadata.
- Have GitHub CLI `gh` installed and authenticated locally before actual publication. The publisher is scoped to the official `OrcaSQL-Workbench/ArkDB` repository and verifies both its origin and public remote identity. It does not use OHPM credentials or create GitHub tokens.

Commits, pushes, tag creation and publication each remain explicit owner-controlled actions. Running checks or implementing release tooling does not grant permission to perform them.

## Develop and check a candidate

```powershell
npm ci --ignore-scripts
npm run restore
npm run verify
```

This local-only gate runs tooling tests and package checks, builds the driver, runs local Hypium cases, clean-builds the release HAR, compiles its actual README examples and runnable sample, runs synthetic sample lifecycle tests, and invokes **OHPM `prepublish`**, which does not upload a package.

Hypium's generated `.test` workspace is refreshed to avoid stale normalized mock record IDs. The gate checks completed result records against the native summary, with no failures/errors/ignored cases. SDK case-name headers can be duplicated or interleaved; they are not completed verdicts. A green `BUILD SUCCESSFUL` alone is not a passed native suite.

`dist` holds candidate outputs and mutable local verification records. A `sourceClean:false` / `sourceCommit:null` candidate is useful for development, not a source release. Do not upload the entire directory: stale optional receipts may belong to a different archive.

The installed SDK currently accepts the retained `1.0.0` version without the warnings it emits for `0.x`; that number is not a stability certificate. Include nonempty package `README.md`, `CHANGELOG.md`, `LICENSE` and `README.OpenSource`. The last file preserves upstream MIT notices in a filename the HAR packager includes. Review any OHPM source-disclosure warning; it is not silently hidden by the tools.

## Prepare one sealed local release set

After the clean reviewed commit and matching annotated tag exist:

```powershell
npm run release:prepare -- --driver mysql --tag mysql-v1.0.0
```

Preparation validates the driver, package/tag version, annotated tag object and current clean source commit **before building**, runs the full local MySQL gate, then rechecks the source, tag, artifact and verification bindings. No Git reference or remote state is changed.

Output:

```text
dist\releases\mysql-v1.0.0\
  arkdb-mysql-1.0.0.har
  arkdb-mysql-1.0.0.har.sha256
  arkdb-mysql-1.0.0.manifest.json
  arkdb-mysql-1.0.0.consumer.json
  arkdb-mysql-1.0.0.readiness.json
  release-set.json
```

`release-set.json` binds repository, driver/module path, package/version, annotated tag object, source commit/fingerprint, API/platform, local validation counts and the five original asset digests/sizes. The publisher uploads it as the sixth asset. Local test/example records are not device, registry, or remote-download evidence.

Only these named, matching regular files are sealed. Extra `dist` files are ignored during preparation; extra files inside a sealed bundle invalidate it. Linked paths, stale receipts, missing assets, byte changes and source/tag changes fail explicitly.

An existing versioned destination is never silently overwritten. If an attempt was interrupted, inspect and deliberately move the old local attempt aside before rebuilding. This command does not delete prior work. Once sealed, do not run another build to replace the bytes for that release.

Future real drivers can reuse module discovery/packaging, but must provide their own complete validation/consumer adapter before release preparation succeeds. Choosing a nonexistent `pgsql` is an error, not an empty artifact.

## Publish the same bytes from this computer

First, the owner must explicitly authorize the source/tag push and public release. Push the reviewed commit and exact annotated tag using the approved Git workflow; the publication script never pushes or creates/moves remote tags.

With the matching remote tag present:

```powershell
npm run release:publish -- --driver mysql --tag mysql-v1.0.0 --confirm-publish
```

**This command performs remote writes.** `--confirm-publish` acknowledges authorization to create/upload and make the verified engineering preview publicly downloadable. Omitting it cannot publish.

The publisher:

1. Reads the immutable local bundle and rechecks the current clean source/tag, public repository, remote annotated tag, HAR declarations and legal/documentation bytes.
2. Creates an identical draft prerelease, never a stable/latest release. It adopts only a release with its exact sealed identity marker.
3. Uploads the original byte snapshots, without invoking a compiler, and verifies GitHub's returned asset size/digest and API identity. Drafts can have temporary `untagged-...` download URLs; those are accepted only for the same repository/asset while the release is still draft.
4. Checks the full asset set and source/tag again before publishing the prerelease.
5. Reads back public state/assets, requires their final version-tagged download URLs, and writes `dist\releases\mysql-v1.0.0.receipt.json`, containing actual Release/asset URLs, IDs and digests. A remaining temporary draft URL cannot enter a successful receipt.

The local preparation manifests continue to say `published:false`; they describe the original local preparation, not mutable remote state. The separate receipt describes the verified remote publication. Do not edit sealed files to flip status flags.

### Reruns and uncertain writes

An identical complete release can be verified/reused without remote writes. For a matching draft with partial uploads, only missing assets may be added. Any same-name asset with a different digest/size, unexpected asset, changed release marker, moved tag or source mismatch fails; the tool never uses clobber or deletes conflicting assets.

On a timeout or uncertain creation/upload/publication response, the tool reads live state once before deciding whether that write completed. If it cannot confirm the result, it stops and asks you to inspect the existing draft/release. Do not repeatedly publish blindly, rebuild the HAR to fit an existing version, or overwrite a conflicting asset. Existing identical local receipts can be reused; a conflicting local receipt is preserved.

The release scripts currently verify these contracts with synthetic GitHub responses. No actual public release is implied until the owner-authorized command has succeeded against GitHub and returned a real receipt.

## Verify the public download

After an actual GitHub prerelease exists:

```powershell
npm run release:verify-download -- --driver mysql --tag mysql-v1.0.0
```

The verifier reads the public release and immutable marker, checks its remote tag, downloads the exact allowlisted HAR/checksum/manifests/evidence, compares size and SHA-256, and installs the **downloaded** HAR into a fresh consumer workspace. It compiles the packaged README examples and sample HAP/Worker and runs synthetic sample lifecycle tests using the local toolchain. It never recompiles the driver or falls back to local `dist` or driver implementation source if the remote file is unavailable or wrong.

Download redirects are limited to GitHub's public asset hosts, are bounded by size/time, and receive no account credential headers. Signed CDN redirect parameters are not written into the public receipt. The result is stored as `dist\mysql-v1.0.0.download.json`, separately from the sealed bundle.

Before a public version exists this command must fail. A download/consumer pass still does not establish actual device networking/TLS or stable production readiness. The release archive identity remains immutable even if a newer local source checkout is used to run the consumer verifier.

For end users, the [build/download guide](building-drivers.md) explains ordinary checksum verification and `ohpm install <local.har>`. They do not run the maintainer scripts or need a publisher account.

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

With separate authorization, publish the **same sealed HAR**, initially under the `preview` distribution tag:

```powershell
node .\tools\run-ohpm.mjs publish `
  .\dist\releases\mysql-v1.0.0\arkdb-mysql-1.0.0.har `
  --tag preview --ensure_dependency_include --disallow_nested_package
```

Package versions cannot be casually replaced. Reconcile uncertain uploads or review states rather than blindly retrying. After availability in the public registry, `npm run verify:registry` verifies exact-version acquisition with an empty package cache and the sample; it is not the GitHub-download verifier.

## Deferred hosted automation

Historical [CLI acquisition research](hosted-toolchain.md) remains recorded, including a known local archive and HTTP 403 observations. It is outside the local-release critical path. No SDK downloader/mirror, self-hosted runner, cloud HAR-build workflow or tag-triggered publication has been introduced.
