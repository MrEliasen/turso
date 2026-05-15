package tests

import turso "../turso"

// conn_exec_batch runs every statement in a multi-statement string. Mirrors
// the Go binding's TestMultiStatementExecution and the Rust binding's
// `Connection::execute_batch`.

test_exec_batch_runs_ddl_plus_inserts :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	script :: "CREATE TABLE t(v INTEGER); INSERT INTO t(v) VALUES (1); INSERT INTO t(v) VALUES (2); INSERT INTO t(v) VALUES (3);"
	rows, e, ok := turso.conn_exec_batch(t.conn, script)
	expect_no_err(e, ok, "exec_batch script")
	expect_eq(rows, u64(3), "cumulative rows-affected across the three INSERTs")

	count, _, _ := turso.conn_scalar_i64(t.conn, "SELECT COUNT(*) FROM t")
	expect_eq(count, i64(3), "three rows visible after the batch ran")
}

test_exec_batch_stops_on_error :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	// First two statements succeed, third fails (table doesn't exist),
	// fourth never runs. The batch returns the first failing statement's
	// error and leaves the table from the first two statements committed.
	script :: "CREATE TABLE t(v INTEGER); INSERT INTO t(v) VALUES (1); INSERT INTO nope(v) VALUES (2); INSERT INTO t(v) VALUES (3);"
	rows, e, ok := turso.conn_exec_batch(t.conn, script)
	defer turso.error_destroy(&e)
	expect_false(ok, "batch with a bad statement must surface the failure")
	expect_eq(rows, u64(1), "rows-affected reflects the successful INSERT before the failure")

	count, _, _ := turso.conn_scalar_i64(t.conn, "SELECT COUNT(*) FROM t")
	expect_eq(count, i64(1), "the post-failure INSERT did not run")
}

test_exec_batch_on_closed_connection_returns_misuse :: proc() {
	t := test_db_open_memory()
	_, _ = turso.conn_close(&t.conn)
	defer test_db_close(&t)

	_, e, ok := turso.conn_exec_batch(t.conn, "CREATE TABLE x(v)")
	defer turso.error_destroy(&e)
	expect_false(ok, "exec_batch on closed connection must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "closed-connection misuse")
}

test_exec_batch_with_only_whitespace_succeeds :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	rows, e, ok := turso.conn_exec_batch(t.conn, "  \n\t  ")
	expect_no_err(e, ok, "whitespace-only script is a no-op")
	expect_eq(rows, u64(0), "no rows affected by whitespace-only script")
}
