package tests

import turso "../turso"

@(private)
roundtrip_setup :: proc(t: ^Test_DB, ddl: string) {
	exec_ok(t.conn, ddl)
}

test_bind_int :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	roundtrip_setup(&t, "CREATE TABLE t(v INTEGER)")

	_, e, ok := turso.db_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_int(42))
	expect_no_err(e, ok, "insert int")

	got, e2, ok2 := turso.db_scalar_i64(t.conn, "SELECT v FROM t LIMIT 1")
	expect_no_err(e2, ok2, "scalar i64")
	expect_eq(got, i64(42), "bind_int roundtrip")
}

test_bind_double :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	roundtrip_setup(&t, "CREATE TABLE t(v REAL)")

	_, e, ok := turso.db_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_double(2.5))
	expect_no_err(e, ok, "insert double")

	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	expect_eq(turso.stmt_value_kind(stmt, 0), turso.Value_Kind.REAL, "kind is REAL")
	expect_eq(turso.stmt_get_double(stmt, 0), 2.5, "bind_double roundtrip")
}

test_bind_text :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	roundtrip_setup(&t, "CREATE TABLE t(v TEXT)")

	_, e, ok := turso.db_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text("hello world"))
	expect_no_err(e, ok, "insert text")

	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	got := turso.stmt_get_text(stmt, 0)
	defer delete(got)
	expect_eq(got, "hello world", "bind_text roundtrip")
}

test_bind_blob :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	roundtrip_setup(&t, "CREATE TABLE t(v BLOB)")

	payload := []u8{1, 2, 3, 4, 5}
	_, e, ok := turso.db_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_blob(payload))
	expect_no_err(e, ok, "insert blob")

	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	got := turso.stmt_get_blob(stmt, 0)
	defer delete(got)
	expect_eq(len(got), len(payload), "blob length matches")
	for b, i in got {
		expect_eq(b, payload[i], "blob byte matches")
	}
}

test_bind_null :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	roundtrip_setup(&t, "CREATE TABLE t(v)")

	_, e, ok := turso.db_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_null())
	expect_no_err(e, ok, "insert null")

	stmt := prep_ok(t.conn, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	expect_true(turso.stmt_is_null(stmt, 0), "bound NULL reads back as NULL")
	expect_eq(turso.stmt_value_kind(stmt, 0), turso.Value_Kind.NULL, "kind is NULL")
}

test_named_position_lookup :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT :start, :stop")
	defer finalize_ok(&stmt)

	expect_eq(turso.stmt_param_position(stmt, ":start"), 1, ":start is position 1")
	expect_eq(turso.stmt_param_position(stmt, ":stop"), 2, ":stop is position 2")
	expect_eq(turso.stmt_param_position(stmt, ":missing"), 0, ":missing not found returns 0")
}

test_named_bind :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT :a + :b")
	defer finalize_ok(&stmt)

	e1, ok1 := turso.stmt_bind_named_int(stmt, ":a", 10)
	expect_no_err(e1, ok1, "bind :a")
	e2, ok2 := turso.stmt_bind_named_int(stmt, ":b", 32)
	expect_no_err(e2, ok2, "bind :b")

	step_expect_row(stmt)
	expect_eq(turso.stmt_get_int(stmt, 0), i64(42), ":a + :b = 42")
}

test_parameter_name_roundtrip :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT :a, $b")
	defer finalize_ok(&stmt)

	expect_eq(turso.parameters_count(stmt), i64(2), "2 named parameters")
	n1 := turso.stmt_param_name(stmt, 1); defer delete(n1)
	n2 := turso.stmt_param_name(stmt, 2); defer delete(n2)
	expect_eq(n1, ":a", "parameter 1 name preserves prefix")
	expect_eq(n2, "$b", "parameter 2 name preserves prefix")
}

test_bind_too_many_args :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	stmt := prep_ok(t.conn, "SELECT ?")
	defer finalize_ok(&stmt)

	e, ok := turso.stmt_bind_args(stmt, turso.bind_int(1), turso.bind_int(2))
	defer turso.error_destroy(&e)
	expect_false(ok, "binding 2 args to a 1-param statement should fail")
	expect_eq(e.code, turso.Status_Code.MISUSE, "error code is MISUSE")
}
