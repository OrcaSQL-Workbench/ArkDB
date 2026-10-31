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
- Expose optional MySQL prepared statements, typed parameters, identifier quoting
  and positional placeholder helpers from the single package entry. Resolve the
  connection-owned executor lazily on every call, preserving ready/busy checks,
  physical-session ownership and the shared streaming/cleanup pipeline.
- Add optional SQL-mode-aware named parameters through `mysqlFeatures.named`.
  Probe the current owned session mode for every call, scan only executable
  `:name` markers, reject mixed positional markers and executable comments, bind
  repeated names in source order through the binary prepared protocol, and keep
  values separate from identifier quoting without caching modes or templates.
- Add optional binary stored procedure calls through `mysqlFeatures.procedures`.
  Model typed `In`, `Out` and `InOut` arguments with `MySqlProcedureArgument` and
  `MySqlParameterDirection`, encode pure OUT values as typed NULL, recognize the
  single-row output result through `SERVER_PS_OUT_PARAMS` in either EOF mode,
  preserve every result and final OK in wire order with `outResultIndex` and
  `outValues`, share text/byte classification with binary row decoding, reject
  unknown or truncated OUT cardinality after full drain, and avoid session
  variables or a text-protocol fallback.
- Add optional restricted multi-row INSERT through `mysqlFeatures.insertRows`.
  Quote table and column identifiers, bind only typed prepared parameters,
  snapshot every request before dispatch, and greedily group rows by exact
  PREPARE/EXECUTE payload bytes with a 16 MiB ceiling and 65535-parameter limit.
  Reuse `MySqlBatchResult`/`MySqlBatchError` partial outcomes, reject raw SQL and
  upsert fragments, support caller-owned manual and callback transactions
  without lifecycle SQL, join callback cancellation cleanup between emitted
  groups, retain decoded results on Unknown retirement, and recreate physical
  execution state after reset. Return the exact transaction-tracked promise
  from callback-scoped execution and observe pre-command snapshot rejections
  without changing their error identity. Preserve request-level validation
  ordering and failure indices, validate all row widths, then copy every inner
  row before reading hostile parameter getters; cover exact PREPARE UTF-8
  bytes, EXECUTE-only splits, 65535-parameter partitioning and length-encoded
  250/251 and 65535/65536 boundaries.
- Expose positional `mapMySqlRows` projection without changing native value types
  or coercing exact decimal, temporal, JSON, NULL or byte values.
- Add optional native `affectedRowsExact` bigint observations while preserving the
  established numeric `affectedRows` field and unchanged legacy data literals.
- Enable the built-in factory's prepared capability hint without adding required
  methods to core or old custom connections. Add a restricted `MySqlSession`
  borrowing interface and retain native/portable text-stream defaults.
- Add optional `mysqlFeatures.deadlines` buffered query/prepared execute support
  with `MySqlDeadlineOptions` defaults of timeout zero and 2000 ms cancellation
  grace. Bind timers to exact command scopes, retain cancellation/close failures,
  give unknown dispatched KILL priority over an original OK result, and start
  target abort before control cleanup on grace expiry. Observe prompt post-abort
  unwind for one bounded event-loop turn, join every cancellation attempt
  recorded for the owned scope (including later public cancellation), and keep
  grace active through all attempts. Chunk timeout and grace delays to the
  platform maximum `2147483647` ms and re-arm them from monotonic absolute
  expiry. Retain any unknown attempt and force final `Unknown`, keep expired
  prepared close idempotent, retire unresolved targets without replay, and
  leave legacy `QueryOptions.statementTimeoutMs` validation-only.
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
