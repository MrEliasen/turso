package turso_sync

import raw "raw"
import turso "../"

// Config is the user-facing sync engine config. Mirrors turso_sync_database_config_t
// from sync/sdk-kit/turso_sync.h. path is required; everything else is optional.
//
// path:        local file that backs the synced DB (must be writable; auxiliary
//              metadata/WAL/revert files derive from this path).
// remote_url:  cloud endpoint, e.g. "https://<db>.turso.io" or "libsql://...".
//              Saved into local metadata on first run; subsequent opens can
//              re-use the persisted URL even if this field is left empty.
// client_name: arbitrary prefix used as part of the unique client identity.
// auth_token:  Bearer token. The IO dispatcher injects this as the
//              "Authorization: Bearer <token>" header on every HTTP request.
//              Static for the lifetime of the Sync_Database — refresh by
//              opening a new Sync_Database.
Config :: struct {
	path:                              string,
	remote_url:                        string,
	client_name:                       string,
	auth_token:                        string,
	long_poll_timeout_ms:              i32,
	bootstrap_if_empty:                bool,
	reserved_bytes:                    i32,
	partial_bootstrap_strategy_prefix: i32,
	partial_bootstrap_strategy_query:  string,
	partial_bootstrap_segment_size:    uint,
	partial_bootstrap_prefetch:        bool,
	remote_encryption_key:             string,
	remote_encryption_cipher:          string,
	push_operations_threshold:         uint,
	pull_bytes_threshold:              uint,
}

// Sync_Database owns the synced-DB handle, the HTTP client used to satisfy
// every IO request emitted by the engine, and a deep copy of the Config so the
// instance is independent of the caller's string lifetimes. Always pair with
// database_close.
//
// All sync operations on a Sync_Database must be serialized by the caller
// (same rule as the Go binding's internal mutex). Concurrent push/pull/
// checkpoint produces TURSO_MISUSE.
Sync_Database :: struct {
	handle: raw.Database_Ptr,
	client: HTTP_Client,
	config: Config,  // owned (deep-cloned from caller's Config at create time)
}

// Sync_Changes is an opaque change set produced by pull's wait-changes phase.
// Ownership rule: apply_changes CONSUMES the underlying pointer. The wrapper
// clears handle to nil after apply, so a follow-up changes_close is a no-op.
// If you want to discard the change set without applying, call changes_close.
Sync_Changes :: struct {
	handle: raw.Changes_Ptr,
}

// Stats is the snapshot returned by stats(). The revision string is owned by
// Stats and must be freed via stats_destroy or by deleting Stats.revision.
Stats :: struct {
	cdc_operations:         i64,
	main_wal_size:          i64,
	revert_wal_size:        i64,
	last_pull_unix_time:    i64,
	last_push_unix_time:    i64,
	network_sent_bytes:     i64,
	network_received_bytes: i64,
	revision:               string,  // owned
}

stats_destroy :: proc(s: ^Stats) {
	if s == nil { return }
	if len(s.revision) > 0 {
		delete(s.revision)
		s.revision = ""
	}
}

// Op_Result_Kind is re-exported so tests can inspect operation kinds without
// reaching into raw.
Op_Result_Kind :: raw.Op_Result_Kind

// sync_db_is_open reports whether the database handle is non-nil.
sync_db_is_open :: proc(d: Sync_Database) -> bool { return d.handle != nil }

@(private)
sync_misuse :: proc(op: string, reason: string) -> turso.Error {
	return turso.make_error(.MISUSE, op, reason)
}
