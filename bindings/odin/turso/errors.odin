package turso

import "core:fmt"
import "core:strings"
import raw "raw"

error_none :: proc() -> Error { return Error{} }

// error_ok returns true for OK and DONE status codes. Anything else is an error.
error_ok :: proc(err: Error) -> bool {
	return err.code == .OK || err.code == .DONE
}

// take_error_string consumes a turso-allocated C string (from **error_opt_out or column_name etc.),
// clones it into Odin memory, and frees the C original via turso_str_deinit. Returns "" for nil.
take_error_string :: proc(c_err: cstring, allocator := context.allocator) -> string {
	if c_err == nil {
		return ""
	}
	out := strings.clone_from_cstring(c_err, allocator)
	raw.turso_str_deinit(c_err)
	return out
}

// error_destroy releases owned strings (message + sql). Safe on zero Error.
error_destroy :: proc(err: ^Error) {
	if err == nil { return }
	if len(err.message) > 0 {
		delete(err.message)
		err.message = ""
	}
	if len(err.sql) > 0 {
		delete(err.sql)
		err.sql = ""
	}
}

// make_error builds an Error with cloned message and sql so the returned value
// is independent of any caller-side buffer. Pass "" for fields you don't want set.
// Use this for synthetic errors (no C-side error string); use error_from_status
// when the C ABI handed back a cstring.
make_error :: proc(
	code: Status_Code,
	op: string = "",
	message: string = "",
	sql: string = "",
	ctx: string = "",
) -> Error {
	e := Error{code = code, op = op, ctx = ctx}
	if message != "" { e.message = strings.clone(message) }
	if sql     != "" { e.sql     = strings.clone(sql) }
	return e
}

error_from_status :: proc(
	code: Status_Code,
	c_err: cstring,
	op: string = "",
	sql: string = "",
	ctx: string = "",
) -> Error {
	sql_owned: string
	if sql != "" { sql_owned = strings.clone(sql) }
	return Error{
		code    = code,
		message = take_error_string(c_err),
		sql     = sql_owned,
		op      = op,
		ctx     = ctx,
	}
}

// status_name returns a human-readable label for a Status_Code. The result is
// allocator-owned so the caller can free it uniformly regardless of whether
// the code was a known constant or an unknown numeric value. Freeing with
// delete is always safe.
status_name :: proc(c: Status_Code, allocator := context.allocator) -> string {
	literal: string
	switch c {
	case .OK:            literal = "TURSO_OK"
	case .DONE:          literal = "TURSO_DONE"
	case .ROW:           literal = "TURSO_ROW"
	case .IO:            literal = "TURSO_IO"
	case .BUSY:          literal = "TURSO_BUSY"
	case .INTERRUPT:     literal = "TURSO_INTERRUPT"
	case .BUSY_SNAPSHOT: literal = "TURSO_BUSY_SNAPSHOT"
	case .ERROR:         literal = "TURSO_ERROR"
	case .MISUSE:        literal = "TURSO_MISUSE"
	case .CONSTRAINT:    literal = "TURSO_CONSTRAINT"
	case .READONLY:      literal = "TURSO_READONLY"
	case .DATABASE_FULL: literal = "TURSO_DATABASE_FULL"
	case .NOTADB:        literal = "TURSO_NOTADB"
	case .CORRUPT:       literal = "TURSO_CORRUPT"
	case .IOERR:         literal = "TURSO_IOERR"
	}
	if literal != "" {
		return strings.clone(literal, allocator)
	}
	return fmt.aprintf("TURSO_UNKNOWN(%d)", i32(c), allocator = allocator)
}

// error_string formats an Error for display. The returned string is allocator-owned.
error_string :: proc(err: Error, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	name := status_name(err.code, allocator)
	defer delete(name, allocator)
	fmt.sbprintf(&sb, "turso: %s (%d)", name, i32(err.code))
	if len(err.op)      > 0 { fmt.sbprintf(&sb, " op=%q", err.op) }
	if len(err.message) > 0 { fmt.sbprintf(&sb, " message=%q", err.message) }
	if len(err.ctx)     > 0 { fmt.sbprintf(&sb, " ctx=%q", err.ctx) }
	if len(err.sql)     > 0 { fmt.sbprintf(&sb, " sql=%q", err.sql) }
	return strings.to_string(sb)
}

// delete_zeroed_cstring zeros the bytes of a heap-allocated cstring before
// returning the buffer to the allocator. Used for fields that hold sensitive
// material the binding materialised on the heap (encryption key, auth token).
// Caller must have allocated the cstring via context.allocator; a nil pointer
// is a no-op so it composes cleanly with the existing `defer if c != nil` idiom.
//
// @(private) because the implementation scans forward until the trailing NUL.
// Internal callers always pass `strings.clone_to_cstring` output which is
// guaranteed NUL-terminated; an external caller passing a raw cstring without
// that guarantee would trigger an out-of-bounds read. For Odin `string`
// callers, use the length-bearing delete_zeroed_string instead.
@(private)
delete_zeroed_cstring :: proc(s: cstring) {
	if s == nil { return }
	bytes := transmute([^]u8)s
	for i := 0; bytes[i] != 0; i += 1 {
		bytes[i] = 0
	}
	delete(s)
}

// delete_zeroed_string zeros the bytes of a heap-allocated Odin string before
// returning the backing buffer. Same intent as delete_zeroed_cstring but for
// values the binding stores in its owned Config structs.
delete_zeroed_string :: proc(s: string) {
	if len(s) == 0 { return }
	bytes := transmute([]u8)s
	for i in 0 ..< len(bytes) { bytes[i] = 0 }
	delete(s)
}

// must_be_nul_free rejects strings that contain an embedded NUL byte. Used at
// the boundary of every input that the binding eventually converts into a
// C-string. Without this guard, strings.clone_to_cstring would silently
// truncate the input at the first NUL because the resulting C-string is read
// with CStr::from_ptr on the Rust side.
must_be_nul_free :: proc(s: string, op: string, what: string) -> (Error, bool) {
	for i in 0 ..< len(s) {
		if s[i] == 0x00 {
			msg := fmt.aprintf("%s contains an embedded NUL byte at offset %d", what, i)
			defer delete(msg)
			return make_error(.MISUSE, op, msg), false
		}
	}
	return error_none(), true
}

// must_be_header_safe rejects strings that would be unsafe to emit as the value
// half of an HTTP header. Refuses NUL plus CR and LF because libcurl forwards
// header values verbatim, and a CRLF would let an attacker smuggle additional
// headers or split the request.
must_be_header_safe :: proc(s: string, op: string, what: string) -> (Error, bool) {
	for i in 0 ..< len(s) {
		c := s[i]
		if c == 0x00 || c == 0x0A || c == 0x0D {
			msg := fmt.aprintf("%s contains a forbidden byte 0x%02x at offset %d", what, int(c), i)
			defer delete(msg)
			return make_error(.MISUSE, op, msg), false
		}
	}
	return error_none(), true
}
