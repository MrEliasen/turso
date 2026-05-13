package tests

import "core:sync"
import turso "../turso"

@(private)
trace_events_mu: sync.Mutex
@(private)
trace_events_count: int
@(private)
trace_events_max_level: turso.Tracing_Level

@(private)
trace_capture :: proc(event: turso.Log_Event) {
	sync.mutex_lock(&trace_events_mu)
	defer sync.mutex_unlock(&trace_events_mu)
	trace_events_count += 1
	if i32(event.level) > i32(trace_events_max_level) {
		trace_events_max_level = event.level
	}
}

test_trace_logger_receives_events :: proc() {
	// Install a logger BEFORE any database op so we capture init/open logs.
	e, ok := turso.setup(turso.Setup_Options{log_level = "trace", logger = trace_capture})
	expect_no_err(e, ok, "setup with trace logger")

	t := test_db_open_memory()
	defer test_db_close(&t)

	// Force operations that should emit log records.
	exec_ok(t.conn, "CREATE TABLE log_probe(v INTEGER)")
	exec_ok(t.conn, "INSERT INTO log_probe(v) VALUES (1)")

	sync.mutex_lock(&trace_events_mu)
	count := trace_events_count
	sync.mutex_unlock(&trace_events_mu)
	expect_true(count > 0, "logger callback should have fired at least once")

	// Subsequent setup() should swap the logger to nil without error.
	e2, ok2 := turso.setup(turso.Setup_Options{})
	expect_no_err(e2, ok2, "setup re-invocation to clear logger")
}
