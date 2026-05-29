package tests

import turso "../turso"

// [A5] Positional binds are 1-based. A position <= 0 must be rejected with a
// typed MISUSE rather than reaching the FFI, where the `uint(position)` cast
// would turn -1 into a huge unsigned value (and 0 would slip through as an
// invalid 0-based position).

test_bind_int_zero_position_returns_misuse :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT ?")
	defer finalize_ok(&stmt)

	e, ok := turso.stmt_bind_int(stmt, 0, 42)
	defer turso.error_destroy(&e)
	expect_false(ok, "bind at position 0 must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "position 0 surfaces MISUSE")
}

test_bind_int_negative_position_returns_misuse :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT ?")
	defer finalize_ok(&stmt)

	e, ok := turso.stmt_bind_int(stmt, -1, 42)
	defer turso.error_destroy(&e)
	expect_false(ok, "bind at position -1 must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "position -1 surfaces MISUSE")
}

// The guard lives in must_be_valid_position, shared by every positional binder.
// Exercise each kind so a future regression on any one binder is caught.
test_bind_all_kinds_reject_non_positive_position :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT ?")
	defer finalize_ok(&stmt)

	{
		e, ok := turso.stmt_bind_null(stmt, 0)
		defer turso.error_destroy(&e)
		expect_false(ok, "stmt_bind_null position 0")
		expect_eq(e.code, turso.Status_Code.MISUSE, "stmt_bind_null position 0 MISUSE")
	}
	{
		e, ok := turso.stmt_bind_double(stmt, -1, 1.0)
		defer turso.error_destroy(&e)
		expect_false(ok, "stmt_bind_double position -1")
		expect_eq(e.code, turso.Status_Code.MISUSE, "stmt_bind_double position -1 MISUSE")
	}
	{
		e, ok := turso.stmt_bind_text(stmt, 0, "x")
		defer turso.error_destroy(&e)
		expect_false(ok, "stmt_bind_text position 0")
		expect_eq(e.code, turso.Status_Code.MISUSE, "stmt_bind_text position 0 MISUSE")
	}
	{
		e, ok := turso.stmt_bind_blob(stmt, -5, []u8{0x01})
		defer turso.error_destroy(&e)
		expect_false(ok, "stmt_bind_blob position -5")
		expect_eq(e.code, turso.Status_Code.MISUSE, "stmt_bind_blob position -5 MISUSE")
	}
}

// Regression: a valid 1-based bind still works after adding the guard.
test_bind_int_position_one_still_works :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	stmt := prep_ok(t.conn, "INSERT INTO t(v) VALUES (?)")
	be, bok := turso.stmt_bind_int(stmt, 1, 99)
	expect_no_err(be, bok, "valid 1-based bind succeeds")
	_, ee, eok := turso.execute(stmt)
	expect_no_err(ee, eok, "execute after valid bind")
	finalize_ok(&stmt)

	got, _, _ := turso.conn_scalar_i64(t.conn, "SELECT v FROM t LIMIT 1")
	expect_eq(got, i64(99), "bound value persisted")
}
