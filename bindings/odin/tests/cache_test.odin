package tests

import turso "../turso"

test_cache_reuses_prepared_statement :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")
	exec_ok(t.conn, "INSERT INTO t(v) VALUES (1), (2), (3)")

	cache := turso.cache_init()
	defer turso.cache_destroy(&cache)

	sql := "SELECT v FROM t WHERE v = ?"

	stmt1, e1, ok1 := turso.prepare_cached(t.conn, &cache, sql)
	expect_no_err(e1, ok1, "first prepare_cached")
	expect_eq(turso.cache_count(cache), 1, "one cached entry after first miss")

	stmt2, e2, ok2 := turso.prepare_cached(t.conn, &cache, sql)
	expect_no_err(e2, ok2, "second prepare_cached")
	expect_eq(turso.cache_count(cache), 1, "still one cached entry on hit")
	expect_true(stmt1.handle == stmt2.handle, "cache hit yields the same underlying C handle")
}

test_cache_resets_between_uses :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")
	for i in 1 ..= 3 {
		_, _, _ = turso.db_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_int(i64(i)))
	}

	cache := turso.cache_init()
	defer turso.cache_destroy(&cache)
	sql := "SELECT v FROM t WHERE v = ?"

	wants := [?]i64{1, 2, 3}
	for want in wants {
		stmt, e, ok := turso.prepare_cached(t.conn, &cache, sql)
		expect_no_err(e, ok, "prepare_cached")
		be, bok := turso.stmt_bind_int(stmt, 1, want)
		expect_no_err(be, bok, "bind on cached stmt")
		step_expect_row(stmt)
		expect_eq(turso.stmt_get_int(stmt, 0), want, "cached stmt yields correct row")
		step_expect_done(stmt)
	}
}

test_cache_distinct_sql_get_distinct_entries :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	cache := turso.cache_init()
	defer turso.cache_destroy(&cache)

	queries := [?]string{"SELECT 1", "SELECT 2", "SELECT 3"}
	for q in queries {
		_, e, ok := turso.prepare_cached(t.conn, &cache, q)
		expect_no_err(e, ok, "prepare_cached distinct")
	}
	expect_eq(turso.cache_count(cache), 3, "three distinct SQL strings create three entries")
}

test_cache_clear_releases_entries :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	cache := turso.cache_init()
	defer turso.cache_destroy(&cache)

	_, _, _ = turso.prepare_cached(t.conn, &cache, "SELECT 1")
	_, _, _ = turso.prepare_cached(t.conn, &cache, "SELECT 2")
	expect_eq(turso.cache_count(cache), 2, "two entries before clear")
	turso.cache_clear(&cache)
	expect_eq(turso.cache_count(cache), 0, "zero entries after clear")
}
