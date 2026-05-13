package sync_tests

import turso "../../turso"
import sync "../../turso/sync"

// test_sync_connect_and_query is the most important smoke test: after a fresh
// create, connect should yield a turso.Connection that the parent turso
// package's prepare/step/finalize wrappers operate on correctly. This proves
// the single-dylib linking strategy works end-to-end — the connection pointer
// allocated inside libturso_sync_sdk_kit is consumed by foreign procs that
// resolve to the same lib (because tests/sync is built with
// -define:TURSO_USE_SYNC_DYLIB=true).
test_sync_connect_and_query :: proc() {
	dir := make_temp_dir("connect_and_query")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)

	cfg := sync.Config{path = db_path(dir), client_name = "turso-odin-test"}
	defer delete(cfg.path)
	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, stub_client(&stub))
	expect_no_err(e, ok, "sync.database_create")
	defer sync.database_close(&db)

	conn, ce, cok := sync.connect(db)
	expect_no_err(ce, cok, "sync.connect")
	defer turso.conn_close(&conn)

	stmt, pe, pok := turso.prepare(conn, "SELECT 1")
	expect_no_err(pe, pok, "prepare SELECT 1")
	defer turso.finalize(&stmt)

	r, se, sok := turso.step(stmt)
	expect_no_err(se, sok, "step")
	expect_eq(r, turso.Step_Result.Row, "first row available")

	v := turso.stmt_get_int(stmt, 0)
	expect_eq(v, i64(1), "SELECT 1 returned 1")
}

// test_sync_changes_close_idempotent — closing a zero Sync_Changes is a no-op.
test_sync_changes_close_idempotent :: proc() {
	var: sync.Sync_Changes
	sync.changes_close(&var)
	sync.changes_close(&var)
	expect_true(true, "double-close on zero Sync_Changes is a no-op")
}

// test_sync_stats_destroy_idempotent — stats_destroy is safe on a zero Stats.
test_sync_stats_destroy_idempotent :: proc() {
	var: sync.Stats
	sync.stats_destroy(&var)
	sync.stats_destroy(&var)
	expect_true(true, "double-destroy on zero Stats is a no-op")
}

// test_sync_stats_local_only collects sync counters immediately after create
// against a stub HTTP. With no remote_url set the engine should produce stats
// with all-zero counters (nothing has been synced yet) — the stub is wired in
// only to satisfy any incidental HTTP traffic the engine might emit.
test_sync_stats_local_only :: proc() {
	dir := make_temp_dir("stats_local")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)

	cfg := sync.Config{path = db_path(dir), client_name = "turso-odin-test"}
	defer delete(cfg.path)
	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, stub_client(&stub))
	expect_no_err(e, ok, "sync.database_create")
	defer sync.database_close(&db)

	s, se, sok := sync.stats(db)
	expect_no_err(se, sok, "sync.stats")
	defer sync.stats_destroy(&s)
	expect_eq(s.cdc_operations, i64(0), "fresh DB has zero CDC ops")
	expect_eq(s.network_sent_bytes, i64(0), "fresh DB has zero bytes sent")
	expect_eq(s.network_received_bytes, i64(0), "fresh DB has zero bytes received")
}

// push / pull / checkpoint require the engine to contact the remote via HTTP
// (push fetches the current generation before sending CDC ops, etc.), so they
// need a protocol-aware stub or a real server. The current stub returns an
// empty body which the engine fails to deserialize. See OUTSTANDING.md Task 1
// follow-ups for the work needed to make these unit-testable end-to-end.
