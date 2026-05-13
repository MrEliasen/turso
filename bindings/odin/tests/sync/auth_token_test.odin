package sync_tests

import "core:mem"
import "core:strings"
import turso "../../turso"
import sync "../../turso/sync"

// Tests that the auth_token a caller sets via curlhttp.client / stub_client
// (HTTP_Client.auth_token) is actually injected on outbound HTTP requests.
//
// As of the current branch, HTTP_Client.auth_token is dead code: the
// dispatcher in turso/sync/io_loop.odin (dispatch_http) reads
// `db.config.auth_token` from sync.Config, never `client.auth_token`. So if a
// caller sets the token on the client but forgets cfg.auth_token, requests
// go out unauthenticated.

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
// sync.Config.auth_token empty. Expectation: outbound HTTP carries the
// Authorization header. Actual: header is missing (dead-code path on
// HTTP_Client.auth_token). This test SHOULD pass after the dispatcher is
// fixed to fall back to client.auth_token when cfg.auth_token is empty.
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
