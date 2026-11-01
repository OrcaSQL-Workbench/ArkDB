# ArkDB

Native ArkTS database drivers for HarmonyOS, distributed as headless Harmony Archives (HARs).

**MySQL is the only database implementation.** MySQL 1.0.2 engineering-preview source uses core 1.0.0 internally, but its delivery is **one self-contained `@arkdb/mysql` HAR**. Users do not install core separately. PostgreSQL is not implemented. ArkDB does not require OrcaSQL Workbench, Node.js, a WebView, or a native MySQL client at runtime.

| Package | Status | Platform |
| --- | --- | --- |
| [`@arkdb/mysql`](mysql/README.md) | [1.0.1 engineering preview](https://github.com/OrcaSQL-Workbench/ArkDB/releases/tag/mysql-v1.0.1); downloadable HAR, not published to OHPM | HarmonyOS 6.1.1 / API 24, tablet and 2in1 |
| MySQL 1.0.2 with shared [`core`](core/README.md) source | Engineering-preview release source; consult [GitHub Releases](https://github.com/OrcaSQL-Workbench/ArkDB/releases) for published downloads | HarmonyOS 6.1.1 / API 24; device interoperability remains unverified |

The published 1.0.1 tag/HAR remains immutable. Its successful historical checks below do not validate the new split. See [shared driver contracts](docs/driver-contracts.md) for ownership, optional interfaces and compatibility changes.

The current driver supports the MySQL text protocol, optional typed prepared statements, restricted prepared multi-row INSERT, session initialization, authentication, TCP/TLS, bounded streamed results, transactions, metadata, cancellation primitives, and server metrics. MariaDB is experimental. Statement caching, pooling and an automatically managed Worker are not implemented. Read the [usage and execution contract](mysql/README.md) before integrating it.

The [package guide](mysql/README.md) includes configuration defaults and examples for typed rows, errors, verified/custom-CA TLS, bounded streaming, transactions, cancellation, and providers. The [runnable example](examples/mysql-client/README.md) supplies a host-owned Worker and UI; it is not a new managed-client interface inside the driver.

## Download and use

For 1.0.2, select `arkdb-mysql-1.0.2.har` and its matching checksum/manifest from
[GitHub Releases](https://github.com/OrcaSQL-Workbench/ArkDB/releases), verify the
checksum, and install that one HAR. Source versioning alone does not establish
publication or OHPM availability. The 1.0.1 links below remain historical downloads.

The [1.0.1 engineering preview](https://github.com/OrcaSQL-Workbench/ArkDB/releases/tag/mysql-v1.0.1) is available through GitHub Releases, independently of OHPM. Download the [HAR](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/arkdb-mysql-1.0.1.har), matching [SHA-256](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/arkdb-mysql-1.0.1.har.sha256), and [manifest](https://github.com/OrcaSQL-Workbench/ArkDB/releases/download/mysql-v1.0.1/arkdb-mysql-1.0.1.manifest.json), verify the checksum, then install the HAR from the consuming application's module directory:

```powershell
ohpm install C:\Downloads\arkdb-mysql-1.0.1.har
```

Import from `@arkdb/mysql`, not internal source paths. Users need a compatible HarmonyOS project/toolchain to build their application, but do not need ArkDB's source, maintenance dependencies, or an OHPM publisher account. See the [download/install guide](docs/building-drivers.md).

The actual **published 1.0.1** HAR was downloaded, checksum-verified, installed and compiled in a fresh independent sample, including its eight packaged README examples and six local sample cases. Real-device networking/TLS/cancellation evidence remains unverified; this is not a production certification or evidence for 1.0.2/core.

## Build an individual driver

The [driver build/download guide](docs/building-drivers.md) explains module selection, versioned artifacts, checksum verification, and importing a downloaded HAR into an application.

```powershell
npm run drivers
npm run pack -- --driver mysql
```

The selector reads registered driver declarations and their source directories; shared source modules are not database drivers. It compiles core plus the selected driver into one temporary delivery module, preserving the maintained source separation. MySQL packaging produces `build\mysql-v1.0.2\arkdb-mysql-1.0.2-local.har`, its checksum and source manifest. A future PostgreSQL selection follows the same model without editing MySQL implementation; it does not invent an unimplemented driver.

## Generated output locations

`build\<driver>-v<version>\` holds local candidates; `dist\<driver>-v<version>\` holds ready, sealed releases. Local filenames use `-local`; package versions inside the HAR stay numeric and imports remain `@arkdb/mysql`. A local build replaces the current candidate for that version, not a released archive.

| Path | Purpose |
| --- | --- |
| `build\<driver>-v<version>\` | Current `-local.har`, matching SHA-256 and provenance manifest |
| `build\<driver>-v<version>\evidence\` | Consumer/readiness records, publication/download receipts and migration evidence |
| `build\<driver>-v<version>\work\` | Owned temporary delivery, consumer and download projects; removed after use |
| `build\<driver>-v<version>\history\` | Preserved older outputs; never used as a build fallback |
| `dist\<driver>-v<version>\` | Immutable, reviewed-source release bundle with canonical filenames, without `-local` |

The filename label is separate from interface compatibility. Current source uses version **1.0.2**, preserving the 1.0.1 connection/factory interface and native result shapes. Portable contracts use distinct `CoreDbConnection`, `CoreDbDriverFactory` and other `Core...` exports instead of replacing established MySQL names. No version is published merely by producing a local candidate; the released 1.0.1 version and bytes remain unchanged.

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
| `npm run test:contracts` | Node-only extension/architecture constraints; no ArkTS compilation |
| `npm run drivers` | List implemented driver modules and their package/source identities |
| `npm run build` | Compile the standalone driver HAR |
| `npm run test:arkts` | Generate current HAR build profiles and run declared core/MySQL Hypium suites at registered source paths, failing on assertion output as well as process errors |
| `npm run pack -- --driver mysql` | Compile core plus the selected driver into one versioned self-contained HAR, checksum and source manifest |
| `npm run test:consumer` | Build the sample HAP/Worker and README examples against the exact HAR, then run offline sample lifecycle tests |
| `npm run example:prepare` | Install the verified HAR into the runnable Worker sample |
| `npm run example:build` | Compile its unsigned HAP for opening/running with owner-supplied debug signing |
| `npm run device:prepare -- --driver mysql --bundle dist\mysql-v1.0.2` | From exact clean sealed source, build one unsigned HAR-bound HAP with an embedded one-time Ed25519 key and publish the pending challenge last |
| `npm run device:verify -- --receipt <file> --manifest <file> --consumer <file> --hap <signed-hap> --profile M1 --out <file>` | Bind the signed receipt to the sealed HAR/consumer and actual signed HAP, then atomically consume the challenge only when every mandatory case passed |
| `npm run release:check` | Validate current archive/sample/guide evidence and run nonpublishing OHPM checks |
| `npm run verify:registry` | After publication, restore an exact registry version into a fresh sample and verify acquisition |
| `npm run verify -- --driver mysql` | Local tooling + declared source-module tests + single-HAR packaging + own sample/README tests + nonpublishing preflight; never publishes |
| `npm run release:prepare -- --driver mysql --tag mysql-v1.0.2` | Authorized build/sealing from clean source and an existing matching annotated tag |
| `npm run release:publish -- --driver mysql --tag mysql-v1.0.2 --confirm-publish` | After separate owner approval, upload the sealed single-HAR release without rebuilding |
| `npm run release:verify-download -- --driver mysql --tag mysql-v1.0.2` | After publication, download the exact release and install/compile its HAR in the matching independent consumer |

**Release route: build locally, distribute through GitHub Releases.** Maintainers use their existing DevEco/CLI installation; there is no dedicated server, self-hosted runner, or SDK installation in GitHub Actions. A tag identifies the reviewed source version; it does not trigger HAR compilation. Hosted CI runs `check` only. The [official-toolchain investigation](docs/hosted-toolchain.md) is historical background, not a prerequisite for this local route.

See [automation naming rules](docs/automation-naming.md) for workflow/run titles and stable required-check names.

Read the [release procedure](docs/releasing.md) before preparing or uploading a bundle. Preparation never commits, pushes, creates tags, or publishes. The separate publish command performs remote writes only with `--confirm-publish` after explicit owner authorization.

## Source and distribution

`core/Index.ets` owns portable contracts; `mysql/Index.ets` owns the stable MySQL interface and native adaptations. Core's `DbConnection` is minimal, optional features are explicit, and typed core factories do not require every engine to accept MySQL options or password authentication. The existing `@arkdb/mysql` `DbConnection` and non-generic `DbDriverFactory` retain their MySQL methods. MySQL configuration, wire fields, native stream defaults and InnoDB metrics stay in the adapter. A test-only independent catalog adapter exercises the shared seam without claiming PostgreSQL support. See [the architecture and migration contract](docs/driver-contracts.md).

The extraction origin and subsequent interface cleanup are recorded in [`docs/source-snapshot.json`](docs/source-snapshot.json); immutable upstream revisions and vectors are in [protocol test provenance](docs/protocol-test-provenance.md). Application code, signing machinery, saved credentials, operational evidence, generated dependencies, and private Git history are not part of this extraction.

See [release and verification requirements](docs/releasing.md) before publishing. Source availability and a local HAR are not registry publication, and local mocks do not establish live TLS or cancellation compatibility. OrcaSQL migration is intentionally outside this repository's extraction work.

## Repository layout

| Path | Owns |
| --- | --- |
| `core/` | Shared source contracts, deadlines and diagnostics; not a required user-installed HAR |
| `mysql/` | MySQL HAR implementation, native extensions, package docs/legal files and local test sources |
| `AppScope/`, `hvigor/`, root build files | Required metadata for the current HAR-only Hvigor workspace; no application UI or runtime |
| `docs/` | Release guidance and extraction/upstream provenance |
| `examples/mysql-client/` | A runnable Stage-model HAP/Worker sample consuming the actual HAR, with offline lifecycle tests |
| `tools/` | Maintainer-only launchers, checks, and packaging; not driver runtime dependencies |

`dist/`, `.hvigor/`, module `build/` and `.test/` directories, generated `BuildProfile.ets` files, `node_modules/`, and `oh_modules/` are generated and ignored. Root npm dependencies support maintenance. Development source imports core; the emitted MySQL HAR embeds that source and has no external core dependency. Root and module build manifests have different roles: source-workspace orchestration versus delivery compilation.

Local validation includes SDK-free checks and actual ArkTS compilation/native contract suites. The exact-archive consumer gate restores one HAR with a fresh cache and unavailable registry before compiling its packaged examples and sample HAP. Only then does it acquire the test framework and run offline cases, including driver-created error identity. Records bind evidence to candidate bytes; source checks alone are not archive-consumption evidence. Device networking/TLS/cancellation remain unverified. Publication requires the separate authorized clean-source release workflow.

The sample also contains an acceptance-disabled device suite. Preparation
requires exact clean sealed source, copies the sample and sealed HAR to an
isolated workspace, embeds one Ed25519 private key, compiles the unsigned HAP,
records that exact HAP digest/size, removes the private source copy, and commits
the 24-hour pending challenge last. After owner signing, the operator records
the actual signed/installed HAP digest and evidence ID in the bound page. The
signed canonical receipt binds profile/features, run ID, clean source, HAR,
sample, signed HAP, API/device class, verified TLS mode, auth plugin, run times,
immutable challenge window, operator evidence ID and ordered case durations/verdicts. The UI exports its
exact JSON through an explicit clipboard action. No host, port, account,
password, schema, CA path or query data is included. The validator separately
hashes the supplied signed HAP, compares its signing-independent application
content with the prepared harness, and checks the sealed manifest/consumer
before publishing external evidence. Preparation and synthetic tests are not device
evidence; hardware attestation, read-only grants and production certification
remain explicitly false.

Use the matching source/consumer when verifying an older major release. Historical single-HAR and dependency-set records remain readable without treating them as evidence for the current architecture.

## License

Apache-2.0; see [LICENSE](LICENSE). Adapted mysql/mysql2 code retains its [upstream MIT notices](mysql/README.OpenSource).
