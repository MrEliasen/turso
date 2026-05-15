package sync_tests

import "core:mem"
import "core:strings"
import turso "../../turso"
import sync "../../turso/sync"

// Tests that the auth_token a caller sets via curlhttp.client / stub_client
// (HTTP_Client.auth_token) is actually injected on outbound HTTP requests.
//
// Contract: sync.Config.auth_token takes precedence; when it is empty the
// dispatcher in turso/sync/io_loop.odin (dispatch_http) falls back to
// HTTP_Client.auth_token. This test pins the fallback path so a caller who
// sets the token only on the client (the natural place per curlhttp.client's
// signature) still gets an Authorization: Bearer header on every request.

@(private="file")
Auth_Spy :: struct {
	saw_authorization: bool,
	authorization:     string,
}

@(private="file")
auth_spy_roundtrip :: proc(user_data: rawptr, req: sync.HTTP_Request, allocator: mem.Allocator) ->
	(resp: sync.HTTP_Response, message: string, ok: bool) {
	spy := cast(^Auth_Spy)user_data
	for h in req.headers {
		if strings.equal_fold(h.key, "Authorization") {
			spy.saw_authorization = true
			spy.authorization = strings.clone(h.value)
		}
	}
	// Force the engine to give up so we don't crash on unexpected payload shapes.
	return sync.HTTP_Response{}, "spy: refused", false
}

// test_http_client_auth_token_is_forwarded sets the token ONLY on the
// HTTP_Client (the natural place per curlhttp.client's signature) and leaves
// sync.Config.auth_token empty. The dispatcher must fall back to the
// client's token so outbound HTTP carries an Authorization header.
test_http_client_auth_token_is_forwarded :: proc() {
	dir := make_temp_dir("auth_token_forward")
	defer remove_temp_dir(dir)

	spy: Auth_Spy
	defer if spy.saw_authorization { delete(spy.authorization) }

	client := sync.HTTP_Client{
		user_data  = &spy,
		roundtrip  = auth_spy_roundtrip,
		auth_token = "token-set-only-on-client",
	}

	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = "https://example.invalid",
		client_name = "auth-token-spy",
		// NOTE: auth_token deliberately omitted on cfg.
	}
	defer delete(cfg.path)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
	defer sync.database_close(&db)
	if ok {
		pe, _ := sync.push(db)
		turso.error_destroy(&pe)
	} else {
		turso.error_destroy(&e)
	}

	expect_true(spy.saw_authorization,
		"HTTP_Client.auth_token must reach outbound requests when sync.Config.auth_token is empty")
}

// test_sync_user_data_freed_after_database_close_no_crash pins the contract
// that the sync engine is pull-based: after sync.database_close returns, the
// dispatcher will never call HTTP_Client.roundtrip with the now-stale
// user_data pointer. The caller is therefore free to deallocate a heap
// HTTP_Client.user_data immediately after database_close.
//
// This is the regression pin for the HTTP_Client field lifetime documented in
// the README's "Sync ownership rules" section. If a future refactor introduced
// a Rust-side background task that retried HTTP requests after deinit, this
// test would surface it as either a segfault on the freed spy pointer or a
// tracking-allocator bad-free when the next allocation reused the slot.
test_sync_user_data_freed_after_database_close_no_crash :: proc() {
	dir := make_temp_dir("user_data_lifetime")
	defer remove_temp_dir(dir)

	// Heap-allocate the spy so the post-close free is meaningful. A stack spy
	// would not prove anything since its memory is only reclaimed at proc exit.
	spy := new(Auth_Spy)

	client := sync.HTTP_Client{
		user_data  = spy,
		roundtrip  = auth_spy_roundtrip,
		auth_token = "user-data-lifetime-pin",
	}

	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = "https://example.invalid",
		client_name = "user-data-lifetime",
	}
	defer delete(cfg.path)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
	if ok {
		// Drive one operation so the dispatcher actually reads user_data at
		// least once. The spy refuses the request which surfaces a typed
		// error from sync.push; we discard it because the dispatch having
		// happened is the only thing we care about here.
		pe, _ := sync.push(db)
		turso.error_destroy(&pe)
	} else {
		turso.error_destroy(&e)
	}

	// Order matters: close the database FIRST, then free user_data. This is
	// the contract under test. If the dispatcher tried to call back into
	// user_data after deinit, the next line would either segfault or surface
	// a bad-free through the test runner's tracking allocator.
	sync.database_close(&db)
	if spy.saw_authorization { delete(spy.authorization) }
	free(spy)

	// No assertion needed: surviving close + free + the end-of-run leak check
	// is the pin.
}
