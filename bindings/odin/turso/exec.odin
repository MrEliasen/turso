package turso

// conn_exec prepares a single statement, executes it, and finalizes. Returns
// rows-affected. Only the first statement in `sql` is compiled; trailing text
// is ignored — use conn_exec_batch if you need to run a multi-statement
// script (DDL bundles, fixture loaders, etc.).
conn_exec :: proc(conn: Connection, sql: string) -> (rows: u64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}
	return execute(stmt)
}

// conn_exec_args prepares, binds positionals, executes, finalizes. Same
// single-statement semantics as conn_exec: trailing statements in `sql` are
// ignored.
conn_exec_args :: proc(conn: Connection, sql: string, args: ..Bind_Arg) -> (rows: u64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}
	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return 0, e2, false }
	}
	return execute(stmt)
}

// conn_exec_batch executes every statement in `sql` in order. It loops over
// prepare_first / execute / finalize until the parser stops producing
// statements. Returns the cumulative row count from the executed statements.
// On error, the offending statement's error is surfaced and any statements
// before it are left committed (this matches the behavior of running
// `sqlite3 db < script.sql`). No implicit transaction is opened; wrap the
// call in conn_with_transaction if you want all-or-nothing semantics.
//
// Mirrors `bindings/rust`'s `Connection::execute_batch` and the Go binding's
// multi-statement Exec path (see TestMultiStatementExecution).
conn_exec_batch :: proc(conn: Connection, sql: string) -> (rows: u64, err: Error, ok: bool) {
	if conn.handle == nil {
		return 0, make_error(.MISUSE, "conn_exec_batch", "connection is not open", sql), false
	}
	remaining := sql
	total: u64
	for len(remaining) > 0 {
		stmt, tail, e, ok2 := prepare_first(conn, remaining)
		if !ok2 { return total, e, false }
		if !stmt_is_open(stmt) {
			// parser saw whitespace / comments only; consume the tail and stop.
			break
		}
		executed, ee, eok := execute(stmt)
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
		if !eok { return total, ee, false }
		total += executed
		remaining = remaining[tail:]
	}
	return total, error_none(), true
}

// conn_scalar_i64 runs a single-row scalar query and returns the first column as i64.
conn_scalar_i64 :: proc(conn: Connection, sql: string, args: ..Bind_Arg) -> (val: i64, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return 0, e1, false }
	defer {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}
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
