package tests

import turso "../turso"

test_async_io_basic_operations :: proc() {
	cfg := turso.Database_Config{
		path     = ":memory:",
		async_io = true,
	}
	db, err, ok := turso.database_open(cfg)
	expect_no_err(err, ok, "open with async_io=true")
	defer turso.database_close(&db)
	conn, e2, ok2 := turso.connect(db)
	expect_no_err(e2, ok2, "connect with async_io=true")
	defer { _, _ = turso.conn_close(&conn) }

	exec_ok(conn, "CREATE TABLE t(v INTEGER)")
	exec_ok(conn, "INSERT INTO t(v) VALUES (1), (2), (3)")

	count, e3, ok3 := turso.db_scalar_i64(conn, "SELECT COUNT(*) FROM t")
	expect_no_err(e3, ok3, "scalar count with async_io")
	expect_eq(count, i64(3), "3 rows inserted with async_io")
}

test_async_io_step_iteration :: proc() {
	cfg := turso.Database_Config{
		path     = ":memory:",
		async_io = true,
	}
	db, err, ok := turso.database_open(cfg)
	expect_no_err(err, ok, "open with async_io=true")
	defer turso.database_close(&db)
	conn, _, _ := turso.connect(db)
	defer { _, _ = turso.conn_close(&conn) }

	exec_ok(conn, "CREATE TABLE t(v INTEGER)")
	for i in 1 ..= 5 {
		_, _, _ = turso.db_exec_args(conn, "INSERT INTO t(v) VALUES (?)", turso.bind_int(i64(i)))
	}

	stmt := prep_ok(conn, "SELECT v FROM t ORDER BY v")
	defer finalize_ok(&stmt)

	sum: i64 = 0
	for {
		r, e, ok := turso.step(stmt)
		expect_no_err(e, ok, "step in async_io mode")
		if r != .Row { break }
		sum += turso.stmt_get_int(stmt, 0)
	}
	expect_eq(sum, i64(15), "sum of 1..5 with async_io step loop")
}

// test_async_io_step_once_manual_drive exercises the explicit step_once + run_io path
// for callers wanting event-loop integration. Drives until DONE/ROW.
test_async_io_step_once_manual_drive :: proc() {
	cfg := turso.Database_Config{
		path     = ":memory:",
		async_io = true,
	}
	db, err, ok := turso.database_open(cfg)
	expect_no_err(err, ok, "open with async_io=true")
	defer turso.database_close(&db)
	conn, _, _ := turso.connect(db)
	defer { _, _ = turso.conn_close(&conn) }

	stmt := prep_ok(conn, "SELECT 7")
	defer finalize_ok(&stmt)

	saw_row := false
	io_loops := 0
	for {
		code, e, ok := turso.step_once(stmt)
		expect_no_err(e, ok, "step_once")
		#partial switch code {
		case .ROW:
			expect_eq(turso.stmt_get_int(stmt, 0), i64(7), "step_once row value")
			saw_row = true
		case .DONE:
			expect_true(saw_row, "DONE only after ROW")
			return
		case .IO:
			io_loops += 1
			if io_loops > 100 { test_fail({}, "run_io looped too many times") }
			e2, ok2 := turso.run_io(stmt)
			expect_no_err(e2, ok2, "manual run_io")
		case:
			test_fail({}, "unexpected status: %v", code)
		}
	}
}
