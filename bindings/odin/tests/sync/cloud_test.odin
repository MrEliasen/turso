package sync_tests

import "core:fmt"
import "core:os"
import turso "../../turso"
import sync "../../turso/sync"
import curlhttp "../../turso/sync/curlhttp"

// test_sync_cloud_e2e is the env-gated end-to-end test against a real Turso
// Cloud database. Skipped silently if TURSO_TEST_URL or TURSO_TEST_TOKEN is
// unset, so `make sync-test` stays green without creds.
//
// Scenario:
//   1. database_create against a fresh tmp dir + the cloud URL
//   2. connect + CREATE TABLE odin_e2e (drops any leftover table first)
//   3. INSERT a row
//   4. sync.push — assert ok + stats.network_sent_bytes > 0
//   5. close + wipe local files
//   6. database_create on a fresh tmp dir — engine bootstraps from remote
//   7. connect + SELECT v FROM odin_e2e — assert "hello"
//   8. sync.checkpoint — assert ok
//   9. DROP TABLE so reruns start clean
test_sync_cloud_e2e :: proc() {
	url, has_url   := os.lookup_env_alloc("TURSO_TEST_URL", context.allocator)
	token, has_tok := os.lookup_env_alloc("TURSO_TEST_TOKEN", context.allocator)
	if !has_url || !has_tok || url == "" || token == "" {
		if has_url   { delete(url) }
		if has_tok   { delete(token) }
		fmt.println("       skipped (TURSO_TEST_URL / TURSO_TEST_TOKEN not set)")
		return
	}
	defer delete(url)
	defer delete(token)

	cloud_run_phase_a(url, token)
	cloud_run_phase_b(url, token)
	cloud_run_cleanup(url, token)
}

@(private)
cloud_run_phase_a :: proc(url: string, token: string) {
	dir := make_temp_dir("cloud_phase_a")
	defer remove_temp_dir(dir)

	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = url,
		client_name = "turso-odin-e2e",
		auth_token  = token,
	}
	defer delete(cfg.path)
	client := curlhttp.client(token)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
	expect_no_err(e, ok, "phase A: sync.database_create against cloud")
	defer sync.database_close(&db)

	conn, ce, cok := sync.connect(db)
	expect_no_err(ce, cok, "phase A: sync.connect")
	defer turso.conn_close(&conn)

	// Drop any leftover state from a prior failed run, then create the table.
	_, _, _ = turso.db_exec(conn, "DROP TABLE IF EXISTS odin_e2e")
	_, dde, ddok := turso.db_exec(conn, "CREATE TABLE odin_e2e(id INTEGER PRIMARY KEY, v TEXT)")
	expect_no_err(dde, ddok, "phase A: CREATE TABLE")
	_, ie, iok := turso.db_exec_args(conn, "INSERT INTO odin_e2e(v) VALUES (?)", turso.bind_text("hello"))
	expect_no_err(ie, iok, "phase A: INSERT row")

	pe, pok := sync.push(db)
	expect_no_err(pe, pok, "phase A: sync.push")

	s, se, sok := sync.stats(db)
	expect_no_err(se, sok, "phase A: sync.stats")
	defer sync.stats_destroy(&s)
	expect_true(s.network_sent_bytes > 0, "phase A: stats.network_sent_bytes > 0 after push")
}

@(private)
cloud_run_phase_b :: proc(url: string, token: string) {
	dir := make_temp_dir("cloud_phase_b")
	defer remove_temp_dir(dir)

	cfg := sync.Config{
		path               = db_path(dir),
		remote_url         = url,
		client_name        = "turso-odin-e2e",
		auth_token         = token,
		bootstrap_if_empty = true,
	}
	defer delete(cfg.path)
	client := curlhttp.client(token)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
	expect_no_err(e, ok, "phase B: sync.database_create on fresh dir (bootstrap from remote)")
	defer sync.database_close(&db)

	conn, ce, cok := sync.connect(db)
	expect_no_err(ce, cok, "phase B: sync.connect")

	stmt, pe, pok := turso.prepare(conn, "SELECT v FROM odin_e2e")
	expect_no_err(pe, pok, "phase B: prepare SELECT")

	r, stepe, stepok := turso.step(stmt)
	expect_no_err(stepe, stepok, "phase B: step")
	expect_eq(r, turso.Step_Result.Row, "phase B: row returned (data bootstrapped from remote)")
	got := turso.stmt_get_text(stmt, 0)
	expect_eq(got, "hello", "phase B: round-tripped value matches")
	delete(got)

	// Tear down the statement + connection BEFORE checkpoint — the engine
	// requires exclusive access to truncate the WAL and reports BUSY otherwise.
	turso.finalize(&stmt)
	turso.conn_close(&conn)

	cpe, cpok := sync.checkpoint(db)
	expect_no_err(cpe, cpok, "phase B: sync.checkpoint")
}

@(private)
cloud_run_cleanup :: proc(url: string, token: string) {
	dir := make_temp_dir("cloud_cleanup")
	defer remove_temp_dir(dir)

	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = url,
		client_name = "turso-odin-e2e",
		auth_token  = token,
	}
	defer delete(cfg.path)
	client := curlhttp.client(token)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
	expect_no_err(e, ok, "cleanup: sync.database_create")
	defer sync.database_close(&db)

	conn, ce, cok := sync.connect(db)
	expect_no_err(ce, cok, "cleanup: sync.connect")
	defer turso.conn_close(&conn)

	_, _, _ = turso.db_exec(conn, "DROP TABLE IF EXISTS odin_e2e")
	_, _ = sync.push(db)
}
