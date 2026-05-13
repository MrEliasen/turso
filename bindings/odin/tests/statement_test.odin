package tests

import turso "../turso"

test_prepare_simple :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT 1")
	defer finalize_ok(&stmt)

	step_expect_row(stmt)
	expect_eq(turso.stmt_get_int(stmt, 0), i64(1), "SELECT 1 returns 1")
	step_expect_done(stmt)
}

test_prepare_invalid :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt, err, ok := turso.prepare(t.conn, "THIS IS NOT SQL")
	defer turso.error_destroy(&err)
	expect_false(ok, "preparing garbage should fail")
	expect_false(turso.stmt_is_open(stmt), "statement handle should be nil on failure")
}

test_column_count_after_prepare :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT 1, 2, 3")
	defer finalize_ok(&stmt)

	expect_eq(turso.column_count(stmt), i64(3), "column_count for SELECT 1,2,3 is 3")
}

test_reset_after_step :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT 42")
	defer finalize_ok(&stmt)

	step_expect_row(stmt)
	expect_eq(turso.stmt_get_int(stmt, 0), i64(42), "first step yields 42")

	e, ok := turso.reset(stmt)
	expect_no_err(e, ok, "reset")

	step_expect_row(stmt)
	expect_eq(turso.stmt_get_int(stmt, 0), i64(42), "second step after reset still yields 42")
}

test_n_change_zero_for_select :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")
	exec_ok(t.conn, "INSERT INTO t(v) VALUES (1), (2), (3)")

	stmt := prep_ok(t.conn, "SELECT v FROM t")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	expect_eq(turso.n_change(stmt), i64(0), "n_change for SELECT is 0")
}
