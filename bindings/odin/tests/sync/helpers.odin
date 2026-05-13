package sync_tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import turso "../../turso"
import sync "../../turso/sync"

test_fail :: proc(loc := #caller_location, format: string = "", args: ..any) -> ! {
	fmt.eprintf("[FAIL] %s:%d %s\n", loc.file_path, loc.line, fmt.tprintf(format, ..args))
	os.exit(1)
}

expect_true :: proc(v: bool, msg: string, loc := #caller_location) {
	if !v { test_fail(loc, "expected true: %s", msg) }
}

expect_false :: proc(v: bool, msg: string, loc := #caller_location) {
	if v { test_fail(loc, "expected false: %s", msg) }
}

expect_eq :: proc(a, b: $T, msg: string, loc := #caller_location) {
	if a != b { test_fail(loc, "%s | got=%v want=%v", msg, a, b) }
}

expect_no_err :: proc(e: turso.Error, ok: bool, msg: string, loc := #caller_location) {
	if !ok {
		s := turso.error_string(e, context.temp_allocator)
		test_fail(loc, "%s | %s", msg, s)
	}
}

expect_err :: proc(e: turso.Error, ok: bool, msg: string, loc := #caller_location) {
	if ok { test_fail(loc, "expected error: %s", msg) }
}

// make_temp_dir returns a path in the system tempdir that does not yet exist.
// The caller owns the returned string AND must remove_temp_dir on it after use.
make_temp_dir :: proc(name: string) -> string {
	base, _ := os.temp_dir(context.allocator)
	defer delete(base)
	path, _ := filepath.join({base, fmt.tprintf("odin_turso_sync_%s_%d", name, os.get_current_thread_id())}, context.allocator)
	// best-effort cleanup of stale dir from a prior failed run
	os.remove_all(path)
	if err := os.make_directory(path); err != nil {
		test_fail(format = "make_directory %q failed", args = []any{path})
	}
	return path
}

// remove_temp_dir wipes the directory created by make_temp_dir AND frees the
// Odin string holding the path. Idempotent on an empty path. Caller's `dir`
// view becomes dangling; pair `defer remove_temp_dir(dir)` with the call site
// just like Odin's stdlib `defer delete(...)` patterns.
remove_temp_dir :: proc(path: string) {
	if path == "" { return }
	os.remove_all(path)
	delete(path)
}

// db_path joins a sync directory with a stable filename.
db_path :: proc(dir: string) -> string {
	p, _ := filepath.join({dir, "synced.db"}, context.allocator)
	return p
}
