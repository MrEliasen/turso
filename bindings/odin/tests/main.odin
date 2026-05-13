package tests

import "core:fmt"
import "core:mem"

Test_Entry :: struct {
	name: string,
	fn:   proc(),
}

ALL_TESTS := [?]Test_Entry{
	{"test_version", test_version},

	// trace test must run BEFORE any other database_open so the tracing subscriber
	// is initialized with our level. The Rust SETUP.call_once locks in level on first call.
	{"test_trace_logger_receives_events", test_trace_logger_receives_events},

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

	{"test_encryption_open_roundtrip", test_encryption_open_roundtrip},
	{"test_encryption_wrong_key_fails", test_encryption_wrong_key_fails},
	{"test_encryption_wal_checkpoint_and_reopen", test_encryption_wal_checkpoint_and_reopen},
	{"test_encryption_plaintext_absent_in_file", test_encryption_plaintext_absent_in_file},

	{"test_two_connections_share_state", test_two_connections_share_state},

	{"test_db_with_transaction_commit",                  test_db_with_transaction_commit},
	{"test_db_with_transaction_rollback",                test_db_with_transaction_rollback},
	{"test_db_with_transaction_manual_commands",         test_db_with_transaction_manual_commands},
	{"test_db_with_savepoint_release",                   test_db_with_savepoint_release},
	{"test_db_with_savepoint_rollback",                  test_db_with_savepoint_rollback},
	{"test_db_with_savepoint_nested",                    test_db_with_savepoint_nested},
	{"test_db_with_transaction_body_failure_propagates", test_db_with_transaction_body_failure_propagates},

	{"test_stmt_scan_struct_by_name",                  test_stmt_scan_struct_by_name},
	{"test_stmt_scan_struct_tag_override",             test_stmt_scan_struct_tag_override},
	{"test_stmt_scan_struct_missing_column_ignored",   test_stmt_scan_struct_missing_column_ignored},
	{"test_stmt_scan_struct_extra_column_ignored",     test_stmt_scan_struct_extra_column_ignored},
	{"test_stmt_scan_struct_type_mismatch_errors",     test_stmt_scan_struct_type_mismatch_errors},
	{"test_stmt_scan_struct_null_handling",            test_stmt_scan_struct_null_handling},
	{"test_stmt_scan_struct_not_a_struct_errors",      test_stmt_scan_struct_not_a_struct_errors},
	{"test_db_query_one_struct",                       test_db_query_one_struct},
	{"test_db_query_optional_struct_zero_rows",        test_db_query_optional_struct_zero_rows},
	{"test_db_query_optional_struct_one_row",          test_db_query_optional_struct_one_row},
	{"test_db_query_all_struct",                       test_db_query_all_struct},

	{"test_async_io_basic_operations",     test_async_io_basic_operations},
	{"test_async_io_step_iteration",       test_async_io_step_iteration},
	{"test_async_io_step_once_manual_drive", test_async_io_step_once_manual_drive},

	{"test_cache_reuses_prepared_statement",      test_cache_reuses_prepared_statement},
	{"test_cache_resets_between_uses",            test_cache_resets_between_uses},
	{"test_cache_distinct_sql_get_distinct_entries", test_cache_distinct_sql_get_distinct_entries},
	{"test_cache_clear_releases_entries",         test_cache_clear_releases_entries},

	// New audit tests — see savepoint_quoting_test.odin / row_mapping_partial_leak_test.odin /
	// error_sql_leak_test.odin.
	{"test_savepoint_name_with_injection_payload",     test_savepoint_name_with_injection_payload},
	{"test_savepoint_name_with_embedded_double_quote", test_savepoint_name_with_embedded_double_quote},
	{"test_savepoint_name_with_nul_byte",              test_savepoint_name_with_nul_byte},
	{"test_stmt_scan_struct_partial_failure_leaks_earlier_text_field", test_stmt_scan_struct_partial_failure_leaks_earlier_text_field},
	{"test_db_query_one_struct_error_clones_sql_and_leaks", test_db_query_one_struct_error_clones_sql_and_leaks},
	{"test_cache_handle_survives_map_grow",                test_cache_handle_survives_map_grow},
	{"test_db_rollback_to_error_sql_is_owned",             test_db_rollback_to_error_sql_is_owned},
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	passed := 0
	for t in ALL_TESTS {
		fmt.printf("[ RUN  ] %s\n", t.name)
		t.fn()
		fmt.printf("[  OK  ] %s\n", t.name)
		passed += 1
	}
	fmt.printf("\n%d/%d tests passed\n", passed, len(ALL_TESTS))

	if len(track.allocation_map) > 0 {
		fmt.eprintf("\n=== %d LEAKED ALLOCATIONS ===\n", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintf("  %v bytes @ %v\n", entry.size, entry.location)
		}
	} else {
		fmt.printf("\n[OK] zero leaked allocations\n")
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintf("\n=== %d BAD FREES ===\n", len(track.bad_free_array))
		for entry in track.bad_free_array {
			fmt.eprintf("  ptr=%v @ %v\n", entry.memory, entry.location)
		}
	}
}
