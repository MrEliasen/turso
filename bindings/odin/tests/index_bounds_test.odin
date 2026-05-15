package tests

import turso "../turso"

// Out-of-range and negative-index behavior for the column accessors. The
// binding documents that `index < 0` returns the zero value; this file pins
// that contract AND the symmetric upper-bound behavior so the C ABI never
// gets handed an unchecked index.

test_stmt_get_int_negative_index_returns_zero :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	stmt := prep_ok(t.conn, "SELECT 42")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	expect_eq(turso.stmt_get_int(stmt, -1), i64(0), "negative index returns zero")
	expect_eq(turso.stmt_get_double(stmt, -5), f64(0), "negative index returns zero for double")
	expect_eq(turso.stmt_value_kind(stmt, -1), turso.Value_Kind.UNKNOWN, "negative index → UNKNOWN kind")
}

test_stmt_get_text_negative_index_returns_empty :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	stmt := prep_ok(t.conn, "SELECT 'value'")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	got := turso.stmt_get_text(stmt, -1)
	defer delete(got)
	expect_eq(len(got), 0, "negative index returns empty string")

	blob := turso.stmt_get_blob(stmt, -1)
	defer delete(blob)
	expect_true(blob == nil, "negative index returns nil blob")
}

test_stmt_column_name_negative_index_returns_empty :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	stmt := prep_ok(t.conn, "SELECT 1 AS a")
	defer finalize_ok(&stmt)

	name := turso.stmt_column_name(stmt, -1)
	defer delete(name)
	expect_eq(len(name), 0, "negative index returns empty column name")

	decl := turso.stmt_column_decltype(stmt, -1)
	defer delete(decl)
	expect_eq(len(decl), 0, "negative index returns empty decltype")
}

test_stmt_param_name_non_positive_index_returns_empty :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	stmt := prep_ok(t.conn, "SELECT :a, :b")
	defer finalize_ok(&stmt)

	zero := turso.stmt_param_name(stmt, 0); defer delete(zero)
	expect_eq(len(zero), 0, "index 0 returns empty (parameters are 1-indexed)")

	negative := turso.stmt_param_name(stmt, -1); defer delete(negative)
	expect_eq(len(negative), 0, "negative index returns empty parameter name")
}
