// Idiomatic Odin bindings for Turso (a SQLite rewrite in Rust).
//
// Layers:
//   turso/raw     extern declarations matching sdk-kit/turso.h 1:1
//   turso/*.odin  handwritten wrappers using the (T, Error, bool) multi-return idiom
//   turso/sync    cloud sync engine wrappers (push, pull, checkpoint, stats)
//
// Shipped:
//   * Local files and ":memory:" databases
//   * Prepared statements with positional and named binding
//   * All five SQL value kinds (INTEGER, REAL, TEXT, BLOB, NULL)
//   * Multi-statement parsing via prepare_first
//   * Convenience helpers: conn_exec, conn_exec_args, conn_scalar_i64
//   * Encryption (experimental; requires experimental_features = "encryption")
//   * Tracing logger callback via setup(Setup_Options{log_level, logger})
//   * Async I/O (Database_Config.async_io = true) with transparent step/execute/finalize
//     and explicit step_once/run_io for event-loop integration
//   * Statement cache (cache_init, prepare_cached, cache_clear, cache_destroy)
//   * Transaction helpers (conn_with_transaction, conn_with_savepoint and the
//     primitive conn_begin / conn_commit / conn_rollback set)
//   * Reflection-based row-to-struct mapping (stmt_scan_struct,
//     conn_query_one_struct, conn_query_optional_struct, conn_query_all_struct)
//   * Sync engine subpackage (turso/sync) with a built-in libcurl client
//     at turso/sync/curlhttp or a caller-supplied HTTP_Client.roundtrip
//
// See README.md for the lifetime contract.
package turso
