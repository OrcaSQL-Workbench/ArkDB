# MySQL Protocol Test Provenance

The protocol regression fixtures are derived from immutable revisions of the two MIT-licensed drivers originally ported by OrcaSQL and extracted into ArkDB. The tests exercise internal connector interfaces only and do not establish live-server interoperability. The complete upstream license texts are retained in [`mysql/README.OpenSource`](../mysql/README.OpenSource).

## Upstream sources

| Repository | Commit | Source | Represented behavior | Driver path under `mysql/src/main/ets` |
|---|---|---|---|---|
| [`mysqljs/mysql`](https://github.com/mysqljs/mysql) | [`dc9c152a87ec51a1f647447268917243d2eab1fd`](https://github.com/mysqljs/mysql/tree/dc9c152a87ec51a1f647447268917243d2eab1fd) | [`lib/protocol/Parser.js`](https://github.com/mysqljs/mysql/blob/dc9c152a87ec51a1f647447268917243d2eab1fd/lib/protocol/Parser.js) | Fixed-width and length-encoded reads, packet sequence reset/wrap, fragmented packet parsing, and `0xFFFFFF` continuation reassembly | `mysql/protocol/PacketReader.ets`, `mysql/protocol/PacketChannel.ets` |
| [`mysqljs/mysql`](https://github.com/mysqljs/mysql) | [`dc9c152a87ec51a1f647447268917243d2eab1fd`](https://github.com/mysqljs/mysql/tree/dc9c152a87ec51a1f647447268917243d2eab1fd) | [`lib/protocol/PacketWriter.js`](https://github.com/mysqljs/mysql/blob/dc9c152a87ec51a1f647447268917243d2eab1fd/lib/protocol/PacketWriter.js) | Fixed-width and length-encoded writes plus `0xFFFFFF` frame splitting and empty termination | `mysql/protocol/PacketWriter.ets`, `mysql/protocol/PacketChannel.ets` |
| [`mysqljs/mysql`](https://github.com/mysqljs/mysql) | [`dc9c152a87ec51a1f647447268917243d2eab1fd`](https://github.com/mysqljs/mysql/tree/dc9c152a87ec51a1f647447268917243d2eab1fd) | [`lib/protocol/Auth.js`](https://github.com/mysqljs/mysql/blob/dc9c152a87ec51a1f647447268917243d2eab1fd/lib/protocol/Auth.js) | `Auth.token`: `mysql_native_password` SHA-1 scramble | `mysql/auth/NativePassword.ets` |
| [`sidorares/node-mysql2`](https://github.com/sidorares/node-mysql2) | [`928c3c511a0316713966ade2cf27e47285feb878`](https://github.com/sidorares/node-mysql2/tree/928c3c511a0316713966ade2cf27e47285feb878) | [`lib/packet_parser.js`](https://github.com/sidorares/node-mysql2/blob/928c3c511a0316713966ade2cf27e47285feb878/lib/packet_parser.js) | Header fragmentation, payload fragmentation, sequence retention, and large-packet continuation | `mysql/protocol/PacketChannel.ets` |
| [`sidorares/node-mysql2`](https://github.com/sidorares/node-mysql2) | [`928c3c511a0316713966ade2cf27e47285feb878`](https://github.com/sidorares/node-mysql2/tree/928c3c511a0316713966ade2cf27e47285feb878) | [`lib/packets/packet.js`](https://github.com/sidorares/node-mysql2/blob/928c3c511a0316713966ade2cf27e47285feb878/lib/packets/packet.js) | Fixed-width, string, and length-encoded packet payload codecs | `mysql/protocol/PacketReader.ets`, `mysql/protocol/PacketWriter.ets` |
| [`sidorares/node-mysql2`](https://github.com/sidorares/node-mysql2) | [`928c3c511a0316713966ade2cf27e47285feb878`](https://github.com/sidorares/node-mysql2/tree/928c3c511a0316713966ade2cf27e47285feb878) | [`lib/auth_41.js`](https://github.com/sidorares/node-mysql2/blob/928c3c511a0316713966ade2cf27e47285feb878/lib/auth_41.js) | `calculateToken`, byte XOR, and `xorRotating` | `mysql/auth/NativePassword.ets`, `mysql/auth/CachingSha2.ets`, `mysql/auth/Crypto.ets` |
| [`sidorares/node-mysql2`](https://github.com/sidorares/node-mysql2) | [`928c3c511a0316713966ade2cf27e47285feb878`](https://github.com/sidorares/node-mysql2/tree/928c3c511a0316713966ade2cf27e47285feb878) | [`lib/auth_plugins/caching_sha2_password.js`](https://github.com/sidorares/node-mysql2/blob/928c3c511a0316713966ade2cf27e47285feb878/lib/auth_plugins/caching_sha2_password.js) | `calculateToken` SHA-256 scramble and RSA-OAEP encryption of a cyclically obfuscated NUL-terminated password | `mysql/auth/CachingSha2.ets`, `mysql/auth/Crypto.ets` |

The applicable license texts are [`mysqljs/mysql/License`](https://github.com/mysqljs/mysql/blob/dc9c152a87ec51a1f647447268917243d2eab1fd/License) and [`sidorares/node-mysql2/License`](https://github.com/sidorares/node-mysql2/blob/928c3c511a0316713966ade2cf27e47285feb878/License).

## Checked primitives and binary input fixtures

`MySqlParameter` is the public typed input model; `encodeBinaryParameters()` is
its internal codec, separate from the unchanged native result union. The codec
does not itself execute prepared commands, decode binary rows or enable a
factory capability. Byte inputs
are snapshotted; the encoder revalidates inputs before allocating its output.
The parameter list is captured before reading any value getters; appended,
replaced or removed caller-list entries cannot change its fixed count, type
table, bitmap, or command-budget accounting.
Invalid inputs use `Validation` errors. Truncated, invalid-length, unsafe
length-encoded, and unterminated packet reads use `Protocol`, not `RangeError`.
Existing unsigned 8/16/24/32-bit writer wrapping remains unchanged.

The new fixtures use independently specified little-endian byte literals:

| Input | Encoded value hex |
| --- | --- |
| UInt64 `18446744073709551615n` | `ffffffffffffffff` |
| Int64 `-9223372036854775808n` | `0000000000000080` |
| Float64 `1.5` | `000000000000f83f` |
| Decimal `"12.3400"` | `0731322e33343030` |
| TIME `"-838:59:59.000001"` | `0c0122000000163b3b01000000` |
| Empty binary or text | `00` |

The parameter NULL bitmap starts at bit zero (unlike the binary-row bitmap).
Typed NULLs retain their type-table entry and contribute no value bytes; UInt64
uses the LONGLONG unsigned byte `80`. JSON input is validated text bound as
VAR_STRING, not the server-specific JSON type. Temporal zero values use a
zero-length body, and other temporal fixtures cover Gregorian leap years,
multi-day negative TIME, wall-clock DATETIME/TIMESTAMP and microseconds without
`Date` or timezone conversion.

Boundary cases include 65 total decimal digits / 30 fractional digits, 65535
parameters, and an exact 16777216-byte command versus one byte over. The command
budget includes the ten-byte execute header, bitmap, new-parameter flag and
complete type table; this codec returns only the bitmap, type table and value
sections. The internal prepared executor emits `new_params_bound_flag=1` for
every nonempty execution, including explicit handle reuse. These local codec fixtures establish no live-server,
SQL-mode, or target-device behavior.

## Shared text and binary result fixtures

The internal `MySqlRowDecoder.decode(payload, columns)` seam separates row values
from the shared result-event, chunk, multi-result and synchronization-drain
pipeline. `TextRowDecoder` retains the text mapping used by `parseQueryStream()`
and `parseResultSet()`. `BinaryRowDecoder` consumes binary rows using the actual
columns of each result, without retaining prepare-time metadata. These internal
adapters do not send prepared commands, add public exports or enable a factory
capability; public query entry points remain text-protocol operations.

Binary fixtures use independent wire literals for the `00` row header, the NULL
bitmap's two-bit offset, signed/unsigned integer widths, floating-point values
and length-encoded fields. Fixed expectations include unsigned BIGINT
`18446744073709551615n`, DECIMAL `"12345678901234567890.1234567890"` and TIME
`"-838:59:59.000001"`. BIT and binary-collation fields remain bytes; JSON and
DECIMAL remain strings even with binary metadata. Temporal fixtures cover zero
values, date-only and wall-clock timestamp bodies, negative multi-day TIME and
fractional precision 0 through 6, without `Date` or timezone conversion.
Malformed lengths, truncated fields, unsupported type codes, trailing binary
bytes and fractional values inconsistent with metadata fail with `Protocol`.

Stream fixtures cover classic/deprecated EOF, `fe`-prefixed text data, changing
metadata, mixed OK/row results, row/decoded-byte/chunk/result-set/drain budgets,
1317 interruption status, callback error identity and receive overflow during a
pending acknowledgement. Both adapters share the existing defaults and awaited
callbacks; they do not change transport or logical-packet bounds. These local
protocol fixtures do not establish live prepared execution or device/server
interoperability.

## Internal prepared statement lifecycle

`MySqlPreparedSession` is an internal PREPARE/CLOSE owner, not a public prepared
capability or an additional transport. Its host supplies the existing command
gate, physical `PacketChannel`, negotiated capabilities, lifecycle state and
physical retirement callback. Create one owner per physical session generation;
do not carry it across reconnect or replace its host channel. The lifecycle owner
does not itself enable the public feature; the optional connection facade below
uses the execution dispatcher. A standalone lifecycle-only session without one keeps
its explicit `Unsupported` execution contract. The internal prepared executor
binds its handles to the original connection's execution dispatcher.

PREPARE consumes the header, every parameter definition and every result-column
definition before returning a handle. Classic mode requires a five-byte EOF
after each nonempty definition block. With negotiated `DEPRECATE_EOF`, both
metadata terminators are omitted, not replaced by OK packets. Zero-count blocks
have no terminator in either mode. Fixed metadata fields, length prefixes,
fillers and truncation are checked before using the existing column decoder.
Both definition blocks reject unknown or unsupported native type codes before
returning a handle; the legacy text-query fallback is unchanged.
The internal parser accepts the documented ten-byte warningless OK and the
twelve-byte OK with warnings; unnegotiated optional metadata is not guessed.

These rules and the response-free CLOSE command are documented in the MySQL
server's [protocol source](https://github.com/mysql/mysql-server/blob/trunk/sql/protocol_classic.cc)
under `COM_STMT_PREPARE` and `COM_STMT_CLOSE`. CLOSE writes `19` followed by the
four-byte little-endian identifier, resets the existing channel sequence and
does not read an ACK. The identifier is private, not a caller-supplied handle
field. Repeated close shares its pending or settled result. A closed physical
session only needs local handle invalidation; it does not manufacture a server
acknowledgement.

Handles are bound to the owner, physical channel and gate generation. Metadata
access returns defensive prepare-time snapshots; it is not proof that future
execution metadata is unchanged after DDL. `prepareOwned`, `closeOwned` and
`assertUsable` require the caller's active gate scope and never reserve or
release it. The owning caller must settle its whole composed operation before
releasing the scope. External overlap fails rather than entering a hidden queue.
A private in-flight guard shared by lifecycle objects also rejects concurrent
owned PREPARE/CLOSE on the same physical channel before phase changes, sequence
reset, dispatch or handle invalidation. It remains held through response and
failure cleanup, then permits sequential reuse of the caller's scope.

Only a consumed, valid first-packet ERR proves a reusable server rejection.
Malformed, unsupported or incomplete metadata, a read/write failure, or an ERR
after the prepare OK invalidates all handles and retires that physical session. A CLOSE
write failure also invalidates the handle and conservatively retires the
session. Primary fields, ordinary causes and retirement failures are retained
using the existing canonical operation error; failure is not a retry signal.
The retirement callback must detach and close the owned physical transport
without acquiring another gate scope or releasing the caller's scope.

The registered lifecycle fixtures use the real gate, checked codecs and packet
channel with a deterministic byte-transport boundary. They cover both EOF
modes, exact consumption, no-ACK/idempotent CLOSE, foreign/stale/recycled IDs,
independent handles, owned composition, overlap, malformed metadata, server and
transport failures, cleanup provenance, UTF-8 budgets and existing packet
fragmentation. They establish neither live-server/device interoperability nor
cursor, long-data, caching, pooling or public capability support.

## Internal prepared execution and cleanup

`command/PreparedExecutor.ets` implements the internal buffered and native-stream
contracts. The connection's protected accessor supplies its real physical
channel, generation, existing command gate, cancellation lifetime and shared
result pipeline. That accessor remains protected; the public feature resolves it
lazily for each method call.
Convenience execution has no cache: one scope owns PREPARE, EXECUTE, consumption
or synchronization of all results, and response-free CLOSE. Explicit handles
reuse their server statement until closed or physically invalidated.

The existing typed encoder captures the parameter list and values before the
first asynchronous dispatch. Invalid values or query options send no PREPARE;
a server count mismatch can follow PREPARE but sends no EXECUTE. The opaque
prepare response builds the ten-byte EXECUTE header with cursor flag zero and
iteration count one, followed, only for nonempty bindings, by the index-zero
NULL bitmap, flag one, full type table and captured values. The identifier never
becomes a caller-supplied field. `PS_MULTI_RESULTS` is negotiated independently
when offered; prepared execution does not enable `MULTI_STATEMENTS`.

Buffered and streamed execution use T03's binary row decoder with each result's
actual execution metadata, not the defensive prepare-time column snapshot.
Chunk, row, decoded-byte, result-set and drain limits retain their existing
defaults. Consumer acknowledgements are awaited, and legacy
`statementTimeoutMs` remains validation-only rather than an automatic deadline.
Only the optional `mysqlFeatures.deadlines` query/execute interface starts
cancellation timers. Its options default to timeout zero and a 2000 ms
cancellation grace period, while retaining a cloned `QueryOptions` budget.
Timeout and grace values above the platform timer range are scheduled in chunks
no larger than `2147483647` ms. Each chunk re-computes the remaining budget from
one monotonic absolute expiry rather than treating the first chunk as timeout.

Only consumed valid server ERR packets establish reusable rejections.
Malformed results, uncertain writes/reads and unsynchronized drain failures
retire the physical protocol path without retrying SQL or writing CLOSE into
an unread response. Cancellation is available in EXECUTE's query phases, not
PREPARE, synchronization PING or statement CLOSE. Control cancellation and its
cleanup settle before convenience CLOSE and scope release, including failures
that finish before the original result. Deadline convergence records and joins
every cancellation attempt for the owned scope, including a later public
`cancel()` after an earlier Requested attempt clears; grace remains active until
the operation and all recorded attempts settle. Any unknown attempt or target
retirement forces final outcome `Unknown`, even if the original command consumed
OK, and retains the failure. On grace expiry, target transport abort starts
before control cleanup is awaited. After abort and cancellation, one zero-delay
event-loop turn gives queued operation/prepared unwind a bounded chance to
contribute its real failure; settlement never waits forever. An expired prepared
handle CLOSE is intentionally idempotent and does not invent a separate
`Protocol` cleanup.

Operation errors retain the execution primary, native code, SQLSTATE, ordinary
consumer cause, cleanup errors and execution outcome. A CLOSE failure after a
fully consumed result reports `Completed`, not a claim that SQL was never sent;
a count mismatch remains `NotDispatched` even if its cleanup also fails.
Bound statement CLOSE retains T04's shared full-operation completion promise.

The registered execution, stream and cancellation regressions exercise the real
connection, gate, packet channel, checked encoder and shared decoders through
the deterministic socket/control boundary. Exact scalar fixtures include
unsigned BIGINT `18446744073709551615n`, DECIMAL
`"12345678901234567890.1234567890"`, TIME `"-838:59:59.000001"`, bytes and SQL NULL
in both EOF modes. Deadline regressions additionally prove exact scope/serial timer
ownership, PREPARE expiry before EXECUTE, lost KILL acknowledgement retention,
multiple cancellation-attempt joining, grace target-abort ordering, bounded
post-abort observation, platform-range timeout/grace chunking, idempotent
expired prepared close and joined close cleanup. Those prepared execution/deadline fixtures do not establish live-server or
device timing interoperability, prepared CALL/OUT support, cursor, long-data,
pooling or automatic retries.

## Prepared long-data upload fixtures

The long-data fixtures use the existing prepared statement owner, packet channel,
typed placeholder encoder and execution/cancellation pipeline. Independent
little-endian literals verify `COM_STMT_SEND_LONG_DATA` payloads as command `18`,
four-byte statement identifier, two-byte zero-based parameter index and raw
chunk bytes. Every long-data command resets its packet sequence and reads no
response. `COM_STMT_RESET` is command `1a` plus the private statement identifier
and must consume one OK response before a failed upload can reuse the handle.
Final EXECUTE fixtures decode the bitmap, new-types flag, full type table and
remaining value bytes. They cover long-before-scalar, scalar-before-long, two
sent long parameters and a zero-chunk source. Sent long indexes omit only their
ordinary placeholder value ranges; following scalar bytes remain aligned, while
zero-chunk input retains the empty placeholder because no long-data state was
created.

The protocol-neutral pump fixtures use deterministic byte sources, writers and
monotonic timer ports. They cover empty/oversized chunks, exact and exceeded
cumulative limits, one absolute read/write/close timeout, serial multi-source
ordering, exactly-once source close, one abort subscription independent of chunk
count, and a separate cleanup budget. Multi-source cleanup fixtures prove every
close starts before timeout observation, timeout evidence does not settle the
pump, unread-source closes still run exactly once, and all actual close
settlements/failures are joined before return. Timed-out writer fixtures prove
the pump timer is registered before an equal-deadline transport timer, upload
Timeout remains primary, transport Protocol remains cleanup evidence,
retirement is requested and the original write settles before cleanup/return.
Pump failures expose no SQL execution outcome.

Absolute-expiry fixtures advance the monotonic clock without firing the retained
timer, then settle a read or write callback. They prove late success cannot
bypass Timeout, late failure is cleanup evidence, the timer is canceled only
after the absolute-expiry recheck, and no late chunk is written. A gated-read
fixture proves timeout starts source close, the pump remains pending, and the
exact read settlement is joined; a late read failure is retained. The source
fixture's close follows the public contract by not settling before its pending
read.

Ordinary-error fixtures reject source read, source close and the
protocol-neutral writer with distinct `Error` objects. They prove the neutral
upload failure and final `MySqlOperationError` preserve exact `originalCause`
identity, retain NotDispatched/Unknown outcome ownership in the adapter, and do
not duplicate the same cause during close cleanup.

Connection fixtures cover zero-byte input, two long parameters, reset
success/failure, first-read/invalid-first-chunk/zero-byte-close reset, upload
timeout without KILL, a timed-out `0x18` that retires without reset, manual cancel
during upload, prepared cancellation after EXECUTE begins, and root close while
a source read is pending. Preflight fixtures separately reject duplicate
parameter indexes and duplicate byte-source object identities before any read,
close or upload command. Post-cursor integration fixtures keep both optional
features on one connection, reject long-data ownership while a cursor is active,
and reject cursor wire work while long-data owns Uploading. Observer assertions
require one Query start and one matching terminal only after
upload/reset-or-execute/cleanup convergence; lifecycle events contain command
metadata only, never SQL or source bytes. These local fixtures do not establish
live server, device, throughput or large-LOB interoperability.

## Read-only prepared server cursors

`command/MySqlCursor.ets` owns the cursor lifetime behind the public
`mysqlFeatures.cursors.open(...)` interface. One command scope covers PREPARE,
read-only COM_STMT_EXECUTE, every caller-requested COM_STMT_FETCH, RESET when
closed early, response-free CLOSE and final owner release. The cursor does not
borrow the convenience statement cache and introduces no pool dependency.

The opaque prepared response builds cursor EXECUTE, FETCH, RESET and CLOSE
payloads without exposing statement identifiers. Open consumes execution-time
column metadata and requires `SERVER_STATUS_CURSOR_EXISTS`. FETCH decodes binary
rows against that metadata and treats only `SERVER_STATUS_LAST_ROW_SENT` as
completion; a short batch alone is not final. Both classic EOF and
deprecated-EOF OK terminators share the result-stream terminator parser.
`fetchRows` accepts exactly 1..10000. Cursor options extend and clone the shared
`QueryOptions`; inherited `maxRows` and `maxResultBytes` are tracked across all
FETCH responses rather than restarting at each batch.

If a server ignores the cursor request and begins a normal buffered result, the
driver does not buffer it as a fallback. Unread/malformed responses retire the
physical path. Per-fetch decoded-byte overflow drains the current FETCH response
to its terminator, then RESETs and CLOSEs without returning partial rows.
Cumulative row/decoded-byte overflow follows the same cleanup path, while exact
limit exhaustion returns the final allowed batch and closes before resolving.
Early close reads RESET OK and never invents a CLOSE acknowledgement.

The deterministic cursor fixtures use the real connection, command gate,
prepared lifecycle, packet channel and binary decoder. They cover fetch-only-on-
request, final-owner release, early close, strict fallback rejection, empty and
partial final batches, exact fetch-count boundaries, per-fetch and cumulative
budgets, disconnect, reentry and both EOF modes. These checks do not establish
live-server/device interoperability, pool-release integration,
scrollable/update cursors or long-data support.

## Optional public prepared capability

The package entry exports `MySqlConnectionFeatures`, `requireMySqlFeatures`,
typed parameters, prepared interfaces, identifier quoting and positional
placeholders. Each built-in creation path supplies the optional feature without
opening a connection. Its methods delegate to the existing ready-only accessor;
they do not duplicate encoding, result adapters, command ownership, cancellation
or cleanup. Core's connection has no new required methods.

Public-boundary fixtures use the actual factory/connection methods and the
existing deterministic socket boundary. They cover buffered execution, explicit
handle reuse/close, native prepared streaming, unchanged native and portable
text-stream defaults, busy/closed-state rejection and separate physical
connections with recycled server IDs. Old custom implementations and data
literals remain part of the public and single-HAR consumer suites. The consumer
imports only `@arkdb/mysql`, checks the canonical error constructor and compiles
the documented prepared example. These local checks are not real-device,
live-server, publication or application-deployment evidence.

## Fixed authentication vectors

Expected bytes were calculated outside the ArkTS implementation with Node.js `node:crypto` SHA-1/SHA-256 digests and byte-wise XOR. Password columns contain UTF-8 bytes, not credentials. An empty expected value is a zero-length response.

Local Hypium does not execute the platform CryptoKit implementation. The module's test replacement returns the independently calculated digest stages for these inputs, so the tests exercise the production UTF-8 conversion, concatenation order, and XOR composition without deriving expected scrambles from the ArkTS implementation.

Salt for all scramble rows: `00112233445566778899aabbccddeeff10213243`.

| Password UTF-8 hex | Expected native scramble hex | Expected caching-SHA2 scramble hex | Expected obfuscated password hex |
|---|---|---|---|
| empty | empty | empty | `00` |
| `70617373776f7264` | `537ff3603fb9185dbf69e3ba0825d3e158dcd7f0` | `18e9cfd3c59bf122b6818722caba101324292af1b90aa79d3096bf54f18570b6` | `70705140333a141388` |
| `e5af86e7a081f09f9492` | `3f5907b21a9d8f27ada52d472982adf5225b11fd` | `3fd6c12aa326e0709dd28c303a15c50cd411618439eb34c67db8739de85a3cdc` | `e5bea4d4e4d496e81c0baa` |

The non-ASCII password bytes decode to `密码🔒`.

## Cyclic obfuscation vectors

`obfuscatePassword()` appends `00` before XOR and repeats the nonce until every byte is covered.

| Password UTF-8 hex | Nonce hex | Expected obfuscated password hex |
|---|---|---|
| `616263646566` | `102030` | `71425374455610` |
| empty | `5a` | `5a` |

## RSA-OAEP test boundary

The local CryptoKit replacement returns distinct 256-byte values for repeated encryption requests and rejects malformed public-key text. This prevents a fixed OAEP ciphertext assertion but does not execute or decrypt real CryptoKit RSA output. Target-device evidence is still required for actual `caching_sha2_password` RSA interoperability.
