package tests

import turso "../turso"

test_column_name :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT 1 AS x, 'a' AS y")
	defer finalize_ok(&stmt)

	n0 := turso.stmt_column_name(stmt, 0); defer delete(n0)
	n1 := turso.stmt_column_name(stmt, 1); defer delete(n1)
	expect_eq(n0, "x", "column 0 alias is x")
	expect_eq(n1, "y", "column 1 alias is y")
}

test_column_decltype :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(a INTEGER, b TEXT)")

	stmt := prep_ok(t.conn, "SELECT a, b FROM t")
	defer finalize_ok(&stmt)

	dt0 := turso.stmt_column_decltype(stmt, 0); defer delete(dt0)
	dt1 := turso.stmt_column_decltype(stmt, 1); defer delete(dt1)
	expect_eq(dt0, "INTEGER", "column 0 decltype is INTEGER")
	expect_eq(dt1, "TEXT", "column 1 decltype is TEXT")
}

test_row_value_kinds :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(i INTEGER, r REAL, s TEXT, b BLOB, n)")

	_, e, ok := turso.db_exec_args(
		t.conn,
		"INSERT INTO t(i, r, s, b, n) VALUES (?, ?, ?, ?, ?)",
		turso.bind_int(7),
		turso.bind_double(1.5),
		turso.bind_text("k"),
		turso.bind_blob([]u8{0xab, 0xcd}),
		turso.bind_null(),
	)
	expect_no_err(e, ok, "insert all kinds")

	stmt := prep_ok(t.conn, "SELECT i, r, s, b, n FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	expect_eq(turso.stmt_value_kind(stmt, 0), turso.Value_Kind.INTEGER, "col 0 is INTEGER")
	expect_eq(turso.stmt_value_kind(stmt, 1), turso.Value_Kind.REAL,    "col 1 is REAL")
	expect_eq(turso.stmt_value_kind(stmt, 2), turso.Value_Kind.TEXT,    "col 2 is TEXT")
	expect_eq(turso.stmt_value_kind(stmt, 3), turso.Value_Kind.BLOB,    "col 3 is BLOB")
	expect_eq(turso.stmt_value_kind(stmt, 4), turso.Value_Kind.NULL,    "col 4 is NULL")
}

test_get_text_independence :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT 'persist'")
	step_expect_row(stmt)
	s := turso.stmt_get_text(stmt, 0)
	defer delete(s)
	// finalize while still holding the string - the copy should remain valid.
	finalize_ok(&stmt)
	expect_eq(s, "persist", "text survives finalize because we copy")
}

test_get_blob_independence :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(b BLOB)")
	payload := []u8{9, 9, 9, 9}
	_, e, ok := turso.db_exec_args(t.conn, "INSERT INTO t(b) VALUES (?)", turso.bind_blob(payload))
	expect_no_err(e, ok, "insert blob")

	stmt := prep_ok(t.conn, "SELECT b FROM t LIMIT 1")
	step_expect_row(stmt)
	got := turso.stmt_get_blob(stmt, 0)
	defer delete(got)
	finalize_ok(&stmt)

	expect_eq(len(got), 4, "blob length preserved post-finalize")
	for b in got {
		expect_eq(b, u8(9), "blob bytes preserved post-finalize")
	}
}
