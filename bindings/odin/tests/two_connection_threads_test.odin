package tests

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:thread"
import turso "../turso"

// One Database, two Connections, two threads. The README documents Database
// as Send+Sync and Connection as exclusive-per-thread. This test exercises
// that contract: each thread owns one Connection for its entire lifetime so
// the Connection's internal mutability is never observed from the other
// thread. Under -sanitize:thread any accidental sharing of mutable Connection
// state shows up as a data race. Under a normal build the test still
// validates that the combined row count is observed by both connections.

@(private)
TwoConn_Args :: struct {
	db:       turso.Database,
	tag:      i64,        // distinguishes thread 1 vs 2 in the v column
	count:    int,        // how many rows this worker inserts
	done:     ^u32,       // atomic done flag, incremented on exit
}

@(private)
two_conn_worker :: proc(args: ^TwoConn_Args) {
	conn, e, ok := turso.connect(args.db)
	if !ok {
		intrinsics.atomic_add(args.done, 1)
		turso.error_destroy(&e)
		return
	}
	defer { _, _ = turso.conn_close(&conn) }

	// Real disk contention with two threads is the point. busy_timeout lets
	// the second writer wait rather than fail with BUSY.
	turso.set_busy_timeout(conn, 2000)

	for i in 0 ..< args.count {
		_, ie, iok := turso.conn_exec_args(
			conn,
			"INSERT INTO probe(t, v) VALUES (?, ?)",
			turso.bind_int(args.tag), turso.bind_int(i64(i)),
		)
		if !iok {
			turso.error_destroy(&ie)
			break
		}
	}
	intrinsics.atomic_add(args.done, 1)
}

test_two_connections_two_threads :: proc() {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path, _ := filepath.join({dir, "odin_turso_two_threads.db"}, context.allocator)
	defer { os.remove(path); delete(path) }
	os.remove(path)

	db, e, ok := turso.database_open(turso.Database_Config{path = path, busy_timeout_ms = 2000})
	expect_no_err(e, ok, "open shared db")
	defer turso.database_close(&db)

	// Schema setup happens on the main thread before any worker runs so the
	// workers only do INSERTs against a known table.
	setup_conn, sce, scok := turso.connect(db)
	expect_no_err(sce, scok, "setup connect")
	turso.set_busy_timeout(setup_conn, 2000)
	exec_ok(setup_conn, "CREATE TABLE probe(t INTEGER, v INTEGER)")
	_, _ = turso.conn_close(&setup_conn)

	// Two workers each insert PER_WORKER rows tagged by their thread id.
	// Iteration count stays modest to keep wall time predictable under TSAN.
	PER_WORKER :: 50
	done: u32 = 0

	args_a := TwoConn_Args{db = db, tag = 1, count = PER_WORKER, done = &done}
	args_b := TwoConn_Args{db = db, tag = 2, count = PER_WORKER, done = &done}

	t_a := thread.create_and_start_with_poly_data(&args_a, two_conn_worker)
	t_b := thread.create_and_start_with_poly_data(&args_b, two_conn_worker)

	thread.join(t_a)
	thread.join(t_b)
	thread.destroy(t_a)
	thread.destroy(t_b)

	expect_eq(int(intrinsics.atomic_load(&done)), 2, "both workers must signal done")

	// A third connection on the main thread reads back the combined state.
	verify, ve, vok := turso.connect(db)
	expect_no_err(ve, vok, "verify connect")
	defer { _, _ = turso.conn_close(&verify) }

	total, te, tok := turso.conn_scalar_i64(verify, "SELECT COUNT(*) FROM probe")
	expect_no_err(te, tok, "count rows")
	expect_eq(total, i64(2 * PER_WORKER),
		fmt.tprintf("expected %d rows total from two threads", 2 * PER_WORKER))

	from_a, _, _ := turso.conn_scalar_i64(verify, "SELECT COUNT(*) FROM probe WHERE t = 1")
	from_b, _, _ := turso.conn_scalar_i64(verify, "SELECT COUNT(*) FROM probe WHERE t = 2")
	expect_eq(from_a, i64(PER_WORKER), "thread 1 row count")
	expect_eq(from_b, i64(PER_WORKER), "thread 2 row count")
}
