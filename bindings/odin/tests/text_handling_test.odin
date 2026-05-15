package tests

import "core:strings"
import turso "../turso"

// UTF-8 and embedded-NUL handling for TEXT values. SQLite treats TEXT as an
// opaque byte slice with a declared kind; the binding's contract is that
// (ptr, len) round-trips byte-exact, regardless of content. These tests pin
// that contract so a future refactor can't silently start truncating on NUL
// or mangling multibyte sequences.

test_bind_text_unicode_roundtrip :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v TEXT)")

	// Mix of: ASCII, Latin-1 supplement, CJK, an emoji (4-byte UTF-8). The
	// emoji is the trickiest case because it forces the binding's TEXT path
	// to handle a 4-byte sequence without splitting.
	payload :: "Hello, 世界! héllo café 🦀"
	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text(payload))
	expect_no_err(e, ok, "insert UTF-8 text")

	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	got := turso.stmt_get_text(stmt, 0)
	defer delete(got)
	expect_eq(got, payload, "UTF-8 text roundtrip is byte-exact")
}

// Embedded NUL bytes are legal SQL TEXT (the C ABI takes ptr + len, not a
// C-string). Verify round-trip both for the bind and the column read paths.
test_bind_text_with_embedded_nul_roundtrip :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v TEXT)")

	parts := [3]string{"prefix", "\x00", "suffix"}
	payload := strings.concatenate(parts[:])
	defer delete(payload)

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text(payload))
	expect_no_err(e, ok, "insert text with embedded NUL")

	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	got, gok := turso.stmt_get_text_ok(stmt, 0)
	defer delete(got)
	expect_true(gok, "stmt_get_text_ok reports the value as a real (non-NULL) TEXT")
	expect_eq(len(got), len(payload), "byte length preserved across NUL")
	expect_eq(got, payload, "text round-trips byte-exact through the engine")
}

// stmt_column_name should pass UTF-8 column aliases through unchanged. This
// guards against an accidental ASCII assumption in the C string cloning path.
test_column_name_utf8_alias :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, `SELECT 1 AS "数値", 2 AS "café"`)
	defer finalize_ok(&stmt)

	n0 := turso.stmt_column_name(stmt, 0); defer delete(n0)
	n1 := turso.stmt_column_name(stmt, 1); defer delete(n1)
	expect_eq(n0, "数値", "CJK column alias preserved byte-for-byte")
	expect_eq(n1, "café", "Latin-1 supplement alias preserved byte-for-byte")
}
