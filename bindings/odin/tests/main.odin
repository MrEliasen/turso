package tests

import "core:fmt"

Test_Entry :: struct {
	name: string,
	fn:   proc(),
}

ALL_TESTS := [?]Test_Entry{
	{"test_version", test_version},

	{"test_open_memory_and_autocommit", test_open_memory_and_autocommit},
	{"test_open_file", test_open_file},
	{"test_open_bad_path", test_open_bad_path},
	{"test_idempotent_close", test_idempotent_close},
	{"test_busy_timeout_setter", test_busy_timeout_setter},

	{"test_prepare_simple", test_prepare_simple},
	{"test_prepare_invalid", test_prepare_invalid},
	{"test_column_count_after_prepare", test_column_count_after_prepare},
	{"test_reset_after_step", test_reset_after_step},
	{"test_n_change_zero_for_select", test_n_change_zero_for_select},

	{"test_bind_int", test_bind_int},
	{"test_bind_double", test_bind_double},
	{"test_bind_text", test_bind_text},
	{"test_bind_blob", test_bind_blob},
	{"test_bind_null", test_bind_null},
	{"test_named_position_lookup", test_named_position_lookup},
	{"test_named_bind", test_named_bind},
	{"test_parameter_name_roundtrip", test_parameter_name_roundtrip},
	{"test_bind_too_many_args", test_bind_too_many_args},

	{"test_column_name", test_column_name},
	{"test_column_decltype", test_column_decltype},
	{"test_row_value_kinds", test_row_value_kinds},
	{"test_get_text_independence", test_get_text_independence},
	{"test_get_blob_independence", test_get_blob_independence},

	{"test_db_exec_ddl", test_db_exec_ddl},
	{"test_insert_two_and_count", test_insert_two_and_count},
	{"test_last_insert_rowid", test_last_insert_rowid},

	{"test_prepare_first_loop", test_prepare_first_loop},
}

main :: proc() {
	passed := 0
	for t in ALL_TESTS {
		fmt.printf("[ RUN  ] %s\n", t.name)
		t.fn()
		fmt.printf("[  OK  ] %s\n", t.name)
		passed += 1
	}
	fmt.printf("\n%d/%d tests passed\n", passed, len(ALL_TESTS))
}
