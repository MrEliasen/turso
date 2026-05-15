package main

import "core:fmt"
import turso "../../turso"

main :: proc() {
	db, err, ok := turso.database_open(turso.Database_Config{path = ":memory:"})
	if !ok {
		s := turso.error_string(err); defer delete(s)
		fmt.eprintln(s)
		return
	}
	defer turso.database_close(&db)

	conn, e_conn, ok_conn := turso.connect(db)
	if !ok_conn {
		s := turso.error_string(e_conn); defer delete(s)
		fmt.eprintln(s)
		return
	}
	defer { _, _ = turso.conn_close(&conn) }

	if _, e, ok_ddl := turso.conn_exec(conn, "CREATE TABLE points(x INTEGER, y INTEGER)"); !ok_ddl {
		s := turso.error_string(e); defer delete(s)
		fmt.eprintln(s)
		return
	}

	// Bind by name into a prepared statement. Re-binding the same statement
	// across iterations avoids re-parsing the SQL for each row.
	insert_stmt, e_prep, ok_prep := turso.prepare(conn, "INSERT INTO points(x, y) VALUES (:x, :y)")
	if !ok_prep {
		s := turso.error_string(e_prep); defer delete(s)
		fmt.eprintln(s)
		return
	}
	defer { _, _ = turso.finalize(&insert_stmt) }

	pairs := [?][2]i64{{1, 10}, {2, 20}, {3, 30}}
	for pair in pairs {
		_, _ = turso.stmt_bind_named_int(insert_stmt, ":x", pair[0])
		_, _ = turso.stmt_bind_named_int(insert_stmt, ":y", pair[1])
		if _, e, ok_exec := turso.execute(insert_stmt); !ok_exec {
			s := turso.error_string(e); defer delete(s)
			fmt.eprintln(s)
			return
		}
		_, _ = turso.reset(insert_stmt)
	}

	// Selection by named parameters.
	stmt, e_sel, ok_sel := turso.prepare(conn, "SELECT x, y FROM points WHERE x >= :min AND y < :max ORDER BY x")
	if !ok_sel {
		s := turso.error_string(e_sel); defer delete(s)
		fmt.eprintln(s)
		return
	}
	defer { _, _ = turso.finalize(&stmt) }

	_, _ = turso.stmt_bind_named_int(stmt, ":min", 2)
	_, _ = turso.stmt_bind_named_int(stmt, ":max", 30)

	fmt.println("rows where x >= 2 AND y < 30:")
	for {
		r, e, ok_step := turso.step(stmt)
		if !ok_step {
			s := turso.error_string(e); defer delete(s)
			fmt.eprintln(s)
			return
		}
		if r != .Row { break }
		fmt.printfln("  x=%d y=%d", turso.stmt_get_int(stmt, 0), turso.stmt_get_int(stmt, 1))
	}
}
