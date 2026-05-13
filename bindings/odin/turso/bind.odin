package turso

import "core:fmt"
import "core:strings"
import raw "raw"

@(private)
bind_status :: proc(stmt: Statement, code: Status_Code, op: string) -> (Error, bool) {
	if code == .OK { return error_none(), true }
	name := status_name(code)
	defer delete(name)
	return make_error(code, op, name, stmt.sql), false
}

stmt_bind_null :: proc(stmt: Statement, position: int) -> (Error, bool) {
	if stmt.handle == nil { return make_error(.MISUSE, "stmt_bind_null", "statement is not open"), false }
	return bind_status(stmt, raw.turso_statement_bind_positional_null(stmt.handle, uint(position)), "stmt_bind_null")
}

stmt_bind_int :: proc(stmt: Statement, position: int, value: i64) -> (Error, bool) {
	if stmt.handle == nil { return make_error(.MISUSE, "stmt_bind_int", "statement is not open"), false }
	return bind_status(stmt, raw.turso_statement_bind_positional_int(stmt.handle, uint(position), value), "stmt_bind_int")
}

stmt_bind_double :: proc(stmt: Statement, position: int, value: f64) -> (Error, bool) {
	if stmt.handle == nil { return make_error(.MISUSE, "stmt_bind_double", "statement is not open"), false }
	return bind_status(stmt, raw.turso_statement_bind_positional_double(stmt.handle, uint(position), value), "stmt_bind_double")
}

// Turso copies the payload internally - caller does not need to extend value's lifetime.
stmt_bind_text :: proc(stmt: Statement, position: int, value: string) -> (Error, bool) {
	if stmt.handle == nil { return make_error(.MISUSE, "stmt_bind_text", "statement is not open"), false }
	ptr: [^]u8 = nil
	if len(value) > 0 { ptr = raw_data(value) }
	code := raw.turso_statement_bind_positional_text(stmt.handle, uint(position), ptr, uint(len(value)))
	return bind_status(stmt, code, "stmt_bind_text")
}

stmt_bind_blob :: proc(stmt: Statement, position: int, value: []u8) -> (Error, bool) {
	if stmt.handle == nil { return make_error(.MISUSE, "stmt_bind_blob", "statement is not open"), false }
	ptr: [^]u8 = nil
	if len(value) > 0 { ptr = raw_data(value) }
	code := raw.turso_statement_bind_positional_blob(stmt.handle, uint(position), ptr, uint(len(value)))
	return bind_status(stmt, code, "stmt_bind_blob")
}

// stmt_param_position returns the 1-based position of a named parameter, plus
// a found flag. The name should include the SQL prefix (e.g. ":start", "?1",
// "$x"). Returns (0, false) for the not-found case so callers can distinguish
// it from any future addition of position 0. An embedded NUL in the name is
// likewise treated as not-found.
stmt_param_position :: proc(stmt: Statement, name: string) -> (int, bool) {
	if stmt.handle == nil || name == "" { return 0, false }
	for i in 0 ..< len(name) {
		if name[i] == 0x00 { return 0, false }
	}
	c_name := strings.clone_to_cstring(name, context.allocator)
	defer delete(c_name)
	pos := raw.turso_statement_named_position(stmt.handle, c_name)
	if pos <= 0 { return 0, false }
	return int(pos), true
}

// stmt_param_name returns the name of the parameter at index (1-based), including the SQL prefix.
// Returns "" for positional-only parameters or out-of-range indices.
stmt_param_name :: proc(stmt: Statement, index: int, allocator := context.allocator) -> string {
	if stmt.handle == nil || index <= 0 { return "" }
	c_name := raw.turso_statement_parameter_name(stmt.handle, i64(index))
	if c_name == nil { return "" }
	out := strings.clone_from_cstring(c_name, allocator)
	raw.turso_str_deinit(c_name)
	return out
}

stmt_bind :: proc(stmt: Statement, position: int, arg: Bind_Arg) -> (Error, bool) {
	switch arg.kind {
	case .Null:   return stmt_bind_null(stmt, position)
	case .Int:    return stmt_bind_int(stmt, position, arg.value.(i64))
	case .Double: return stmt_bind_double(stmt, position, arg.value.(f64))
	case .Text:   return stmt_bind_text(stmt, position, arg.value.(string))
	case .Blob:   return stmt_bind_blob(stmt, position, arg.value.([]u8))
	}
	return make_error(.MISUSE, "stmt_bind", "unknown Bind_Kind"), false
}

// stmt_bind_args binds positional arguments in order. Errors if more args than parameters.
stmt_bind_args :: proc(stmt: Statement, args: ..Bind_Arg) -> (Error, bool) {
	expected := parameters_count(stmt)
	if i64(len(args)) > expected {
		msg := fmt.aprintf("too many bind args: got %d, max %d", len(args), expected)
		defer delete(msg)
		return make_error(.MISUSE, "stmt_bind_args", msg, stmt.sql), false
	}
	for arg, i in args {
		e, ok := stmt_bind(stmt, i + 1, arg)
		if !ok { return e, false }
	}
	return error_none(), true
}

stmt_bind_named :: proc(stmt: Statement, name: string, arg: Bind_Arg) -> (Error, bool) {
	pos, found := stmt_param_position(stmt, name)
	if !found {
		msg := fmt.aprintf("named parameter not found: %q", name)
		defer delete(msg)
		return make_error(.MISUSE, "stmt_bind_named", msg, stmt.sql), false
	}
	return stmt_bind(stmt, pos, arg)
}

stmt_bind_named_null   :: proc(stmt: Statement, name: string)               -> (Error, bool) { return stmt_bind_named(stmt, name, bind_null()) }
stmt_bind_named_int    :: proc(stmt: Statement, name: string, v: i64)       -> (Error, bool) { return stmt_bind_named(stmt, name, bind_int(v)) }
stmt_bind_named_double :: proc(stmt: Statement, name: string, v: f64)       -> (Error, bool) { return stmt_bind_named(stmt, name, bind_double(v)) }
stmt_bind_named_text   :: proc(stmt: Statement, name: string, v: string)    -> (Error, bool) { return stmt_bind_named(stmt, name, bind_text(v)) }
stmt_bind_named_blob   :: proc(stmt: Statement, name: string, v: []u8)      -> (Error, bool) { return stmt_bind_named(stmt, name, bind_blob(v)) }
