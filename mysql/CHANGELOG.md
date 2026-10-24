# Changelog

## 1.0.2 - 2026-10-24 (engineering preview)

- Depend on the independent `@arkdb/core` 1.0.0 source module for common errors,
  results, metadata and connection contracts.
- Preserve the 1.0.1 MySQL connection, non-generic factory, handle-based controller
  and provider interfaces; expose generic contracts under distinct `Core...` names.
- Keep native scalar/column/stream types, numeric error codes and established
  constructor defaults. Make additions to existing data shapes optional.
- Keep one shared error constructor with a separate numeric/textual `nativeCode`;
  preserve portable unknown observations separately from native stream defaults.
- Compile core plus MySQL into one self-contained delivery HAR, with internal
  declarations, source provenance and no consumer core dependency/override.
- Validate the assembled manifest, merged module definition and combined legal
  notices when publishing the sealed single-HAR release.
- Expose adapter-typed factory creation and optional connection features; keep
  native MySQL creation/provider helpers and public native information aliases.
- Keep configuration, TCP/TLS, handshake/column details and InnoDB metrics in MySQL.
- Add connection-owned cancellation lifetime and explicit reuse outcomes;
  retain the lower-level handle-based control-session primitive.
- Retire the target connection after an unacknowledged cancellation dispatch;
  preserve reuse after a definite server rejection and prevent late completion
  from resurrecting a closed connection.
- Omit unreported insert IDs from EOF streaming summaries and retain identifiers
  actually reported by OK row terminators, preserving native buffered defaults.
- Distinguish unknown session state and catalog/schema alias validation.
- Define per-driver single-HAR delivery and independent extension/composition regressions.
- Generate current HAR profiles before native tests, resolve registered test
  source paths, and use explicit ArkTS streaming/error types.
- Keep local native/consumer evidence separate from unverified device behavior
  and publication. No 1.0.1 asset or tag is replaced.

## 1.0.1 - 2026-10-23 (engineering preview)

- Preserve the strict runner's checked native verdict across release clean-build cleanup; preparation no longer rereads a raw SDK report that packaging has removed.
- Publish the first downloadable preview under a fresh version without rewriting the earlier unpublished local candidate tag.

## 1.0.0 - Internal candidate (not published)

- Extract the existing headless MySQL HAR into the independent ArkDB repository.
- Preserve the `@arkdb/mysql` import name, protocol behavior, bounded execution, optional providers, and Hypium regression suites.
- Use `ArkDbError` / `ArkDbErrorKind` without Workbench compatibility aliases.
- Limit connection options to implemented driver settings; remove saved-profile metadata, ignored future knobs, and display-name validation.
- Use driver-owned logging tags and remove unused application subsystem tags.
- Add standalone builds, package checks, versioned artifact checksums, and a consumer of the release HAR.
- Consolidate provenance under `docs`, remove empty obfuscation rule placeholders, and validate the current package interface without a frozen Workbench export list or single-module workspace restriction.
- Include the Apache-2.0 license and upstream mysql/mysql2 MIT notices.
- Document complete consumer usage with ArkTS examples compiled against the actual release archive.
- Provide a runnable Worker-based sample HAP with bounded read-only output and offline lifecycle tests.
- Document registry publisher/scope/SSH-key setup; add nonpublishing release checks and an explicit post-publication registry-acquisition command.
- Use a maintainer-local build and GitHub Release delivery route, with clean annotated source tags, a sealed asset allowlist, and explicit publication confirmation.
- Add draft-first immutable upload/reconciliation and actual downloaded-HAR consumer verification without rebuilding or source/local-file fallback.
- Keep GitHub Actions SDK-free, and keep public download, OHPM availability, local test and real-device evidence distinct.

This engineering preview does not certify live TLS, cancellation races, MariaDB compatibility, or additional platforms. Availability of GitHub HAR downloads and optional OHPM publication are separate from this version's build identity.
