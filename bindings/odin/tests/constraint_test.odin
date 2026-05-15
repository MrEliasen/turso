package tests

import turso "../turso"

// Constraint-violation tests. The Java JDBC suite covers UNIQUE/CHECK/NOT NULL
// constraints individually; the Rust binding's test_concurrent_unique_constraint_regression
// is the canonical reference for how constraint errors should surface in Turso.
// These tests pin the same surface for the Odin binding without spinning up
// concurrent workers.

test_unique_constraint_violation_returns_constraint_code :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	exec_ok(t.conn, "CREATE TABLE u(id INTEGER PRIMARY KEY, email TEXT UNIQUE)")
	exec_ok(t.conn, "INSERT INTO u(email) VALUES ('a@example.com')")

	_, e, ok := turso.conn_exec_args(
		t.conn,
		"INSERT INTO u(email) VALUES (?)",
		turso.bind_text("a@example.com"),
	)
	defer turso.error_destroy(&e)
	expect_false(ok, "duplicate UNIQUE value must fail")
	expect_eq(e.code, turso.Status_Code.CONSTRAINT, "UNIQUE violation surfaces CONSTRAINT")
}

test_not_null_constraint_violation_returns_constraint_code :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	exec_ok(t.conn, "CREATE TABLE n(id INTEGER PRIMARY KEY, label TEXT NOT NULL)")

	_, e, ok := turso.conn_exec_args(
		t.conn,
		"INSERT INTO n(label) VALUES (?)",
		turso.bind_null(),
	)
	defer turso.error_destroy(&e)
	expect_false(ok, "NULL into NOT NULL column must fail")
	expect_eq(e.code, turso.Status_Code.CONSTRAINT, "NOT NULL violation surfaces CONSTRAINT")
}

test_check_constraint_violation_returns_constraint_code :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	exec_ok(t.conn, "CREATE TABLE c(id INTEGER PRIMARY KEY, age INTEGER CHECK(age >= 0))")

	_, e, ok := turso.conn_exec_args(
		t.conn,
		"INSERT INTO c(age) VALUES (?)",
		turso.bind_int(-1),
	)
	defer turso.error_destroy(&e)
	expect_false(ok, "CHECK constraint must reject negative age")
	expect_eq(e.code, turso.Status_Code.CONSTRAINT, "CHECK violation surfaces CONSTRAINT")
}

// The Error retains the failing SQL so the caller can inspect what was tried.
// This is what error_destroy is responsible for cleaning up — verify the
// invariant holds for the constraint-error code path.
test_constraint_error_carries_failing_sql :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	exec_ok(t.conn, "CREATE TABLE u(id INTEGER PRIMARY KEY)")
	exec_ok(t.conn, "INSERT INTO u(id) VALUES (1)")

	sql :: "INSERT INTO u(id) VALUES (1)"
	_, e, ok := turso.conn_exec(t.conn, sql)
	defer turso.error_destroy(&e)
	expect_false(ok, "duplicate primary key must fail")
	expect_eq(e.code, turso.Status_Code.CONSTRAINT, "PK collision surfaces CONSTRAINT")
	expect_eq(e.sql, sql, "Error.sql must carry the offending statement")
}
