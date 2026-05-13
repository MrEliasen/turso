package turso

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

// Reflection-based row → struct mapping. No FFI changes; everything goes
// through the existing column accessors. Name resolution: field tag
// `turso:"col_name"` wins, otherwise the field's Odin name. Comparison is
// case-sensitive — same convention as core:encoding/json.
//
// Type coercion table:
//   INTEGER → i64/i32/i16/i8/int/u64/u32/u16/u8/bool
//   REAL    → f64/f32
//   TEXT    → string  (allocated via `allocator`)
//   BLOB    → []u8    (allocated via `allocator`)
//   NULL    → field's zero value (string="", []u8=nil, numeric=0, bool=false)
//   anything else → mismatch error with field name + column kind
//
// Columns with no matching field are silently dropped. Struct fields with
// no matching column are left at their zero value. Caller is expected to
// pass a freshly-declared `T` (Odin zero-inits) — we do not pre-zero.

// stmt_scan_struct populates `out^` from the current row. Caller must have
// stepped the statement to a Row first.
stmt_scan_struct :: proc(stmt: Statement, out: ^$T, allocator := context.allocator) -> (Error, bool) {
	if out == nil {
		return Error{
			code = .MISUSE, op = "stmt_scan_struct",
			message = strings.clone("out pointer is nil"),
		}, false
	}

	ti := runtime.type_info_base(type_info_of(T))
	s, is_struct := ti.variant.(runtime.Type_Info_Struct)
	if !is_struct {
		return Error{
			code = .MISUSE, op = "stmt_scan_struct",
			message = strings.clone(fmt.tprintf("T must be a struct (got %v)", typeid_of(T))),
		}, false
	}

	n := int(column_count(stmt))
	for col_idx in 0 ..< n {
		col_name := stmt_column_name(stmt, col_idx)
		defer delete(col_name)

		field_index := find_field_for_column(s, col_name)
		if field_index < 0 { continue }

		target_ptr := rawptr(uintptr(out) + s.offsets[field_index])
		field_type := s.types[field_index]
		display_name := s.names[field_index]

		if e, ok := scan_column_into(stmt, col_idx, target_ptr, field_type, display_name, allocator); !ok {
			return e, false
		}
	}
	return error_none(), true
}

// db_query_one_struct prepares + binds + steps `sql`, expects exactly one
// row, and scans it into `out`. Returns an error for zero or two+ rows.
db_query_one_struct :: proc(conn: Connection, sql: string, out: ^$T, args: ..Bind_Arg) -> (Error, bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return e1, false }
	defer { _, _ = finalize(&stmt) }

	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return e2, false }
	}

	sr, e3, ok3 := step(stmt)
	if !ok3 { return e3, false }
	if sr != .Row {
		return Error{
			code = .ERROR, op = "db_query_one_struct", sql = strings.clone(sql),
			message = strings.clone("expected exactly one row, got zero"),
		}, false
	}

	if se, sok := stmt_scan_struct(stmt, out); !sok { return se, false }

	sr2, _, _ := step(stmt)
	if sr2 == .Row {
		return Error{
			code = .ERROR, op = "db_query_one_struct", sql = strings.clone(sql),
			message = strings.clone("expected exactly one row, got multiple"),
		}, false
	}
	return error_none(), true
}

// db_query_optional_struct is like db_query_one_struct but tolerates zero
// rows: `found=false, ok=true` on no match. Two+ rows is still an error.
db_query_optional_struct :: proc(conn: Connection, sql: string, out: ^$T, args: ..Bind_Arg) ->
	(found: bool, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return false, e1, false }
	defer { _, _ = finalize(&stmt) }

	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return false, e2, false }
	}

	sr, e3, ok3 := step(stmt)
	if !ok3 { return false, e3, false }
	if sr != .Row { return false, error_none(), true }

	if se, sok := stmt_scan_struct(stmt, out); !sok { return false, se, false }

	sr2, _, _ := step(stmt)
	if sr2 == .Row {
		return false, Error{
			code = .ERROR, op = "db_query_optional_struct", sql = strings.clone(sql),
			message = strings.clone("expected at most one row, got multiple"),
		}, false
	}
	return true, error_none(), true
}

// db_query_all_struct runs `sql` and scans every row into a caller-owned
// []T. T is passed explicitly because there's no input value to deduce
// from; usage: `rows, e, ok := turso.db_query_all_struct(User_Row, conn, sql, bind_int(5))`.
db_query_all_struct :: proc($T: typeid, conn: Connection, sql: string, args: ..Bind_Arg) ->
	(rows: []T, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return nil, e1, false }
	defer { _, _ = finalize(&stmt) }

	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return nil, e2, false }
	}

	out: [dynamic]T
	for {
		sr, e3, ok3 := step(stmt)
		if !ok3 { delete(out); return nil, e3, false }
		if sr != .Row { break }
		row: T
		if se, sok := stmt_scan_struct(stmt, &row); !sok {
			delete(out); return nil, se, false
		}
		append(&out, row)
	}
	return out[:], error_none(), true
}

@(private)
find_field_for_column :: proc(s: runtime.Type_Info_Struct, col_name: string) -> int {
	field_count := int(s.field_count)
	for j in 0 ..< field_count {
		if field_target_name(s, j) == col_name { return j }
	}
	return -1
}

@(private)
field_target_name :: proc(s: runtime.Type_Info_Struct, j: int) -> string {
	tag := reflect.Struct_Tag(s.tags[j])
	if v, ok := reflect.struct_tag_lookup(tag, "turso"); ok { return v }
	return s.names[j]
}

@(private)
scan_column_into :: proc(
	stmt: Statement,
	col_idx: int,
	target_ptr: rawptr,
	field_type: ^runtime.Type_Info,
	field_name: string,
	allocator: mem.Allocator,
) -> (Error, bool) {
	kind := stmt_value_kind(stmt, col_idx)
	base := runtime.type_info_base(field_type)

	if kind == .NULL {
		// Zero the destination region. Works for primitives, strings ({nil,0})
		// and slices ({nil,0}). Caller is expected to pass a freshly-declared
		// T, so this is usually a no-op — but cheap insurance for reused structs.
		intrinsics.mem_zero(target_ptr, base.size)
		return error_none(), true
	}

	#partial switch v in base.variant {
	case runtime.Type_Info_Integer:
		if kind != .INTEGER { return mismatch_error(field_name, kind, base), false }
		write_integer(target_ptr, base.size, v.signed, stmt_get_int(stmt, col_idx))
		return error_none(), true

	case runtime.Type_Info_Float:
		if kind != .REAL { return mismatch_error(field_name, kind, base), false }
		write_float(target_ptr, base.size, stmt_get_double(stmt, col_idx))
		return error_none(), true

	case runtime.Type_Info_Boolean:
		if kind != .INTEGER { return mismatch_error(field_name, kind, base), false }
		(^bool)(target_ptr)^ = stmt_get_int(stmt, col_idx) != 0
		return error_none(), true

	case runtime.Type_Info_String:
		if v.is_cstring { return mismatch_error(field_name, kind, base), false }
		if kind != .TEXT { return mismatch_error(field_name, kind, base), false }
		(^string)(target_ptr)^ = stmt_get_text(stmt, col_idx, allocator)
		return error_none(), true

	case runtime.Type_Info_Slice:
		if v.elem.id != u8 { return mismatch_error(field_name, kind, base), false }
		if kind != .BLOB { return mismatch_error(field_name, kind, base), false }
		(^[]u8)(target_ptr)^ = stmt_get_blob(stmt, col_idx, allocator)
		return error_none(), true
	}

	return mismatch_error(field_name, kind, base), false
}

@(private)
write_integer :: proc(target_ptr: rawptr, size: int, signed: bool, val: i64) {
	switch size {
	case 8:
		if signed { (^i64)(target_ptr)^ = val } else { (^u64)(target_ptr)^ = u64(val) }
	case 4:
		if signed { (^i32)(target_ptr)^ = i32(val) } else { (^u32)(target_ptr)^ = u32(val) }
	case 2:
		if signed { (^i16)(target_ptr)^ = i16(val) } else { (^u16)(target_ptr)^ = u16(val) }
	case 1:
		if signed { (^i8)(target_ptr)^ = i8(val) } else { (^u8)(target_ptr)^ = u8(val) }
	}
}

@(private)
write_float :: proc(target_ptr: rawptr, size: int, val: f64) {
	switch size {
	case 8: (^f64)(target_ptr)^ = val
	case 4: (^f32)(target_ptr)^ = f32(val)
	}
}

@(private)
mismatch_error :: proc(field_name: string, kind: Value_Kind, ti: ^runtime.Type_Info) -> Error {
	return Error{
		code    = .ERROR,
		op      = "stmt_scan_struct",
		message = strings.clone(fmt.tprintf(
			"column kind=%v cannot map into field %q (size=%d)", kind, field_name, ti.size,
		)),
	}
}
