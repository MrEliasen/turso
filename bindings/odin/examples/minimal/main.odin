package main

import "core:fmt"
import turso "../../turso"

main :: proc() {
	v := turso.version()
	defer delete(v)
	fmt.println("turso version:", v)

	db, err, ok := turso.database_open(turso.Database_Config{path = ":memory:"})
	if !ok {
		s := turso.error_string(err); defer delete(s)
		fmt.eprintln(s)
		return
	}
	defer turso.database_close(&db)

	conn, err2, ok2 := turso.connect(db)
	if !ok2 {
		s := turso.error_string(err2); defer delete(s)
		fmt.eprintln(s)
		return
	}
	defer { _, _ = turso.conn_close(&conn) }

	_, e1, ok_ddl := turso.conn_exec(conn, "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT)")
	if !ok_ddl {
		s := turso.error_string(e1); defer delete(s)
		fmt.eprintln(s)
		return
	}

	names := [?]string{"alice", "bob"}
	for name in names {
		_, e, ok_ins := turso.conn_exec_args(conn, "INSERT INTO users(name) VALUES (?)", turso.bind_text(name))
		if !ok_ins {
			s := turso.error_string(e); defer delete(s)
			fmt.eprintln(s)
			return
		}
	}

	fmt.println("last_insert_rowid:", turso.last_insert_rowid(conn))

	stmt, e_prep, ok_prep := turso.prepare(conn, "SELECT id, name FROM users")
	if !ok_prep {
		s := turso.error_string(e_prep); defer delete(s)
		fmt.eprintln(s)
		return
	}
	defer { _, _ = turso.finalize(&stmt) }

	for {
		r, _, _ := turso.step(stmt)
		if r != .Row { break }
		id := turso.stmt_get_int(stmt, 0)
		name := turso.stmt_get_text(stmt, 1)
		defer delete(name)
		fmt.printfln("  row id=%d name=%q", id, name)
	}
}
