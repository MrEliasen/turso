package turso

import "core:strings"

// Transaction helpers — thin wrappers around `conn_exec` for BEGIN/COMMIT/
// ROLLBACK/SAVEPOINT/RELEASE. No new FFI; everything goes through the
// existing exec path. Caller owns the conn; helpers only run SQL.
//
// `conn_with_transaction` and `conn_with_savepoint` are the high-leverage entry
// points: pass a body proc, return true to commit, false to roll back. They
// guarantee a cleanup pass even if the body returned false or never had a
// chance to return at all (currently the body cannot panic-recover, but the
// rollback path covers every other early-exit).

conn_begin :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := conn_exec(conn, "BEGIN")
	return e, ok
}

conn_begin_deferred :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := conn_exec(conn, "BEGIN DEFERRED")
	return e, ok
}

conn_begin_immediate :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := conn_exec(conn, "BEGIN IMMEDIATE")
	return e, ok
}

conn_begin_exclusive :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := conn_exec(conn, "BEGIN EXCLUSIVE")
	return e, ok
}

conn_commit :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := conn_exec(conn, "COMMIT")
	return e, ok
}

conn_rollback :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := conn_exec(conn, "ROLLBACK")
	return e, ok
}

// conn_savepoint runs `SAVEPOINT "name"`. The name is double-quoted to escape
// reserved words / unusual characters; pre-existing double quotes are
// doubled per SQLite's identifier rules. NUL bytes in `name` are rejected
// up-front (they would truncate the C-string passed to the engine and yield
// a confusing parse error).
conn_savepoint :: proc(conn: Connection, name: string) -> (Error, bool) {
	sql, name_ok := build_savepoint_sql("SAVEPOINT ", name)
	if !name_ok {
		return make_error(.MISUSE, "conn_savepoint", "savepoint name contains NUL byte"), false
	}
	defer delete(sql)
	_, e, ok := conn_exec(conn, sql)
	return e, ok
}

// conn_release fires `RELEASE "name"`. Removes the savepoint from the stack
// and commits its work into the surrounding transaction (or outer DB if at
// top level).
conn_release :: proc(conn: Connection, name: string) -> (Error, bool) {
	sql, name_ok := build_savepoint_sql("RELEASE ", name)
	if !name_ok {
		return make_error(.MISUSE, "conn_release", "savepoint name contains NUL byte"), false
	}
	defer delete(sql)
	_, e, ok := conn_exec(conn, sql)
	return e, ok
}

// conn_rollback_to runs `ROLLBACK TO "name"`. Per SQLite semantics, this
// reverts work since the named savepoint but does NOT pop it from the
// stack — pair with conn_release if you want to discard the savepoint.
conn_rollback_to :: proc(conn: Connection, name: string) -> (Error, bool) {
	sql, name_ok := build_savepoint_sql("ROLLBACK TO ", name)
	if !name_ok {
		return make_error(.MISUSE, "conn_rollback_to", "savepoint name contains NUL byte"), false
	}
	defer delete(sql)
	_, e, ok := conn_exec(conn, sql)
	return e, ok
}

// conn_with_transaction wraps `body` between BEGIN and COMMIT/ROLLBACK.
// Returns true to commit, false to roll back. If BEGIN fails the body is
// never called. If COMMIT fails after a successful body, the surfaced error
// is the commit error and the transaction has been rolled back implicitly
// by the engine.
//
// When the body returns false the wrapper runs ROLLBACK eagerly and surfaces
// any error from it rather than swallowing — a rollback that fails leaves
// the transaction in an unknown state, which the caller needs to know about.
conn_with_transaction :: proc(conn: Connection, body: proc(conn: Connection) -> bool) -> (Error, bool) {
	if e, ok := conn_begin(conn); !ok { return e, false }

	if !body(conn) {
		return conn_rollback(conn)
	}

	e, ok := conn_commit(conn)
	if !ok { return e, false }
	return error_none(), true
}

// conn_with_savepoint wraps `body` between SAVEPOINT name and RELEASE name.
// Returns true to release (commit savepoint work), false to roll back to
// the savepoint and then release it (discarding the body's writes).
//
// If the body returns false, both ROLLBACK TO and RELEASE run; the first
// non-OK error from either is surfaced rather than silently swallowed so the
// caller can react to a savepoint stack that drifted out of sync.
conn_with_savepoint :: proc(conn: Connection, name: string, body: proc(conn: Connection) -> bool) -> (Error, bool) {
	if e, ok := conn_savepoint(conn, name); !ok { return e, false }

	if !body(conn) {
		// Discard the body's writes. ROLLBACK TO does not pop the savepoint
		// per SQLite semantics, so RELEASE must follow to remove the entry
		// from the stack. We surface the first error we hit.
		rb_err, rb_ok := conn_rollback_to(conn, name)
		rel_err, rel_ok := conn_release(conn, name)
		if !rb_ok {
			error_destroy(&rel_err)
			return rb_err, false
		}
		if !rel_ok {
			error_destroy(&rb_err)
			return rel_err, false
		}
		return error_none(), true
	}

	e, ok := conn_release(conn, name)
	if !ok { return e, false }
	return error_none(), true
}

// build_savepoint_sql doubles embedded double-quotes (SQLite identifier
// escape) and rejects NUL bytes. Returns (sql, true) on success, ("", false)
// when name contained a NUL.
@(private)
build_savepoint_sql :: proc(prefix: string, name: string) -> (string, bool) {
	for i in 0 ..< len(name) {
		if name[i] == 0 { return "", false }
	}
	sb: strings.Builder
	strings.builder_init(&sb)
	strings.write_string(&sb, prefix)
	strings.write_byte(&sb, '"')
	for i in 0 ..< len(name) {
		c := name[i]
		if c == '"' { strings.write_byte(&sb, '"') }
		strings.write_byte(&sb, c)
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb), true
}
