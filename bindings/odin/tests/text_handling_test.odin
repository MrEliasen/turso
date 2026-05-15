package tests

import "core:strings"
import turso "../turso"

// Text-handling FFI boundary. Multibyte UTF-8 roundtrip is a core engine
// concern and the binding only relays bytes, so those variants live in
// core's sqltests. What the binding owns is the (ptr, len) contract: a
// TEXT value with an embedded NUL must survive both the bind and the
// column-read paths because the C ABI uses pointer + length, not a
// C-string.

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
