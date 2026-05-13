package tests

import "core:strings"
import turso "../turso"

// Adversarial savepoint name tests. The build_savepoint_sql helper claims to
// "double-quote names with escaping, safe for reserved words / unusual
// identifiers". These tests verify:
//   - embedded double-quotes are doubled correctly
//   - the engine rejects (rather than executes) injection payloads
//   - existing-table integrity is preserved across savepoint cycles

@(private="file")
quoting_setup :: proc(name: string) -> Test_DB {
	t := test_db_open_file(name)
	exec_ok(t.conn, "CREATE TABLE marker(v INTEGER)")
	exec_ok(t.conn, "INSERT INTO marker(v) VALUES (1)")
	return t
}

@(private="file")
table_exists :: proc(conn: turso.Connection, name: string) -> bool {
	n, _, _ := turso.conn_scalar_i64(
		conn,
		"SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name=?",
		turso.bind_text(name),
	)
	return n > 0
}

// Names containing semicolons and SQL keywords. With correct double-quoting,
// the engine treats the whole payload as an identifier and the marker table
// survives untouched.
test_savepoint_name_with_injection_payload :: proc() {
	t := quoting_setup("savepoint_inject")
	defer test_db_close(&t)

	evil := `evil"; DROP TABLE marker; --`
	e, ok := turso.conn_with_savepoint(t.conn, evil, proc(c: turso.Connection) -> bool {
		return true
	})
	expect_no_err(e, ok, "savepoint with injection-shaped name must succeed under proper escaping")
	expect_true(table_exists(t.conn, "marker"), "marker table must survive savepoint cycle")
}

// Names whose only meta-char is a double quote — exact escaping check.
test_savepoint_name_with_embedded_double_quote :: proc() {
	t := quoting_setup("savepoint_dquote")
	defer test_db_close(&t)

	e, ok := turso.conn_with_savepoint(t.conn, `a"b`, proc(c: turso.Connection) -> bool {
		return true
	})
	expect_no_err(e, ok, `savepoint name a"b must be accepted (doubled-quote escape)`)
	expect_true(table_exists(t.conn, "marker"), "marker still there")
}

// NUL byte in name: the binding rejects up-front with a typed MISUSE error
// before any SQL is built. Post-NUL bytes never reach the engine.
test_savepoint_name_with_nul_byte :: proc() {
	t := quoting_setup("savepoint_nul")
	defer test_db_close(&t)

	parts := [3]string{"x", "\x00", "; DROP TABLE marker; --"}
	name_with_nul := strings.concatenate(parts[:])
	defer delete(name_with_nul)

	e, ok := turso.conn_savepoint(t.conn, name_with_nul)
	defer turso.error_destroy(&e)
	expect_false(ok, "savepoint with NUL byte must fail with a typed error")
	expect_eq(e.code, turso.Status_Code.MISUSE, "NUL byte triggers MISUSE")
	expect_true(table_exists(t.conn, "marker"), "marker must survive — post-NUL bytes never reach the engine")
}
