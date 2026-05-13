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

// prepare_cached returns a cached prepared statement for sql, creating one on miss.
// The returned pointer is owned by the cache - do NOT finalize it. Bindings persist
// across calls; re-bind every parameter before each use to avoid stale data.
//
// On a cache hit the statement is reset() so it's ready to be re-bound and stepped.
prepare_cached :: proc(conn: Connection, cache: ^Stmt_Cache, sql: string) -> (^Statement, Error, bool) {
	if cache == nil {
		return nil, Error{code = .MISUSE, op = "prepare_cached", sql = sql, message = strings.clone("cache is nil")}, false
	}

	if sql in cache.entries {
		e, ok := reset(cache.entries[sql])
		if !ok { return nil, e, false }
		// We need a stable pointer; iterate via the map key. Odin maps return
		// pointers via the &cache.entries[key] pattern.
		stmt_ptr := &cache.entries[sql]
		return stmt_ptr, error_none(), true
	}

	stmt, err, ok := prepare(conn, sql)
	if !ok { return nil, err, false }

	owned_sql := strings.clone(sql)
	stmt.sql = owned_sql
	cache.entries[owned_sql] = stmt
	stmt_ptr := &cache.entries[owned_sql]
	return stmt_ptr, error_none(), true
}
