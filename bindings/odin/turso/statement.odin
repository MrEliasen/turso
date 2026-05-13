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
// .Done when no more rows.
//
// When the underlying database was opened with async_io=true, step transparently
// drives run_io until the operation makes progress or terminates. To handle I/O
// yourself (e.g. event-loop integration), use step_once + run_io instead.
step :: proc(stmt: Statement) -> (Step_Result, Error, bool) {
	if stmt.handle == nil {
		return .Done, Error{code = .MISUSE, op = "step", sql = stmt.sql, message = strings.clone("statement is not open")}, false
	}
	c_err: cstring
	for {
		code := raw.turso_statement_step(stmt.handle, &c_err)
		#partial switch code {
		case .ROW:
			return .Row, error_none(), true
		case .DONE:
			return .Done, error_none(), true
		case .IO:
			if c_err != nil { raw.turso_str_deinit(c_err); c_err = nil }
			io_err: cstring
			io_code := raw.turso_statement_run_io(stmt.handle, &io_err)
			if io_code != .OK {
				return .Done, error_from_status(io_code, io_err, "turso_statement_run_io", stmt.sql), false
			}
			if io_err != nil { raw.turso_str_deinit(io_err) }
			continue
		}
		return .Done, error_from_status(code, c_err, "turso_statement_step", stmt.sql), false
	}
}

// step_once advances the statement exactly once without driving I/O. Returns the
// raw status code so the caller can react to TURSO_IO by calling run_io and retrying.
// For most callers, the blocking step() above is the right choice.
step_once :: proc(stmt: Statement) -> (code: Status_Code, err: Error, ok: bool) {
	if stmt.handle == nil {
		return .MISUSE, Error{code = .MISUSE, op = "step_once", sql = stmt.sql, message = strings.clone("statement is not open")}, false
	}
	c_err: cstring
	c := raw.turso_statement_step(stmt.handle, &c_err)
	#partial switch c {
	case .ROW, .DONE, .IO:
		if c_err != nil { raw.turso_str_deinit(c_err) }
		return c, error_none(), true
	}
	return c, error_from_status(c, c_err, "turso_statement_step", stmt.sql), false
}

// run_io drives one iteration of the underlying I/O backend after step_once or
// execute_once returned TURSO_IO. Returns OK on success or an error.
run_io :: proc(stmt: Statement) -> (Error, bool) {
	if stmt.handle == nil {
		return Error{code = .MISUSE, op = "run_io", sql = stmt.sql, message = strings.clone("statement is not open")}, false
	}
	c_err: cstring
	code := raw.turso_statement_run_io(stmt.handle, &c_err)
	if code != .OK {
		return error_from_status(code, c_err, "turso_statement_run_io", stmt.sql), false
	}
	if c_err != nil { raw.turso_str_deinit(c_err) }
	return error_none(), true
}

// execute drains a non-row-producing statement and returns rows-affected.
// Transparently drives run_io when async_io is enabled.
execute :: proc(stmt: Statement) -> (rows_changed: u64, err: Error, ok: bool) {
	if stmt.handle == nil {
		return 0, Error{code = .MISUSE, op = "execute", sql = stmt.sql, message = strings.clone("statement is not open")}, false
	}
	rows: u64
	c_err: cstring
	for {
		code := raw.turso_statement_execute(stmt.handle, &rows, &c_err)
		#partial switch code {
		case .DONE, .OK:
			if c_err != nil { raw.turso_str_deinit(c_err) }
			return rows, error_none(), true
		case .IO:
			if c_err != nil { raw.turso_str_deinit(c_err); c_err = nil }
			io_err: cstring
			io_code := raw.turso_statement_run_io(stmt.handle, &io_err)
			if io_code != .OK {
				return 0, error_from_status(io_code, io_err, "turso_statement_run_io", stmt.sql), false
			}
			if io_err != nil { raw.turso_str_deinit(io_err) }
			continue
		}
		return 0, error_from_status(code, c_err, "turso_statement_execute", stmt.sql), false
	}
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
// Transparently drives run_io when async_io is enabled.
finalize :: proc(stmt: ^Statement) -> (Error, bool) {
	if stmt == nil || stmt.handle == nil { return error_none(), true }
	err := error_none()
	ok := true
	c_err: cstring
	loop: for {
		code := raw.turso_statement_finalize(stmt.handle, &c_err)
		#partial switch code {
		case .DONE, .OK:
			if c_err != nil { raw.turso_str_deinit(c_err) }
			break loop
		case .IO:
			if c_err != nil { raw.turso_str_deinit(c_err); c_err = nil }
			io_err: cstring
			io_code := raw.turso_statement_run_io(stmt.handle, &io_err)
			if io_code != .OK {
				err = error_from_status(io_code, io_err, "turso_statement_run_io", stmt.sql)
				ok = false
				break loop
			}
			if io_err != nil { raw.turso_str_deinit(io_err) }
			continue
		}
		err = error_from_status(code, c_err, "turso_statement_finalize", stmt.sql)
		ok = false
		break
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
