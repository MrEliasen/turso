package raw

// Hand-written FFI surface matching sdk-kit/turso.h 1:1.
//
// Build the shared library first:
//   cargo build -p turso_sdk_kit
// then run odin with a linker -L pointing at target/debug/ (the Makefile
// in bindings/odin/ does this for you).

// Library resolution. The Makefile passes -extra-linker-flags pointing at
// target/debug/, and -Wl,-rpath bakes the path into the binary so the loader
// finds libturso_sdk_kit.{dylib,so,dll} at run time. To override the file name
// for distribution layouts, rebuild after editing this file.
//
// When the sync engine is in use the FFI must route through
// libturso_sync_sdk_kit instead of libturso_sdk_kit so all pointers share one
// memory namespace (the sync dylib re-exports every core symbol). Build the
// sync test binary with `-define:TURSO_USE_SYNC_DYLIB=true` to flip the
// foreign import; the Makefile's `sync-test` target does this for you.
USE_SYNC_DYLIB :: #config(TURSO_USE_SYNC_DYLIB, false)

when USE_SYNC_DYLIB {
	when ODIN_OS == .Windows {
		foreign import turso "system:turso_sync_sdk_kit.dll"
	} else when ODIN_OS == .Darwin {
		foreign import turso "system:turso_sync_sdk_kit"
	} else when ODIN_OS == .Linux {
		foreign import turso "system:turso_sync_sdk_kit"
	} else when ODIN_OS == .FreeBSD {
		foreign import turso "system:turso_sync_sdk_kit"
	} else when ODIN_OS == .OpenBSD {
		foreign import turso "system:turso_sync_sdk_kit"
	}
} else {
	when ODIN_OS == .Windows {
		foreign import turso "system:turso_sdk_kit.dll"
	} else when ODIN_OS == .Darwin {
		foreign import turso "system:turso_sdk_kit"
	} else when ODIN_OS == .Linux {
		foreign import turso "system:turso_sdk_kit"
	} else when ODIN_OS == .FreeBSD {
		foreign import turso "system:turso_sdk_kit"
	} else when ODIN_OS == .OpenBSD {
		foreign import turso "system:turso_sdk_kit"
	}
}

// turso_status_code_t - turso.h:19-36
Status_Code :: enum i32 {
	OK            = 0,
	DONE          = 1,
	ROW           = 2,
	IO            = 3,
	BUSY          = 4,
	INTERRUPT     = 5,
	BUSY_SNAPSHOT = 6,
	ERROR         = 127,
	MISUSE        = 128,
	CONSTRAINT    = 129,
	READONLY      = 130,
	DATABASE_FULL = 131,
	NOTADB        = 132,
	CORRUPT       = 133,
	IOERR         = 134,
}

// turso_type_t - turso.h:39-47
Value_Kind :: enum i32 {
	UNKNOWN = 0,
	INTEGER = 1,
	REAL    = 2,
	TEXT    = 3,
	BLOB    = 4,
	NULL    = 5,
}

// turso_tracing_level_t - turso.h:49-56
Tracing_Level :: enum i32 {
	ERROR = 1,
	WARN  = 2,
	INFO  = 3,
	DEBUG = 4,
	TRACE = 5,
}

// Opaque types - distinct so caller can't mix them.
Database_T   :: struct{}
Connection_T :: struct{}
Statement_T  :: struct{}

Database_Ptr   :: ^Database_T
Connection_Ptr :: ^Connection_T
Statement_Ptr  :: ^Statement_T

// turso_log_t - turso.h:74-85
Log_Struct :: struct {
	message:   cstring,
	target:    cstring,
	file:      cstring,
	timestamp: u64,
	line:      uint,
	level:     Tracing_Level,
}

// turso_config_t - turso.h:87-94
Setup_Config :: struct {
	logger:    rawptr,  // "C" proc(^Log_Struct), nil in v1
	log_level: cstring,
}

// turso_database_config_t - turso.h:96-127
Database_Config :: struct {
	async_io:              u64,      // non-zero == async I/O; v1 always 0
	path:                  cstring,
	experimental_features: cstring,  // nil unless set
	vfs:                   cstring,  // nil unless set
	encryption_cipher:     cstring,  // nil in v1
	encryption_hexkey:     cstring,  // nil in v1
}

@(default_calling_convention = "c")
foreign turso {
	// Version - turso.h:72
	turso_version :: proc() -> cstring ---

	// Global setup - turso.h:130
	turso_setup :: proc(config: ^Setup_Config, error_opt_out: ^cstring) -> Status_Code ---

	// Database lifecycle - turso.h:136-157
	turso_database_new     :: proc(config: ^Database_Config, database: ^Database_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_database_open    :: proc(database: Database_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_database_connect :: proc(self: Database_Ptr, connection: ^Connection_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_database_deinit  :: proc(self: Database_Ptr) ---

	// Connection - turso.h:160-199
	turso_connection_set_busy_timeout_ms :: proc(self: Connection_Ptr, timeout_ms: i64) ---
	turso_connection_get_autocommit      :: proc(self: Connection_Ptr) -> b8 ---
	turso_connection_last_insert_rowid   :: proc(self: Connection_Ptr) -> i64 ---
	turso_connection_prepare_single      :: proc(self: Connection_Ptr, sql: cstring, statement: ^Statement_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_connection_prepare_first       :: proc(self: Connection_Ptr, sql: cstring, statement: ^Statement_Ptr, tail_idx: ^uint, error_opt_out: ^cstring) -> Status_Code ---
	turso_connection_close               :: proc(self: Connection_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_connection_deinit              :: proc(self: Connection_Ptr) ---

	// Statement lifecycle - turso.h:205-233
	turso_statement_execute  :: proc(self: Statement_Ptr, rows_changes: ^u64, error_opt_out: ^cstring) -> Status_Code ---
	turso_statement_step     :: proc(self: Statement_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_statement_run_io   :: proc(self: Statement_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_statement_reset    :: proc(self: Statement_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_statement_finalize :: proc(self: Statement_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_statement_deinit   :: proc(self: Statement_Ptr) ---

	// Statement metadata - turso.h:236-250
	turso_statement_n_change         :: proc(self: Statement_Ptr) -> i64 ---
	turso_statement_column_count     :: proc(self: Statement_Ptr) -> i64 ---
	// FREE return string with turso_str_deinit
	turso_statement_column_name      :: proc(self: Statement_Ptr, index: uint) -> cstring ---
	// FREE return string with turso_str_deinit (or nil)
	turso_statement_column_decltype  :: proc(self: Statement_Ptr, index: uint) -> cstring ---

	// Row value accessors - turso.h:256-272
	// Pointer/byte lifetime: valid only until next step/reset/finalize.
	turso_statement_row_value_kind        :: proc(self: Statement_Ptr, index: uint) -> Value_Kind ---
	turso_statement_row_value_bytes_count :: proc(self: Statement_Ptr, index: uint) -> i64 ---
	turso_statement_row_value_bytes_ptr   :: proc(self: Statement_Ptr, index: uint) -> [^]u8 ---
	turso_statement_row_value_int         :: proc(self: Statement_Ptr, index: uint) -> i64 ---
	turso_statement_row_value_double      :: proc(self: Statement_Ptr, index: uint) -> f64 ---

	// Parameters - turso.h:278-294
	// 1-indexed; returns -1 if name not found.
	turso_statement_named_position    :: proc(self: Statement_Ptr, name: cstring) -> i64 ---
	turso_statement_parameters_count  :: proc(self: Statement_Ptr) -> i64 ---
	// FREE return string with turso_str_deinit (or nil for positional-only)
	turso_statement_parameter_name    :: proc(self: Statement_Ptr, index: i64) -> cstring ---

	// Positional bind - turso.h:297-318
	turso_statement_bind_positional_null   :: proc(self: Statement_Ptr, position: uint) -> Status_Code ---
	turso_statement_bind_positional_int    :: proc(self: Statement_Ptr, position: uint, value: i64) -> Status_Code ---
	turso_statement_bind_positional_double :: proc(self: Statement_Ptr, position: uint, value: f64) -> Status_Code ---
	turso_statement_bind_positional_blob   :: proc(self: Statement_Ptr, position: uint, ptr: [^]u8, len: uint) -> Status_Code ---
	turso_statement_bind_positional_text   :: proc(self: Statement_Ptr, position: uint, ptr: [^]u8, len: uint) -> Status_Code ---

	// String free - turso.h:321
	turso_str_deinit :: proc(self: cstring) ---
}
