package sync_tests

import "core:fmt"
import sync_pkg "../../turso/sync"

// Unit tests for sync_pkg.http_response_chunks — the pure helper that splits a
// large HTTP response body into push_buffer-sized pieces before the dispatcher
// hands them to the engine. Verifying the splitting math here is the only way
// to catch off-by-one bugs without instrumenting the Rust-side push_buffer.

test_http_response_chunks_empty_body :: proc() {
	chunks := sync_pkg.http_response_chunks([]u8{}, 1024, context.temp_allocator)
	expect_eq(len(chunks), 0, "empty body produces zero chunks")
}

test_http_response_chunks_smaller_than_chunk :: proc() {
	body := []u8{1, 2, 3, 4, 5}
	chunks := sync_pkg.http_response_chunks(body, 64, context.temp_allocator)
	expect_eq(len(chunks), 1, "body smaller than chunk_size produces one chunk")
	expect_eq(len(chunks[0]), 5, "chunk size matches body size")
	expect_eq(chunks[0][0], u8(1), "chunk content unchanged at front")
	expect_eq(chunks[0][4], u8(5), "chunk content unchanged at back")
}

test_http_response_chunks_exact_multiple :: proc() {
	body := make([]u8, 128, context.temp_allocator)
	for i in 0 ..< 128 { body[i] = u8(i) }
	chunks := sync_pkg.http_response_chunks(body, 64, context.temp_allocator)
	expect_eq(len(chunks), 2, "128 / 64 = 2 chunks")
	expect_eq(len(chunks[0]), 64, "first chunk full")
	expect_eq(len(chunks[1]), 64, "second chunk full")
	expect_eq(chunks[0][0], u8(0), "first chunk starts at body[0]")
	expect_eq(chunks[1][0], u8(64), "second chunk starts at body[64]")
}

test_http_response_chunks_uneven_split :: proc() {
	body := make([]u8, 200, context.temp_allocator)
	for i in 0 ..< 200 { body[i] = u8(i) }
	chunks := sync_pkg.http_response_chunks(body, 64, context.temp_allocator)
	expect_eq(len(chunks), 4, "ceil(200 / 64) = 4 chunks")
	expect_eq(len(chunks[0]), 64, "chunk 0 full")
	expect_eq(len(chunks[1]), 64, "chunk 1 full")
	expect_eq(len(chunks[2]), 64, "chunk 2 full")
	expect_eq(len(chunks[3]), 8, "chunk 3 tail = 200 - 64*3")
	expect_eq(chunks[3][0], u8(192), "last chunk starts at body[192]")
	expect_eq(chunks[3][7], u8(199), "last chunk ends at body[199]")
}

test_http_response_chunks_zero_chunk_size_falls_back_to_single :: proc() {
	body := []u8{1, 2, 3}
	chunks := sync_pkg.http_response_chunks(body, 0, context.temp_allocator)
	expect_eq(len(chunks), 1, "chunk_size <= 0 produces a single full-body chunk")
	expect_eq(len(chunks[0]), 3, "single chunk holds the whole body")
}

test_http_response_chunks_reassembly_matches_body :: proc() {
	body := make([]u8, 70 * 1024, context.temp_allocator)
	for i in 0 ..< len(body) { body[i] = u8(i & 0xff) }
	chunks := sync_pkg.http_response_chunks(body, sync_pkg.HTTP_PUSH_CHUNK_SIZE, context.temp_allocator)
	expect_eq(len(chunks), 2, "70KB / 64KB = 2 chunks")

	reassembled := make([dynamic]u8, 0, len(body), context.temp_allocator)
	for c in chunks { for b in c { append(&reassembled, b) } }
	expect_eq(len(reassembled), len(body), "reassembled length matches input")
	for i in 0 ..< len(body) {
		if reassembled[i] != body[i] {
			test_fail(format = "byte %d mismatch after reassembly: got=%d want=%d",
				args = []any{i, reassembled[i], body[i]})
		}
	}
	// Touch the unused fmt import via a no-op format call (linter would
	// otherwise flag fmt as unused; keep parity with sibling tests).
	_ = fmt.tprintf("ok")
}
