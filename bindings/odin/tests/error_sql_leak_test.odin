package tests

import turso "../turso"

// Post-audit, Error.sql is owned by the Error and freed by error_destroy. So
// any error path that previously cloned the SQL (and leaked the clone) now
// gets cleaned up when the caller calls error_destroy. The tracking allocator
// in tests/main.odin will catch any regression on this contract.

@(private="file")
Row :: struct {
	id: i64,
	v:  i64,
}

test_db_query_one_struct_error_clones_sql_and_leaks :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")
	r: Row
	e, ok := turso.db_query_one_struct(t.conn, "SELECT id, v FROM t", &r)
	expect_false(ok, "must report error on zero rows")
	// error_destroy now frees both message and sql; tracking allocator should
	// report zero leaks after this returns.
	turso.error_destroy(&e)
}
