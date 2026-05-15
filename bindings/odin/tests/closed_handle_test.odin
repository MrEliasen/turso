package tests

import turso "../turso"

// MISUSE-on-closed-handle contract. Every public proc that operates on a
// Connection or Statement is expected to short-circuit with a typed MISUSE
// error rather than dereferencing a freed pointer. The Java JDBC tests
// (JDBC4ConnectionTest, JDBC4StatementTest) pin the equivalent guarantee for
// the JDBC suite; this file pins it for Odin.

test_step_on_closed_statement_returns_misuse :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT 1")
	finalize_ok(&stmt)

	_, e, ok := turso.step(stmt)
	defer turso.error_destroy(&e)
	expect_false(ok, "step on finalized statement must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "step on finalized statement surfaces MISUSE")
}

test_bind_on_closed_statement_returns_misuse :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT ?")
	finalize_ok(&stmt)

	e, ok := turso.stmt_bind_int(stmt, 1, 42)
	defer turso.error_destroy(&e)
	expect_false(ok, "bind on finalized statement must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "bind on finalized statement surfaces MISUSE")
}

test_prepare_on_closed_connection_returns_misuse :: proc() {
	t := test_db_open_memory()
	_, _ = turso.conn_close(&t.conn)
	defer test_db_close(&t)

	_, e, ok := turso.prepare(t.conn, "SELECT 1")
	defer turso.error_destroy(&e)
	expect_false(ok, "prepare on closed connection must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "prepare on closed connection surfaces MISUSE")
}

test_exec_on_closed_connection_returns_misuse :: proc() {
	t := test_db_open_memory()
	_, _ = turso.conn_close(&t.conn)
	defer test_db_close(&t)

	_, e, ok := turso.conn_exec(t.conn, "SELECT 1")
	defer turso.error_destroy(&e)
	expect_false(ok, "conn_exec on closed connection must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "conn_exec on closed connection surfaces MISUSE")
}

test_connect_on_closed_database_returns_misuse :: proc() {
	t := test_db_open_memory()
	_, _ = turso.conn_close(&t.conn)
	turso.database_close(&t.db)
	defer test_db_close(&t)  // idempotent

	_, e, ok := turso.connect(t.db)
	defer turso.error_destroy(&e)
	expect_false(ok, "connect on closed database must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "connect on closed database surfaces MISUSE")
}
