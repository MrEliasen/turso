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

	// async_io: when true, the library returns TURSO_IO from step/execute/finalize
	// when it needs I/O. The wrapper transparently calls run_io() and retries, so
	// callers still see a blocking API. Use the explicit step_once/run_io procs if
	// you need event-loop integration.
	async_io: bool,

	// Encryption is experimental. To use, experimental_features MUST contain "encryption".
	// cipher: cipher algorithm name, e.g. "aes256gcm", "aegis256"
	// hexkey: encryption key as a hex string of the required length for the cipher
	encryption_cipher: string,
	encryption_hexkey: string,
}

// Tracing_Level mirrors raw.Tracing_Level so callers don't need to import the raw package.
Tracing_Level :: raw.Tracing_Level

// Log_Event is the Odin-side view of a turso log record.
// The string fields BORROW the underlying C memory and are valid only for the duration
// of the Logger_Proc invocation. Clone with strings.clone(...) to outlive the callback.
Log_Event :: struct {
	message:   string,
	target:    string,
	file:      string,
	timestamp: u64,
	line:      uint,
	level:     Tracing_Level,
}

// Logger_Proc is the callback signature for receiving turso log events.
// The Log_Event's string fields are valid only for the duration of the call.
Logger_Proc :: proc(event: Log_Event)

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
	sql:     string,  // owned by Error (cloned at construction); free with error_destroy
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
