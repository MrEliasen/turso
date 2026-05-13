package turso

import "core:strings"
import raw "raw"

// database_open creates and opens a Turso database using synchronous I/O.
// Returns a Database the caller must close with database_close.
//
// The provided cfg.path is required; pass ":memory:" for an in-memory DB.
database_open :: proc(cfg: Database_Config) -> (Database, Error, bool) {
	if e, ok := setup(); !ok {
		return Database{}, e, false
	}

	if cfg.path == "" {
		return Database{}, Error{code = .MISUSE, op = "database_open", message = strings.clone("Database_Config.path is required")}, false
	}

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

	raw_cfg := raw.Database_Config{
		async_io              = 0,  // v1: always synchronous
		path                  = c_path,
		experimental_features = c_features,
		vfs                   = c_vfs,
		encryption_cipher     = nil,
		encryption_hexkey     = nil,
	}

	db_handle: raw.Database_Ptr
	c_err: cstring
	code := raw.turso_database_new(&raw_cfg, &db_handle, &c_err)
	if code != .OK {
		return Database{}, error_from_status(code, c_err, "turso_database_new", "", cfg.path), false
	}

	code = raw.turso_database_open(db_handle, &c_err)
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
connect :: proc(db: Database) -> (Connection, Error, bool) {
	if db.handle == nil {
		return Connection{}, Error{
			code    = .MISUSE,
			op      = "connect",
			message = strings.clone("database is not open"),
		}, false
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
