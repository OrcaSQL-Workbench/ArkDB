# PostgreSQL device acceptance harness

This standalone HarmonyOS application contains the fixed PostgreSQL device
acceptance runner. The committed source is unbound: the run button is disabled
and cannot produce device evidence. Driver registration, release binding and
verification support are not yet available for PostgreSQL.

The application consumes a self-contained PostgreSQL HAR at
`dependency\postgres.har`. It uses a host-owned Worker, clears the password from
page state when starting or hiding, stops an active run when the page is hidden,
and publishes a receipt only after Worker shutdown is confirmed. Copying a
receipt writes its exact JSON to the local-device clipboard; clear the clipboard
after secure transfer.

An API-24 emulator is useful for application and Worker integration checks, but
is not physical-device acceptance evidence. The PostgreSQL 15–18 live matrix
and bound device acceptance remain separate release gates.
