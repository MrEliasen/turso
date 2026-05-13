package tests

import "core:strings"
import turso "../turso"

// Every input the binding eventually hands to a C-string boundary must reject
// an embedded NUL byte rather than silently truncating the value. Without
// these guards, a developer who constructs SQL from arbitrary bytes (or who
// loads a config value via a parser that allows NUL) would run a different
// query than they wrote.
//
// The Rust C ABI reads each cstring with CStr::from_ptr, which stops at the
// first NUL, so any post-NUL bytes never reach the engine.

@(private="file")
nul_string :: proc(prefix: string, suffix: string) -> string {
	parts := [3]string{prefix, "\x00", suffix}
	return strings.concatenate(parts[:])
}

test_prepare_rejects_sql_with_embedded_nul :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	sql := nul_string("SELECT 1", "; DROP TABLE marker; --")
	defer delete(sql)

	stmt, e, ok := turso.prepare(t.conn, sql)
	expect_false(ok, "prepare with NUL-bearing SQL must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "NUL in SQL surfaces MISUSE")
	expect_true(!turso.stmt_is_open(stmt), "no statement handle on failure")
	turso.error_destroy(&e)
}

test_prepare_first_rejects_sql_with_embedded_nul :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	sql := nul_string("SELECT 1; SELECT 2", "; SELECT 3")
	defer delete(sql)

	stmt, _, e, ok := turso.prepare_first(t.conn, sql)
	expect_false(ok, "prepare_first with NUL-bearing SQL must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "NUL in SQL surfaces MISUSE")
	expect_true(!turso.stmt_is_open(stmt), "no statement handle on failure")
	turso.error_destroy(&e)
}

test_database_open_rejects_path_with_embedded_nul :: proc() {
	path := nul_string(":memory:", "/etc/passwd")
	defer delete(path)

	db, e, ok := turso.database_open(turso.Database_Config{path = path})
	expect_false(ok, "database_open with NUL-bearing path must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "NUL in path surfaces MISUSE")
	expect_true(!turso.db_is_open(db), "no db handle on failure")
	turso.error_destroy(&e)
}

test_database_open_rejects_features_with_embedded_nul :: proc() {
	features := nul_string("encryption", ",hostile_feature")
	defer delete(features)

	db, e, ok := turso.database_open(turso.Database_Config{
		path                  = ":memory:",
		experimental_features = features,
	})
	expect_false(ok, "database_open with NUL-bearing features must fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "NUL in experimental_features surfaces MISUSE")
	expect_true(!turso.db_is_open(db), "no db handle on failure")
	turso.error_destroy(&e)
}

test_param_position_returns_not_found_for_nul_name :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT :a")
	defer finalize_ok(&stmt)

	name := nul_string(":a", "; DROP TABLE marker")
	defer delete(name)

	pos, found := turso.stmt_param_position(stmt, name)
	expect_false(found, "param name with NUL byte must be treated as not-found")
	expect_eq(pos, 0, "param position is 0 when not found")
}
