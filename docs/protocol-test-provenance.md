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

`MySqlParameter` and `encodeBinaryParameters()` are internal input-codec seams,
separate from the unchanged native result union. They do not execute prepared
commands, decode binary rows, or enable a public factory capability. Byte inputs
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
sections. A future command caller must emit `new_params_bound_flag=1` for
nonempty bindings. These local codec fixtures establish no live-server,
SQL-mode, or target-device behavior.

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
