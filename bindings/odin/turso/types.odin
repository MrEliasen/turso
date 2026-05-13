package turso

import raw "raw"

// Database holds an opened database. Always pair with database_close.
Database :: struct {
	handle: raw.Database_Ptr,
	config: Database_Config,
}

// Connection is an exclusive session against a Database. Always pair with conn_close.
// Multiple connections to the same Database are allowed.
Connection :: struct {
	handle: raw.Connection_Ptr,
	db:     raw.Database_Ptr,
}

// Statement is a prepared statement. Always pair with finalize.
// SQL is borrowed from the caller's allocation; not owned.
Statement :: struct {
	handle: raw.Statement_Ptr,
	db:     raw.Database_Ptr,
	sql:    string,
}

// Database_Config is the user-facing config for database_open.
// path is required; remaining fields are optional.
Database_Config :: struct {
	path:                  string,  // e.g. "test.db" or ":memory:"
	experimental_features: string,  // optional comma-separated list; "" = unset
	vfs:                   string,  // optional VFS name; "" = unset
	busy_timeout_ms:       i64,     // applied to every new connection; <= 0 means no setter call
}

Step_Result :: enum {
	Done = 0,
	Row  = 1,
}

// Re-export raw enums so callers don't need to import the raw package.
Value_Kind  :: raw.Value_Kind
Status_Code :: raw.Status_Code

Error :: struct {
	code:    Status_Code,
	message: string,  // owned by Error (cloned from C); free with error_destroy
	sql:     string,  // borrowed
	op:      string,  // static literal identifying the call site
	ctx:     string,  // borrowed
}

Bind_Kind :: enum {
	Null,
	Int,
	Double,
	Text,
	Blob,
}

Bind_Value :: union #no_nil {
	i64,
	f64,
	string,
	[]u8,
}

Bind_Arg :: struct {
	kind:  Bind_Kind,
	value: Bind_Value,
}

bind_null   :: proc() -> Bind_Arg               { return Bind_Arg{kind = .Null,   value = i64(0)} }
bind_int    :: proc(v: i64) -> Bind_Arg         { return Bind_Arg{kind = .Int,    value = v} }
bind_double :: proc(v: f64) -> Bind_Arg         { return Bind_Arg{kind = .Double, value = v} }
bind_text   :: proc(v: string) -> Bind_Arg      { return Bind_Arg{kind = .Text,   value = v} }
bind_blob   :: proc(v: []u8) -> Bind_Arg        { return Bind_Arg{kind = .Blob,   value = v} }

db_is_open   :: proc(d: Database)   -> bool { return d.handle != nil }
conn_is_open :: proc(c: Connection) -> bool { return c.handle != nil }
stmt_is_open :: proc(s: Statement)  -> bool { return s.handle != nil }
