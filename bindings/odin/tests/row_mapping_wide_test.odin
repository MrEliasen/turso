package tests

import "core:fmt"
import "core:strings"
import turso "../turso"

// stmt_scan_struct must accept rows wider than STACK_COLS without an artificial
// MISUSE ceiling. Pre-fix the helper hard-capped at 256; SQLite's default
// SQLITE_MAX_COLUMN is 2000, so legitimate wide projections need to round-trip.

@(private="file")
Wide_Row :: struct {
	v000: i64, v001: i64, v002: i64, v003: i64, v004: i64, v005: i64, v006: i64, v007: i64,
	v008: i64, v009: i64, v010: i64, v011: i64, v012: i64, v013: i64, v014: i64, v015: i64,
	v016: i64, v017: i64, v018: i64, v019: i64, v020: i64, v021: i64, v022: i64, v023: i64,
	v024: i64, v025: i64, v026: i64, v027: i64, v028: i64, v029: i64, v030: i64, v031: i64,
	v032: i64, v033: i64, v034: i64, v035: i64, v036: i64, v037: i64, v038: i64, v039: i64,
	v040: i64, v041: i64, v042: i64, v043: i64, v044: i64, v045: i64, v046: i64, v047: i64,
	v048: i64, v049: i64, v050: i64, v051: i64, v052: i64, v053: i64, v054: i64, v055: i64,
	v056: i64, v057: i64, v058: i64, v059: i64, v060: i64, v061: i64, v062: i64, v063: i64,
	v064: i64, v065: i64, v066: i64, v067: i64, v068: i64, v069: i64, v070: i64, v071: i64,
	v072: i64, v073: i64, v074: i64, v075: i64, v076: i64, v077: i64, v078: i64, v079: i64,
	v080: i64, v081: i64, v082: i64, v083: i64, v084: i64, v085: i64, v086: i64, v087: i64,
	v088: i64, v089: i64, v090: i64, v091: i64, v092: i64, v093: i64, v094: i64, v095: i64,
	v096: i64, v097: i64, v098: i64, v099: i64,
}

test_stmt_scan_struct_handles_more_than_stack_cols :: proc() {
	t := test_db_open_memory()
	defer test_db_close(&t)

	// Build a 100-column SELECT (above STACK_COLS=64). Without the heap fallback
	// this would have failed with MISUSE on the count check.
	sb: strings.Builder
	strings.builder_init(&sb)
	defer delete(sb.buf)
	strings.write_string(&sb, "SELECT ")
	for i in 0 ..< 100 {
		if i > 0 { strings.write_string(&sb, ", ") }
		fmt.sbprintf(&sb, "%d AS v%03d", i, i)
	}
	sql := strings.to_string(sb)

	stmt := prep_ok(t.conn, sql)
	defer finalize_ok(&stmt)
	step_expect_row(stmt)

	row: Wide_Row
	e, ok := turso.stmt_scan_struct(stmt, &row)
	expect_no_err(e, ok, "scan into 100-field struct must succeed")
	expect_eq(row.v000, i64(0),  "first column maps")
	expect_eq(row.v050, i64(50), "midpoint column maps")
	expect_eq(row.v099, i64(99), "last column maps")
}
