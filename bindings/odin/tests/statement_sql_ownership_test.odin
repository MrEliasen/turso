package tests

import "core:strings"
import turso "../turso"

// Regression tests for M1: prepare and prepare_first MUST clone the caller's
// SQL into the returned Statement. The Statement owns the clone for its
// lifetime and finalize releases it. After prepare returns, the caller may
// free, reuse, or mutate the original SQL buffer without affecting the
// Statement.
//
// The tests below pin both halves of the contract:
//   1. Caller mutates the original buffer in place after prepare. With a
//      true clone, the Statement's view (surfaced through Error.sql on a
//      step failure) keeps the original bytes. With a borrow, the Error
//      would carry the mutated text.
//   2. Caller frees the original buffer immediately after prepare. With a
//      clone, step, execute, and finalize continue to work. With a borrow,
//      finalize would either leak the binding's never-cloned memory or
//      hit a use-after-free reading stmt.sql.
//
// The tracking allocator wired into main.odin catches the symmetric leak
// regression: if prepare allocates the clone but finalize forgets to free it,
// the leak report is non-empty.

test_prepare_owns_sql_when_caller_mutates_buffer :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")
	exec_ok(t.conn, "INSERT INTO t(id, v) VALUES (1, 100)")

	original := "INSERT INTO t(id, v) VALUES (1, 999)"
	sql := strings.clone(original)
	defer delete(sql)

	stmt, err, ok := turso.prepare(t.conn, sql)
	expect_no_err(err, ok, "prepare succeeds on cloned-input SQL")

	// Mutate the caller's buffer in place. A correct binding has already
	// cloned into stmt.sql, so the original bytes no longer matter; a borrow
	// regression would expose this overwrite through Error.sql on the
	// upcoming UNIQUE violation.
	mutable := transmute([]u8)sql
	for i in 0 ..< len(mutable) { mutable[i] = 'X' }

	_, e2, e2ok := turso.execute(stmt)
	expect_false(e2ok, "execute on UNIQUE violation must fail")
	defer turso.error_destroy(&e2)
	expect_string_contains(e2.sql, original, "Error.sql preserves the original SQL")
	expect_false(strings.contains(e2.sql, "XXXXX"), "Error.sql not corrupted by caller mutation")

	fe, fok := turso.finalize(&stmt)
	expect_no_err(fe, fok, "finalize releases the clone cleanly")
}

test_prepare_clones_sql_so_caller_can_free_immediately :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")

	sql := strings.clone("INSERT INTO t(id, v) VALUES (1, 100)")
	stmt, err, ok := turso.prepare(t.conn, sql)
	expect_no_err(err, ok, "prepare clones sql so caller-frees is safe")

	delete(sql)

	rows, ee, eok := turso.execute(stmt)
	expect_no_err(ee, eok, "execute after caller-free")
	expect_eq(rows, u64(1), "INSERT executed exactly once")

	fe, fok := turso.finalize(&stmt)
	expect_no_err(fe, fok, "finalize releases clone without UAF")
}

test_prepare_first_clones_sql_so_caller_can_free_immediately :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")

	sql := strings.clone("INSERT INTO t(id, v) VALUES (1, 100); INSERT INTO t(id, v) VALUES (2, 200);")
	stmt, _, err, ok := turso.prepare_first(t.conn, sql)
	expect_no_err(err, ok, "prepare_first clones sql")

	delete(sql)

	rows, ee, eok := turso.execute(stmt)
	expect_no_err(ee, eok, "execute prepare_first stmt after caller-free")
	expect_eq(rows, u64(1), "first INSERT executed once")

	fe, fok := turso.finalize(&stmt)
	expect_no_err(fe, fok, "finalize prepare_first stmt")
}
