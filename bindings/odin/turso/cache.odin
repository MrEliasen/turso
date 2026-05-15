package turso

import "core:mem"

// Stmt_Cache memoizes prepared statements by SQL text. Reuse avoids the cost of
// re-parsing and re-planning for hot queries. The cache owns the statements -
// the caller must NOT finalize them directly. Call cache_destroy when done.
//
// Concurrency: not internally synchronized. A cache is bound to a single connection
// (statements are per-connection in Turso); multiple goroutines sharing one
// connection+cache must serialize access.
//
// Lifetime: cache_destroy MUST be called BEFORE the source Connection is
// closed. The cached statement handles point into engine memory owned by that
// connection; closing the connection first leaves the cache pointing at freed
// state. The test suite has a regression assertion for this ordering
// (test_cache_destroy_after_connection_close_does_not_crash); if a future
// engine change makes the reverse order fatal, this contract will need
// enforcement (e.g. a back-reference + assert) rather than just documentation.
//
// Schema changes: if you ALTER/DROP a table that a cached statement references,
// clear the cache first - stale plans may misbehave.
//
// The zero value `Stmt_Cache{}` is usable; `prepare_cached` will allocate the
// backing map on first insert. `cache_init` is still available for callers who
// want to fix the allocator up front or pre-size the map.
Stmt_Cache :: struct {
	entries:   map[string]Statement,
	// allocator is recorded by cache_init so a lazy re-init after cache_destroy
	// uses the same allocator as the original `make`. Zero-value caches grab
	// `context.allocator` on first insert.
	allocator: Maybe(mem.Allocator),
}

// cache_init creates an empty cache. SQL keys are cloned with context.allocator on insert.
// Callers can equivalently use a zero-value `Stmt_Cache{}` and let `prepare_cached`
// lazily allocate; the explicit init helper exists for pre-sizing and allocator pinning.
cache_init :: proc(allocator := context.allocator) -> Stmt_Cache {
	c := Stmt_Cache{}
	c.entries = make(map[string]Statement, 0, allocator)
	c.allocator = allocator
	return c
}

// cache_count returns the number of cached statements.
cache_count :: proc(cache: Stmt_Cache) -> int {
	return len(cache.entries)
}

// cache_destroy finalizes every cached statement and frees the cache's owned
// memory. The map keys alias `Statement.sql` for each entry, so finalize is
// responsible for releasing the key memory too - the cache only needs to free
// the map's internal storage.
cache_destroy :: proc(cache: ^Stmt_Cache) {
	if cache == nil || cache.entries == nil { return }
	for _, &stmt in cache.entries {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}
	delete(cache.entries)
	cache.entries = nil
}

// cache_clear finalizes and removes every cached statement but keeps the cache usable.
// Same key-ownership rule as cache_destroy: finalize frees each entry's SQL clone.
cache_clear :: proc(cache: ^Stmt_Cache) {
	if cache == nil || cache.entries == nil { return }
	for _, &stmt in cache.entries {
		fe, _ := finalize(&stmt)
		error_destroy(&fe)
	}
	clear(&cache.entries)
}

// prepare_cached returns a cached prepared Statement for sql, creating one on
// miss. The cache owns the underlying C handle - do NOT call finalize on the
// returned Statement; let cache_destroy / cache_clear handle it. Bindings
// persist across calls; re-bind every parameter before each use to avoid stale
// data.
//
// On a cache hit the statement is reset() so it's ready to be re-bound and
// stepped. Returns Statement by value - the wrapper is a few pointers + a
// length, and copying it shares the underlying C handle. This avoids the
// dangling-pointer hazard that interior map pointers had across map grows.
//
// The cache map is lazily initialised on first insert, so callers can pass
// a zero-value `Stmt_Cache{}` without first calling `cache_init`.
prepare_cached :: proc(conn: Connection, cache: ^Stmt_Cache, sql: string) -> (Statement, Error, bool) {
	if cache == nil {
		return Statement{}, make_error(.MISUSE, "prepare_cached", "cache is nil", sql), false
	}

	if cache.entries != nil {
		if sql in cache.entries {
			stmt := cache.entries[sql]
			if e, ok := reset(stmt); !ok { return Statement{}, e, false }
			return stmt, error_none(), true
		}
	}

	stmt, err, ok := prepare(conn, sql)
	if !ok { return Statement{}, err, false }

	if cache.entries == nil {
		alloc := context.allocator
		if pinned, has := cache.allocator.(mem.Allocator); has { alloc = pinned }
		cache.entries = make(map[string]Statement, 0, alloc)
	}
	// stmt.sql is the owned clone produced by prepare; reuse it as the cache key.
	cache.entries[stmt.sql] = stmt
	return stmt, error_none(), true
}
