package tests

import "core:math"
import turso "../turso"

// Value-roundtrip tests at the edges of every SQL kind. Mirrors the boundary
// coverage in the Java JDBC suite (`JDBC4PreparedStatementTest.setInt`
// stress + the `bind_large_blob_test`) and the Go suite's `TestDataTypes`. The
// goal is to pin the C ABI plumbing for `size_t len`, `i64`, and `f64` against
// values that would expose any silent truncation or sign-bit confusion.

test_bind_int_boundary_i64_min :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_int(min(i64)))
	expect_no_err(e, ok, "bind min(i64)")

	got, ge, gok := turso.conn_scalar_i64(t.conn, "SELECT v FROM t LIMIT 1")
	expect_no_err(ge, gok, "scalar i64 min")
	expect_eq(got, min(i64), "min(i64) roundtrip")
}

test_bind_int_boundary_i64_max :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_int(max(i64)))
	expect_no_err(e, ok, "bind max(i64)")

	got, ge, gok := turso.conn_scalar_i64(t.conn, "SELECT v FROM t LIMIT 1")
	expect_no_err(ge, gok, "scalar i64 max")
	expect_eq(got, max(i64), "max(i64) roundtrip")
}

test_bind_double_special_values :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v REAL)")

	// Insert a small set of f64 values that historically have surfaced sign
	// or normalization issues in SQL bindings. Each is round-tripped via a
	// fresh prepared statement so the values come back in INSERT order.
	values := [?]f64{
		math.F64_MIN,                              // smallest normal positive
		math.F64_MAX,                              // largest finite
		math.inf_f64(1),                           // +Inf
		math.inf_f64(-1),                          // -Inf
		1e-300,                                    // subnormal-adjacent
		-1e300,                                    // large negative
	}
	for v in values {
		_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_double(v))
		expect_no_err(e, ok, "bind f64 boundary")
	}

	stmt := prep_ok(t.conn, "SELECT v FROM t ORDER BY rowid")
	defer finalize_ok(&stmt)
	for v in values {
		step_expect_row(stmt)
		got := turso.stmt_get_double(stmt, 0)
		expect_eq(got, v, "f64 boundary roundtrip")
	}
	step_expect_done(stmt)
}

// SQLite stores NaN as NULL (TEXT-of-NaN is not a number). The binding
// should still hand the NaN to the C ABI without faulting; the test just
// asserts the call sequence completes rather than asserting NaN-equals-NaN
// (which is never true by IEEE754 rules).
test_bind_double_nan_does_not_crash :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v REAL)")

	nan := math.nan_f64()
	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_double(nan))
	expect_no_err(e, ok, "bind NaN must not crash the binding")

	// Read it back; SQLite stores NaN as NULL, so we expect NULL kind.
	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	expect_true(turso.stmt_is_null(stmt, 0), "NaN insert is stored as NULL per SQLite semantics")
}

// One-megabyte BLOB: well past the default page size (4 KiB) so the engine
// has to walk overflow chains. Catches any truncation of `size_t` to `int`
// in the bind path and verifies that pointer arithmetic over a long slice
// stays correct end-to-end.
test_bind_blob_one_mb_roundtrip :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v BLOB)")

	N :: 1024 * 1024
	payload := make([]u8, N)
	defer delete(payload)
	for i in 0 ..< N {
		payload[i] = u8(i & 0xff)
	}

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_blob(payload))
	expect_no_err(e, ok, "bind 1MB blob")

	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	got := turso.stmt_get_blob(stmt, 0)
	defer delete(got)
	expect_eq(len(got), N, "1MB blob length preserved")
	// Spot-check the first byte, a midpoint, and the last byte to detect
	// any off-by-one in the overflow-chain reassembly.
	expect_eq(got[0],         u8(0),                "byte 0 preserved")
	expect_eq(got[N / 2],     u8((N / 2) & 0xff),   "midpoint byte preserved")
	expect_eq(got[N - 1],     u8((N - 1) & 0xff),   "last byte preserved")
}
