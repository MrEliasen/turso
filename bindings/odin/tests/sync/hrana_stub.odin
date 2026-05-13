package sync_tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import sync "../../turso/sync"

// Protocol-aware stub handlers that emit wire-format-correct responses for
// the Turso sync engine. Hand-coded (not captured traces) for determinism —
// regressions in the wire format show up as test failures, not creds-only
// cloud E2E flakes.
//
// Wire shapes verified against:
//   sync/engine/src/server_proto.rs (PipelineRespBody, BatchStreamResp, ...)
//   sync/engine/src/database_sync_operations.rs (sql_execute_http,
//     wal_pull_to_file_v1, wait_proto_message, read_varint)

// EMPTY_STMT_RESULT is a minimal StmtResult JSON with zeroed stats and no
// rows. Adequate for INSERT/UPDATE/DELETE responses and for SELECT queries
// that should be interpreted as "no matching rows".
@(private)
EMPTY_STMT_RESULT :: `{"cols":[],"rows":[],"affected_row_count":0,"last_insert_rowid":null,"replication_index":null,"rows_read":0,"rows_written":0,"query_duration_ms":0.0}`

@(private)
EMPTY_EXECUTE_RESULT :: `{"type":"ok","response":{"type":"execute","result":` + EMPTY_STMT_RESULT + `}}`

// pipeline_ok_handler responds to /v2/pipeline with a PipelineRespBody that
// mirrors the inbound request shape: one StreamResult per inbound request,
// and for batches, one StmtResult per step. This lets the engine deserialize
// and walk the response without `assert!(response.len() == N)` mismatches in
// the common cases (fetch_last_change_id sends a Batch with 1 step).
pipeline_ok_handler :: proc(req: sync.HTTP_Request, allocator: mem.Allocator) -> (status: i32, body: []u8, ok: bool) {
	requests := parse_pipeline_requests(req.body, allocator)

	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	strings.write_string(&sb, `{"baton":null,"base_url":null,"results":[`)

	if len(requests) == 0 {
		strings.write_string(&sb, EMPTY_EXECUTE_RESULT)
	} else {
		for r, i in requests {
			if i > 0 { strings.write_string(&sb, ",") }
			switch r.kind {
			case .Execute, .Unknown:
				strings.write_string(&sb, EMPTY_EXECUTE_RESULT)
			case .Batch:
				strings.write_string(&sb, `{"type":"ok","response":{"type":"batch","result":{"step_results":[`)
				for j in 0 ..< r.step_count {
					if j > 0 { strings.write_string(&sb, ",") }
					strings.write_string(&sb, EMPTY_STMT_RESULT)
				}
				strings.write_string(&sb, `],"step_errors":[`)
				for j in 0 ..< r.step_count {
					if j > 0 { strings.write_string(&sb, ",") }
					strings.write_string(&sb, "null")
				}
				strings.write_string(&sb, `],"replication_index":null}}}`)
			}
		}
	}

	strings.write_string(&sb, `]}`)
	return 200, transmute([]u8)strings.to_string(sb), true
}

// pipeline_error_handler responds with a PipelineRespBody whose every result
// is a structured error. Lets us verify that the engine deserialized the
// stub's body (not blowing up on JSON parse) and propagated the error message
// to the caller.
pipeline_error_handler :: proc(req: sync.HTTP_Request, allocator: mem.Allocator) -> (status: i32, body: []u8, ok: bool) {
	requests := parse_pipeline_requests(req.body, allocator)
	count := len(requests)
	if count == 0 { count = 1 }

	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	strings.write_string(&sb, `{"baton":null,"base_url":null,"results":[`)
	for i in 0 ..< count {
		if i > 0 { strings.write_string(&sb, ",") }
		strings.write_string(&sb, `{"type":"error","error":{"message":"intentional stub failure","code":"STUB_ERROR"}}`)
	}
	strings.write_string(&sb, `]}`)
	return 200, transmute([]u8)strings.to_string(sb), true
}

@(private)
Parsed_Request_Kind :: enum { Execute, Batch, Unknown }

@(private)
Parsed_Request :: struct {
	kind:       Parsed_Request_Kind,
	step_count: int,
}

@(private)
parse_pipeline_requests :: proc(body: []u8, allocator: mem.Allocator) -> []Parsed_Request {
	out: [dynamic]Parsed_Request
	out.allocator = allocator

	val, err := json.parse(body, .JSON, true, allocator)
	if err != .None { return out[:] }
	obj, is_obj := val.(json.Object)
	if !is_obj { return out[:] }
	requests_val, has_requests := obj["requests"]
	if !has_requests { return out[:] }
	requests_arr, is_arr := requests_val.(json.Array)
	if !is_arr { return out[:] }

	for r in requests_arr {
		ro, is_ro := r.(json.Object)
		if !is_ro {
			append(&out, Parsed_Request{kind = .Unknown})
			continue
		}
		t, has_t := ro["type"]
		if !has_t {
			append(&out, Parsed_Request{kind = .Unknown})
			continue
		}
		ts, is_str := t.(json.String)
		if !is_str {
			append(&out, Parsed_Request{kind = .Unknown})
			continue
		}
		switch string(ts) {
		case "execute":
			append(&out, Parsed_Request{kind = .Execute})
		case "batch":
			append(&out, Parsed_Request{kind = .Batch, step_count = batch_step_count(ro)})
		case:
			append(&out, Parsed_Request{kind = .Unknown})
		}
	}
	return out[:]
}

@(private)
batch_step_count :: proc(req_obj: json.Object) -> int {
	batch_val, has_batch := req_obj["batch"]
	if !has_batch { return 0 }
	bo, ok_bo := batch_val.(json.Object)
	if !ok_bo { return 0 }
	steps_val, has_steps := bo["steps"]
	if !has_steps { return 0 }
	steps_arr, ok_arr := steps_val.(json.Array)
	if !ok_arr { return 0 }
	return len(steps_arr)
}

// pull_updates_empty_handler emits a length-delimited protobuf payload
// containing a single PullUpdatesRespProtoBody with no PageData entries.
// Models a "server has nothing new" response from /pull-updates.
//
// PullUpdatesRespProtoBody (sync/engine/src/server_proto.rs:62):
//   field 1 (string)  server_revision
//   field 2 (uint64)  db_size                              -- proto3 default 0 skipped
//   field 3 (message) raw_encoding (PageSetRawEncodingProto = empty)
//   field 4 (message) zstd_encoding
// Engine reads each message length-prefixed via read_varint
// (database_sync_operations.rs:1798); on empty remaining buffer the streaming
// loop returns None and the operation completes.
pull_updates_empty_handler :: proc(req: sync.HTTP_Request, allocator: mem.Allocator) -> (status: i32, body: []u8, ok: bool) {
	return 200, encode_pull_updates_response("r0", 0, nil, allocator), true
}

// Stub_Page_Data is one PageData entry for the pull-updates protobuf stream.
// page_id matches PageData.page_id (the engine adds 1 to get the SQLite page
// number, see database_sync_operations.rs:`frame_info.page_no = page_id + 1`).
Stub_Page_Data :: struct {
	page_id:      u64,
	encoded_page: []u8,
}

// encode_pull_updates_response builds a length-delimited protobuf payload
// matching what the engine consumes from /pull-updates: one
// PullUpdatesRespProtoBody header followed by N PageData messages, each
// prefixed with its varint length.
//
// db_size is in PAGES (not bytes). When non-zero, the engine treats the last
// page as the final db size; pass 1 for a single-page snapshot, etc.
encode_pull_updates_response :: proc(revision: string, db_size: u64, pages: []Stub_Page_Data, allocator: mem.Allocator) -> []u8 {
	out: [dynamic]u8
	out.allocator = allocator

	header: [dynamic]u8
	header.allocator = allocator
	write_string_field(&header, 1, revision)
	if db_size != 0 {
		write_uint64_field(&header, 2, db_size)
	}
	write_submessage_field(&header, 3, []u8{}) // raw_encoding (signals "use raw")
	write_varint(&out, u64(len(header)))
	for b in header { append(&out, b) }

	for p in pages {
		page_msg: [dynamic]u8
		page_msg.allocator = allocator
		write_uint64_field(&page_msg, 1, p.page_id)
		write_bytes_field(&page_msg, 2, p.encoded_page)
		write_varint(&out, u64(len(page_msg)))
		for b in page_msg { append(&out, b) }
	}
	return out[:]
}

@(private)
write_uint64_field :: proc(buf: ^[dynamic]u8, field: u32, v: u64) {
	if v == 0 { return } // proto3 default
	write_tag(buf, field, 0)
	write_varint(buf, v)
}

@(private)
write_bytes_field :: proc(buf: ^[dynamic]u8, field: u32, b: []u8) {
	write_tag(buf, field, 2)
	write_varint(buf, u64(len(b)))
	for x in b { append(buf, x) }
}

@(private)
pull_updates_with_pages_response: []u8

// pull_updates_with_pages_handler returns the bytes previously installed via
// set_pull_updates_with_pages. The closure-free shape is required because
// Stub_Handler does not carry user_data; tests serialize through this global,
// which is fine because sync tests run single-threaded.
pull_updates_with_pages_handler :: proc(req: sync.HTTP_Request, allocator: mem.Allocator) -> (status: i32, body: []u8, ok: bool) {
	return 200, pull_updates_with_pages_response, true
}

set_pull_updates_with_pages :: proc(body: []u8) {
	pull_updates_with_pages_response = body
}

clear_pull_updates_with_pages :: proc() {
	pull_updates_with_pages_response = nil
}

@(private)
write_varint :: proc(buf: ^[dynamic]u8, v: u64) {
	x := v
	for {
		if x < 0x80 {
			append(buf, u8(x))
			return
		}
		append(buf, u8(x & 0x7f) | 0x80)
		x >>= 7
	}
}

@(private)
write_tag :: proc(buf: ^[dynamic]u8, field: u32, wire: u32) {
	write_varint(buf, u64((field << 3) | wire))
}

@(private)
write_string_field :: proc(buf: ^[dynamic]u8, field: u32, s: string) {
	write_tag(buf, field, 2)
	write_varint(buf, u64(len(s)))
	for i in 0 ..< len(s) { append(buf, s[i]) }
}

@(private)
write_submessage_field :: proc(buf: ^[dynamic]u8, field: u32, sub: []u8) {
	write_tag(buf, field, 2)
	write_varint(buf, u64(len(sub)))
	for b in sub { append(buf, b) }
}
