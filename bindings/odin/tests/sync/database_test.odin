package sync_tests

import turso "../../turso"
import sync "../../turso/sync"

// test_sync_link is the linking smoke test. Calls a noop on a nil handle (the
// raw API tolerates nil per the C contract). If this runs without crashing,
// the dylib was loaded and the foreign import resolved.
test_sync_link :: proc() {
	var: sync.Sync_Database
	sync.database_close(&var)
	expect_true(true, "sync dylib linked")
}

// test_sync_database_create_close exercises the smallest viable
// create/close roundtrip against a fresh tmp dir. The stub client is wired in
// but we expect no HTTP calls during a purely-local create.
test_sync_database_create_close :: proc() {
	dir := make_temp_dir("create_close")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)

	cfg := sync.Config{path = db_path(dir), client_name = "turso-odin-test"}
	defer delete(cfg.path)
	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, stub_client(&stub))
	expect_no_err(e, ok, "sync.database_create local-only")
	defer sync.database_close(&db)
	expect_true(sync.sync_db_is_open(db), "database handle non-nil after create")
}

// test_sync_database_open_without_setup verifies that opening a sync DB on a
// directory that has not been previously create'd returns an error.
test_sync_database_open_without_setup :: proc() {
	dir := make_temp_dir("open_without_setup")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)

	cfg := sync.Config{path = db_path(dir), client_name = "turso-odin-test"}
	defer delete(cfg.path)
	db, e, ok := sync.database_open(turso.Database_Config{path = cfg.path}, cfg, stub_client(&stub))
	defer sync.database_close(&db)
	expect_err(e, ok, "sync.database_open without prior create must fail")
	turso.error_destroy(&e)
}

// test_sync_database_close_idempotent ensures double-close is safe.
test_sync_database_close_idempotent :: proc() {
	var: sync.Sync_Database
	sync.database_close(&var)
	sync.database_close(&var)
	expect_true(true, "double-close on zero Sync_Database is a no-op")
}
