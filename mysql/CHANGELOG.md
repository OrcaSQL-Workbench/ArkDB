# Changelog

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
