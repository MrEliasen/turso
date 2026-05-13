package tests

import turso "../turso"

// Post-audit, stmt_scan_struct uses a two-pass design: pass 1 validates every
// column's kind against its target field's type WITHOUT allocating; pass 2
// only runs after every column passed validation, so no half-populated
// allocations are possible on a type-mismatch error.
//
// This test exercises the mismatch path: column 0 is a TEXT, column 1 is
// INTEGER, but the destination field for column 1 is `string`. Pass 1
// catches the kind mismatch on column 1; no allocation for column 0 ever
// happens. Tracking allocator should show zero allocations attributable to
// this scan.

@(private="file")
Bad_Row :: struct {
	a: string,  // matches column "a" TEXT — never reached because validation fails first
	b: string,  // matches column "b" but column is INTEGER → mismatch
}

test_stmt_scan_struct_partial_failure_leaks_earlier_text_field :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(a TEXT, b INTEGER)")
	_, _, _ = turso.db_exec_args(t.conn, "INSERT INTO t(a, b) VALUES (?, ?)",
		turso.bind_text("payload-bytes-that-would-have-leaked"), turso.bind_int(42))

	stmt := prep_ok(t.conn, "SELECT a, b FROM t")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row: Bad_Row
	e, ok := turso.stmt_scan_struct(stmt, &row)
	expect_false(ok, "type mismatch on column b must surface as error")
	turso.error_destroy(&e)

	// With the pre-allocation validation, row.a is never written.
	expect_eq(len(row.a), 0, "row.a must be untouched when validation fails before allocation")
	expect_eq(len(row.b), 0, "row.b must be untouched when validation fails before allocation")
}
