package tests

import "base:intrinsics"
import "core:thread"
import turso "../turso"

// Stress test for the setup() seqlock and atomic logger pointer landed in S9.
//
// The existing trace test (tests/trace_test.odin) only fires the trampoline
// while no writer is racing it. It therefore cannot catch a torn read of
// g_setup_ctx or g_logger. This test runs setup() in a tight loop on a worker
// thread while the main thread drives database operations that emit log
// events (forcing the trampoline). Two pass criteria:
//
//   1. No crash. With the seqlock + atomic logger in place, neither the
//      Context.allocator pointer nor the logger function pointer should ever
//      read a torn value.
//   2. At least one event reaches the user logger. If the seqlock retries
//      timed out for every emit (e.g. the writer dominates the loop) the
//      logger never fires and the test would pass for the wrong reason.
//
// Iteration count comes from -define:TURSO_TSAN_STRESS so the same source
// supports both a fast default run (catches gross failures) and a long run
// suitable for `make tsan-test` under -sanitize:thread (catches torn reads).
//
// Convention for contributors: if you touch turso/setup.odin (or this file)
// run `make tsan-test` locally and, before merging, also workflow_dispatch
// the "ThreadSanitizer stress (manual dispatch)" job in .github/workflows/
// odin.yml. The TSAN job is not on the per-PR matrix because the race
// surface is narrow and the slowdown is large.

@(private)
TURSO_TSAN_STRESS :: #config(TURSO_TSAN_STRESS, false)

@(private)
STRESS_ITERATIONS :: 5000 when TURSO_TSAN_STRESS else 200

// Module-level state because Odin procs cannot capture closures and the
// trampoline expects a bare proc(Log_Event).
@(private) stress_events: u64
@(private) stress_stop:   bool

@(private)
stress_logger_a :: proc(event: turso.Log_Event) {
	intrinsics.atomic_add(&stress_events, 1)
}

@(private)
stress_logger_b :: proc(event: turso.Log_Event) {
	intrinsics.atomic_add(&stress_events, 1)
}

@(private)
stress_setup_swapper :: proc() {
	use_a := true
	for !intrinsics.atomic_load(&stress_stop) {
		opts := turso.Setup_Options{
			logger = use_a ? stress_logger_a : stress_logger_b,
		}
		_, _ = turso.setup(opts)
		use_a = !use_a
	}
}

test_setup_seqlock_stress :: proc() {
	// Install a logger on the main thread so the engine wires the trampoline
	// before any swaps begin. log_level locks in on first call - this test
	// runs after trace_test, so the engine is already at trace level.
	e, ok := turso.setup(turso.Setup_Options{logger = stress_logger_a})
	expect_no_err(e, ok, "initial setup")
	intrinsics.atomic_store(&stress_stop, false)
	intrinsics.atomic_store(&stress_events, 0)

	worker := thread.create_and_start(stress_setup_swapper)
	defer {
		intrinsics.atomic_store(&stress_stop, true)
		thread.join(worker)
		thread.destroy(worker)
	}

	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE seqlock_probe(v INTEGER)")
	for i in 0 ..< STRESS_ITERATIONS {
		_, _, _ = turso.conn_exec_args(
			t.conn,
			"INSERT INTO seqlock_probe(v) VALUES (?)",
			turso.bind_int(i64(i)),
		)
	}

	// Restore a known logger so subsequent tests start from a clean state.
	_, _ = turso.setup(turso.Setup_Options{logger = stress_logger_a})

	count := intrinsics.atomic_load(&stress_events)
	expect_true(count > 0, "stress logger must fire at least once - otherwise the test proves nothing")
}
