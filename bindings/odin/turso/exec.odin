package turso

import "core:strings"

// db_exec prepares a single statement, executes it, and finalizes. Returns rows-affected.
db_exec :: proc(conn: Connection, sql: string) -> (rows: u64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer { _, _ = finalize(&stmt) }
	return execute(stmt)
}

// db_exec_args prepares, binds positionals, executes, finalizes.
db_exec_args :: proc(conn: Connection, sql: string, args: ..Bind_Arg) -> (rows: u64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer { _, _ = finalize(&stmt) }
	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return 0, e2, false }
	}
	return execute(stmt)
}

// db_scalar_i64 runs a single-row scalar query and returns the first column as i64.
db_scalar_i64 :: proc(conn: Connection, sql: string, args: ..Bind_Arg) -> (val: i64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer { _, _ = finalize(&stmt) }
	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return 0, e2, false }
	}
	sr, e3, ok3 := step(stmt)
	if !ok3 { return 0, e3, false }
	if sr != .Row {
		return 0, Error{
			code    = .ERROR,
			op      = "db_scalar_i64",
			sql     = sql,
			message = strings.clone("query returned no rows"),
		}, false
	}
	return stmt_get_int(stmt, 0), error_none(), true
}
