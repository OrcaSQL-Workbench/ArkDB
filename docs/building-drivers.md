# Build and consume a driver HAR

ArkDB distributes Harmony Archives, not the whole repository. **Both MySQL 1.0.1 and the MySQL 1.0.2 engineering-preview delivery use one HAR.** Core 1.0.0 is maintained separately in source and included in the selected driver artifact, not installed separately by users. Local native suites and the exact-archive consumer gate establish different evidence; neither certifies device interoperability or publication.

## Implemented drivers

Root `build-profile.json5`, each module's `module.json5`, and its tooling-only `arkdb-package.json` declare the source path, HAR type and shared/driver role. Package names, exact runtime dependencies and versions come from `oh-package.json5`. The source workspace uses a project-level OHPM override for local core source; the driver manifest retains a portable exact-version dependency.

```powershell
npm run drivers
```

The driver list contains only `mysql` / `@arkdb/mysql`; `core` / `@arkdb/core` is a shared dependency, not a driver. PostgreSQL is not implemented. Selecting `pgsql` or selecting `core` as a driver fails before compilation.

## Select a driver

With the documented HarmonyOS API-24 toolchain available:

```powershell
npm ci --ignore-scripts
npm run restore
npm run pack -- --driver mysql
```

`--driver` selects a registered driver, not a filesystem path. Outside/linked source paths, dependency cycles, shared-to-driver dependencies and missing/version-mismatched source dependencies are rejected. Packaging stages the selected source closure once inside one SDK module, then checks its bytecode HAR, internal declarations, merged legal notices and permissions against that plan.

The local next-version MySQL outputs are:

```text
build\mysql-v1.0.2\
  arkdb-mysql-1.0.2-local.har
  arkdb-mysql-1.0.2-local.har.sha256
  arkdb-mysql-1.0.2-local.manifest.json
  evidence\
    arkdb-mysql-1.0.2-local.consumer.json
    arkdb-mysql-1.0.2-local.readiness.json
  work\        # owned temporary delivery/consumer/download projects
  history\     # preserved older outputs, when present
```

The manifest binds package/source identity, size and SHA-256. `artifactChannel: "local"` labels a local candidate, even though the SDK compiles optimized release-mode bytecode. The `-local` suffix is only a filename label: `oh-package.json5` and the HAR retain numeric version `1.0.2`. One current candidate is written per version; fingerprints identify its source rather than timestamped filenames. `delivery: "self-contained"` distinguishes the new format; `sourceDependencies` and `embeddedPackages` retain the shared source graph while runtime `dependencies` and `dependencyArtifacts` are empty. Clean builds record their commit; uncommitted candidates have `sourceClean:false`, `sourceCommit:null` and `checkoutHead`, not a false reviewed-source claim.

`dist\<driver>-v<version>\` is the ready, sealed release area. Its HAR filenames have no `-local` suffix. Test records never appear as loose `dist` files. Download/publication receipts live under the matching tag's `build\<driver>-v<version>\evidence\`, even when the current source has another version. Older outputs are preserved under each version's `history\`, never selected as fallbacks. The historical layout migration's size/hash ledger remains at `build\mysql-v2.0.0\evidence\layout-migration.json`; that earlier candidate directory is not the current build target.

Interface compatibility determines release versioning, not the number of generated HARs. The MySQL public entry preserves the published 1.0.1 connection/factory names, native scalar/stream types and defaults; the portable core interfaces have distinct `Core...` export names. Current source uses the corrected 1.0.2 version. Local naming alone does not prove compatibility. The compatibility consumer is checked against both the original 1.0.1 HAR and the rebuilt candidate.

`npm run verify -- --driver mysql` is the local gate: SDK-free checks, declared core/MySQL source suites, single-HAR packaging, exact-archive sample/README compilation, local sample tests and nonpublishing OHPM checks. Runtime restoration is first proved with an unavailable registry and no test-only dependency; the public test framework is acquired separately afterward. Native suite launching generates current HAR BuildProfiles and uses registered source paths. Nothing is published.

The API24 pipeline deliberately uses standard compilation of one generated SDK module. Huawei's legacy `bundledDependencies` flag includes dependency code but leaves this graph's core dependency/public type imports; two isolated legacy variants still attempted to fetch core. The newer full declaration/dependency bundling documented for 26.0.0+ is not assumed available on the installed toolchain. Source assembly keeps the existing public package/import name without editing compiled archives or requiring a toolchain upgrade. See [Huawei's HAR build guide](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-hvigor-build-har).

## Local module and directory selection

`--driver mysql` selects the `mysql` build-module registration and its actual source path. It is not an arbitrary directory argument and does not create a driver from a name. Existing changed-path planning helpers can identify affected registered drivers, but **no cloud HAR-build workflow is configured or required**.

The delivery route prepares one selected driver with shared code inside its HAR, then separately authorizes upload of the same bytes. The next tag, `mysql-v1.0.2`, must match clean reviewed source. This source does not recreate, move or overwrite `mysql-v1.0.1`. Pushing a tag does not compile a HAR in Actions.

Package identity and directory identity need not be identical. For example, a future real module named `pgsql` could live under `drivers/pgsql` and publish a package named `@arkdb/postgres`; its artifact name would follow the package identity. There is no placeholder PostgreSQL package in this repository.

To add a driver, implement its HAR/public entry, package/legal/usage files and contract suites, depend on core, and add its build registration and `arkdb-package.json` declaration. Its own consumer path, native dependency modules and Internet requirement drive verification; no MySQL-specific tool branch or MySQL implementation edit is required. See [driver contracts](driver-contracts.md). Generic packaging and the MySQL sample are not proof of another driver.

## Prepare an official download

After reviewing/committing the source and creating the matching local annotated tag through the owner-approved Git workflow:

```powershell
npm run release:prepare -- --driver mysql --tag mysql-v1.0.2
```

After owner approval, preparation requires clean source and full declared verification. It creates `dist\mysql-v1.0.2\` with one HAR, checksum, provenance manifest, consumer/readiness evidence and `release-set.json`. The verified HAR bytes are unchanged when the local filename becomes canonical; checksum basenames, manifest filenames/channels and any legacy dependency-file references are normalized before sealing. Local metadata is left untouched. It does not create/push a tag or publish. Local uncommitted candidates are not eligible for this sealing step.

The `release-set.json` pins the annotated tag object, source commit, package identity, platform, exact asset digests/sizes, and actual local validation counts. No stale `dist` receipt, SDK, credential or unrelated HAP is admitted merely because it is present. Existing output is preserved and rejected rather than overwritten; inspect interrupted attempts before deliberately moving them aside.

With a matching remote tag already present and explicit owner release approval, the separate local publish command uploads only that sealed set:

```powershell
npm run release:publish -- --driver mysql --tag mysql-v1.0.2 --confirm-publish
```

It verifies an initially private draft's complete assets before making an engineering prerelease publicly downloadable. It does not rebuild. A completed identical release is reusable; a conflicting same-name asset is never replaced. See [releasing](releasing.md) for permissions, partial uploads and uncertain-write recovery.

## Install a downloaded HAR

The first downloadable engineering preview is [mysql-v1.0.1](https://github.com/OrcaSQL-Workbench/ArkDB/releases/tag/mysql-v1.0.1). Download its [HAR](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/arkdb-mysql-1.0.1.har), matching [checksum](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/arkdb-mysql-1.0.1.har.sha256), and [manifest](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/arkdb-mysql-1.0.1.manifest.json) from that same version. Verify the SHA-256 before importing it:

```powershell
Get-FileHash -Algorithm SHA256 .\arkdb-mysql-1.0.1.har
Get-Content .\arkdb-mysql-1.0.1.har.sha256
```

The hashes must match exactly. The artifact must also target the consumer's supported HarmonyOS SDK; the current package is an API-24 bytecode HAR using normalized OHM URLs.

For the immutable 1.0.1 HAR, the published SHA-256 is `5bbf36425405392c4b18b3d11a8a891c8be765d9d9ef4f292e8a310863ae884e` (114,127 bytes). Its source commit is `27d4095575ca56ff4f1b9d38221e610034f3a049`; later main-branch documentation/maintenance fixes do not replace those release bytes.

From the consuming application's module directory, for example `entry`:

```powershell
ohpm install C:\Downloads\arkdb-mysql-1.0.1.har
```

Alternatively, keep a project-local `libs\arkdb-mysql-1.0.1.har` and declare its path relative to `entry\oh-package.json5`:

```json5
{
  "dependencies": {
    "@arkdb/mysql": "file:../libs/arkdb-mysql-1.0.1.har"
  }
}
```

The filenames above apply to **published 1.0.1**. Its packaged guide describes that version; the current [source usage guide](../mysql/README.md) describes 1.0.2. Select the matching 1.0.2 archive/checksum/manifest from [GitHub Releases](https://github.com/OrcaSQL-Workbench/ArkDB/releases) when consuming that version. Both use one HAR. Do not add ArkDB source modules to the application's module registry.

## Consume a local 1.0.2 single-HAR candidate

Verify the candidate's checksum and put only `arkdb-mysql-1.0.2-local.har` under `MyApp\libs`. The module `entry\oh-package.json5` declares:

```json5
{
  "dependencies": {
    "@arkdb/mysql": "file:../libs/arkdb-mysql-1.0.2-local.har"
  }
}
```

No core file, dependency or project override is required. Import the driver and its re-exported shared contracts from `@arkdb/mysql`. The isolated gate checks registry-independent restoration, normalized OHM compilation and driver-created error identity; pure Node checks alone cannot establish those results. Device behavior remains separate.

When upgrading, replace the dependency with a deliberately selected new HAR version, restore with OHPM, and rebuild the app. Do not mix an older checksum or manifest with a newly downloaded HAR.

Maintainers can verify the public download itself:

```powershell
npm run release:verify-download -- --driver mysql --tag mysql-v1.0.2
```

After that version is published, this reads the actual Release, downloads and checks the sealed assets, and builds/tests an independent MySQL sample against the downloaded HAR and packaged examples. A failed or mismatched download cannot fall back to local artifacts or driver source. The command needs the matching source-version consumer/toolchain, not driver-source compilation. Ordinary users install the HAR directly in their own projects.

Neither producing nor consuming a downloaded HAR requires an OHPM publisher account. Registry publication is a separate distribution route with separate ownership/credential requirements.
