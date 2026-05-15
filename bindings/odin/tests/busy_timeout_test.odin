package tests

import "base:intrinsics"
import "core:thread"
import "core:time"
import turso "../turso"

// Busy-handler regression: a second writer racing for the BEGIN IMMEDIATE
// reservation either fails fast (no busy_timeout) or waits up to busy_timeout
// for the holder to release. The first test pins the no-timeout failure path,
// the second pins the with-timeout wait-and-succeed path.
//
// MVCC-only tests (snapshot isolation, BUSY_SNAPSHOT) are intentionally absent:
// the sdk-kit's experimental_features list does not include "mvcc", so MVCC is
// unreachable from this binding today. When sdk-kit exposes it, fold those
// tests in here.

test_busy_immediate_without_timeout_surfaces_busy :: proc() {
	t := test_db_open_file("busy_no_timeout")
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	conn_b, e, ok := turso.connect(t.db)
	expect_no_err(e, ok, "connect second")
	defer { _, _ = turso.conn_close(&conn_b) }
	// Intentionally do not set busy_timeout on conn_b.

	be, bok := turso.conn_begin_immediate(t.conn)
	expect_no_err(be, bok, "BEGIN IMMEDIATE on the first connection")
	defer {
		rbe, _ := turso.conn_rollback(t.conn)
		turso.error_destroy(&rbe)
	}

	_, _, _ = turso.conn_exec(t.conn, "INSERT INTO t(v) VALUES (1)")

	// Without a busy_timeout the second writer must surface the contention
	// rather than block. The Error code may be BUSY or BUSY_SNAPSHOT depending
	// on the engine path, so we assert on outcome only.
	err, ok2 := turso.conn_begin_immediate(conn_b)
	expect_false(ok2, "second BEGIN IMMEDIATE should fail without busy_timeout")
	defer turso.error_destroy(&err)
}

@(private)
Busy_Wait_Args :: struct {
	db:           turso.Database,
	worker_ready: ^u32,
	worker_done:  ^u32,
	worker_ok:    ^u32,
	hold_ms:      i64,
}

@(private)
busy_wait_worker :: proc(args: ^Busy_Wait_Args) {
	conn, e, ok := turso.connect(args.db)
	if !ok {
		turso.error_destroy(&e)
		intrinsics.atomic_store(args.worker_done, 1)
		return
	}
	defer { _, _ = turso.conn_close(&conn) }

	be, bok := turso.conn_begin_immediate(conn)
	if !bok {
		turso.error_destroy(&be)
		intrinsics.atomic_store(args.worker_done, 1)
		return
	}
	_, _, _ = turso.conn_exec(conn, "INSERT INTO t(v) VALUES (100)")

	// Tell the main thread the writer lock is taken, then hold it for hold_ms
	// before committing. The main thread's busy-wait test races against this
	// release window.
	intrinsics.atomic_store(args.worker_ready, 1)
	time.sleep(time.Duration(args.hold_ms) * time.Millisecond)

	if ce, cok := turso.conn_commit(conn); cok {
		intrinsics.atomic_store(args.worker_ok, 1)
	} else {
		turso.error_destroy(&ce)
	}
	intrinsics.atomic_store(args.worker_done, 1)
}

test_busy_immediate_with_timeout_waits_then_succeeds :: proc() {
	t := test_db_open_file("busy_with_timeout")
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(v INTEGER)")

	worker_ready: u32 = 0
	worker_done:  u32 = 0
	worker_ok:    u32 = 0
	// Hold the writer lock for 100ms. busy_timeout below is 5000ms, so the
	// main thread's BEGIN IMMEDIATE has a 50x margin to unblock before the
	// timeout fires.
	args := Busy_Wait_Args{
		db           = t.db,
		worker_ready = &worker_ready,
		worker_done  = &worker_done,
		worker_ok    = &worker_ok,
		hold_ms      = 100,
	}
	wt := thread.create_and_start_with_poly_data(&args, busy_wait_worker)

	// Spin until the worker confirms it owns the writer reservation. Without
	// this, the main thread could race ahead and grab the lock first, which
	// would defeat the purpose of the test.
	for intrinsics.atomic_load(&worker_ready) == 0 { thread.yield() }

	conn_b, e, ok := turso.connect(t.db)
	expect_no_err(e, ok, "connect main-thread writer")
	defer { _, _ = turso.conn_close(&conn_b) }
	turso.set_busy_timeout(conn_b, 5000)

	// With busy_timeout=5000 and the worker holding for ~100ms, BEGIN
	// IMMEDIATE should block then succeed once the worker COMMITs.
	start := time.tick_now()
	be, bok := turso.conn_begin_immediate(conn_b)
	elapsed := time.tick_since(start)
	expect_no_err(be, bok, "BEGIN IMMEDIATE with busy_timeout should succeed after worker releases")

	_, _, _ = turso.conn_exec(conn_b, "INSERT INTO t(v) VALUES (200)")
	ce, cok := turso.conn_commit(conn_b)
	expect_no_err(ce, cok, "main-thread COMMIT")

	// The wait must have been non-trivial; if BEGIN IMMEDIATE returned
	// instantly the busy_timeout never engaged and either the worker had
	// already released or the test is racing. A 10ms lower bound is well
	// below the 100ms hold but above instantaneous wakeups.
	expect_true(elapsed >= 10 * time.Millisecond, "BEGIN IMMEDIATE must have waited for the worker's COMMIT")

	thread.join(wt)
	thread.destroy(wt)
	expect_eq(int(intrinsics.atomic_load(&worker_ok)), 1, "worker committed cleanly")

	total, _, _ := turso.conn_scalar_i64(t.conn, "SELECT COUNT(*) FROM t")
	expect_eq(total, i64(2), "both writers committed their inserts")
}
