package turso

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"

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
//
// Two-pass design: pass 1 walks every column and validates kind-vs-field-type
// without allocating; pass 2 then allocates + writes. This guarantees no
// orphaned TEXT/BLOB allocations on a kind-mismatch error — any earlier
// failure aborts before any allocation happens.
stmt_scan_struct :: proc(stmt: Statement, out: ^$T, allocator := context.allocator) -> (Error, bool) {
	if out == nil {
		return make_error(.MISUSE, "stmt_scan_struct", "out pointer is nil"), false
	}

	ti := runtime.type_info_base(type_info_of(T))
	s, is_struct := ti.variant.(runtime.Type_Info_Struct)
	if !is_struct {
		msg := fmt.tprintf("T must be a struct (got %v)", typeid_of(T))
		return make_error(.MISUSE, "stmt_scan_struct", msg), false
	}

	n := int(column_count(stmt))

	// Resolve column → field mapping once, validating types in the same pass.
	// For the common case (n <= STACK_COLS) the plans live on the stack so no
	// heap allocation happens on the happy path. Wider rows promote to a
	// temp-allocator slice so the binding does not artificially cap queries
	// below SQLITE_MAX_COLUMN (default 2000).
	//
	// 64 covers any reasonable struct row (column count in real-world apps is
	// typically well under 20). Larger rows are uncommon enough to be worth
	// paying a temp_allocator hit; on the hot path the stack version avoids
	// allocator pressure entirely.
	STACK_COLS :: 64
	stack_plans: [STACK_COLS]Scan_Plan
	heap_plans:  []Scan_Plan
	plans:       []Scan_Plan
	if n <= STACK_COLS {
		plans = stack_plans[:n]
	} else {
		heap_plans = make([]Scan_Plan, n, context.temp_allocator)
		plans = heap_plans
	}
	plan_count := 0

	for col_idx in 0 ..< n {
		// col_name is allocator-owned and only needed for the field lookup. We
		// delete it explicitly at end of use rather than deferring, because
		// Odin's defer is procedure-scoped: queueing N deferred deletes inside
		// a loop holds O(N) tiny strings until the function returns. For wide
		// rows that matters; on narrow rows it is identical.
		col_name := stmt_column_name(stmt, col_idx)
		field_index := find_field_for_column(s, col_name)
		delete(col_name)
		if field_index < 0 { continue }

		target_ptr := rawptr(uintptr(out) + s.offsets[field_index])
		field_type := s.types[field_index]
		display_name := s.names[field_index]
		kind := stmt_value_kind(stmt, col_idx)

		if e, ok := validate_column_against_field(kind, field_type, display_name); !ok {
			return e, false
		}

		plans[plan_count] = Scan_Plan{
			col_idx    = col_idx,
			target_ptr = target_ptr,
			field_type = field_type,
			kind       = kind,
		}
		plan_count += 1
	}

	// Allocation pass. Validation already succeeded, so every plan is safe to
	// execute and the only remaining failure mode (e.g. an OOM during clone)
	// is unrecoverable.
	for i in 0 ..< plan_count {
		p := plans[i]
		write_column(stmt, p.col_idx, p.target_ptr, p.field_type, p.kind, allocator)
	}
	return error_none(), true
}

@(private)
Scan_Plan :: struct {
	col_idx:    int,
	target_ptr: rawptr,
	field_type: ^runtime.Type_Info,
	kind:       Value_Kind,
}

// conn_query_one_struct prepares + binds + steps `sql`, expects exactly one
// row, and scans it into `out`. Returns an error for zero or two+ rows.
//
// `allocator` is forwarded to stmt_scan_struct for TEXT/BLOB allocations. On
// the two+ rows error path the binding releases the just-scanned fields so
// `out^` is restored to a zero struct rather than leaking owned memory the
// caller never gets a chance to free.
conn_query_one_struct :: proc(conn: Connection, sql: string, out: ^$T, args: ..Bind_Arg, allocator := context.allocator) -> (Error, bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return e1, false }
	defer {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}

	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return e2, false }
	}

	sr, e3, ok3 := step(stmt)
	if !ok3 { return e3, false }
	if sr != .Row {
		return make_error(.ERROR, "conn_query_one_struct", "expected exactly one row, got zero", sql), false
	}

	if se, sok := stmt_scan_struct(stmt, out, allocator); !sok { return se, false }

	sr2, _, _ := step(stmt)
	if sr2 == .Row {
		free_owned_out(out, allocator)
		return make_error(.ERROR, "conn_query_one_struct", "expected exactly one row, got multiple", sql), false
	}
	return error_none(), true
}

// conn_query_optional_struct is like conn_query_one_struct but tolerates zero
// rows: `found=false, ok=true` on no match. Two+ rows is still an error.
conn_query_optional_struct :: proc(conn: Connection, sql: string, out: ^$T, args: ..Bind_Arg, allocator := context.allocator) ->
	(found: bool, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return false, e1, false }
	defer {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}

	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return false, e2, false }
	}

	sr, e3, ok3 := step(stmt)
	if !ok3 { return false, e3, false }
	if sr != .Row { return false, error_none(), true }

	if se, sok := stmt_scan_struct(stmt, out, allocator); !sok { return false, se, false }

	sr2, _, _ := step(stmt)
	if sr2 == .Row {
		free_owned_out(out, allocator)
		return false, make_error(.ERROR, "conn_query_optional_struct", "expected at most one row, got multiple", sql), false
	}
	return true, error_none(), true
}

// free_owned_out releases any TEXT/BLOB field allocated into a `^T` by
// stmt_scan_struct. No-op when T is not a struct (the scan itself would have
// returned MISUSE before allocating, so there is nothing to free).
@(private)
free_owned_out :: proc(out: ^$T, allocator: mem.Allocator) {
	ti := runtime.type_info_base(type_info_of(T))
	s, is_struct := ti.variant.(runtime.Type_Info_Struct)
	if !is_struct { return }
	free_owned_row_fields(rawptr(out), s, allocator)
}

// conn_query_all_struct runs `sql` and scans every row into a caller-owned
// []T. T is passed explicitly because there's no input value to deduce
// from; usage: `rows, e, ok := turso.conn_query_all_struct(User_Row, conn, sql, bind_int(5))`.
//
// `allocator` is used both for the returned slice and for TEXT/BLOB fields
// inside each row. On error every row already scanned has its owned
// string/blob fields released through the same allocator before the function
// returns, so the caller never has to clean up a partial result.
conn_query_all_struct :: proc($T: typeid, conn: Connection, sql: string, args: ..Bind_Arg, allocator := context.allocator) ->
	(rows: []T, err: Error, ok: bool) {
	stmt, e1, ok1 := prepare(conn, sql)
	if !ok1 { return nil, e1, false }
	defer {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}

	if len(args) > 0 {
		if e2, ok2 := stmt_bind_args(stmt, ..args); !ok2 { return nil, e2, false }
	}

	out := make([dynamic]T, 0, 0, allocator)
	for {
		sr, e3, ok3 := step(stmt)
		if !ok3 {
			free_partial_rows(&out, allocator)
			return nil, e3, false
		}
		if sr != .Row { break }
		row: T
		if se, sok := stmt_scan_struct(stmt, &row, allocator); !sok {
			free_partial_rows(&out, allocator)
			return nil, se, false
		}
		append(&out, row)
	}
	return out[:], error_none(), true
}

// free_partial_rows walks an already-populated [dynamic]T and frees any
// string/[]u8 field that the row-mapping layer allocated. Used by
// conn_query_all_struct to clean up on error so the caller never sees a
// partially-populated slice with owned fields still alive.
@(private)
free_partial_rows :: proc(out: ^[dynamic]$T, allocator: mem.Allocator) {
	ti := runtime.type_info_base(type_info_of(T))
	s, is_struct := ti.variant.(runtime.Type_Info_Struct)
	if !is_struct {
		delete(out^)
		return
	}
	for &row in out^ {
		free_owned_row_fields(rawptr(&row), s, allocator)
	}
	delete(out^)
}

// free_owned_row_fields releases TEXT and BLOB fields the row-mapping layer
// populated via the caller's allocator. Skips other field kinds (integers,
// floats, booleans, cstrings, anything non-`string` non-`[]u8`) because they
// hold no allocations. Safe on a zero struct: empty strings/slices are no-ops.
@(private)
free_owned_row_fields :: proc(row_ptr: rawptr, s: runtime.Type_Info_Struct, allocator: mem.Allocator) {
	field_count := int(s.field_count)
	for j in 0 ..< field_count {
		field_type := s.types[j]
		base := runtime.type_info_base(field_type)
		field_ptr := rawptr(uintptr(row_ptr) + s.offsets[j])
		#partial switch v in base.variant {
		case runtime.Type_Info_String:
			if v.is_cstring { continue }
			str := (^string)(field_ptr)^
			if len(str) > 0 {
				delete(str, allocator)
				(^string)(field_ptr)^ = ""
			}
		case runtime.Type_Info_Slice:
			if v.elem.id != u8 { continue }
			b := (^[]u8)(field_ptr)^
			if len(b) > 0 {
				delete(b, allocator)
				(^[]u8)(field_ptr)^ = nil
			}
		}
	}
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

// validate_column_against_field is pass 1: checks that the source kind can be
// coerced into the destination field type. Never allocates. NULL kind is
// always accepted regardless of field type (the write pass will zero the
// destination region).
@(private)
validate_column_against_field :: proc(
	kind: Value_Kind,
	field_type: ^runtime.Type_Info,
	field_name: string,
) -> (Error, bool) {
	if kind == .NULL { return error_none(), true }
	base := runtime.type_info_base(field_type)

	#partial switch v in base.variant {
	case runtime.Type_Info_Integer:
		if kind != .INTEGER { return mismatch_error(field_name, kind, base), false }
		return error_none(), true
	case runtime.Type_Info_Float:
		if kind != .REAL    { return mismatch_error(field_name, kind, base), false }
		return error_none(), true
	case runtime.Type_Info_Boolean:
		if kind != .INTEGER { return mismatch_error(field_name, kind, base), false }
		return error_none(), true
	case runtime.Type_Info_String:
		if v.is_cstring     { return mismatch_error(field_name, kind, base), false }
		if kind != .TEXT    { return mismatch_error(field_name, kind, base), false }
		return error_none(), true
	case runtime.Type_Info_Slice:
		if v.elem.id != u8  { return mismatch_error(field_name, kind, base), false }
		if kind != .BLOB    { return mismatch_error(field_name, kind, base), false }
		return error_none(), true
	}
	return mismatch_error(field_name, kind, base), false
}

// write_column is pass 2: assumes validate_column_against_field already
// accepted the (kind, field_type) pair. Performs the actual allocation/copy
// into the struct field.
@(private)
write_column :: proc(
	stmt: Statement,
	col_idx: int,
	target_ptr: rawptr,
	field_type: ^runtime.Type_Info,
	kind: Value_Kind,
	allocator: mem.Allocator,
) {
	base := runtime.type_info_base(field_type)

	if kind == .NULL {
		intrinsics.mem_zero(target_ptr, base.size)
		return
	}

	#partial switch v in base.variant {
	case runtime.Type_Info_Integer:
		write_integer(target_ptr, base.size, v.signed, stmt_get_int(stmt, col_idx))
	case runtime.Type_Info_Float:
		write_float(target_ptr, base.size, stmt_get_double(stmt, col_idx))
	case runtime.Type_Info_Boolean:
		(^bool)(target_ptr)^ = stmt_get_int(stmt, col_idx) != 0
	case runtime.Type_Info_String:
		(^string)(target_ptr)^ = stmt_get_text(stmt, col_idx, allocator)
	case runtime.Type_Info_Slice:
		(^[]u8)(target_ptr)^ = stmt_get_blob(stmt, col_idx, allocator)
	}
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
	msg := fmt.tprintf("column kind=%v cannot map into field %q (size=%d)", kind, field_name, ti.size)
	return make_error(.ERROR, "stmt_scan_struct", msg)
}
