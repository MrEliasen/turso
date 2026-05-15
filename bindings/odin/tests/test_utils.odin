package tests

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import turso "../turso"

Test_DB :: struct {
	db:   turso.Database,
	conn: turso.Connection,
	path: string,  // "" for in-memory
}

// Test runner state. test_fail records the failure and longjmps back to the
// per-test setjmp landing pad in main, so the runner can surface the failure,
// move on to the next test, and still print the tracking allocator's leak
// report at the end. The test body's defers do not run on longjmp; the
// runner notes this in the final report so a noisy leak listing on a failing
// run is not mistaken for a binding regression.
//
// Threads spawned by a test must be joined before any expect_* in the test
// body, otherwise the longjmp leaves them running across the next test's
// setup.
test_jmp_buf: libc.jmp_buf
test_failed:  bool

test_fail :: proc(loc := #caller_location, format: string = "", args: ..any) -> ! {
	test_failed = true
	fmt.eprintf("[FAIL] %s:%d %s\n", loc.file_path, loc.line, fmt.tprintf(format, ..args))
	libc.longjmp(&test_jmp_buf, 1)
}

expect_true :: proc(v: bool, msg: string, loc := #caller_location) {
	if !v { test_fail(loc, "expected true: %s", msg) }
}

expect_false :: proc(v: bool, msg: string, loc := #caller_location) {
	if v { test_fail(loc, "expected false: %s", msg) }
}

expect_eq :: proc(a, b: $T, msg: string, loc := #caller_location) {
	if a != b { test_fail(loc, "%s | got=%v want=%v", msg, a, b) }
}

expect_no_err :: proc(e: turso.Error, ok: bool, msg: string, loc := #caller_location) {
	if !ok {
		s := turso.error_string(e, context.temp_allocator)
		test_fail(loc, "%s | %s", msg, s)
	}
}

expect_err :: proc(e: turso.Error, ok: bool, msg: string, loc := #caller_location) {
	if ok { test_fail(loc, "expected error: %s", msg) }
}

expect_string_contains :: proc(s, needle: string, msg: string, loc := #caller_location) {
	if len(needle) == 0 { return }
	if len(s) < len(needle) { test_fail(loc, "%s | %q does not contain %q", msg, s, needle) }
	found := false
	for i := 0; i + len(needle) <= len(s); i += 1 {
		if s[i:i + len(needle)] == needle {
			found = true
			break
		}
	}
	if !found { test_fail(loc, "%s | %q does not contain %q", msg, s, needle) }
}

test_db_open_memory :: proc(loc := #caller_location) -> Test_DB {
	db, err1, ok1 := turso.database_open(turso.Database_Config{path = ":memory:"})
	expect_no_err(err1, ok1, "database_open memory", loc)
	conn, err2, ok2 := turso.connect(db)
	expect_no_err(err2, ok2, "connect memory", loc)
	return Test_DB{db = db, conn = conn}
}

test_db_open_file :: proc(name: string, loc := #caller_location) -> Test_DB {
	dir, _ := os.temp_dir(context.allocator)
	path, _ := filepath.join({dir, fmt.tprintf("odin_turso_%s.db", name)}, context.allocator)
	delete(dir)
	os.remove(path)  // best-effort cleanup
	db, err1, ok1 := turso.database_open(turso.Database_Config{path = path})
	expect_no_err(err1, ok1, fmt.tprintf("database_open file %q", path), loc)
	conn, err2, ok2 := turso.connect(db)
	expect_no_err(err2, ok2, fmt.tprintf("connect file %q", path), loc)
	return Test_DB{db = db, conn = conn, path = path}
}

test_db_close :: proc(t: ^Test_DB) {
	_, _ = turso.conn_close(&t.conn)
	turso.database_close(&t.db)
	if t.path != "" {
		os.remove(t.path)
		delete(t.path)
		t.path = ""
	}
}

exec_ok :: proc(conn: turso.Connection, sql: string, loc := #caller_location) -> u64 {
	rows, err, ok := turso.conn_exec(conn, sql)
	expect_no_err(err, ok, fmt.tprintf("exec %q", sql), loc)
	return rows
}

prep_ok :: proc(conn: turso.Connection, sql: string, loc := #caller_location) -> turso.Statement {
	stmt, err, ok := turso.prepare(conn, sql)
	expect_no_err(err, ok, fmt.tprintf("prepare %q", sql), loc)
	return stmt
}

finalize_ok :: proc(stmt: ^turso.Statement, loc := #caller_location) {
	fe, _ := turso.finalize(stmt)
	turso.error_destroy(&fe)
}

step_expect_row :: proc(stmt: turso.Statement, loc := #caller_location) {
	r, e, ok := turso.step(stmt)
	expect_no_err(e, ok, "step", loc)
	expect_true(r == .Row, "expected row", loc)
}

step_expect_done :: proc(stmt: turso.Statement, loc := #caller_location) {
	r, e, ok := turso.step(stmt)
	expect_no_err(e, ok, "step", loc)
	expect_true(r == .Done, "expected done", loc)
}
