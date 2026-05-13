package sync_tests

import "core:mem"
import turso "../../turso"
import sync "../../turso/sync"

// Error-path tests verify that HTTP failures propagate cleanly back to the
// caller as turso.Error rather than panicking, hanging, or silently
// succeeding. They use a stub HTTP client configured to fail in different
// ways, so they don't need TURSO_TEST_URL / TURSO_TEST_TOKEN.
//
// All three follow the same shape:
//   1. database_create against a fake remote_url ("https://stub.local")
//   2. local writes (CREATE TABLE + INSERT) queue CDC ops without HTTP
//   3. configure the HTTP client to fail
//   4. sync.push — expect (error, ok=false)
//
// The fake remote_url is needed because the engine only emits push-side HTTP
// when a remote endpoint is configured.

// Always-fails HTTP_Do. Used by test_sync_push_returns_error_when_client_fails.
@(private)
failing_roundtrip :: proc(user_data: rawptr, req: sync.HTTP_Request, allocator: mem.Allocator) ->
	(sync.HTTP_Response, string, bool) {
	return {}, "simulated transport failure", false
}

@(private)
make_db_with_local_changes :: proc(dir: string, client: sync.HTTP_Client) -> sync.Sync_Database {
	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = "https://stub.local",
		client_name = "turso-odin-errpath",
	}
	defer delete(cfg.path)
	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
	expect_no_err(e, ok, "errpath: sync.database_create")

	conn, ce, cok := sync.connect(db)
	expect_no_err(ce, cok, "errpath: sync.connect")
	_, _, _ = turso.conn_exec(conn, "CREATE TABLE t(v TEXT)")
	_, _, _ = turso.conn_exec_args(conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text("changes-to-push"))
	turso.conn_close(&conn)

	return db
}

// test_sync_push_returns_error_when_client_fails covers the catastrophic
// transport-layer failure case: the HTTP_Do callback itself returns ok=false.
// Models DNS error, connection refused, TLS handshake failure, etc. The
// dispatcher poisons the IO item and the engine surfaces an error.
test_sync_push_returns_error_when_client_fails :: proc() {
	dir := make_temp_dir("err_client_fails")
	defer remove_temp_dir(dir)

	client := sync.HTTP_Client{roundtrip = failing_roundtrip}
	db := make_db_with_local_changes(dir, client)
	defer sync.database_close(&db)

	e, ok := sync.push(db)
	expect_err(e, ok, "sync.push must fail when HTTP_Do returns ok=false")
	turso.error_destroy(&e)
}

// test_sync_push_returns_error_on_http_401 covers an authenticated server
// rejecting the request. Stub returns HTTP 401 for every endpoint; the
// engine should refuse to proceed without retrying indefinitely.
test_sync_push_returns_error_on_http_401 :: proc() {
	dir := make_temp_dir("err_401")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)
	stub.default_status = 401
	stub.default_body = transmute([]u8)string("{\"error\":\"unauthorized\"}")

	db := make_db_with_local_changes(dir, stub_client(&stub))
	defer sync.database_close(&db)

	e, ok := sync.push(db)
	expect_err(e, ok, "sync.push must fail when server returns 401")
	turso.error_destroy(&e)
}

// test_sync_push_returns_error_on_http_500 covers transient server failure.
// Engine should surface the failure, not retry forever.
test_sync_push_returns_error_on_http_500 :: proc() {
	dir := make_temp_dir("err_500")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)
	stub.default_status = 500
	stub.default_body = transmute([]u8)string("internal server error")

	db := make_db_with_local_changes(dir, stub_client(&stub))
	defer sync.database_close(&db)

	e, ok := sync.push(db)
	expect_err(e, ok, "sync.push must fail when server returns 500")
	turso.error_destroy(&e)
}
