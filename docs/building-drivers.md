# Build and consume a driver HAR

ArkDB distributes independent Harmony Archives, not the whole repository. A consumer downloads one driver's HAR and imports its package name; it does not install ArkDB's maintenance tools or copy an OrcaSQL module.

## Implemented drivers

The root `build-profile.json5` module registry and each module's `src/main/module.json5` are the source of truth. A registered module must actually exist and be a HAR. The package name/version come from that module's `oh-package.json5`.

```powershell
npm run drivers
```

The current repository lists only `mysql` / `@arkdb/mysql`. PostgreSQL is planned, not implemented. Selecting `pgsql` currently fails explicitly before compilation; a build matrix is not evidence of an implemented driver.

## Select a driver

With the documented HarmonyOS API-24 toolchain available:

```powershell
npm ci --ignore-scripts
npm run restore
npm run pack -- --driver mysql
```

`--driver` selects the registered build-module name, not an arbitrary filesystem path. Paths outside the checkout and linked source directories are rejected. The tool resolves that module's real directory, compiles only its release HAR, and compares the packaged declarations, manifest, legal files, and permissions with its source.

MySQL outputs:

```text
dist\
  arkdb-mysql-1.0.0.har
  arkdb-mysql-1.0.0.har.sha256
  arkdb-mysql-1.0.0.manifest.json
```

The manifest binds the selected driver, source directory, source fingerprint, artifact size, and SHA-256. A clean source build also records its Git commit; an uncommitted candidate has `sourceClean: false`, `sourceCommit: null`, and a separate `checkoutHead`, so an ambient Git HEAD is not presented as the artifact's reviewed source. The `.sha256` file permits checksum verification without interpreting the full manifest.

`npm run verify` is the full local MySQL gate: driver tests, release packaging, exact-archive sample/README compilation, synthetic sample lifecycle tests, and nonpublishing OHPM validation. It never publishes. Compile-only evidence remains distinct from local Previewer tests and real-device verification.

## Local module and directory selection

`--driver mysql` selects the `mysql` build-module registration and its actual source path. It is not an arbitrary directory argument and does not create a driver from a name. Existing changed-path planning helpers can identify affected registered drivers, but **no cloud HAR-build workflow is configured or required**.

The maintained delivery route is local preparation of a single selected driver, then authorized upload of the same bytes. An annotated tag such as `mysql-v1.0.0` must match its package version and the current clean source commit. Pushing that tag does not compile a HAR in Actions.

Package identity and directory identity need not be identical. For example, a future real module named `pgsql` could live under `drivers/pgsql` and publish a package named `@arkdb/postgres`; its artifact name would follow the package identity. There is no placeholder PostgreSQL package in this repository.

To add another driver, implement and register its actual HAR, public `Index.ets`, package/legal/usage files, local test registry, and its own release/consumer verification. Keep its implementation behind that public interface. Generic packaging is not a successful driver test, and MySQL's sample is not proof of PostgreSQL support.

## Prepare an official download

After reviewing/committing the source and creating the matching local annotated tag through the owner-approved Git workflow:

```powershell
npm run release:prepare -- --driver mysql --tag mysql-v1.0.0
```

Preparation requires clean source and runs the full MySQL local verification. It creates `dist\releases\mysql-v1.0.0\` containing an explicit allowlist of the HAR, checksum, manifest, matching consumer/readiness records, and `release-set.json`. It does not create or push the tag and performs no remote publication.

The `release-set.json` pins the annotated tag object, source commit, package identity, platform, exact asset digests/sizes, and actual local validation counts. No stale `dist` receipt, SDK, credential or unrelated HAP is admitted merely because it is present. Existing output is preserved and rejected rather than overwritten; inspect interrupted attempts before deliberately moving them aside.

With a matching remote tag already present and explicit owner release approval, the separate local publish command uploads only that sealed set:

```powershell
npm run release:publish -- --driver mysql --tag mysql-v1.0.0 --confirm-publish
```

It verifies an initially private draft's complete assets before making an engineering prerelease publicly downloadable. It does not rebuild. A completed identical release is reusable; a conflicting same-name asset is never replaced. See [releasing](releasing.md) for permissions, partial uploads and uncertain-write recovery.

## Install a downloaded HAR

Open the official [GitHub Releases page](https://github.com/OrcaSQL-Workbench/ArkDB/releases). The first public HAR release has not been published yet; a local build is not a public download. Once a release is available, download the HAR, its matching checksum and manifest from that same version. Verify the SHA-256 before importing it:

```powershell
Get-FileHash -Algorithm SHA256 .\arkdb-mysql-1.0.0.har
Get-Content .\arkdb-mysql-1.0.0.har.sha256
```

The hashes must match exactly. The artifact must also target the consumer's supported HarmonyOS SDK; the current package is an API-24 bytecode HAR using normalized OHM URLs.

From the consuming application's module directory, for example `entry`:

```powershell
ohpm install C:\Downloads\arkdb-mysql-1.0.0.har
```

Alternatively, keep a project-local `libs\arkdb-mysql-1.0.0.har` and declare its path relative to `entry\oh-package.json5`:

```json5
{
  "dependencies": {
    "@arkdb/mysql": "file:../libs/arkdb-mysql-1.0.0.har"
  }
}
```

Import only from `@arkdb/mysql`. Do not add ArkDB's source module to the application's module registry. The package's [usage guide](../mysql/README.md) covers Workers, permissions, TLS, typed results, streaming, transactions, and cancellation; the [sample](../examples/mysql-client/README.md) supplies a complete host application.

When upgrading, replace the dependency with a deliberately selected new HAR version, restore with OHPM, and rebuild the app. Do not mix an older checksum or manifest with a newly downloaded HAR.

Maintainers can verify the public download itself:

```powershell
npm run release:verify-download -- --driver mysql --tag mysql-v1.0.0
```

This reads the actual Release, downloads and checks the sealed assets, and builds/tests an independent MySQL sample against the downloaded HAR and its packaged README examples. A failed or mismatched download cannot fall back to local `dist` or driver source. The command needs the local sample/toolchain for verification, not driver-source compilation; ordinary users can install the HAR directly in their own projects.

Neither producing nor consuming a downloaded HAR requires an OHPM publisher account. Registry publication is a separate distribution route with separate ownership/credential requirements.
