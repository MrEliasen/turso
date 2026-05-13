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

// error_destroy releases the owned message string. Safe on zero Error.
error_destroy :: proc(err: ^Error) {
	if err == nil { return }
	if len(err.message) > 0 {
		delete(err.message)
		err.message = ""
	}
}

error_from_status :: proc(
	code: Status_Code,
	c_err: cstring,
	op: string = "",
	sql: string = "",
	ctx: string = "",
) -> Error {
	return Error{
		code    = code,
		message = take_error_string(c_err),
		sql     = sql,
		op      = op,
		ctx     = ctx,
	}
}

status_name :: proc(c: Status_Code) -> string {
	switch c {
	case .OK:            return "TURSO_OK"
	case .DONE:          return "TURSO_DONE"
	case .ROW:           return "TURSO_ROW"
	case .IO:            return "TURSO_IO"
	case .BUSY:          return "TURSO_BUSY"
	case .INTERRUPT:     return "TURSO_INTERRUPT"
	case .BUSY_SNAPSHOT: return "TURSO_BUSY_SNAPSHOT"
	case .ERROR:         return "TURSO_ERROR"
	case .MISUSE:        return "TURSO_MISUSE"
	case .CONSTRAINT:    return "TURSO_CONSTRAINT"
	case .READONLY:      return "TURSO_READONLY"
	case .DATABASE_FULL: return "TURSO_DATABASE_FULL"
	case .NOTADB:        return "TURSO_NOTADB"
	case .CORRUPT:       return "TURSO_CORRUPT"
	case .IOERR:         return "TURSO_IOERR"
	}
	return fmt.tprintf("TURSO_UNKNOWN(%d)", i32(c))
}

// error_string formats an Error for display. The returned string is allocator-owned.
error_string :: proc(err: Error, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "turso: %s (%d)", status_name(err.code), i32(err.code))
	if len(err.op)      > 0 { fmt.sbprintf(&sb, " op=%q", err.op) }
	if len(err.message) > 0 { fmt.sbprintf(&sb, " message=%q", err.message) }
	if len(err.ctx)     > 0 { fmt.sbprintf(&sb, " ctx=%q", err.ctx) }
	if len(err.sql)     > 0 { fmt.sbprintf(&sb, " sql=%q", err.sql) }
	return strings.to_string(sb)
}
