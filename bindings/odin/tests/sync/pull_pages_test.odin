package sync_tests

import "core:bytes"
import "core:os"
import turso "../../turso"
import sync_pkg "../../turso/sync"

// Unit tests for encode_pull_updates_response — the protobuf encoder that
// builds /pull-updates responses with PageData entries. Verifies the byte
// structure end-to-end (varint length prefixes, field tags, payload bytes).
// Future agents using pull_updates_with_pages_handler to drive bootstrap
// flows can trust this encoding without running an integration test first.

@(private="file")
expect_bytes_eq :: proc(got: []u8, want: []u8, msg: string) {
	if !bytes.equal(got, want) {
		test_fail(format = "%s | got=%v want=%v", args = []any{msg, got, want})
	}
}

test_encode_pull_updates_response_empty :: proc() {
	got := encode_pull_updates_response("r0", 0, nil, context.temp_allocator)

	// Header bytes: tag(field=1,wire=2)=0x0a, varint(2)=0x02, "r0"=0x72 0x30,
	//               tag(field=3,wire=2)=0x1a, varint(0)=0x00
	header := []u8{0x0a, 0x02, 0x72, 0x30, 0x1a, 0x00}
	// db_size (field 2) is skipped at default 0; raw_encoding is empty submessage.
	expected_body := []u8{u8(len(header))} // single-byte varint length
	expected := make([dynamic]u8, 0, len(expected_body) + len(header), context.temp_allocator)
	append(&expected, ..expected_body)
	append(&expected, ..header)
	expect_bytes_eq(got, expected[:], "empty response bytes")
}

test_encode_pull_updates_response_with_db_size :: proc() {
	got := encode_pull_updates_response("rev", 5, nil, context.temp_allocator)
	// tag(1,2)=0x0a varint(3)=0x03 "rev"=0x72 0x65 0x76
	// tag(2,0)=0x10 varint(5)=0x05
	// tag(3,2)=0x1a varint(0)=0x00
	header := []u8{0x0a, 0x03, 0x72, 0x65, 0x76, 0x10, 0x05, 0x1a, 0x00}
	expected := make([dynamic]u8, 0, 1 + len(header), context.temp_allocator)
	append(&expected, u8(len(header)))
	append(&expected, ..header)
	expect_bytes_eq(got, expected[:], "header with db_size bytes")
}

test_encode_pull_updates_response_with_one_page :: proc() {
	page := []u8{0xab, 0xcd, 0xef}
	pages := []Stub_Page_Data{{page_id = 7, encoded_page = page}}
	got := encode_pull_updates_response("R", 1, pages, context.temp_allocator)

	// Header: tag(1,2)=0x0a varint(1)=0x01 "R"=0x52
	//         tag(2,0)=0x10 varint(1)=0x01
	//         tag(3,2)=0x1a varint(0)=0x00
	header := []u8{0x0a, 0x01, 0x52, 0x10, 0x01, 0x1a, 0x00}
	// PageData: tag(1,0)=0x08 varint(7)=0x07 tag(2,2)=0x12 varint(3)=0x03 ab cd ef
	page_msg := []u8{0x08, 0x07, 0x12, 0x03, 0xab, 0xcd, 0xef}

	expected := make([dynamic]u8, 0, 2 + len(header) + len(page_msg), context.temp_allocator)
	append(&expected, u8(len(header)))
	append(&expected, ..header)
	append(&expected, u8(len(page_msg)))
	append(&expected, ..page_msg)
	expect_bytes_eq(got, expected[:], "one-page response bytes")
}

test_encode_pull_updates_response_with_three_pages :: proc() {
	pages := []Stub_Page_Data{
		{page_id = 0, encoded_page = []u8{0x01}},
		{page_id = 1, encoded_page = []u8{0x02, 0x03}},
		{page_id = 2, encoded_page = []u8{0x04, 0x05, 0x06}},
	}
	got := encode_pull_updates_response("r", 3, pages, context.temp_allocator)
	// Each page length-prefixed; verify structurally by stepping through.

	// header section
	expect_eq(got[0], u8(7), "header length (1+1 + 1+1 + 1+1+0 = 7)")
	expect_eq(got[1], u8(0x0a), "field 1 tag")
	expect_eq(got[2], u8(1), "string len 1")
	expect_eq(got[3], u8('r'), "revision payload")
	expect_eq(got[4], u8(0x10), "field 2 tag (uint64)")
	expect_eq(got[5], u8(3), "db_size = 3")
	expect_eq(got[6], u8(0x1a), "field 3 tag (raw_encoding)")
	expect_eq(got[7], u8(0), "raw_encoding empty submessage")

	offset := 8

	// page 0: tag(1,0)=8 varint(0)=0 tag(2,2)=0x12 varint(1)=1 [0x01]
	// page_id=0 — proto3 default suppressed, so emitted only if we wrote it.
	// We did write it (write_uint64_field returns early when v==0), so page 0
	// has page_id field elided.
	// page_msg bytes: tag(2,2)=0x12 varint(1)=1 [0x01] -> 3 bytes
	expect_eq(got[offset], u8(3), "page 0 message length")
	expect_eq(got[offset + 1], u8(0x12), "page 0 bytes-field tag")
	expect_eq(got[offset + 2], u8(1), "page 0 encoded_page length")
	expect_eq(got[offset + 3], u8(0x01), "page 0 encoded_page byte")
	offset += 4

	// page 1: tag(1,0)=8 varint(1)=1 tag(2,2)=0x12 varint(2)=2 [0x02 0x03] -> 6 bytes
	expect_eq(got[offset], u8(6), "page 1 message length")
	expect_eq(got[offset + 1], u8(0x08), "page 1 page_id tag")
	expect_eq(got[offset + 2], u8(1), "page 1 page_id varint")
	expect_eq(got[offset + 3], u8(0x12), "page 1 bytes-field tag")
	expect_eq(got[offset + 4], u8(2), "page 1 encoded_page length")
	expect_eq(got[offset + 5], u8(0x02), "page 1 byte 0")
	expect_eq(got[offset + 6], u8(0x03), "page 1 byte 1")
	offset += 7

	// page 2: tag(1,0)=8 varint(2)=2 tag(2,2)=0x12 varint(3)=3 [0x04 0x05 0x06] -> 7 bytes
	expect_eq(got[offset], u8(7), "page 2 message length")
	expect_eq(got[offset + 1], u8(0x08), "page 2 page_id tag")
	expect_eq(got[offset + 2], u8(2), "page 2 page_id varint")
	expect_eq(got[offset + 3], u8(0x12), "page 2 bytes-field tag")
	expect_eq(got[offset + 4], u8(3), "page 2 encoded_page length")
	expect_eq(got[offset + 5], u8(0x04), "page 2 byte 0")
	expect_eq(got[offset + 6], u8(0x05), "page 2 byte 1")
	expect_eq(got[offset + 7], u8(0x06), "page 2 byte 2")
}

test_pull_updates_with_pages_handler_returns_installed_bytes :: proc() {
	defer clear_pull_updates_with_pages()
	body := []u8{0x10, 0x20, 0x30}
	set_pull_updates_with_pages(body)

	status, got, ok := pull_updates_with_pages_handler(sync_pkg.HTTP_Request{url = "http://stub/pull-updates", method = "POST"}, context.temp_allocator)
	expect_true(ok, "handler returns ok=true")
	expect_eq(status, i32(200), "status 200")
	expect_eq(len(got), 3, "body length matches installed")
	expect_eq(got[0], u8(0x10), "body byte 0")
	expect_eq(got[1], u8(0x20), "body byte 1")
	expect_eq(got[2], u8(0x30), "body byte 2")
}

@(private="file")
PAGE_SIZE :: 4096

// test_sync_bootstrap_from_captured_pages drives the full bootstrap-pull path
// against an in-process stub. Source-of-truth pages come from a freshly
// checkpointed local Turso DB, so the byte layout is guaranteed valid SQLite —
// no need to hand-craft a header page. After bootstrap, opening the synced DB
// and querying the seeded row proves the engine consumed the PageData stream
// and wrote PAGE_SIZE-aligned content into the local file.
//
// Regression demo: corrupting the page_id of any Stub_Page_Data flips the
// resulting DB file (engine writes to offset=page_id*PAGE_SIZE) and the
// subsequent SELECT errors with a CORRUPT/NOTADB. Reordering or dropping
// the encoded_page bytes triggers the same surface.
test_sync_bootstrap_from_captured_pages :: proc() {
	// Phase 1: build a source DB locally with one table+row, checkpoint to flush
	// WAL into the main file, then read the file bytes.
	src_dir := make_temp_dir("bootstrap_src")
	defer remove_temp_dir(src_dir)
	src_path := db_path(src_dir)
	defer delete(src_path)

	src_db, e1, ok1 := turso.database_open(turso.Database_Config{path = src_path})
	expect_no_err(e1, ok1, "open source DB")
	src_conn, e2, ok2 := turso.connect(src_db)
	expect_no_err(e2, ok2, "connect source DB")

	_, e3, ok3 := turso.db_exec(src_conn, "CREATE TABLE marker(id INTEGER PRIMARY KEY, v TEXT)")
	expect_no_err(e3, ok3, "CREATE TABLE marker")
	_, e4, ok4 := turso.db_exec_args(src_conn, "INSERT INTO marker(v) VALUES (?)", turso.bind_text("hello"))
	expect_no_err(e4, ok4, "INSERT row")

	// PRAGMA wal_checkpoint(TRUNCATE) ensures the main file holds every page —
	// otherwise the WAL would still own the latest writes and the captured
	// bytes would be inconsistent (header says N pages, file shows fewer).
	_, e5, ok5 := turso.db_exec(src_conn, "PRAGMA wal_checkpoint(TRUNCATE)")
	expect_no_err(e5, ok5, "checkpoint source DB")

	turso.conn_close(&src_conn)
	turso.database_close(&src_db)

	src_bytes, rerr := os.read_entire_file(src_path, context.allocator)
	expect_true(rerr == nil, "read source DB bytes")
	defer delete(src_bytes)
	expect_true(len(src_bytes) >= PAGE_SIZE, "source DB has at least one page")
	expect_true(len(src_bytes) % PAGE_SIZE == 0, "source DB size is a multiple of PAGE_SIZE")
	num_pages := len(src_bytes) / PAGE_SIZE

	// Phase 2: encode the pages as a PullUpdatesResp protobuf body.
	pages := make([]Stub_Page_Data, num_pages, context.temp_allocator)
	for i in 0 ..< num_pages {
		pages[i] = Stub_Page_Data{
			page_id      = u64(i),
			encoded_page = src_bytes[i * PAGE_SIZE : (i + 1) * PAGE_SIZE],
		}
	}
	body := encode_pull_updates_response("bootstrap-r1", u64(num_pages), pages, context.temp_allocator)
	set_pull_updates_with_pages(body)
	defer clear_pull_updates_with_pages()

	// Phase 3: bootstrap a fresh sync database against the stub.
	target_dir := make_temp_dir("bootstrap_target")
	defer remove_temp_dir(target_dir)
	target_path := db_path(target_dir)
	defer delete(target_path)

	state: Stub_State
	stub_init(&state)
	defer stub_destroy(&state)
	stub_set_handler(&state, "/pull-updates", pull_updates_with_pages_handler)
	stub_set_handler(&state, "/v2/pipeline",  pipeline_ok_handler)

	cfg := sync_pkg.Config{
		path               = target_path,
		remote_url         = "https://stub.example",
		client_name        = "bootstrap-test",
		bootstrap_if_empty = true,
	}
	db, e6, ok6 := sync_pkg.database_create(turso.Database_Config{path = cfg.path}, cfg, stub_client(&state))
	expect_no_err(e6, ok6, "sync.database_create with bootstrap_if_empty")
	defer sync_pkg.database_close(&db)

	expect_true(stub_path_call_count(&state, "/pull-updates") >= 1, "engine called /pull-updates at least once during bootstrap")

	// Phase 4: connect and query the bootstrapped row.
	conn, ce, cok := sync_pkg.connect(db)
	expect_no_err(ce, cok, "sync.connect to bootstrapped DB")
	defer turso.conn_close(&conn)

	stmt, pe, pok := turso.prepare(conn, "SELECT v FROM marker")
	expect_no_err(pe, pok, "prepare SELECT against bootstrapped DB")
	defer turso.finalize(&stmt)

	r, se, sok := turso.step(stmt)
	expect_no_err(se, sok, "step bootstrapped SELECT")
	expect_eq(r, turso.Step_Result.Row, "bootstrapped table has a row")

	got := turso.stmt_get_text(stmt, 0)
	defer delete(got)
	expect_eq(got, "hello", "bootstrapped row carries source data")
}
