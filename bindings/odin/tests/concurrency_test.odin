package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import turso "../turso"

// test_two_connections_share_state opens two independent Database handles
// against the same on-disk file and verifies that writes via one are visible
// to reads via the other. Mirrors the regression the Rust binding catches
// with test_concurrent_unique_constraint_regression (bindings/rust/tests/integration_tests.rs)
// but without threading — the goal is to prove cross-connection visibility,
// not to fuzz the lock manager.
test_two_connections_share_state :: proc() {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path, _ := filepath.join({dir, "odin_turso_concurrency.db"}, context.allocator)
	defer { os.remove(path); delete(path) }
	os.remove(path)

	cfg := turso.Database_Config{path = path}

	db1, e1, ok1 := turso.database_open(cfg)
	expect_no_err(e1, ok1, "open db1")
	defer turso.database_close(&db1)
	conn1, e1c, ok1c := turso.connect(db1)
	expect_no_err(e1c, ok1c, "connect db1")
	defer { _, _ = turso.conn_close(&conn1) }

	exec_ok(conn1, "CREATE TABLE t(id INTEGER PRIMARY KEY, src INTEGER, v TEXT)")

	db2, e2, ok2 := turso.database_open(cfg)
	expect_no_err(e2, ok2, "open db2 (same path)")
	defer turso.database_close(&db2)
	conn2, e2c, ok2c := turso.connect(db2)
	expect_no_err(e2c, ok2c, "connect db2")
	defer { _, _ = turso.conn_close(&conn2) }

	// Alternating inserts from both connections.
	for i in 0 ..< 10 {
		_, ie, iok := turso.db_exec_args(
			conn1,
			"INSERT INTO t(src, v) VALUES (?, ?)",
			turso.bind_int(1), turso.bind_text(fmt.tprintf("c1-%d", i)),
		)
		expect_no_err(ie, iok, "conn1 insert")

		_, je, jok := turso.db_exec_args(
			conn2,
			"INSERT INTO t(src, v) VALUES (?, ?)",
			turso.bind_int(2), turso.bind_text(fmt.tprintf("c2-%d", i)),
		)
		expect_no_err(je, jok, "conn2 insert")
	}

	// Both connections see all 20 rows.
	count1, ce1, cok1 := turso.db_scalar_i64(conn1, "SELECT COUNT(*) FROM t")
	expect_no_err(ce1, cok1, "count via conn1")
	expect_eq(count1, i64(20), "conn1 row count after cross-connection inserts")

	count2, ce2, cok2 := turso.db_scalar_i64(conn2, "SELECT COUNT(*) FROM t")
	expect_no_err(ce2, cok2, "count via conn2")
	expect_eq(count2, i64(20), "conn2 row count after cross-connection inserts")

	// Cross-source verification: conn1 sees rows inserted by conn2 and vice versa.
	c1_via_c2, _, _ := turso.db_scalar_i64(conn2, "SELECT COUNT(*) FROM t WHERE src = 1")
	expect_eq(c1_via_c2, i64(10), "conn2 must see conn1's rows")
	c2_via_c1, _, _ := turso.db_scalar_i64(conn1, "SELECT COUNT(*) FROM t WHERE src = 2")
	expect_eq(c2_via_c1, i64(10), "conn1 must see conn2's rows")
}
