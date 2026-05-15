package tests

import turso "../turso"

test_open_memory_and_autocommit :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	expect_true(turso.get_autocommit(t.conn), "autocommit defaults to true outside a transaction")
}

test_open_file :: proc() {
	t := test_db_open_file("connection_open_file")
	defer test_db_close(&t)
	expect_true(turso.db_is_open(t.db), "db handle present after file open")
	expect_true(turso.conn_is_open(t.conn), "conn handle present after file open")
}

test_open_bad_path :: proc() {
	_, err, ok := turso.database_open(turso.Database_Config{path = "/no/such/dir/x.db"})
	defer turso.error_destroy(&err)
	expect_false(ok, "opening a non-existent directory should fail")
}

test_idempotent_close :: proc() {
	t := test_db_open_memory()
	test_db_close(&t)
	// Second call should be a no-op, not crash.
	test_db_close(&t)
	expect_false(turso.db_is_open(t.db), "db handle should be nil after second close")
}

test_busy_timeout_setter :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	turso.set_busy_timeout(t.conn, 1000)  // no error path, just must not crash
}

// test_set_busy_timeout_after_close_is_noop pins the closed-handle branch of
// set_busy_timeout. The proc has no return value and is documented to no-op
// on a closed Connection (see turso/connection.odin:115; the contract mirrors
// SQLite's C API which treats most accessors on a closed handle as benign
// rather than as errors). The pin is the absence of a crash plus a clean
// tracking-allocator report at end of run.
test_set_busy_timeout_after_close_is_noop :: proc() {
	t := test_db_open_memory()
	_, _ = turso.conn_close(&t.conn)
	defer test_db_close(&t)  // idempotent; conn already closed above

	turso.set_busy_timeout(t.conn, 1000)
	expect_false(turso.conn_is_open(t.conn), "set_busy_timeout on a closed connection must not revive the handle")
}
