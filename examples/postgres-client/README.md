# ArkDB PostgreSQL skeleton consumer

This independent HarmonyOS application compiles the registered
`@arkdb/postgres` package skeleton. Its local Hypium test verifies that
`connect()` rejects with the shared `ArkDbError` identity and
`ArkDbErrorKind.Unsupported`, while every advertised driver capability remains
false.

The entry build removes the skeleton HAR's inherited INTERNET permission. The
sample does not open a socket, implement PostgreSQL protocol behavior, or
establish release or interoperability evidence.
