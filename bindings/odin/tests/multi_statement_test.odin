package tests

import turso "../turso"

test_prepare_first_loop :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	sql := "CREATE TABLE t(a INTEGER); INSERT INTO t(a) VALUES (1); SELECT a FROM t;"
	remaining := sql
	saw_select := false

	for len(remaining) > 0 {
		stmt, tail, err, ok := turso.prepare_first(t.conn, remaining)
		expect_no_err(err, ok, "prepare_first")
		if !turso.stmt_is_open(stmt) {
			// No more statements parseable.
			break
		}

		col_count := turso.column_count(stmt)
		if col_count > 0 {
			// Row-producing - step through.
			saw_select = true
			step_expect_row(stmt)
			expect_eq(turso.stmt_get_int(stmt, 0), i64(1), "SELECT in multi-statement yields 1")
			step_expect_done(stmt)
		} else {
			_, e2, ok2 := turso.execute(stmt)
			expect_no_err(e2, ok2, "execute non-row stmt")
		}

		_, _ = turso.finalize(&stmt)
		remaining = remaining[tail:]
	}

	expect_true(saw_select, "the SELECT statement was reached")
}
