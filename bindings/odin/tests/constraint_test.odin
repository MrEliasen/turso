package tests

import "core:fmt"
import turso "../turso"

// Constraint-violation propagation. The binding's role is to forward the
// engine-supplied CONSTRAINT status code intact and to carry the failing SQL
// in the Error so the caller can diagnose. Core Turso's sqltests cover the
// SQL semantics of UNIQUE / NOT NULL / CHECK / ON CONFLICT clauses
// exhaustively; the binding only needs to prove the propagation path once
// per trigger shape.

@(private)
Constraint_Case :: struct {
	name:        string,
	ddl:         string,
	insert_sql:  string,
	bind_arg:    turso.Bind_Arg,
}

// test_constraint_violations_surface_constraint_code is parametric: one
// driver, three rows, each exercising a different engine-side trigger but
// hitting the same status-code propagation surface in the binding.
test_constraint_violations_surface_constraint_code :: proc() {
	cases := [?]Constraint_Case{
		{
			name       = "UNIQUE",
			ddl        = "CREATE TABLE u(id INTEGER PRIMARY KEY, email TEXT UNIQUE)",
			insert_sql = "INSERT INTO u(email) VALUES (?)",
			bind_arg   = turso.bind_text("a@example.com"),
		},
		{
			name       = "NOT NULL",
			ddl        = "CREATE TABLE n(id INTEGER PRIMARY KEY, label TEXT NOT NULL)",
			insert_sql = "INSERT INTO n(label) VALUES (?)",
			bind_arg   = turso.bind_null(),
		},
		{
			name       = "CHECK",
			ddl        = "CREATE TABLE c(id INTEGER PRIMARY KEY, age INTEGER CHECK(age >= 0))",
			insert_sql = "INSERT INTO c(age) VALUES (?)",
			bind_arg   = turso.bind_int(-1),
		},
	}

	for tc in cases {
		t := test_db_open_memory()
		defer test_db_close(&t)

		exec_ok(t.conn, tc.ddl)
		if tc.name == "UNIQUE" {
			// UNIQUE needs a prior row to collide against.
			exec_ok(t.conn, "INSERT INTO u(email) VALUES ('a@example.com')")
		}

		_, e, ok := turso.conn_exec_args(t.conn, tc.insert_sql, tc.bind_arg)
		defer turso.error_destroy(&e)
		expect_false(ok, fmt.tprintf("%s violation must fail", tc.name))
		expect_eq(e.code, turso.Status_Code.CONSTRAINT, fmt.tprintf("%s violation surfaces CONSTRAINT", tc.name))
	}
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
