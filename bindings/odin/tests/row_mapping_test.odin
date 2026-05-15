package tests

import "core:slice"
import turso "../turso"

@(private)
RM_User :: struct {
	id:   i64,
	name: string,
}

test_stmt_scan_struct_by_name :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn,
		"INSERT INTO t(id, name) VALUES (?, ?)",
		turso.bind_int(7), turso.bind_text("alice"),
	)

	stmt := prep_ok(t.conn, "SELECT id, name FROM t")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row: RM_User
	e, ok := turso.stmt_scan_struct(stmt, &row)
	expect_no_err(e, ok, "stmt_scan_struct by name")
	defer delete(row.name)
	expect_eq(row.id, i64(7), "id populated")
	expect_eq(row.name, "alice", "name populated")
}

@(private)
RM_Tagged :: struct {
	identifier: i64    `turso:"id"`,
	label:      string `turso:"name"`,
}

test_stmt_scan_struct_tag_override :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn,
		"INSERT INTO t(id, name) VALUES (?, ?)",
		turso.bind_int(42), turso.bind_text("bob"),
	)

	stmt := prep_ok(t.conn, "SELECT id, name FROM t")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row: RM_Tagged
	e, ok := turso.stmt_scan_struct(stmt, &row)
	expect_no_err(e, ok, "stmt_scan_struct tag override")
	defer delete(row.label)
	expect_eq(row.identifier, i64(42), "tag-mapped id")
	expect_eq(row.label, "bob", "tag-mapped name")
}

@(private)
RM_Wide :: struct {
	id:    i64,
	name:  string,
	extra: i64,  // no matching column in SELECT below
}

test_stmt_scan_struct_missing_column_ignored :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn,
		"INSERT INTO t(id, name) VALUES (?, ?)",
		turso.bind_int(1), turso.bind_text("carol"),
	)

	stmt := prep_ok(t.conn, "SELECT id, name FROM t")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row: RM_Wide
	e, ok := turso.stmt_scan_struct(stmt, &row)
	expect_no_err(e, ok, "missing column stays zero")
	defer delete(row.name)
	expect_eq(row.id, i64(1), "id populated")
	expect_eq(row.name, "carol", "name populated")
	expect_eq(row.extra, i64(0), "extra field stays zero")
}

test_stmt_scan_struct_extra_column_ignored :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT, extra INTEGER)")
	_, _, _ = turso.conn_exec_args(t.conn,
		"INSERT INTO t(id, name, extra) VALUES (?, ?, ?)",
		turso.bind_int(2), turso.bind_text("dave"), turso.bind_int(999),
	)

	stmt := prep_ok(t.conn, "SELECT id, name, extra FROM t")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row: RM_User
	e, ok := turso.stmt_scan_struct(stmt, &row)
	expect_no_err(e, ok, "extra column dropped silently")
	defer delete(row.name)
	expect_eq(row.id, i64(2), "id populated")
	expect_eq(row.name, "dave", "name populated")
}

test_stmt_scan_struct_type_mismatch_errors :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	stmt := prep_ok(t.conn, "SELECT 'hello' AS id")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	Mismatch :: struct { id: i64 }
	row: Mismatch
	e, ok := turso.stmt_scan_struct(stmt, &row)
	defer turso.error_destroy(&e)
	expect_err(e, ok, "scan must reject TEXT into i64")
	expect_string_contains(e.message, "cannot map", "error mentions mismatch")
	expect_eq(row.id, i64(0), "struct unchanged on error")
}

@(private)
RM_Nullable :: struct {
	id:      i64,
	name:    string,
	payload: []u8,
}

test_stmt_scan_struct_null_handling :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	stmt := prep_ok(t.conn, "SELECT NULL AS id, NULL AS name, NULL AS payload")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row: RM_Nullable
	row.id = 999            // pre-fill to verify NULL zeros it
	row.name = "preset"
	row.payload = []u8{0xAA}

	e, ok := turso.stmt_scan_struct(stmt, &row)
	expect_no_err(e, ok, "NULL columns scan cleanly")
	expect_eq(row.id, i64(0), "NULL → 0")
	expect_eq(row.name, "", "NULL → empty string")
	expect_true(row.payload == nil, "NULL → nil slice")
}

test_stmt_scan_struct_not_a_struct_errors :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	stmt := prep_ok(t.conn, "SELECT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	val: i64
	e, ok := turso.stmt_scan_struct(stmt, &val)
	defer turso.error_destroy(&e)
	expect_err(e, ok, "scan into non-struct must error")
	expect_eq(e.code, turso.Status_Code.MISUSE, "MISUSE code for non-struct target")
}

test_conn_query_one_struct :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn,
		"INSERT INTO t(id, name) VALUES (?, ?)",
		turso.bind_int(11), turso.bind_text("eve"),
	)

	row: RM_User
	e, ok := turso.conn_query_one_struct(t.conn, "SELECT id, name FROM t", &row)
	expect_no_err(e, ok, "conn_query_one_struct")
	defer delete(row.name)
	expect_eq(row.id, i64(11), "id populated")
	expect_eq(row.name, "eve", "name populated")
}

// T2: conn_query_one_struct against an empty table must surface a typed
// error rather than silently returning an unpopulated struct.
test_conn_query_one_struct_zero_rows_errors :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")

	row: RM_User
	e, ok := turso.conn_query_one_struct(t.conn, "SELECT id, name FROM t", &row)
	defer turso.error_destroy(&e)
	expect_false(ok, "conn_query_one_struct on empty table must fail")
	expect_eq(e.code, turso.Status_Code.ERROR, "zero-rows is ERROR not MISUSE")
	expect_eq(row.id, i64(0), "struct stays at zero value on error")
}

test_conn_query_optional_struct_zero_rows :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")

	row: RM_User
	found, e, ok := turso.conn_query_optional_struct(t.conn, "SELECT id, name FROM t", &row)
	expect_no_err(e, ok, "optional struct on empty table")
	expect_false(found, "no rows → found=false")
	expect_eq(row.id, i64(0), "struct unchanged")
}

test_conn_query_optional_struct_one_row :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn,
		"INSERT INTO t(id, name) VALUES (?, ?)",
		turso.bind_int(33), turso.bind_text("frank"),
	)

	row: RM_User
	found, e, ok := turso.conn_query_optional_struct(t.conn, "SELECT id, name FROM t", &row)
	expect_no_err(e, ok, "optional struct on one-row table")
	expect_true(found, "one row → found=true")
	defer delete(row.name)
	expect_eq(row.id, i64(33), "id populated")
	expect_eq(row.name, "frank", "name populated")
}

test_conn_query_all_struct :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER, name TEXT)")
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(id, name) VALUES (?, ?)", turso.bind_int(1), turso.bind_text("a"))
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(id, name) VALUES (?, ?)", turso.bind_int(2), turso.bind_text("b"))
	_, _, _ = turso.conn_exec_args(t.conn, "INSERT INTO t(id, name) VALUES (?, ?)", turso.bind_int(3), turso.bind_text("c"))

	rows, e, ok := turso.conn_query_all_struct(RM_User, t.conn, "SELECT id, name FROM t ORDER BY id")
	expect_no_err(e, ok, "conn_query_all_struct")
	defer {
		for &r in rows { delete(r.name) }
		delete(rows)
	}
	expect_eq(len(rows), 3, "three rows returned")

	ids := [3]i64{rows[0].id, rows[1].id, rows[2].id}
	expect_true(slice.equal(ids[:], []i64{1, 2, 3}), "ids in order")
	expect_eq(rows[0].name, "a", "row 0 name")
	expect_eq(rows[1].name, "b", "row 1 name")
	expect_eq(rows[2].name, "c", "row 2 name")
}
