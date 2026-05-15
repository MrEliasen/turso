package tests

import "core:math"
import turso "../turso"

// Value-boundary tests. Most integer / double / blob boundary semantics live
// in core Turso's sqltests (storage, vdbe, parser); the binding's role is
// byte propagation through `i64`, `f64`, and `(ptr, len)`. The one boundary
// the binding owns is the SQLite-specific NaN-becomes-NULL policy: the
// binding must hand NaN to the C ABI without faulting AND the read-back
// path must honour the NULL kind.

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
