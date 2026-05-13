package tests

import turso "../turso"

// bind_bool / bind_i32 / bind_u64 / bind_f32 widen at the call site so callers
// do not have to spell `bind_int(i64(...))` for every non-i64 numeric. SQLite
// stores all integers as i64 and all floats as f64; these helpers stay aligned
// with the storage layout.

test_bind_bool_roundtrip :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	_, e1, ok1 := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_bool(true))
	expect_no_err(e1, ok1, "bind_bool(true)")
	_, e2, ok2 := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_bool(false))
	expect_no_err(e2, ok2, "bind_bool(false)")

	stmt := prep_ok(t.conn, "SELECT v FROM t ORDER BY rowid")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	expect_eq(turso.stmt_get_int(stmt, 0), i64(1), "bind_bool(true) stores as 1")
	step_expect_row(stmt)
	expect_eq(turso.stmt_get_int(stmt, 0), i64(0), "bind_bool(false) stores as 0")
}

test_bind_small_int_widens :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_i32(-42))
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_i16(7))
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_u32(0xDEADBEEF))

	got, _, _ := turso.conn_scalar_i64(t.conn, "SELECT SUM(v) FROM t")
	expect_eq(got, i64(-42) + i64(7) + i64(0xDEADBEEF), "sized-int helpers preserve numeric value")
}

test_bind_u64_wraps_to_i64 :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	// 0xFFFF_FFFF_FFFF_FFFF (max u64) transmutes to -1 as i64. The roundtrip
	// must therefore yield -1, matching how SQLite stores unsigned 64-bit
	// values in INTEGER columns.
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_u64(0xFFFF_FFFF_FFFF_FFFF))
	got, _, _ := turso.conn_scalar_i64(t.conn, "SELECT v FROM t LIMIT 1")
	expect_eq(got, i64(-1), "u64 max wraps to -1 as i64")
}

test_bind_f32_widens_to_f64 :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v REAL)")

	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_f32(0.5))
	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	expect_eq(turso.stmt_get_double(stmt, 0), 0.5, "bind_f32 widens to f64 exactly for 0.5")
}
