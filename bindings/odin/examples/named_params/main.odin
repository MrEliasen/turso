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

	conn, _, _ := turso.connect(db)
	defer { _, _ = turso.conn_close(&conn) }

	_, _, _ = turso.db_exec(conn, "CREATE TABLE points(x INTEGER, y INTEGER)")

	pairs := [?][2]i64{{1, 10}, {2, 20}, {3, 30}}
	for pair in pairs {
		_, _, _ = turso.db_exec_args(
			conn,
			"INSERT INTO points(x, y) VALUES (:x, :y)",
			turso.bind_int(pair[0]),
			turso.bind_int(pair[1]),
		)
	}

	stmt, _, _ := turso.prepare(conn, "SELECT x, y FROM points WHERE x >= :min AND y < :max ORDER BY x")
	defer { _, _ = turso.finalize(&stmt) }

	_, _ = turso.stmt_bind_named_int(stmt, ":min", 2)
	_, _ = turso.stmt_bind_named_int(stmt, ":max", 30)

	fmt.println("rows where x >= 2 AND y < 30:")
	for {
		r, _, _ := turso.step(stmt)
		if r != .Row { break }
		fmt.printfln("  x=%d y=%d", turso.stmt_get_int(stmt, 0), turso.stmt_get_int(stmt, 1))
	}
}
