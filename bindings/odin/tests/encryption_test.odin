package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import turso "../turso"

// AES-256-GCM requires a 32-byte (64 hex char) key.
ENC_TEST_KEY :: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
ENC_TEST_CIPHER :: "aes256gcm"

@(private)
encrypted_db_path :: proc(name: string) -> string {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path, _ := filepath.join({dir, fmt.tprintf("odin_turso_enc_%s.db", name)}, context.allocator)
	os.remove(path)
	return path
}

test_encryption_open_roundtrip :: proc() {
	path := encrypted_db_path("roundtrip")
	defer { os.remove(path); delete(path) }

	cfg := turso.Database_Config{
		path                  = path,
		experimental_features = "encryption",
		encryption_cipher     = ENC_TEST_CIPHER,
		encryption_hexkey     = ENC_TEST_KEY,
	}

	db, err, ok := turso.database_open(cfg)
	expect_no_err(err, ok, "open encrypted DB")
	conn, e2, ok2 := turso.connect(db)
	expect_no_err(e2, ok2, "connect to encrypted DB")
	exec_ok(conn, "CREATE TABLE t(v TEXT)")
	_, e3, ok3 := turso.db_exec_args(conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text("secret"))
	expect_no_err(e3, ok3, "insert into encrypted DB")
	_, _ = turso.conn_close(&conn)
	turso.database_close(&db)

	// Reopen with the same key - data should be readable.
	db2, err2, ok2_open := turso.database_open(cfg)
	expect_no_err(err2, ok2_open, "reopen encrypted DB with same key")
	defer turso.database_close(&db2)
	conn2, e4, ok4 := turso.connect(db2)
	expect_no_err(e4, ok4, "connect to reopened encrypted DB")
	defer { _, _ = turso.conn_close(&conn2) }

	stmt := prep_ok(conn2, "SELECT v FROM t LIMIT 1")
	defer finalize_ok(&stmt)
	step_expect_row(stmt)
	got := turso.stmt_get_text(stmt, 0)
	defer delete(got)
	expect_eq(got, "secret", "encrypted data roundtrip")
}

test_encryption_wrong_key_fails :: proc() {
	path := encrypted_db_path("wrong_key")
	defer { os.remove(path); delete(path) }

	good := turso.Database_Config{
		path                  = path,
		experimental_features = "encryption",
		encryption_cipher     = ENC_TEST_CIPHER,
		encryption_hexkey     = ENC_TEST_KEY,
	}

	db, err, ok := turso.database_open(good)
	expect_no_err(err, ok, "open with good key")
	conn, _, _ := turso.connect(db)
	exec_ok(conn, "CREATE TABLE t(v TEXT)")
	exec_ok(conn, "INSERT INTO t(v) VALUES ('payload')")
	_, _ = turso.conn_close(&conn)
	turso.database_close(&db)

	bad_key := "0000000000000000000000000000000000000000000000000000000000000000"
	bad := good
	bad.encryption_hexkey = bad_key

	db2, err2, ok2 := turso.database_open(bad)
	defer { turso.error_destroy(&err2); turso.database_close(&db2) }
	if ok2 {
		// Open succeeded; reading should fail because decryption breaks.
		conn2, _, _ := turso.connect(db2)
		defer { _, _ = turso.conn_close(&conn2) }
		_, read_err, read_ok := turso.db_scalar_i64(conn2, "SELECT COUNT(*) FROM t")
		defer turso.error_destroy(&read_err)
		expect_false(read_ok, "querying with wrong key must fail")
	}
	// otherwise open itself failed, which also satisfies the test.
}

// test_encryption_wal_checkpoint_and_reopen mirrors the .NET and Rust
// encryption suites: insert data, run PRAGMA wal_checkpoint(truncate) to
// force WAL contents into the main DB file, close, reopen, and verify the
// data survived. Catches regressions where WAL frames containing encrypted
// pages don't make it back into the main file on checkpoint.
test_encryption_wal_checkpoint_and_reopen :: proc() {
	path := encrypted_db_path("wal_checkpoint")
	defer { os.remove(path); delete(path) }

	cfg := turso.Database_Config{
		path                  = path,
		experimental_features = "encryption",
		encryption_cipher     = ENC_TEST_CIPHER,
		encryption_hexkey     = ENC_TEST_KEY,
	}

	{
		db, err, ok := turso.database_open(cfg)
		expect_no_err(err, ok, "open encrypted DB for checkpoint test")
		defer turso.database_close(&db)
		conn, ce, cok := turso.connect(db)
		expect_no_err(ce, cok, "connect for checkpoint test")
		defer { _, _ = turso.conn_close(&conn) }

		exec_ok(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
		exec_ok(conn, "INSERT INTO t(v) VALUES ('alpha'), ('beta'), ('gamma')")

		// PRAGMA wal_checkpoint flushes WAL frames into the main DB file.
		// db_exec returns an error if the engine refuses; we accept any
		// outcome (some Turso build modes treat PRAGMA as no-op) provided
		// the data is still queryable after reopen.
		_, _, _ = turso.db_exec(conn, "PRAGMA wal_checkpoint(TRUNCATE)")
	}

	db2, err2, ok2 := turso.database_open(cfg)
	expect_no_err(err2, ok2, "reopen encrypted DB after checkpoint")
	defer turso.database_close(&db2)
	conn2, ce2, cok2 := turso.connect(db2)
	expect_no_err(ce2, cok2, "connect to reopened DB")
	defer { _, _ = turso.conn_close(&conn2) }

	count, qe, qok := turso.db_scalar_i64(conn2, "SELECT COUNT(*) FROM t")
	expect_no_err(qe, qok, "count rows after checkpoint+reopen")
	expect_eq(count, i64(3), "all rows must survive WAL checkpoint and reopen")
}

// test_encryption_plaintext_absent_in_file confirms that a string written to
// an encrypted DB does not appear in the raw on-disk bytes — a stronger
// guarantee than just "wrong key returns error". This is what the .NET and
// Rust encryption tests assert (TursoTests.cs `contentStr.Should().NotContain`,
// integration_tests.rs `!content.windows(N).any(...)`).
test_encryption_plaintext_absent_in_file :: proc() {
	path := encrypted_db_path("plaintext_absent")
	defer { os.remove(path); delete(path) }

	// Distinctive multi-byte payload — unlikely to coincide with header
	// metadata or default schema text. 16+ bytes for windowed-search confidence.
	PAYLOAD :: "ODIN_ENC_SENTINEL_X1Y2Z3"

	cfg := turso.Database_Config{
		path                  = path,
		experimental_features = "encryption",
		encryption_cipher     = ENC_TEST_CIPHER,
		encryption_hexkey     = ENC_TEST_KEY,
	}

	db, err, ok := turso.database_open(cfg)
	expect_no_err(err, ok, "open encrypted DB for plaintext check")
	conn, ce, cok := turso.connect(db)
	expect_no_err(ce, cok, "connect for plaintext check")
	exec_ok(conn, "CREATE TABLE t(v TEXT)")
	_, ie, iok := turso.db_exec_args(
		conn, "INSERT INTO t(v) VALUES (?)", turso.bind_text(PAYLOAD),
	)
	expect_no_err(ie, iok, "insert sentinel payload")
	// Force WAL → main file so the on-disk bytes reflect the insert.
	_, _, _ = turso.db_exec(conn, "PRAGMA wal_checkpoint(TRUNCATE)")
	_, _ = turso.conn_close(&conn)
	turso.database_close(&db)

	bytes, rerr := os.read_entire_file_from_path(path, context.allocator)
	expect_true(rerr == nil, "read encrypted DB file from disk")
	defer delete(bytes)
	expect_true(len(bytes) > 0, "encrypted DB file must be non-empty")
	expect_false(
		bytes_contain(bytes, transmute([]u8)string(PAYLOAD)),
		"plaintext payload must not appear in encrypted file bytes",
	)
}

@(private)
bytes_contain :: proc(haystack: []u8, needle: []u8) -> bool {
	if len(needle) == 0 || len(haystack) < len(needle) { return false }
	for i := 0; i + len(needle) <= len(haystack); i += 1 {
		match := true
		for j in 0 ..< len(needle) {
			if haystack[i + j] != needle[j] { match = false; break }
		}
		if match { return true }
	}
	return false
}
