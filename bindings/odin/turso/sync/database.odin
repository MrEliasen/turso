package turso_sync

import "core:strings"
import raw "raw"
import turso "../"

// database_create opens a synced database, creating local state if it doesn't
// already exist. Mirrors driver_sync.go:NewTursoSyncDb. Returns a Sync_Database
// the caller must close with database_close.
//
// The provided cfg.path is required. The HTTP client is stored on the returned
// Sync_Database and used for every subsequent operation; pass a HTTP_Client
// with a non-nil .do. If cfg.auth_token is set, the dispatcher injects it as
// "Authorization: Bearer <token>" on every HTTP request.
database_create :: proc(core: turso.Database_Config, cfg: Config, client: HTTP_Client) -> (Sync_Database, turso.Error, bool) {
	return open_or_create(core, cfg, client, true, "database_create")
}

// database_open opens an EXISTING synced database. Fails if local state hasn't
// been set up via a prior database_create.
database_open :: proc(core: turso.Database_Config, cfg: Config, client: HTTP_Client) -> (Sync_Database, turso.Error, bool) {
	return open_or_create(core, cfg, client, false, "database_open")
}

@(private)
push_cstring :: proc(buf: ^[dynamic]cstring, s: string) -> cstring {
	if s == "" { return nil }
	c := strings.clone_to_cstring(s, context.allocator)
	append(buf, c)
	return c
}

@(private)
open_or_create :: proc(
	core: turso.Database_Config,
	cfg: Config,
	client: HTTP_Client,
	create_if_missing: bool,
	op_name: string,
) -> (Sync_Database, turso.Error, bool) {
	if cfg.path == "" {
		return Sync_Database{}, sync_misuse(op_name, "sync.Config.path is required"), false
	}
	if cfg.client_name == "" {
		return Sync_Database{}, sync_misuse(op_name, "sync.Config.client_name is required"), false
	}

	// Validate every string that ends up as a C-string handed to either the
	// core or sync engine. An embedded NUL would silently truncate the input;
	// auth_token additionally must not contain CR or LF because it goes into
	// an HTTP header value where CRLF would let a caller smuggle additional
	// headers.
	if e, ok := turso.must_be_nul_free(core.path,                              op_name, "Database_Config.path");                  !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(core.experimental_features,             op_name, "Database_Config.experimental_features"); !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(core.vfs,                               op_name, "Database_Config.vfs");                   !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(core.encryption_cipher,                 op_name, "Database_Config.encryption_cipher");     !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(core.encryption_hexkey,                 op_name, "Database_Config.encryption_hexkey");     !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(cfg.path,                               op_name, "sync.Config.path");                              !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(cfg.remote_url,                         op_name, "sync.Config.remote_url");                        !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(cfg.client_name,                        op_name, "sync.Config.client_name");                       !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(cfg.partial_bootstrap_strategy_query,   op_name, "sync.Config.partial_bootstrap_strategy_query");  !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(cfg.remote_encryption_key,              op_name, "sync.Config.remote_encryption_key");             !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_nul_free(cfg.remote_encryption_cipher,           op_name, "sync.Config.remote_encryption_cipher");          !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_header_safe(cfg.auth_token,                      op_name, "sync.Config.auth_token");                        !ok { return Sync_Database{}, e, false }
	if e, ok := turso.must_be_header_safe(client.auth_token,                   op_name, "HTTP_Client.auth_token");                        !ok { return Sync_Database{}, e, false }

	c_strings: [dynamic]cstring
	defer {
		for s in c_strings { delete(s) }
		delete(c_strings)
	}

	// Build the raw core Database_Config (mirrors turso/connection.odin:database_open).
	async_io_flag: u64 = 0
	if core.async_io { async_io_flag = 1 }
	raw_core := raw.Database_Config{
		async_io              = async_io_flag,
		path                  = push_cstring(&c_strings, core.path),
		experimental_features = push_cstring(&c_strings, core.experimental_features),
		vfs                   = push_cstring(&c_strings, core.vfs),
		encryption_cipher     = push_cstring(&c_strings, core.encryption_cipher),
		encryption_hexkey     = push_cstring(&c_strings, core.encryption_hexkey),
	}

	raw_sync := raw.Sync_Database_Config{
		path                              = push_cstring(&c_strings, cfg.path),
		remote_url                        = push_cstring(&c_strings, cfg.remote_url),
		client_name                       = push_cstring(&c_strings, cfg.client_name),
		long_poll_timeout_ms              = cfg.long_poll_timeout_ms,
		bootstrap_if_empty                = b8(cfg.bootstrap_if_empty),
		reserved_bytes                    = cfg.reserved_bytes,
		partial_bootstrap_strategy_prefix = cfg.partial_bootstrap_strategy_prefix,
		partial_bootstrap_strategy_query  = push_cstring(&c_strings, cfg.partial_bootstrap_strategy_query),
		partial_bootstrap_segment_size    = cfg.partial_bootstrap_segment_size,
		partial_bootstrap_prefetch        = b8(cfg.partial_bootstrap_prefetch),
		remote_encryption_key             = push_cstring(&c_strings, cfg.remote_encryption_key),
		remote_encryption_cipher          = push_cstring(&c_strings, cfg.remote_encryption_cipher),
		push_operations_threshold         = cfg.push_operations_threshold,
		pull_bytes_threshold              = cfg.pull_bytes_threshold,
	}

	db_handle: raw.Database_Ptr
	c_err: cstring
	if code := raw.turso_sync_database_new(&raw_core, &raw_sync, &db_handle, &c_err); code != .OK {
		return Sync_Database{}, turso.error_from_status(code, c_err, "turso_sync_database_new", "", cfg.path), false
	}

	// Kick off the open/create op and drive it through the IO loop.
	op_handle: raw.Operation_Ptr
	open_code: raw.Status_Code
	c_call: string
	if create_if_missing {
		open_code = raw.turso_sync_database_create(db_handle, &op_handle, &c_err)
		c_call = "turso_sync_database_create"
	} else {
		open_code = raw.turso_sync_database_open(db_handle, &op_handle, &c_err)
		c_call = "turso_sync_database_open"
	}
	if open_code != .OK {
		raw.turso_sync_database_deinit(db_handle)
		return Sync_Database{}, turso.error_from_status(open_code, c_err, c_call, "", cfg.path), false
	}
	defer raw.turso_sync_operation_deinit(op_handle)

	_, drive_err, ok := drive_op_until_done(db_handle, op_handle, client, cfg.remote_url, cfg.auth_token, op_name)
	if !ok {
		raw.turso_sync_database_deinit(db_handle)
		return Sync_Database{}, drive_err, false
	}

	// Deep-copy the Config so the Sync_Database is independent of the caller's
	// string lifetimes. Subsequent push/pull/checkpoint calls read these
	// fields through db.config; freeing the caller's buffers between calls
	// would otherwise yield UB.
	return Sync_Database{handle = db_handle, client = client, config = clone_config(cfg)}, turso.error_none(), true
}

// database_close releases the underlying handle. Idempotent.
database_close :: proc(db: ^Sync_Database) {
	if db == nil || db.handle == nil { return }
	raw.turso_sync_database_deinit(db.handle)
	db.handle = nil
	free_config(&db.config)
}

@(private)
clone_config :: proc(cfg: Config) -> Config {
	out := cfg
	if cfg.path                             != "" { out.path                             = strings.clone(cfg.path) }
	if cfg.remote_url                       != "" { out.remote_url                       = strings.clone(cfg.remote_url) }
	if cfg.client_name                      != "" { out.client_name                      = strings.clone(cfg.client_name) }
	if cfg.auth_token                       != "" { out.auth_token                       = strings.clone(cfg.auth_token) }
	if cfg.partial_bootstrap_strategy_query != "" { out.partial_bootstrap_strategy_query = strings.clone(cfg.partial_bootstrap_strategy_query) }
	if cfg.remote_encryption_key            != "" { out.remote_encryption_key            = strings.clone(cfg.remote_encryption_key) }
	if cfg.remote_encryption_cipher         != "" { out.remote_encryption_cipher         = strings.clone(cfg.remote_encryption_cipher) }
	return out
}

@(private)
free_config :: proc(cfg: ^Config) {
	if cfg == nil { return }
	if len(cfg.path)                             > 0 { delete(cfg.path);                             cfg.path = "" }
	if len(cfg.remote_url)                       > 0 { delete(cfg.remote_url);                       cfg.remote_url = "" }
	if len(cfg.client_name)                      > 0 { delete(cfg.client_name);                      cfg.client_name = "" }
	if len(cfg.partial_bootstrap_strategy_query) > 0 { delete(cfg.partial_bootstrap_strategy_query); cfg.partial_bootstrap_strategy_query = "" }
	if len(cfg.remote_encryption_cipher)         > 0 { delete(cfg.remote_encryption_cipher);         cfg.remote_encryption_cipher = "" }
	// Sensitive material: zero the buffer before returning it to the allocator
	// so a later allocation cannot read a stale credential. The remote_url and
	// path fields above are not treated as sensitive.
	if len(cfg.auth_token)            > 0 { turso.delete_zeroed_string(cfg.auth_token);            cfg.auth_token = "" }
	if len(cfg.remote_encryption_key) > 0 { turso.delete_zeroed_string(cfg.remote_encryption_key); cfg.remote_encryption_key = "" }
}

// changes_close frees an unconsumed change set. After apply_changes is called
// (via pull), the handle is already cleared; this is then a no-op.
changes_close :: proc(c: ^Sync_Changes) {
	if c == nil || c.handle == nil { return }
	raw.turso_sync_changes_deinit(c.handle)
	c.handle = nil
}
