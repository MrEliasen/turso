package tests

import "core:strings"
import turso "../turso"

// Post-audit, Error.sql is owned by the Error (cloned at construction in
// errors.odin:make_error / error_from_status) and freed by error_destroy.
// conn_savepoint / conn_release / conn_rollback_to in turso/transaction.odin still
// build a temporary SQL string and free it via defer, but the returned Error
// holds its OWN copy of the SQL — so even after the defer runs, e.sql is
// safe to read until the caller calls error_destroy.
//
// This test verifies that contract: drive conn_rollback_to into an error path,
// burn heap allocations that would have clobbered any borrowed SQL view, and
// confirm e.sql still matches the SQL we built.

test_conn_rollback_to_error_sql_is_owned :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	name := "definitely_not_a_savepoint"
	e, ok := turso.conn_rollback_to(t.conn, name)
	expect_false(ok, "ROLLBACK TO a missing savepoint must fail")
	defer turso.error_destroy(&e)

	// Burn enough allocations that an unowned sql view would be clobbered.
	for i in 0 ..< 64 {
		sb: strings.Builder
		strings.builder_init(&sb)
		strings.write_string(&sb, "FILLER_BYTES_TO_RECLAIM_FREED_SAVEPOINT_SQL_BUFFER")
		_ = strings.to_string(sb)
		delete(sb.buf)
	}

	// e.sql is the wrapper-built SQL: "ROLLBACK TO \"definitely_not_a_savepoint\""
	expect_true(strings.contains(e.sql, name),
		"Error.sql must still contain the savepoint name after potential heap reuse")
	expect_true(strings.has_prefix(e.sql, "ROLLBACK TO "),
		"Error.sql must still carry the wrapper-built prefix after heap churn")
}
