# Changelog

## 1.1.0 - Shared source included in MySQL 1.1.0

- Preserve the distinct `Core...` public contracts and one shared `ArkDbError`
  runtime identity while keeping database-specific options and behavior in adapters.
- Centralize portable query validation and execution failure composition so new
  drivers can reuse policy without depending on MySQL implementation files.
- Organize runtime sources under explicit connection, diagnostics, driver,
  execution, metadata, metrics, model and time ownership with zero file-level
  dependency cycles.
- Keep the minimal connection interface and additive optional features as the
  stable seam for independent driver implementations and contract tests.
- Continue embedding the selected core source closure into one self-contained
  driver HAR; core is not a separately installed consumer artifact.

## 1.0.0 - Shared source included in MySQL 1.0.2

- Extract one shared source for connection, result, error, optional capability,
  metadata, cancellation and metric interfaces, deadlines and diagnostics.
- Keep engine-owned configuration, native information and wire implementations
  outside this module.
- Retain one shared error constructor with numeric `code` compatibility and
  numeric/textual `nativeCode`; keep additive data fields optional for existing shapes.
- Keep core independently maintained in source while including it once in a
  selected driver's self-contained delivery HAR.
- Exercise the independent adapter through native contract tests and validate
  shared error identity in the exact-archive consumer.
- Keep local validation, unpublished candidate archives and unverified device
  behavior distinct.
