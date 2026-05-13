package turso

import "core:strings"

// Transaction helpers — thin wrappers around `db_exec` for BEGIN/COMMIT/
// ROLLBACK/SAVEPOINT/RELEASE. No new FFI; everything goes through the
// existing exec path. Caller owns the conn; helpers only run SQL.
//
// `db_with_transaction` and `db_with_savepoint` are the high-leverage entry
// points: pass a body proc, return true to commit, false to roll back. They
// guarantee a cleanup pass even if the body returned false or never had a
// chance to return at all (currently the body cannot panic-recover, but the
// rollback path covers every other early-exit).

db_begin :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := db_exec(conn, "BEGIN")
	return e, ok
}

db_begin_deferred :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := db_exec(conn, "BEGIN DEFERRED")
	return e, ok
}

db_begin_immediate :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := db_exec(conn, "BEGIN IMMEDIATE")
	return e, ok
}

db_begin_exclusive :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := db_exec(conn, "BEGIN EXCLUSIVE")
	return e, ok
}

db_commit :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := db_exec(conn, "COMMIT")
	return e, ok
}

db_rollback :: proc(conn: Connection) -> (Error, bool) {
	_, e, ok := db_exec(conn, "ROLLBACK")
	return e, ok
}

// db_savepoint runs `SAVEPOINT "name"`. The name is double-quoted to escape
// reserved words / unusual characters; pre-existing double quotes are
// doubled per SQLite's identifier rules. NUL bytes in `name` are rejected
// up-front (they would truncate the C-string passed to the engine and yield
// a confusing parse error).
db_savepoint :: proc(conn: Connection, name: string) -> (Error, bool) {
	sql, name_ok := build_savepoint_sql("SAVEPOINT ", name)
	if !name_ok {
		return make_error(.MISUSE, "db_savepoint", "savepoint name contains NUL byte"), false
	}
	defer delete(sql)
	_, e, ok := db_exec(conn, sql)
	return e, ok
}

// db_release fires `RELEASE "name"`. Removes the savepoint from the stack
// and commits its work into the surrounding transaction (or outer DB if at
// top level).
db_release :: proc(conn: Connection, name: string) -> (Error, bool) {
	sql, name_ok := build_savepoint_sql("RELEASE ", name)
	if !name_ok {
		return make_error(.MISUSE, "db_release", "savepoint name contains NUL byte"), false
	}
	defer delete(sql)
	_, e, ok := db_exec(conn, sql)
	return e, ok
}

// db_rollback_to runs `ROLLBACK TO "name"`. Per SQLite semantics, this
// reverts work since the named savepoint but does NOT pop it from the
// stack — pair with db_release if you want to discard the savepoint.
db_rollback_to :: proc(conn: Connection, name: string) -> (Error, bool) {
	sql, name_ok := build_savepoint_sql("ROLLBACK TO ", name)
	if !name_ok {
		return make_error(.MISUSE, "db_rollback_to", "savepoint name contains NUL byte"), false
	}
	defer delete(sql)
	_, e, ok := db_exec(conn, sql)
	return e, ok
}

// db_with_transaction wraps `body` between BEGIN and COMMIT/ROLLBACK.
// Returns true to commit, false to roll back. If BEGIN fails the body is
// never called. If COMMIT fails after a successful body, the surfaced error
// is the commit error and the transaction has been rolled back implicitly
// by the engine.
db_with_transaction :: proc(conn: Connection, body: proc(conn: Connection) -> bool) -> (Error, bool) {
	if e, ok := db_begin(conn); !ok { return e, false }
	committed := false
	defer if !committed {
		_, _ = db_rollback(conn)
	}
	if !body(conn) {
		return error_none(), true
	}
	e, ok := db_commit(conn)
	if !ok { return e, false }
	committed = true
	return error_none(), true
}

// db_with_savepoint wraps `body` between SAVEPOINT name and RELEASE name.
// Returns true to release (commit savepoint work), false to roll back to
// the savepoint and then release it (discarding the body's writes).
db_with_savepoint :: proc(conn: Connection, name: string, body: proc(conn: Connection) -> bool) -> (Error, bool) {
	if e, ok := db_savepoint(conn, name); !ok { return e, false }
	released := false
	defer if !released {
		_, _ = db_rollback_to(conn, name)
		_, _ = db_release(conn, name)
	}
	if !body(conn) {
		return error_none(), true
	}
	e, ok := db_release(conn, name)
	if !ok { return e, false }
	released = true
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
