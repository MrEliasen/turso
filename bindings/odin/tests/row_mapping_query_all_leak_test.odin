package tests

import turso "../turso"

// conn_query_all_struct must release every TEXT/BLOB field of rows that were
// already scanned when a later row fails to coerce into the target type.
// Without the cleanup pass, row 1's TEXT allocation leaks once row 2's kind
// mismatch aborts the loop. The tracking allocator in tests/main.odin asserts
// zero leaks at the end of the run, so this test catches a regression on the
// cleanup path.

@(private="file")
Text_Row :: struct {
	v: string,
}

test_query_all_struct_frees_partial_rows_on_type_mismatch :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	// Untyped column: SQLite stores each value with its own kind. The first
	// row is TEXT (matches Text_Row.v), the second is INTEGER (mismatch on
	// pass 1 of stmt_scan_struct → error after row 1 is already in `out`).
	exec_ok(t.conn, "CREATE TABLE t(v)")
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text("payload-that-must-not-leak"))
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_int(42))

	rows, e, ok := turso.conn_query_all_struct(Text_Row, t.conn, "SELECT v FROM t ORDER BY rowid")
	defer turso.error_destroy(&e)
	expect_false(ok, "kind mismatch on row 2 must surface as error")
	expect_true(rows == nil, "rows slice must be nil on error so caller never sees a partial result")
}

// conn_query_one_struct returns an error when the query yields more than one
// row, but only after stmt_scan_struct has already populated `out`. The
// binding must release any TEXT/BLOB field allocated into `out` so the caller,
// who got ok=false, is not on the hook for cleanup of a struct they never
// asked for.

@(private="file")
Named_Row :: struct {
	name: string,
}

test_query_one_struct_frees_out_on_too_many_rows :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	exec_ok(t.conn, "CREATE TABLE t(name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(name) VALUES (?)", turso.bind_text("alice"))
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(name) VALUES (?)", turso.bind_text("bob"))

	row: Named_Row
	e, ok := turso.conn_query_one_struct(t.conn, "SELECT name FROM t ORDER BY rowid", &row)
	defer turso.error_destroy(&e)
	expect_false(ok, "two-row result on query_one must surface as error")
	expect_eq(len(row.name), 0, "out^ must be zeroed after the two-rows error path frees the partially-scanned TEXT field")
}

// Same shape as the test above but exercising conn_query_optional_struct's
// two-rows error path. Verifies the same free_owned_out call.

test_query_optional_struct_frees_out_on_too_many_rows :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	exec_ok(t.conn, "CREATE TABLE t(name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(name) VALUES (?)", turso.bind_text("first"))
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(name) VALUES (?)", turso.bind_text("second"))

	row: Named_Row
	found, e, ok := turso.conn_query_optional_struct(t.conn, "SELECT name FROM t ORDER BY rowid", &row)
	defer turso.error_destroy(&e)
	expect_false(ok, "two-row result on query_optional must surface as error")
	expect_false(found, "found must be false on error")
	expect_eq(len(row.name), 0, "out^ must be zeroed after the two-rows error path frees the partially-scanned TEXT field")
}
