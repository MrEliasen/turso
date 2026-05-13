package turso

// conn_exec prepares a single statement, executes it, and finalizes. Returns rows-affected.
conn_exec :: proc(conn: Connection, sql: string) -> (rows: u64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer { _, _ = finalize(&stmt) }
	return execute(stmt)
}

// conn_exec_args prepares, binds positionals, executes, finalizes.
conn_exec_args :: proc(conn: Connection, sql: string, args: ..Bind_Arg) -> (rows: u64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer { _, _ = finalize(&stmt) }
	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return 0, e2, false }
	}
	return execute(stmt)
}

// conn_scalar_i64 runs a single-row scalar query and returns the first column as i64.
conn_scalar_i64 :: proc(conn: Connection, sql: string, args: ..Bind_Arg) -> (val: i64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer { _, _ = finalize(&stmt) }
	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return 0, e2, false }
	}
	sr, e3, ok3 := step(stmt)
	if !ok3 { return 0, e3, false }
	if sr != .Row {
		return 0, make_error(.ERROR, "conn_scalar_i64", "query returned no rows", sql), false
	}
	return stmt_get_int(stmt, 0), error_none(), true
}
