package turso

import "core:strings"
import raw "raw"

// database_open creates and opens a Turso database using synchronous I/O.
// Returns a Database the caller must close with database_close.
//
// The provided cfg.path is required; pass ":memory:" for an in-memory DB.
//
// To enable encryption: set experimental_features = "encryption" and supply
// encryption_cipher (e.g. "aes256gcm") + encryption_hexkey.
//
// To enable logging: call setup() with a Setup_Options before database_open().
//
// All string fields are validated for embedded NUL bytes up front. Any NUL
// would otherwise truncate the C-string handed to the Rust side and produce a
// silently-wrong config; a typed MISUSE error is friendlier.
//
// C ABI: turso.h:136-141 (turso_database_new) + turso.h:146-149 (turso_database_open)
database_open :: proc(cfg: Database_Config) -> (Database, Error, bool) {
	if cfg.path == "" {
		return Database{}, make_error(.MISUSE, "database_open", "Database_Config.path is required"), false
	}

	if e, ok := must_be_nul_free(cfg.path,                  "database_open", "Database_Config.path");                  !ok { return Database{}, e, false }
	if e, ok := must_be_nul_free(cfg.experimental_features, "database_open", "Database_Config.experimental_features"); !ok { return Database{}, e, false }
	if e, ok := must_be_nul_free(cfg.vfs,                   "database_open", "Database_Config.vfs");                   !ok { return Database{}, e, false }
	if e, ok := must_be_nul_free(cfg.encryption_cipher,     "database_open", "Database_Config.encryption_cipher");     !ok { return Database{}, e, false }
	if e, ok := must_be_nul_free(cfg.encryption_hexkey,     "database_open", "Database_Config.encryption_hexkey");     !ok { return Database{}, e, false }

	c_path := strings.clone_to_cstring(cfg.path, context.allocator)
	defer delete(c_path)

	c_features: cstring
	if cfg.experimental_features != "" {
		c_features = strings.clone_to_cstring(cfg.experimental_features, context.allocator)
	}
	defer if c_features != nil { delete(c_features) }

	c_vfs: cstring
	if cfg.vfs != "" {
		c_vfs = strings.clone_to_cstring(cfg.vfs, context.allocator)
	}
	defer if c_vfs != nil { delete(c_vfs) }

	c_cipher: cstring
	if cfg.encryption_cipher != "" {
		c_cipher = strings.clone_to_cstring(cfg.encryption_cipher, context.allocator)
	}
	defer if c_cipher != nil { delete(c_cipher) }

	c_hexkey: cstring
	if cfg.encryption_hexkey != "" {
		c_hexkey = strings.clone_to_cstring(cfg.encryption_hexkey, context.allocator)
	}
	defer if c_hexkey != nil { delete_zeroed_cstring(c_hexkey) }

	async_io_flag: u64 = 0
	if cfg.async_io { async_io_flag = 1 }

	raw_cfg := raw.Database_Config{
		async_io              = async_io_flag,
		path                  = c_path,
		experimental_features = c_features,
		vfs                   = c_vfs,
		encryption_cipher     = c_cipher,
		encryption_hexkey     = c_hexkey,
	}

	db_handle: raw.Database_Ptr
	c_err: cstring
	code := raw.turso_database_new(&raw_cfg, &db_handle, &c_err)
	if code != .OK {
		return Database{}, error_from_status(code, c_err, "turso_database_new", "", cfg.path), false
	}

	code = raw.turso_database_open(db_handle, &c_err)
	// async open can yield TURSO_IO, but the C ABI has no turso_database_run_io
	// to drive it; :memory: never hits this, so surface a clear error only here.
	if code == .IO {
		if c_err != nil { raw.turso_str_deinit(c_err) }
		raw.turso_database_deinit(db_handle)
		return Database{}, make_error(.MISUSE, "turso_database_open", "async_io open requires I/O that the current C ABI cannot drive (no turso_database_run_io); use async_io=false for file-backed databases", "", cfg.path), false
	}
	if code != .OK {
		raw.turso_database_deinit(db_handle)
		return Database{}, error_from_status(code, c_err, "turso_database_open", "", cfg.path), false
	}

	return Database{handle = db_handle, config = cfg}, error_none(), true
}

// database_close releases the database resources. Idempotent.
database_close :: proc(db: ^Database) {
	if db == nil || db.handle == nil { return }
	raw.turso_database_deinit(db.handle)
	db.handle = nil
}

// connect opens a new connection to the database. Caller must call conn_close.
// Applies busy_timeout_ms from the Database_Config if > 0.
//
// C ABI: turso.h:152-157 (turso_database_connect)
connect :: proc(db: Database) -> (Connection, Error, bool) {
	if db.handle == nil {
		return Connection{}, make_error(.MISUSE, "connect", "database is not open"), false
	}
	conn_handle: raw.Connection_Ptr
	c_err: cstring
	code := raw.turso_database_connect(db.handle, &conn_handle, &c_err)
	if code != .OK {
		return Connection{}, error_from_status(code, c_err, "turso_database_connect"), false
	}
	if db.config.busy_timeout_ms > 0 {
		raw.turso_connection_set_busy_timeout_ms(conn_handle, db.config.busy_timeout_ms)
	}
	return Connection{handle = conn_handle, db = db.handle}, error_none(), true
}

// set_busy_timeout, get_autocommit, and last_insert_rowid silently no-op on a
// closed Connection. Use `conn_is_open(conn)` before calling them if you need
// to distinguish "value of 0 / false" from "connection was already closed".
// This shape mirrors SQLite's own C API, which treats most accessors on a
// closed handle as benign rather than as errors.
set_busy_timeout :: proc(conn: Connection, ms: i64) {
	if conn.handle == nil { return }
	raw.turso_connection_set_busy_timeout_ms(conn.handle, ms)
}

get_autocommit :: proc(conn: Connection) -> bool {
	if conn.handle == nil { return false }
	return bool(raw.turso_connection_get_autocommit(conn.handle))
}

last_insert_rowid :: proc(conn: Connection) -> i64 {
	if conn.handle == nil { return 0 }
	return raw.turso_connection_last_insert_rowid(conn.handle)
}

// conn_close closes the connection then deinits the handle. Idempotent.
// Returns the close-status error if turso_connection_close failed; deinit always runs.
conn_close :: proc(conn: ^Connection) -> (Error, bool) {
	if conn == nil || conn.handle == nil { return error_none(), true }
	c_err: cstring
	code := raw.turso_connection_close(conn.handle, &c_err)
	err := error_none()
	ok := true
	if code != .OK {
		err = error_from_status(code, c_err, "turso_connection_close")
		ok = false
	}
	raw.turso_connection_deinit(conn.handle)
	conn.handle = nil
	return err, ok
}
