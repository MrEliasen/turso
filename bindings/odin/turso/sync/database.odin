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

	return Sync_Database{handle = db_handle, client = client, config = cfg}, turso.error_none(), true
}

// database_close releases the underlying handle. Idempotent.
database_close :: proc(db: ^Sync_Database) {
	if db == nil || db.handle == nil { return }
	raw.turso_sync_database_deinit(db.handle)
	db.handle = nil
}

// changes_close frees an unconsumed change set. After apply_changes is called
// (via pull), the handle is already cleared; this is then a no-op.
changes_close :: proc(c: ^Sync_Changes) {
	if c == nil || c.handle == nil { return }
	raw.turso_sync_changes_deinit(c.handle)
	c.handle = nil
}
