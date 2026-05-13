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

// stmt_get_text returns a copy of the column's text value. The underlying C
// pointer is only valid until the next step/reset/finalize (turso.h:253-254)
// so we copy here. Returns "" for NULL, non-text columns, or out-of-range
// indices. Use stmt_get_text_ok when distinguishing a real NULL from an
// empty string matters.
stmt_get_text :: proc(stmt: Statement, index: int, allocator := context.allocator) -> string {
	out, _ := stmt_get_text_ok(stmt, index, allocator)
	return out
}

// stmt_get_text_ok mirrors stmt_get_text but also reports whether a non-NULL
// TEXT value was read. The second return is false for SQL NULL, for non-text
// kinds, and for the closed-handle / bad-index cases; in those cases the
// returned string is "". Caller still owns and must delete the string when
// the second return is true.
stmt_get_text_ok :: proc(stmt: Statement, index: int, allocator := context.allocator) -> (string, bool) {
	if stmt.handle == nil || index < 0 { return "", false }
	kind := stmt_value_kind(stmt, index)
	if kind == .NULL { return "", false }
	if kind != .TEXT { return "", false }
	count := raw.turso_statement_row_value_bytes_count(stmt.handle, uint(index))
	if count < 0 { return "", false }
	if count == 0 { return "", true }
	ptr := raw.turso_statement_row_value_bytes_ptr(stmt.handle, uint(index))
	if ptr == nil { return "", false }
	src := ptr[:int(count)]
	out := make([]u8, int(count), allocator)
	copy(out, src)
	return string(out), true
}

// stmt_get_blob returns a copy of the column's blob value. Same lifetime story
// as stmt_get_text. Returns nil for NULL or non-blob columns, and the empty
// slice for a present-but-zero-length BLOB. Use stmt_get_blob_ok if you need
// to distinguish "no value" from "zero-length value" without falling back to
// stmt_is_null.
stmt_get_blob :: proc(stmt: Statement, index: int, allocator := context.allocator) -> []u8 {
	out, _ := stmt_get_blob_ok(stmt, index, allocator)
	return out
}

stmt_get_blob_ok :: proc(stmt: Statement, index: int, allocator := context.allocator) -> ([]u8, bool) {
	if stmt.handle == nil || index < 0 { return nil, false }
	kind := stmt_value_kind(stmt, index)
	if kind == .NULL { return nil, false }
	if kind != .BLOB { return nil, false }
	count := raw.turso_statement_row_value_bytes_count(stmt.handle, uint(index))
	if count < 0 { return nil, false }
	if count == 0 { return make([]u8, 0, allocator), true }
	ptr := raw.turso_statement_row_value_bytes_ptr(stmt.handle, uint(index))
	if ptr == nil { return nil, false }
	src := ptr[:int(count)]
	out := make([]u8, int(count), allocator)
	copy(out, src)
	return out, true
}
