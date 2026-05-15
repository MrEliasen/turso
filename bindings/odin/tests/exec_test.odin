package tests

import turso "../turso"

test_conn_exec_ddl :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	rows, e, ok := turso.conn_exec(t.conn, "CREATE TABLE t(a INTEGER)")
	expect_no_err(e, ok, "DDL")
	expect_eq(rows, u64(0), "DDL affects 0 rows")
}

test_last_insert_rowid :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")
	exec_ok(t.conn, "INSERT INTO t(v) VALUES (10)")
	rid := turso.last_insert_rowid(t.conn)
	expect_true(rid > 0, "last_insert_rowid is positive after INSERT")
}

// T1: INSERT...RETURNING partial consumption. Mirrors the Rust binding's
// `test_insert_returning_partial_consume` (bindings/rust/tests/integration_tests.rs).
// The point is: stepping the RETURNING statement once and finalizing
// without draining MUST still commit every inserted row.
test_insert_returning_partial_consume :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")

	stmt, e, ok := turso.prepare(t.conn,
		"INSERT INTO t(v) VALUES (10), (20), (30) RETURNING id")
	expect_no_err(e, ok, "prepare INSERT RETURNING")

	// Consume only the FIRST returned row, then finalize. The other two
	// rows are still committed - the engine doesn't roll back on partial
	// consumption.
	step_expect_row(stmt)
	first_id := turso.stmt_get_int(stmt, 0)
	expect_true(first_id > 0, "first RETURNING id is positive")
	_, _ = turso.finalize(&stmt)

	count, ce, cok := turso.conn_scalar_i64(t.conn, "SELECT COUNT(*) FROM t")
	expect_no_err(ce, cok, "count after partial RETURNING consume")
	expect_eq(count, i64(3), "all three rows must be committed even though we only stepped once")
}
