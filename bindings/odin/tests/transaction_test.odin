package tests

import turso "../turso"

// Set up a temp file-backed DB with a single counter table. File-backed
// because Turso's MVCC + WAL plumbing varies between :memory: and on-disk;
// transaction tests want the on-disk path.
@(private)
txn_setup :: proc(name: string) -> Test_DB {
	t := test_db_open_file(name)
	exec_ok(t.conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)")
	return t
}

@(private)
count_rows :: proc(conn: turso.Connection) -> i64 {
	n, _, _ := turso.conn_scalar_i64(conn, "SELECT COUNT(*) FROM t")
	return n
}

test_conn_with_transaction_commit :: proc() {
	t := txn_setup("txn_commit")
	defer test_db_close(&t)

	e, ok := turso.conn_with_transaction(t.conn, proc(c: turso.Connection) -> bool {
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (1)")
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (2)")
		return true
	})
	expect_no_err(e, ok, "conn_with_transaction commit path")
	expect_eq(count_rows(t.conn), i64(2), "rows must persist after commit")
}

test_conn_with_transaction_rollback :: proc() {
	t := txn_setup("txn_rollback")
	defer test_db_close(&t)

	e, ok := turso.conn_with_transaction(t.conn, proc(c: turso.Connection) -> bool {
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (1)")
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (2)")
		return false
	})
	expect_no_err(e, ok, "conn_with_transaction rollback path")
	expect_eq(count_rows(t.conn), i64(0), "rollback must discard the inserts")
}

test_conn_with_transaction_manual_commands :: proc() {
	t := txn_setup("txn_manual")
	defer test_db_close(&t)

	e1, ok1 := turso.conn_begin(t.conn)
	expect_no_err(e1, ok1, "conn_begin")
	_, _, _ = turso.conn_exec(t.conn, "INSERT INTO t(v) VALUES (10)")
	e2, ok2 := turso.conn_rollback(t.conn)
	expect_no_err(e2, ok2, "conn_rollback")
	expect_eq(count_rows(t.conn), i64(0), "manual rollback discards inserts")

	e3, ok3 := turso.conn_begin(t.conn)
	expect_no_err(e3, ok3, "conn_begin again")
	_, _, _ = turso.conn_exec(t.conn, "INSERT INTO t(v) VALUES (20)")
	e4, ok4 := turso.conn_commit(t.conn)
	expect_no_err(e4, ok4, "conn_commit")
	expect_eq(count_rows(t.conn), i64(1), "manual commit persists insert")
}

test_conn_with_savepoint_release :: proc() {
	t := txn_setup("savepoint_release")
	defer test_db_close(&t)

	_, _, _ = turso.conn_exec(t.conn, "INSERT INTO t(v) VALUES (1)")
	e, ok := turso.conn_with_savepoint(t.conn, "inner", proc(c: turso.Connection) -> bool {
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (2)")
		return true
	})
	expect_no_err(e, ok, "conn_with_savepoint release path")
	expect_eq(count_rows(t.conn), i64(2), "savepoint release must keep inner insert")
}

test_conn_with_savepoint_rollback :: proc() {
	t := txn_setup("savepoint_rollback")
	defer test_db_close(&t)

	_, _, _ = turso.conn_exec(t.conn, "INSERT INTO t(v) VALUES (1)")
	e, ok := turso.conn_with_savepoint(t.conn, "inner", proc(c: turso.Connection) -> bool {
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (2)")
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (3)")
		return false
	})
	expect_no_err(e, ok, "conn_with_savepoint rollback path")
	expect_eq(count_rows(t.conn), i64(1), "savepoint rollback must discard inner inserts")
}

// Nested savepoints: inner rolls back, outer commits the work that happened
// before the inner savepoint was opened.
test_conn_with_savepoint_nested :: proc() {
	t := txn_setup("savepoint_nested")
	defer test_db_close(&t)

	e, ok := turso.conn_with_savepoint(t.conn, "outer", proc(c: turso.Connection) -> bool {
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (1)")
		_, inner_ok := turso.conn_with_savepoint(c, "inner", proc(c2: turso.Connection) -> bool {
			_, _, _ = turso.conn_exec(c2, "INSERT INTO t(v) VALUES (2)")
			return false
		})
		if !inner_ok { return false }
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (3)")
		return true
	})
	expect_no_err(e, ok, "nested savepoint outer release")
	expect_eq(count_rows(t.conn), i64(2), "nested: outer keeps (1) and (3), inner (2) discarded")
}

// Error in body: body decides to abort by returning false in response to a
// failed write. The wrapper still cleans up and the next exec runs outside a
// transaction.
test_conn_with_transaction_body_failure_propagates :: proc() {
	t := txn_setup("txn_body_fail")
	defer test_db_close(&t)

	e, ok := turso.conn_with_transaction(t.conn, proc(c: turso.Connection) -> bool {
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (1)")
		_, ie, iok := turso.conn_exec(c, "INSERT INTO nonexistent_table VALUES (1)")
		defer turso.error_destroy(&ie)
		if !iok { return false }
		return true
	})
	expect_no_err(e, ok, "wrapper itself must succeed despite body failure")
	expect_eq(count_rows(t.conn), i64(0), "body failure → rollback discards prior insert")

	// Verify we're back in autocommit by writing again.
	_, _, _ = turso.conn_exec(t.conn, "INSERT INTO t(v) VALUES (99)")
	expect_eq(count_rows(t.conn), i64(1), "post-rollback inserts go through autocommit")
}
