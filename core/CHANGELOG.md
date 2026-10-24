# Changelog

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
