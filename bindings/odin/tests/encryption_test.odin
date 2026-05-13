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
