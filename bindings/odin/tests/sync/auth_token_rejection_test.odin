package sync_tests

import "core:strings"
import turso "../../turso"
import sync "../../turso/sync"

// sync.Config.auth_token and HTTP_Client.auth_token end up in an HTTP header
// value. libcurl forwards CR / LF / NUL inside header values verbatim, which
// would let a caller-supplied string smuggle additional headers or split the
// request body. The binding rejects those bytes up front with a typed MISUSE
// error so the request never goes out.

@(private="file")
header_unsafe_string :: proc(prefix: string, sep: string, suffix: string) -> string {
	parts := [3]string{prefix, sep, suffix}
	return strings.concatenate(parts[:])
}

@(private="file")
expect_misuse :: proc(e: turso.Error, ok: bool, msg: string) {
	expect_false(ok, msg)
	expect_eq(e.code, turso.Status_Code.MISUSE, msg)
}

test_sync_config_auth_token_rejects_crlf :: proc() {
	dir := make_temp_dir("auth_token_crlf")
	defer remove_temp_dir(dir)

	token := header_unsafe_string("legit-token", "\r\n", "X-Injected: pwned")
	defer delete(token)

	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = "https://example.invalid",
		client_name = "auth-token-crlf",
		auth_token  = token,
	}
	defer delete(cfg.path)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, sync.HTTP_Client{})
	defer sync.database_close(&db)
	expect_misuse(e, ok, "auth_token with CRLF must be rejected with MISUSE")
	turso.error_destroy(&e)
}

test_sync_config_auth_token_rejects_nul :: proc() {
	dir := make_temp_dir("auth_token_nul")
	defer remove_temp_dir(dir)

	token := header_unsafe_string("legit", "\x00", "trailing")
	defer delete(token)

	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = "https://example.invalid",
		client_name = "auth-token-nul",
		auth_token  = token,
	}
	defer delete(cfg.path)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, sync.HTTP_Client{})
	defer sync.database_close(&db)
	expect_misuse(e, ok, "auth_token with NUL must be rejected with MISUSE")
	turso.error_destroy(&e)
}

test_sync_client_auth_token_rejects_crlf :: proc() {
	dir := make_temp_dir("client_auth_token_crlf")
	defer remove_temp_dir(dir)

	token := header_unsafe_string("legit", "\r\n", "X-Injected: pwned")
	defer delete(token)

	client := sync.HTTP_Client{auth_token = token}
	cfg := sync.Config{
		path        = db_path(dir),
		remote_url  = "https://example.invalid",
		client_name = "client-auth-crlf",
	}
	defer delete(cfg.path)

	db, e, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
	defer sync.database_close(&db)
	expect_misuse(e, ok, "HTTP_Client.auth_token with CRLF must be rejected with MISUSE")
	turso.error_destroy(&e)
}
