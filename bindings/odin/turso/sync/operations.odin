package turso_sync

import "core:strings"
import raw "raw"
import core_raw "../raw"
import turso "../"

// connect drives the connect async op, extracts the turso_connection_t, and
// wraps it as a turso.Connection ready for prepare/step/finalize. Caller must
// call turso.conn_close on the returned Connection.
//
// Applies busy_timeout_ms from the core Database_Config if > 0 (matches the
// non-sync connect's behavior).
connect :: proc(db: Sync_Database) -> (turso.Connection, turso.Error, bool) {
	if db.handle == nil {
		return turso.Connection{}, sync_misuse("sync.connect", "sync database is not open"), false
	}
	op: raw.Operation_Ptr
	c_err: cstring
	if code := raw.turso_sync_database_connect(db.handle, &op, &c_err); code != .OK {
		return turso.Connection{}, turso.error_from_status(code, c_err, "turso_sync_database_connect"), false
	}
	defer raw.turso_sync_operation_deinit(op)

	kind, err, ok := drive_op_until_done(db.handle, op, db.client, db.config.remote_url, db.config.auth_token, "sync.connect")
	if !ok {
		return turso.Connection{}, err, false
	}
	if kind != .CONNECTION {
		return turso.Connection{}, sync_misuse("sync.connect", "unexpected operation result kind for connect"), false
	}

	conn_handle: core_raw.Connection_Ptr
	if code := raw.turso_sync_operation_result_extract_connection(op, &conn_handle); code != .OK {
		return turso.Connection{}, turso.error_from_status(code, nil, "turso_sync_operation_result_extract_connection"), false
	}
	// db field is informational metadata only; sync's underlying db lives in
	// the sync handle and the core code never dereferences it.
	conn := turso.Connection{handle = conn_handle, db = nil}
	return conn, turso.error_none(), true
}

// push pushes local CDC operations to the remote. Synchronously drives the IO
// loop until the engine reports done.
push :: proc(db: Sync_Database) -> (turso.Error, bool) {
	if db.handle == nil {
		return sync_misuse("sync.push", "sync database is not open"), false
	}
	op: raw.Operation_Ptr
	c_err: cstring
	if code := raw.turso_sync_database_push_changes(db.handle, &op, &c_err); code != .OK {
		return turso.error_from_status(code, c_err, "turso_sync_database_push_changes"), false
	}
	defer raw.turso_sync_operation_deinit(op)
	_, err, ok := drive_op_until_done(db.handle, op, db.client, db.config.remote_url, db.config.auth_token, "sync.push")
	if !ok {
		return err, false
	}
	return turso.error_none(), true
}

// checkpoint truncates the local WAL after committing all pending changes
// against the remote.
checkpoint :: proc(db: Sync_Database) -> (turso.Error, bool) {
	if db.handle == nil {
		return sync_misuse("sync.checkpoint", "sync database is not open"), false
	}
	op: raw.Operation_Ptr
	c_err: cstring
	if code := raw.turso_sync_database_checkpoint(db.handle, &op, &c_err); code != .OK {
		return turso.error_from_status(code, c_err, "turso_sync_database_checkpoint"), false
	}
	defer raw.turso_sync_operation_deinit(op)
	_, err, ok := drive_op_until_done(db.handle, op, db.client, db.config.remote_url, db.config.auth_token, "sync.checkpoint")
	if !ok {
		return err, false
	}
	return turso.error_none(), true
}

// pull fetches remote changes (wait_changes) and applies them locally
// (apply_changes). Returns applied=true if changes were fetched and applied,
// applied=false if the wait_changes step reports no changes available.
pull :: proc(db: Sync_Database) -> (applied: bool, err: turso.Error, ok: bool) {
	if db.handle == nil {
		return false, sync_misuse("sync.pull", "sync database is not open"), false
	}

	// Phase 1: wait_changes.
	wait_op: raw.Operation_Ptr
	c_err: cstring
	if code := raw.turso_sync_database_wait_changes(db.handle, &wait_op, &c_err); code != .OK {
		return false, turso.error_from_status(code, c_err, "turso_sync_database_wait_changes"), false
	}

	wait_kind, wait_err, wait_ok := drive_op_until_done(db.handle, wait_op, db.client, db.config.remote_url, db.config.auth_token, "sync.pull")
	if !wait_ok {
		raw.turso_sync_operation_deinit(wait_op)
		return false, wait_err, false
	}
	if wait_kind != .CHANGES {
		raw.turso_sync_operation_deinit(wait_op)
		return false, sync_misuse("sync.pull", "unexpected operation result kind for wait_changes"), false
	}

	changes_handle: raw.Changes_Ptr
	if code := raw.turso_sync_operation_result_extract_changes(wait_op, &changes_handle); code != .OK {
		raw.turso_sync_operation_deinit(wait_op)
		return false, turso.error_from_status(code, nil, "turso_sync_operation_result_extract_changes"), false
	}
	raw.turso_sync_operation_deinit(wait_op)

	if changes_handle == nil {
		return false, turso.error_none(), true
	}

	// Phase 2: apply_changes. CONSUMES the changes handle even on failure —
	// do not call turso_sync_changes_deinit afterward.
	//
	// Failure path note: when apply_changes returns non-OK we return at the
	// next line WITHOUT reaching the deferred deinit on the line below, which
	// is correct because the C ABI guarantees `*apply_op` is left nil on
	// failure (see turso_sync.h on turso_sync_database_apply_changes). Should
	// a future engine change leak a non-nil operation on failure, the early
	// return would leak it; revisit then.
	apply_op: raw.Operation_Ptr
	if code := raw.turso_sync_database_apply_changes(db.handle, changes_handle, &apply_op, &c_err); code != .OK {
		return false, turso.error_from_status(code, c_err, "turso_sync_database_apply_changes"), false
	}
	defer raw.turso_sync_operation_deinit(apply_op)
	_, apply_err, apply_ok := drive_op_until_done(db.handle, apply_op, db.client, db.config.remote_url, db.config.auth_token, "sync.pull")
	if !apply_ok {
		return false, apply_err, false
	}
	return true, turso.error_none(), true
}

// stats collects sync engine counters and the current server revision.
// The returned Stats.revision is owned — free via stats_destroy or delete the field.
stats :: proc(db: Sync_Database) -> (Stats, turso.Error, bool) {
	if db.handle == nil {
		return Stats{}, sync_misuse("sync.stats", "sync database is not open"), false
	}
	op: raw.Operation_Ptr
	c_err: cstring
	if code := raw.turso_sync_database_stats(db.handle, &op, &c_err); code != .OK {
		return Stats{}, turso.error_from_status(code, c_err, "turso_sync_database_stats"), false
	}
	defer raw.turso_sync_operation_deinit(op)

	kind, err, ok := drive_op_until_done(db.handle, op, db.client, db.config.remote_url, db.config.auth_token, "sync.stats")
	if !ok {
		return Stats{}, err, false
	}
	if kind != .STATS {
		return Stats{}, sync_misuse("sync.stats", "unexpected operation result kind for stats"), false
	}

	raw_stats: raw.Stats
	if code := raw.turso_sync_operation_result_extract_stats(op, &raw_stats); code != .OK {
		return Stats{}, turso.error_from_status(code, nil, "turso_sync_operation_result_extract_stats"), false
	}
	// Copy revision before the op is deinitialized at function exit.
	revision_borrowed := slice_to_string(raw_stats.revision)
	out := Stats{
		cdc_operations         = raw_stats.cdc_operations,
		main_wal_size          = raw_stats.main_wal_size,
		revert_wal_size        = raw_stats.revert_wal_size,
		last_pull_unix_time    = raw_stats.last_pull_unix_time,
		last_push_unix_time    = raw_stats.last_push_unix_time,
		network_sent_bytes     = raw_stats.network_sent_bytes,
		network_received_bytes = raw_stats.network_received_bytes,
	}
	if len(revision_borrowed) > 0 {
		out.revision = strings.clone(revision_borrowed)
	}
	return out, turso.error_none(), true
}

