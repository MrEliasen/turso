package turso

import "core:strings"

// Stmt_Cache memoizes prepared statements by SQL text. Reuse avoids the cost of
// re-parsing and re-planning for hot queries. The cache owns the statements -
// the caller must NOT finalize them directly. Call cache_destroy when done.
//
// Concurrency: not internally synchronized. A cache is bound to a single connection
// (statements are per-connection in Turso); multiple goroutines sharing one
// connection+cache must serialize access.
//
// Schema changes: if you ALTER/DROP a table that a cached statement references,
// clear the cache first - stale plans may misbehave.
Stmt_Cache :: struct {
	entries: map[string]Statement,
}

// cache_init creates an empty cache. SQL keys are cloned with context.allocator on insert.
cache_init :: proc(allocator := context.allocator) -> Stmt_Cache {
	c := Stmt_Cache{}
	c.entries = make(map[string]Statement, 0, allocator)
	return c
}

// cache_count returns the number of cached statements.
cache_count :: proc(cache: Stmt_Cache) -> int {
	return len(cache.entries)
}

// cache_destroy finalizes every cached statement and frees the cache's owned memory.
cache_destroy :: proc(cache: ^Stmt_Cache) {
	if cache == nil { return }
	for key, _ in cache.entries {
		stmt := cache.entries[key]
		_, _ = finalize(&stmt)
		delete(key)
	}
	delete(cache.entries)
	cache.entries = nil
}

// cache_clear finalizes and removes every cached statement but keeps the cache usable.
cache_clear :: proc(cache: ^Stmt_Cache) {
	if cache == nil { return }
	for key, _ in cache.entries {
		stmt := cache.entries[key]
		_, _ = finalize(&stmt)
		delete(key)
	}
	clear(&cache.entries)
}

// prepare_cached returns a cached prepared Statement for sql, creating one on
// miss. The cache owns the underlying C handle — do NOT call finalize on the
// returned Statement; let cache_destroy / cache_clear handle it. Bindings
// persist across calls; re-bind every parameter before each use to avoid stale
// data.
//
// On a cache hit the statement is reset() so it's ready to be re-bound and
// stepped. Returns Statement by value — the wrapper is a few pointers + a
// length, and copying it shares the underlying C handle. This avoids the
// dangling-pointer hazard that interior map pointers had across map grows.
prepare_cached :: proc(conn: Connection, cache: ^Stmt_Cache, sql: string) -> (Statement, Error, bool) {
	if cache == nil {
		return Statement{}, make_error(.MISUSE, "prepare_cached", "cache is nil", sql), false
	}

	if sql in cache.entries {
		stmt := cache.entries[sql]
		if e, ok := reset(stmt); !ok { return Statement{}, e, false }
		return stmt, error_none(), true
	}

	stmt, err, ok := prepare(conn, sql)
	if !ok { return Statement{}, err, false }

	owned_sql := strings.clone(sql)
	stmt.sql = owned_sql
	cache.entries[owned_sql] = stmt
	return stmt, error_none(), true
}
