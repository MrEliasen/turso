package tests

import "core:fmt"
import turso "../turso"

// prepare_cached returns Statement by value (post-audit fix). The wrapped
// raw.Statement_Ptr is the C handle the engine cares about; copying the
// Statement struct keeps that handle stable. This test forces several map
// grows after capturing the original handle and asserts the handle survives.
//
// Pre-audit, prepare_cached returned `^Statement` and Odin's map grow moved
// the value array, invalidating any captured interior pointer (see
// base/runtime/dynamic_map_internal.odin:map_grow_dynamic). The by-value
// signature eliminates that risk for callers.

test_cache_handle_survives_map_grow :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	cache := turso.cache_init()
	defer turso.cache_destroy(&cache)

	first, e0, ok0 := turso.prepare_cached(t.conn, &cache, "SELECT 0")
	expect_no_err(e0, ok0, "first cache entry")
	original_handle := first.handle

	for i in 0 ..< 200 {
		sql := fmt.aprintf("SELECT %d", i + 1)
		_, e, ok := turso.prepare_cached(t.conn, &cache, sql)
		delete(sql)
		expect_no_err(e, ok, "cache insert during growth")
	}

	again, e1, ok1 := turso.prepare_cached(t.conn, &cache, "SELECT 0")
	expect_no_err(e1, ok1, "cache hit after growth")
	expect_true(again.handle == original_handle,
		"cached C handle must remain identical across map grows")
}
