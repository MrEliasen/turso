package tests

import turso "../turso"

test_db_exec_ddl :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	rows, e, ok := turso.db_exec(t.conn, "CREATE TABLE t(a INTEGER)")
	expect_no_err(e, ok, "DDL")
	expect_eq(rows, u64(0), "DDL affects 0 rows")
}

test_insert_two_and_count :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")
	exec_ok(t.conn, "INSERT INTO t(v) VALUES (1)")
	exec_ok(t.conn, "INSERT INTO t(v) VALUES (2)")
	n, e, ok := turso.db_scalar_i64(t.conn, "SELECT COUNT(*) FROM t")
	expect_no_err(e, ok, "scalar count")
	expect_eq(n, i64(2), "row count after two inserts")
}

test_last_insert_rowid :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")
	exec_ok(t.conn, "INSERT INTO t(v) VALUES (10)")
	rid := turso.last_insert_rowid(t.conn)
	expect_true(rid > 0, "last_insert_rowid is positive after INSERT")
}
