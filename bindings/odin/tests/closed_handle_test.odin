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

// test_closed_connection_exec_apis_return_misuse drives every exec-family API
// through the closed-connection path in one parametric run. The exec APIs
// (conn_exec, conn_exec_args, conn_exec_batch) share the same handle-nil guard
// inside the binding; the test pins that surface for all three so a future
// guard regression on any of them is caught.
test_closed_connection_exec_apis_return_misuse :: proc() {
	cases := [?]struct{
		name: string,
		call: proc(conn: turso.Connection) -> (turso.Error, bool),
	}{
		{"conn_exec", proc(conn: turso.Connection) -> (turso.Error, bool) {
			_, e, ok := turso.conn_exec(conn, "SELECT 1")
			return e, ok
		}},
		{"conn_exec_args", proc(conn: turso.Connection) -> (turso.Error, bool) {
			_, e, ok := turso.conn_exec_args(conn, "SELECT ?", turso.bind_int(1))
			return e, ok
		}},
		{"conn_exec_batch", proc(conn: turso.Connection) -> (turso.Error, bool) {
			_, e, ok := turso.conn_exec_batch(conn, "CREATE TABLE x(v)")
			return e, ok
		}},
	}

	for tc in cases {
		t := test_db_open_memory()
		_, _ = turso.conn_close(&t.conn)
		defer test_db_close(&t)

		e, ok := tc.call(t.conn)
		defer turso.error_destroy(&e)
		expect_false(ok, tc.name)
		expect_eq(e.code, turso.Status_Code.MISUSE, tc.name)
	}
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
