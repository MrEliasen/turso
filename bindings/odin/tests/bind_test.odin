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

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_int(42))
	expect_no_err(e, ok, "insert int")

	got, e2, ok2 := turso.conn_scalar_i64(t.conn, "SELECT v FROM t LIMIT 1")
	expect_no_err(e2, ok2, "scalar i64")
	expect_eq(got, i64(42), "bind_int roundtrip")
}

test_bind_double :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	roundtrip_setup(&t, "CREATE TABLE t(v REAL)")

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_double(2.5))
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

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text("hello world"))
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
	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_blob(payload))
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

	_, e, ok := turso.conn_exec_args(t.conn, "INSERT INTO t(v) VALUES (?)", turso.bind_null())
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

	start_pos, start_found := turso.stmt_param_position(stmt, ":start")
	expect_true(start_found, ":start must be found")
	expect_eq(start_pos, 1, ":start is position 1")

	stop_pos, stop_found := turso.stmt_param_position(stmt, ":stop")
	expect_true(stop_found, ":stop must be found")
	expect_eq(stop_pos, 2, ":stop is position 2")

	missing_pos, missing_found := turso.stmt_param_position(stmt, ":missing")
	expect_false(missing_found, ":missing must not be found")
	expect_eq(missing_pos, 0, ":missing returns position 0 when not found")
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

// Named-parameter prefix coverage. SQLite recognises `:name`, `@name`, and
// `$name` for named binding (positional `?N` is dispatched separately and is
// covered by test_bind_positional_question_index). The binding's role is to
// forward the prefix bytes verbatim to `stmt_bind_named_*`; this driver
// proves each prefix shape hits the same dispatch with a single statement
// per shape so any future regression in the prefix-forwarding path surfaces
// immediately.
test_bind_named_prefix_variants :: proc() {
	cases := [?]struct{
		name, sql, a, b: string,
		want:            i64,
	}{
		{name = ":colon",  sql = "SELECT :a + :b", a = ":a", b = ":b", want = 12},
		{name = "@at",     sql = "SELECT @x + @y", a = "@x", b = "@y", want = 30},
		{name = "$dollar", sql = "SELECT $a + $b", a = "$a", b = "$b", want = 123},
	}
	for tc in cases {
		t := test_db_open_memory()
		defer test_db_close(&t)

		stmt := prep_ok(t.conn, tc.sql)
		defer finalize_ok(&stmt)

		e1, ok1 := turso.stmt_bind_named_int(stmt, tc.a, 5)
		expect_no_err(e1, ok1, tc.a)
		e2, ok2 := turso.stmt_bind_named_int(stmt, tc.b, tc.want - 5)
		expect_no_err(e2, ok2, tc.b)

		step_expect_row(stmt)
		expect_eq(turso.stmt_get_int(stmt, 0), tc.want, tc.name)
	}
}

test_bind_positional_question_index :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	// ?N positional binding: bind args by 1-based index regardless of order.
	stmt := prep_ok(t.conn, "SELECT ?2 - ?1")
	defer finalize_ok(&stmt)

	e1, ok1 := turso.stmt_bind_int(stmt, 1, 10)
	expect_no_err(e1, ok1, "bind ?1")
	e2, ok2 := turso.stmt_bind_int(stmt, 2, 50)
	expect_no_err(e2, ok2, "bind ?2")

	step_expect_row(stmt)
	expect_eq(turso.stmt_get_int(stmt, 0), i64(40), "?2 - ?1 = 40")
}
