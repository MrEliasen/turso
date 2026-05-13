// Idiomatic Odin bindings for Turso (a SQLite rewrite in Rust).
//
// Layers:
//   turso/raw     - extern declarations matching turso.h 1:1
//   turso/*.odin  - handwritten wrappers using the (T, Error, bool) multi-return idiom
//
// v1 scope:
//   - Local database only (path or ":memory:")
//   - Synchronous I/O only (async_io = 0)
//   - No encryption (encryption_cipher/encryption_hexkey are never set)
//   - No sync engine
//
// See README.md for the lifetime contract and future work.
package turso
