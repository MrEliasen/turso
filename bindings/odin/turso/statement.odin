package turso

import "core:strings"
import raw "raw"

// prepare compiles a single SQL statement on the connection.
// If sql contains multiple statements, only the first is compiled and remaining
// text is ignored - use prepare_first to iterate.
prepare :: proc(conn: Connection, sql: string) -> (Statement, Error, bool) {
	if conn.handle == nil {
		return Statement{}, Error{code = .MISUSE, op = "prepare", sql = sql, message = strings.clone("connection is not open")}, false
	}
	c_sql := strings.clone_to_cstring(sql, context.allocator)
	defer delete(c_sql)

	stmt_handle: raw.Statement_Ptr
	c_err: cstring
	code := raw.turso_connection_prepare_single(conn.handle, c_sql, &stmt_handle, &c_err)
	if code != .OK {
		return Statement{}, error_from_status(code, c_err, "turso_connection_prepare_single", sql), false
	}
	return Statement{handle = stmt_handle, db = conn.db, sql = sql}, error_none(), true
}

// prepare_first compiles the next statement from a multi-statement string and
// returns the byte offset immediately after the parsed statement. Loop over the
// result to consume the full string. Returns ok with a nil-handle Statement
// when no more statements can be parsed.
prepare_first :: proc(conn: Connection, sql: string) -> (stmt: Statement, tail: int, err: Error, ok: bool) {
	if conn.handle == nil {
		return Statement{}, 0, Error{code = .MISUSE, op = "prepare_first", sql = sql, message = strings.clone("connection is not open")}, false
	}
	c_sql := strings.clone_to_cstring(sql, context.allocator)
	defer delete(c_sql)

	stmt_handle: raw.Statement_Ptr
	tail_idx: uint
	c_err: cstring
	code := raw.turso_connection_prepare_first(conn.handle, c_sql, &stmt_handle, &tail_idx, &c_err)
	if code != .OK {
		return Statement{}, 0, error_from_status(code, c_err, "turso_connection_prepare_first", sql), false
	}
	if stmt_handle == nil {
		return Statement{}, int(tail_idx), error_none(), true
	}
	return Statement{handle = stmt_handle, db = conn.db, sql = sql}, int(tail_idx), error_none(), true
}

// step advances the statement one cycle. Returns .Row if a row is available,
// .Done when no more rows. TURSO_IO is never expected (sync I/O) and maps to an error.
step :: proc(stmt: Statement) -> (Step_Result, Error, bool) {
	if stmt.handle == nil {
		return .Done, Error{code = .MISUSE, op = "step", sql = stmt.sql, message = strings.clone("statement is not open")}, false
	}
	c_err: cstring
	code := raw.turso_statement_step(stmt.handle, &c_err)
	#partial switch code {
	case .ROW:
		return .Row, error_none(), true
	case .DONE:
		return .Done, error_none(), true
	case .IO:
		return .Done, error_from_status(code, c_err, "turso_statement_step", stmt.sql, "TURSO_IO returned while async_io is disabled (v1 limitation)"), false
	}
	return .Done, error_from_status(code, c_err, "turso_statement_step", stmt.sql), false
}

// execute drains a non-row-producing statement and returns rows-affected.
execute :: proc(stmt: Statement) -> (rows_changed: u64, err: Error, ok: bool) {
	if stmt.handle == nil {
		return 0, Error{code = .MISUSE, op = "execute", sql = stmt.sql, message = strings.clone("statement is not open")}, false
	}
	rows: u64
	c_err: cstring
	code := raw.turso_statement_execute(stmt.handle, &rows, &c_err)
	// turso.h:202 - execute returns DONE on completion.
	if code != .DONE && code != .OK {
		return 0, error_from_status(code, c_err, "turso_statement_execute", stmt.sql), false
	}
	return rows, error_none(), true
}

// reset rewinds the statement so it can be re-stepped. Bindings are preserved.
reset :: proc(stmt: Statement) -> (Error, bool) {
	if stmt.handle == nil { return error_none(), true }
	c_err: cstring
	code := raw.turso_statement_reset(stmt.handle, &c_err)
	if code != .OK {
		return error_from_status(code, c_err, "turso_statement_reset", stmt.sql), false
	}
	return error_none(), true
}

// finalize completes execution and releases statement resources. Idempotent.
finalize :: proc(stmt: ^Statement) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil { return error_none(), true }
	c_err: cstring
	code := raw.turso_statement_finalize(stmt.handle, &c_err)
	err := error_none()
	ok := true
	// turso.h:230 - finalize returns DONE on completion.
	if code != .DONE && code != .OK {
		err = error_from_status(code, c_err, "turso_statement_finalize", stmt.sql)
		ok = false
	}
	raw.turso_statement_deinit(stmt.handle)
	stmt.handle = nil
	return err, ok
}

n_change :: proc(stmt: Statement) -> i64 {
	if stmt.handle == nil { return 0 }
	return raw.turso_statement_n_change(stmt.handle)
}

column_count :: proc(stmt: Statement) -> i64 {
	if stmt.handle == nil { return 0 }
	return raw.turso_statement_column_count(stmt.handle)
}

parameters_count :: proc(stmt: Statement) -> i64 {
	if stmt.handle == nil { return 0 }
	return raw.turso_statement_parameters_count(stmt.handle)
}
