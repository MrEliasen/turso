package sync_raw

// Hand-written FFI surface matching sync/sdk-kit/turso_sync.h 1:1.
//
// Linking strategy (verified 2026-05-13):
//   `nm -gU target/debug/libturso_sync_sdk_kit.dylib` shows the sync cdylib
//   exports BOTH the 29 turso_sync_* functions and every turso_* core symbol
//   (database/connection/statement/setup/str/version). `otool -L` shows no
//   transitive dep on libturso_sdk_kit.dylib — the sync dylib is
//   self-contained.
//
//   Consequence: a binary that uses turso/sync MUST link only against
//   libturso_sync_sdk_kit. The parent turso/raw package is built with
//   -define:TURSO_USE_SYNC_DYLIB=true so its foreign import points at the
//   sync dylib too, keeping all FFI on a single memory namespace. Linking
//   both dylibs splits turso_core state and yields wrong-state access on
//   cross-lib pointer use.
//
// Build the shared library first:
//   cargo build -p turso_sync_sdk_kit
// then run odin via `make sync-test` (sets the define and rpath).

import core_raw "../../raw"

// Re-exports so wrappers in turso/sync can use raw.Status_Code without
// pulling the core raw package directly.
Status_Code      :: core_raw.Status_Code
Connection_Ptr   :: core_raw.Connection_Ptr
Database_Config  :: core_raw.Database_Config
turso_str_deinit :: core_raw.turso_str_deinit

when ODIN_OS == .Windows {
	foreign import sync "system:turso_sync_sdk_kit.dll"
} else when ODIN_OS == .Darwin {
	foreign import sync "system:turso_sync_sdk_kit"
} else when ODIN_OS == .Linux {
	foreign import sync "system:turso_sync_sdk_kit"
} else when ODIN_OS == .FreeBSD {
	foreign import sync "system:turso_sync_sdk_kit"
} else when ODIN_OS == .OpenBSD {
	foreign import sync "system:turso_sync_sdk_kit"
}

// turso_slice_ref_t - turso.h:13-17. Non-owning view into a memory region.
Slice_Ref :: struct {
	ptr: rawptr,
	len: uint,
}

// Opaque handle types - distinct so caller can't mix them.
Database_T  :: struct{}
Operation_T :: struct{}
Io_Item_T   :: struct{}
Changes_T   :: struct{}

Database_Ptr  :: ^Database_T
Operation_Ptr :: ^Operation_T
Io_Item_Ptr   :: ^Io_Item_T
Changes_Ptr   :: ^Changes_T

// turso_sync_io_request_type_t - turso_sync.h:13-23
Io_Request_Kind :: enum i32 {
	NONE       = 0,
	HTTP       = 1,
	FULL_READ  = 2,
	FULL_WRITE = 3,
}

// turso_sync_operation_result_type_t - turso_sync.h:66-76
Op_Result_Kind :: enum i32 {
	NONE       = 0,
	CONNECTION = 1,
	CHANGES    = 2,
	STATS      = 3,
}

// turso_sync_io_http_request_t - turso_sync.h:26-38
Http_Request :: struct {
	url:     Slice_Ref,
	method:  Slice_Ref,
	path:    Slice_Ref,
	body:    Slice_Ref,
	headers: i32,
}

// turso_sync_io_http_header_t - turso_sync.h:41-45
Http_Header :: struct {
	key:   Slice_Ref,
	value: Slice_Ref,
}

// turso_sync_io_full_read_request_t - turso_sync.h:48-52
Full_Read_Request :: struct {
	path: Slice_Ref,
}

// turso_sync_io_full_write_request_t - turso_sync.h:55-61
Full_Write_Request :: struct {
	path:    Slice_Ref,
	content: Slice_Ref,
}

// turso_sync_stats_t - turso_sync.h:85-95. revision is valid only during
// async operation lifetime; copy before turso_sync_operation_deinit.
Stats :: struct {
	cdc_operations:         i64,
	main_wal_size:          i64,
	revert_wal_size:        i64,
	last_pull_unix_time:    i64,
	last_push_unix_time:    i64,
	network_sent_bytes:     i64,
	network_received_bytes: i64,
	revision:               Slice_Ref,
}

// turso_sync_database_config_t - turso_sync.h:102-141
Sync_Database_Config :: struct {
	path:                              cstring,
	remote_url:                        cstring,
	client_name:                       cstring,
	long_poll_timeout_ms:              i32,
	bootstrap_if_empty:                b8,
	reserved_bytes:                    i32,
	partial_bootstrap_strategy_prefix: i32,
	partial_bootstrap_strategy_query:  cstring,
	partial_bootstrap_segment_size:    uint,
	partial_bootstrap_prefetch:        b8,
	remote_encryption_key:             cstring,
	remote_encryption_cipher:          cstring,
	push_operations_threshold:         uint,
	pull_bytes_threshold:              uint,
}

@(default_calling_convention = "c")
foreign sync {
	// Database lifecycle - turso_sync.h:155-193
	turso_sync_database_new     :: proc(db_config: ^Database_Config, sync_config: ^Sync_Database_Config, database: ^Database_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_open    :: proc(self: Database_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_create  :: proc(self: Database_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_connect :: proc(self: Database_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---

	// Operations - turso_sync.h:198-250
	turso_sync_database_stats         :: proc(self: Database_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_checkpoint    :: proc(self: Database_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_push_changes  :: proc(self: Database_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_wait_changes  :: proc(self: Database_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	// apply_changes CONSUMES the changes pointer. Caller MUST NOT call
	// turso_sync_changes_deinit afterward, even on failure.
	turso_sync_database_apply_changes :: proc(self: Database_Ptr, changes: Changes_Ptr, operation: ^Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---

	// Async operation control - turso_sync.h:252-283
	turso_sync_operation_resume                    :: proc(self: Operation_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_operation_result_kind               :: proc(self: Operation_Ptr) -> Op_Result_Kind ---
	turso_sync_operation_result_extract_connection :: proc(self: Operation_Ptr, connection: ^Connection_Ptr) -> Status_Code ---
	// extract_changes may set *changes to nil when status is OK (means "no changes available").
	turso_sync_operation_result_extract_changes    :: proc(self: Operation_Ptr, changes: ^Changes_Ptr) -> Status_Code ---
	turso_sync_operation_result_extract_stats      :: proc(self: Operation_Ptr, stats: ^Stats) -> Status_Code ---

	// IO loop - turso_sync.h:285-319
	turso_sync_database_io_take_item            :: proc(self: Database_Ptr, item: ^Io_Item_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_io_step_callbacks       :: proc(self: Database_Ptr, error_opt_out: ^cstring) -> Status_Code ---
	turso_sync_database_io_request_kind         :: proc(self: Io_Item_Ptr) -> Io_Request_Kind ---
	turso_sync_database_io_request_http         :: proc(self: Io_Item_Ptr, request: ^Http_Request) -> Status_Code ---
	turso_sync_database_io_request_http_header  :: proc(self: Io_Item_Ptr, index: uint, header: ^Http_Header) -> Status_Code ---
	turso_sync_database_io_request_full_read    :: proc(self: Io_Item_Ptr, request: ^Full_Read_Request) -> Status_Code ---
	turso_sync_database_io_request_full_write   :: proc(self: Io_Item_Ptr, request: ^Full_Write_Request) -> Status_Code ---

	// IO completion - turso_sync.h:321-331
	turso_sync_database_io_poison      :: proc(self: Io_Item_Ptr, error: ^Slice_Ref) -> Status_Code ---
	turso_sync_database_io_status      :: proc(self: Io_Item_Ptr, status: i32) -> Status_Code ---
	turso_sync_database_io_push_buffer :: proc(self: Io_Item_Ptr, buffer: ^Slice_Ref) -> Status_Code ---
	turso_sync_database_io_done        :: proc(self: Io_Item_Ptr) -> Status_Code ---

	// Cleanup - turso_sync.h:333-343
	turso_sync_database_deinit         :: proc(self: Database_Ptr) ---
	turso_sync_operation_deinit        :: proc(self: Operation_Ptr) ---
	turso_sync_database_io_item_deinit :: proc(self: Io_Item_Ptr) ---
	turso_sync_changes_deinit          :: proc(self: Changes_Ptr) ---
}
