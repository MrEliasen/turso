package tests

import turso "../turso"

// [A4] conn_scalar_i64 must require an INTEGER result. stmt_get_int yields 0
// for NULL/TEXT/REAL/BLOB, so before the fix a non-integer scalar silently
// reported 0 as a valid answer. This is a deliberate behaviour change: a
// non-INTEGER first column is now a typed ERROR naming the actual kind.

test_conn_scalar_i64_integer_result :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	got, e, ok := turso.conn_scalar_i64(t.conn, "SELECT 5")
	expect_no_err(e, ok, "SELECT 5 is an INTEGER scalar")
	expect_eq(got, i64(5), "SELECT 5 returns 5")
}

test_conn_scalar_i64_text_result_errors :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	got, e, ok := turso.conn_scalar_i64(t.conn, "SELECT 'x'")
	defer turso.error_destroy(&e)
	expect_false(ok, "SELECT 'x' is TEXT, not INTEGER, and must error")
	expect_eq(e.code, turso.Status_Code.ERROR, "non-integer scalar surfaces ERROR")
	expect_eq(got, i64(0), "no integer value is returned on the error path")
	expect_string_contains(e.message, "TEXT", "error names the actual kind")
}

// A REAL result must also be rejected: the silent stmt_get_int(0) coercion
// would have returned 0, not the rounded/truncated value, which is exactly the
// silent type mismatch [A4] closes.
test_conn_scalar_i64_real_result_errors :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	got, e, ok := turso.conn_scalar_i64(t.conn, "SELECT 1.5")
	defer turso.error_destroy(&e)
	expect_false(ok, "SELECT 1.5 is REAL, not INTEGER, and must error")
	expect_eq(e.code, turso.Status_Code.ERROR, "non-integer scalar surfaces ERROR")
	expect_eq(got, i64(0), "no integer value is returned on the error path")
	expect_string_contains(e.message, "REAL", "error names the actual kind")
}

// NULL must be rejected too (e.g. an aggregate over an empty set). Before the
// fix this returned 0, indistinguishable from a genuine 0 count.
test_conn_scalar_i64_null_result_errors :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	got, e, ok := turso.conn_scalar_i64(t.conn, "SELECT NULL")
	defer turso.error_destroy(&e)
	expect_false(ok, "SELECT NULL has no INTEGER value and must error")
	expect_eq(e.code, turso.Status_Code.ERROR, "NULL scalar surfaces ERROR")
	expect_eq(got, i64(0), "no integer value is returned on the error path")
	expect_string_contains(e.message, "NULL", "error names the actual kind")
}
