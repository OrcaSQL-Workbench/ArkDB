# ArkDB

Native ArkTS database drivers for HarmonyOS, distributed as headless Harmony Archives (HARs).

**MySQL is the first implementation.** PostgreSQL and a separate shared-core package are not implemented. ArkDB does not require OrcaSQL Workbench, Node.js, a WebView, or a native MySQL client at runtime.

| Package | Status | Platform |
| --- | --- | --- |
| [`@arkdb/mysql`](mysql/README.md) | Engineering-preview candidate; no public HAR release or OHPM publication yet | HarmonyOS 6.1.1 / API 24, tablet and 2in1 |

The current driver supports the MySQL text protocol, authentication, TCP/TLS, bounded streamed results, transactions, metadata, cancellation primitives, and server metrics. MariaDB is experimental. Prepared statements, parameter binding, pooling, and an automatically managed Worker are not implemented. Read the [usage and execution contract](mysql/README.md) before integrating it.

The [package guide](mysql/README.md) includes configuration defaults and examples for typed rows, errors, verified/custom-CA TLS, bounded streaming, transactions, cancellation, and providers. The [runnable example](examples/mysql-client/README.md) supplies a host-owned Worker and UI; it is not a new managed-client interface inside the driver.

## Download and use

Versioned HAR downloads are distributed through [GitHub Releases](https://github.com/OrcaSQL-Workbench/ArkDB/releases), independently of OHPM. **The first public download is not published yet.** When a reviewed release is available, download its HAR, matching `.har.sha256`, and manifest, verify the checksum, then install the HAR from the consuming application's module directory:

```powershell
ohpm install C:\Downloads\arkdb-mysql-1.0.1.har
```

Import from `@arkdb/mysql`, not internal source paths. Users need a compatible HarmonyOS project/toolchain to build their application, but do not need ArkDB's source, maintenance dependencies, or an OHPM publisher account. See the [download/install guide](docs/building-drivers.md).

## Build an individual driver

The [driver build/download guide](docs/building-drivers.md) explains module selection, versioned artifacts, checksum verification, and importing a downloaded HAR into an application.

```powershell
npm run drivers
npm run pack -- --driver mysql
```

The selector reads actual registered HAR modules and their source directories; it does not invent a PostgreSQL implementation. MySQL produces `dist\arkdb-mysql-1.0.1.har`, its `.sha256`, and a package/source manifest.

## Develop

Use Node.js >=22.19.0 and an installed DevEco Studio toolchain. The extraction baseline uses DevEco Studio 6.1.1.300 / HarmonyOS API 24. No SDK is downloaded or redistributed by this repository.

```powershell
npm ci --ignore-scripts
npm run restore
npm run verify
```

`DEVECO_HOME` defaults to `C:\Program Files\Huawei\DevEco Studio` on Windows. Set it for another installation; `DEVECO_SDK_HOME` can select an external SDK. `HARMONYOS_HVIGORW` and `HARMONYOS_OHPM` can select explicit tool executables.

| Command | Purpose |
| --- | --- |
| `npm run check` | Toolchain-free tooling tests and package/interface/import checks |
| `npm run drivers` | List implemented driver modules and their package/source identities |
| `npm run build` | Compile the standalone driver HAR |
| `npm run test:arkts` | Run the extracted Hypium suites, failing on assertion output as well as process errors |
| `npm run pack -- --driver mysql` | Compile one selected HAR and produce its versioned artifact, checksum, and source manifest |
| `npm run test:consumer` | Build the sample HAP/Worker and README examples against the exact HAR, then run offline sample lifecycle tests |
| `npm run example:prepare` | Install the verified HAR into the runnable Worker sample |
| `npm run example:build` | Compile its unsigned HAP for opening/running with owner-supplied debug signing |
| `npm run release:check` | Validate current archive/sample/guide evidence and run nonpublishing OHPM checks |
| `npm run verify:registry` | After publication, restore an exact registry version into a fresh sample and verify acquisition |
| `npm run verify` | Local tooling + driver tests + HAR packaging + sample/README tests + nonpublishing preflight; never publishes |
| `npm run release:prepare -- --driver mysql --tag mysql-v1.0.1` | Build and seal a local release bundle from clean source and an existing matching annotated tag |
| `npm run release:publish -- --driver mysql --tag mysql-v1.0.1 --confirm-publish` | After owner approval, upload the sealed bundle as a GitHub prerelease without rebuilding |
| `npm run release:verify-download -- --driver mysql --tag mysql-v1.0.1` | Download an actual published release and install/compile its HAR in an independent consumer |

**Release route: build locally, distribute through GitHub Releases.** Maintainers use their existing DevEco/CLI installation; there is no dedicated server, self-hosted runner, or SDK installation in GitHub Actions. A tag identifies the reviewed source version; it does not trigger HAR compilation. Hosted CI runs `check` only. The [official-toolchain investigation](docs/hosted-toolchain.md) is historical background, not a prerequisite for this local route.

Read the [release procedure](docs/releasing.md) before preparing or uploading a bundle. Preparation never commits, pushes, creates tags, or publishes. The separate publish command performs remote writes only with `--confirm-publish` after explicit owner authorization.

## Source and distribution

`mysql/Index.ets` is the supported import seam. The standalone interface uses `ArkDbError` / `ArkDbErrorKind` and connection options without saved-profile metadata or ignored future settings. Workbench compatibility aliases are not provided. Shared contracts remain inside the MySQL package until another working driver proves the shared interface.

The extraction origin and subsequent interface cleanup are recorded in [`docs/source-snapshot.json`](docs/source-snapshot.json); immutable upstream revisions and vectors are in [protocol test provenance](docs/protocol-test-provenance.md). Application code, signing machinery, saved credentials, operational evidence, generated dependencies, and private Git history are not part of this extraction.

See [release and verification requirements](docs/releasing.md) before publishing. Source availability and a local HAR are not registry publication, and local mocks do not establish live TLS or cancellation compatibility. OrcaSQL migration is intentionally outside this repository's extraction work.

## Repository layout

| Path | Owns |
| --- | --- |
| `mysql/` | The publishable HAR: public entry, implementation, package docs/legal files, and local test sources |
| `AppScope/`, `hvigor/`, root build files | Required metadata for the current HAR-only Hvigor workspace; no application UI or runtime |
| `docs/` | Release guidance and extraction/upstream provenance |
| `examples/mysql-client/` | A runnable Stage-model HAP/Worker sample consuming the actual HAR, with offline lifecycle tests |
| `tools/` | Maintainer-only launchers, checks, and packaging; not driver runtime dependencies |

`dist/`, `.hvigor/`, `mysql/build/`, `mysql/.test/`, generated `BuildProfile.ets` files, `node_modules/`, and `oh_modules/` are generated and ignored. Root npm dependencies support maintenance; the driver package has no third-party runtime package dependencies. Root and module build manifests have different roles: workspace orchestration versus HAR configuration.

## License

Apache-2.0; see [LICENSE](LICENSE). Adapted mysql/mysql2 code retains its [upstream MIT notices](mysql/README.OpenSource).
