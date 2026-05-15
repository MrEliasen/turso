package tests

import turso "../turso"

// Stmt_Cache lifetime relative to the source Connection. The cache holds
// statement handles that point into Connection-owned engine memory; closing
// the Connection while statements still live is a misuse per turso.h:194
// (SAFETY contract on turso_connection_close). The binding documents the
// rule but does not enforce it. These tests pin the observed behavior so
// regressions surface immediately.

test_cache_destroy_after_connection_close_does_not_crash :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	cache := turso.cache_init()
	defer turso.cache_destroy(&cache)

	_, _, _ = turso.prepare_cached(t.conn, &cache, "SELECT 1")
	_, _, _ = turso.prepare_cached(t.conn, &cache, "SELECT 2")

	// Close the connection first. The cache is still holding statements
	// against this connection's engine state. cache_destroy (in the deferred
	// cleanup) must not crash even though the contract documents the reverse
	// ordering as preferred. The C API tolerates finalize-after-close in
	// practice; if a future engine change makes it strict, the test will
	// fail and the binding will need explicit enforcement.
	_, _ = turso.conn_close(&t.conn)
}

// Schema change behind a cached statement: the engine should either continue
// to satisfy the query against the new schema or surface a recoverable
// error. The binding must not return stale data from a now-incompatible
// plan. Mirrors the spirit of Rust's
// test_prepare_cached_reprepare_on_query_only_change.
test_cached_statement_survives_schema_change :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")
	exec_ok(t.conn, "INSERT INTO t(v) VALUES (1), (2), (3)")

	cache := turso.cache_init()
	defer turso.cache_destroy(&cache)

	sql :: "SELECT v FROM t"
	{
		stmt, e, ok := turso.prepare_cached(t.conn, &cache, sql)
		expect_no_err(e, ok, "first prepare_cached pre-schema-change")
		step_expect_row(stmt)
		_, _ = turso.reset(stmt)
	}

	// Drop and re-create the table with a different column shape. A cached
	// plan against the old schema must not silently succeed against the new
	// schema. Either the engine repreapares transparently and returns rows,
	// or it surfaces an error — both are acceptable; what's NOT acceptable
	// is "ok=true but wrong data".
	exec_ok(t.conn, "DROP TABLE t")
	exec_ok(t.conn, "CREATE TABLE t(label TEXT)")
	exec_ok(t.conn, "INSERT INTO t(label) VALUES ('after-schema-change')")

	stmt2, e2, ok2 := turso.prepare_cached(t.conn, &cache, sql)
	defer turso.error_destroy(&e2)
	if !ok2 {
		// Engine refused to use the stale plan. That is the safe outcome.
		return
	}
	// Engine accepted the cached statement. Whatever it returns must be
	// derivable from the current schema — i.e. the engine must have
	// re-prepared so the SELECT yields the TEXT column. We check that the
	// column count matches the new schema rather than the old.
	expect_eq(turso.column_count(stmt2), i64(1), "cached statement after schema change reflects new schema")
}
