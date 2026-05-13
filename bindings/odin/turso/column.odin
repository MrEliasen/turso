package turso

import "core:strings"
import raw "raw"

// stmt_column_name returns the column name at index (0-based). Owned by caller.
stmt_column_name :: proc(stmt: Statement, index: int, allocator := context.allocator) -> string {
	if stmt.handle == nil || index < 0 { return "" }
	c_name := raw.turso_statement_column_name(stmt.handle, uint(index))
	if c_name == nil { return "" }
	out := strings.clone_from_cstring(c_name, allocator)
	raw.turso_str_deinit(c_name)
	return out
}

// stmt_column_decltype returns the declared type ("INTEGER", "TEXT", ...) at index.
// Returns "" for expressions or columns without a declared type.
stmt_column_decltype :: proc(stmt: Statement, index: int, allocator := context.allocator) -> string {
	if stmt.handle == nil || index < 0 { return "" }
	c_dt := raw.turso_statement_column_decltype(stmt.handle, uint(index))
	if c_dt == nil { return "" }
	out := strings.clone_from_cstring(c_dt, allocator)
	raw.turso_str_deinit(c_dt)
	return out
}

stmt_value_kind :: proc(stmt: Statement, index: int) -> Value_Kind {
	if stmt.handle == nil || index < 0 { return .UNKNOWN }
	return raw.turso_statement_row_value_kind(stmt.handle, uint(index))
}

stmt_is_null :: proc(stmt: Statement, index: int) -> bool {
	return stmt_value_kind(stmt, index) == .NULL
}

stmt_get_int :: proc(stmt: Statement, index: int) -> i64 {
	if stmt.handle == nil || index < 0 { return 0 }
	return raw.turso_statement_row_value_int(stmt.handle, uint(index))
}

stmt_get_double :: proc(stmt: Statement, index: int) -> f64 {
	if stmt.handle == nil || index < 0 { return 0 }
	return raw.turso_statement_row_value_double(stmt.handle, uint(index))
}

// stmt_get_text returns a copy of the column's text value. The underlying C pointer
// is only valid until the next step/reset/finalize (turso.h:253-254) so we copy here.
// Returns "" for NULL or non-text columns.
stmt_get_text :: proc(stmt: Statement, index: int, allocator := context.allocator) -> string {
	if stmt.handle == nil || index < 0 { return "" }
	if stmt_is_null(stmt, index) { return "" }
	count := raw.turso_statement_row_value_bytes_count(stmt.handle, uint(index))
	if count <= 0 { return "" }
	ptr := raw.turso_statement_row_value_bytes_ptr(stmt.handle, uint(index))
	if ptr == nil { return "" }
	src := ptr[:int(count)]
	out := make([]u8, int(count), allocator)
	copy(out, src)
	return string(out)
}

// stmt_get_blob returns a copy of the column's blob value. Same lifetime story as stmt_get_text.
stmt_get_blob :: proc(stmt: Statement, index: int, allocator := context.allocator) -> []u8 {
	if stmt.handle == nil || index < 0 { return nil }
	if stmt_is_null(stmt, index) { return nil }
	count := raw.turso_statement_row_value_bytes_count(stmt.handle, uint(index))
	if count < 0 { return nil }
	if count == 0 { return make([]u8, 0, allocator) }
	ptr := raw.turso_statement_row_value_bytes_ptr(stmt.handle, uint(index))
	if ptr == nil { return nil }
	src := ptr[:int(count)]
	out := make([]u8, int(count), allocator)
	copy(out, src)
	return out
}
