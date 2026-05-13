package turso_sync

import "core:os"
import "core:path/filepath"
import "core:strings"
import raw "raw"

// internal_do_full_read satisfies a TURSO_SYNC_IO_FULL_READ request. Reads the
// entire file into memory and pushes it to the engine. Per the engine contract
// a missing file is NOT an error — done with no buffer pushed; the engine
// treats it as an empty file.
@(private)
internal_do_full_read :: proc(item: raw.Io_Item_Ptr) -> (poisoned: bool) {
	req: raw.Full_Read_Request
	if code := raw.turso_sync_database_io_request_full_read(item, &req); code != .OK {
		poison_with_message(item, "turso_sync_database_io_request_full_read failed")
		return true
	}
	path := slice_to_string(req.path)
	if !os.exists(path) {
		return false
	}
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		poison_with_message(item, "file read failed")
		return true
	}
	if len(bytes) > 0 {
		buf := bytes_to_slice_ref(bytes)
		raw.turso_sync_database_io_push_buffer(item, &buf)
	}
	return false
}

// internal_do_full_write satisfies a TURSO_SYNC_IO_FULL_WRITE request via
// write-temp-then-rename. Mirrors the Go binding's atomic write path.
@(private)
internal_do_full_write :: proc(item: raw.Io_Item_Ptr) -> (poisoned: bool) {
	req: raw.Full_Write_Request
	if code := raw.turso_sync_database_io_request_full_write(item, &req); code != .OK {
		poison_with_message(item, "turso_sync_database_io_request_full_write failed")
		return true
	}
	path := slice_to_string(req.path)
	content := slice_to_bytes(req.content)

	if dir := filepath.dir(path); dir != "" && dir != "." {
		os.make_directory(dir)  // best-effort; if it exists the engine call still works
	}

	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, content); err != nil {
		poison_with_message(item, "atomic write: temp write failed")
		return true
	}
	if err := os.rename(tmp, path); err != nil {
		poison_with_message(item, "atomic write: rename failed")
		return true
	}
	return false
}

@(private)
poison_with_message :: proc(item: raw.Io_Item_Ptr, msg: string) {
	slice := string_to_slice_ref(msg)
	raw.turso_sync_database_io_poison(item, &slice)
}
