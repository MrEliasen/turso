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

// Regression test for M3: when COMMIT fails (body succeeded but the engine
// rejects the commit, here via a deferred FK violation), conn_with_transaction
// must surface the commit error AND run a best-effort ROLLBACK so the
// connection ends in autocommit rather than stuck in an open transaction.
// A subsequent write through the same connection must succeed without first
// calling ROLLBACK manually.
test_conn_with_transaction_commit_failure_rollback_recovers :: proc() {
	t := test_db_open_file("txn_commit_fail")
	defer test_db_close(&t)

	exec_ok(t.conn, "PRAGMA foreign_keys = ON")
	exec_ok(t.conn, "CREATE TABLE parent(id INTEGER PRIMARY KEY)")
	exec_ok(t.conn, "CREATE TABLE child(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)")

	// The body inserts an orphan child. With a DEFERRABLE INITIALLY DEFERRED
	// foreign key, the row check fires at COMMIT time, so the body's INSERT
	// itself succeeds and the body returns true. The wrapper's COMMIT then
	// fails with a FK error.
	err, ok := turso.conn_with_transaction(t.conn, proc(c: turso.Connection) -> bool {
		_, _, iok := turso.conn_exec(c, "INSERT INTO child(id, parent_id) VALUES (1, 999)")
		return iok
	})
	defer turso.error_destroy(&err)
	expect_false(ok, "deferred FK violation must propagate as a transaction failure")

	// The error must clearly identify the FK violation rather than a generic
	// commit failure. The message comes from the engine via error_from_status,
	// so the substring check is on the formatted Error.
	msg := turso.error_string(err, context.temp_allocator)
	expect_string_contains(msg, "foreign key", "commit error must mention the FK violation")

	// The orphan row must not be visible: the wrapper either let the engine
	// auto-rollback or ran the explicit ROLLBACK itself.
	child_count, _, _ := turso.conn_scalar_i64(t.conn, "SELECT COUNT(*) FROM child")
	expect_eq(child_count, i64(0), "failed commit must not leave the orphan child behind")

	// The connection must be in autocommit now. A follow-up
	// conn_with_transaction must complete normally; if the wrapper had
	// skipped the rollback, BEGIN here would fail with "cannot start a
	// transaction within a transaction".
	rerr, rok := turso.conn_with_transaction(t.conn, proc(c: turso.Connection) -> bool {
		_, _, ok := turso.conn_exec(c, "INSERT INTO parent(id) VALUES (1)")
		return ok
	})
	expect_no_err(rerr, rok, "follow-up transaction must succeed after the commit failure was cleaned up")

	parent_count, _, _ := turso.conn_scalar_i64(t.conn, "SELECT COUNT(*) FROM parent")
	expect_eq(parent_count, i64(1), "recovery transaction must persist its insert")
}

// Package-level scratch state. Odin proc literals do not capture surrounding
// locals, so reentrancy observation has to plumb through here.
@(private="file")
nested_inner_ok: bool

@(private="file")
nested_inner_body_ran: bool

// test_conn_with_transaction_reentrancy_inner_begin_errors pins the contract
// for calling conn_with_transaction from inside an open conn_with_transaction
// on the same connection. The engine does NOT promote nested BEGIN to a
// savepoint; SQLite returns "cannot start a transaction within a transaction"
// and the inner wrapper short-circuits:
//   1. inner conn_begin fails;
//   2. inner body never runs;
//   3. inner ROLLBACK does not fire (the wrapper only rolls back if BEGIN
//      succeeded and the body chose to abort);
//   4. inner returns the typed error to the outer body.
// The outer transaction is therefore unaffected and can commit normally.
//
// Callers who want nested transactional scope on the same connection should
// use conn_with_savepoint, which composes correctly (see
// test_conn_with_savepoint_nested).
test_conn_with_transaction_reentrancy_inner_begin_errors :: proc() {
	t := txn_setup("txn_reentrancy")
	defer test_db_close(&t)

	nested_inner_ok = true
	nested_inner_body_ran = false

	outer_err, outer_ok := turso.conn_with_transaction(t.conn, proc(c: turso.Connection) -> bool {
		_, _, _ = turso.conn_exec(c, "INSERT INTO t(v) VALUES (1)")

		ie, iok := turso.conn_with_transaction(c, proc(c2: turso.Connection) -> bool {
			nested_inner_body_ran = true
			return true
		})
		nested_inner_ok = iok
		turso.error_destroy(&ie)

		return true
	})
	defer turso.error_destroy(&outer_err)

	expect_no_err(outer_err, outer_ok, "outer transaction must succeed despite the nested BEGIN failing")
	expect_false(nested_inner_ok, "nested conn_with_transaction must report failure when the outer transaction is already open")
	expect_false(nested_inner_body_ran, "nested body must not run when BEGIN failed")
	expect_eq(count_rows(t.conn), i64(1), "outer transaction must commit its writes after the nested wrapper failed")
}
