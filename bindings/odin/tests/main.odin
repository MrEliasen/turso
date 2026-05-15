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

	{"test_conn_exec_ddl", test_conn_exec_ddl},
	{"test_insert_two_and_count", test_insert_two_and_count},
	{"test_last_insert_rowid", test_last_insert_rowid},

	{"test_prepare_first_loop", test_prepare_first_loop},

	{"test_encryption_open_roundtrip", test_encryption_open_roundtrip},
	{"test_encryption_wrong_key_fails", test_encryption_wrong_key_fails},
	{"test_encryption_wal_checkpoint_and_reopen", test_encryption_wal_checkpoint_and_reopen},
	{"test_encryption_plaintext_absent_in_file", test_encryption_plaintext_absent_in_file},

	{"test_two_connections_share_state", test_two_connections_share_state},

	{"test_conn_with_transaction_commit",                  test_conn_with_transaction_commit},
	{"test_conn_with_transaction_rollback",                test_conn_with_transaction_rollback},
	{"test_conn_with_transaction_manual_commands",         test_conn_with_transaction_manual_commands},
	{"test_conn_with_savepoint_release",                   test_conn_with_savepoint_release},
	{"test_conn_with_savepoint_rollback",                  test_conn_with_savepoint_rollback},
	{"test_conn_with_savepoint_nested",                    test_conn_with_savepoint_nested},
	{"test_conn_with_transaction_body_failure_propagates", test_conn_with_transaction_body_failure_propagates},

	{"test_stmt_scan_struct_by_name",                  test_stmt_scan_struct_by_name},
	{"test_stmt_scan_struct_tag_override",             test_stmt_scan_struct_tag_override},
	{"test_stmt_scan_struct_missing_column_ignored",   test_stmt_scan_struct_missing_column_ignored},
	{"test_stmt_scan_struct_extra_column_ignored",     test_stmt_scan_struct_extra_column_ignored},
	{"test_stmt_scan_struct_type_mismatch_errors",     test_stmt_scan_struct_type_mismatch_errors},
	{"test_stmt_scan_struct_null_handling",            test_stmt_scan_struct_null_handling},
	{"test_stmt_scan_struct_not_a_struct_errors",      test_stmt_scan_struct_not_a_struct_errors},
	{"test_conn_query_one_struct",                       test_conn_query_one_struct},
	{"test_conn_query_optional_struct_zero_rows",        test_conn_query_optional_struct_zero_rows},
	{"test_conn_query_optional_struct_one_row",          test_conn_query_optional_struct_one_row},
	{"test_conn_query_all_struct",                       test_conn_query_all_struct},

	{"test_async_io_basic_operations",     test_async_io_basic_operations},
	{"test_async_io_step_iteration",       test_async_io_step_iteration},
	{"test_async_io_step_once_manual_drive", test_async_io_step_once_manual_drive},

	{"test_cache_reuses_prepared_statement",      test_cache_reuses_prepared_statement},
	{"test_cache_resets_between_uses",            test_cache_resets_between_uses},
	{"test_cache_distinct_sql_get_distinct_entries", test_cache_distinct_sql_get_distinct_entries},
	{"test_cache_clear_releases_entries",         test_cache_clear_releases_entries},

	// row_mapping_query_all_leak_test.odin: cleanup on partial failure for
	// conn_query_all_struct / conn_query_one_struct / conn_query_optional_struct.
	{"test_query_all_struct_frees_partial_rows_on_type_mismatch", test_query_all_struct_frees_partial_rows_on_type_mismatch},
	{"test_query_one_struct_frees_out_on_too_many_rows",          test_query_one_struct_frees_out_on_too_many_rows},
	{"test_query_optional_struct_frees_out_on_too_many_rows",     test_query_optional_struct_frees_out_on_too_many_rows},

	// New audit tests — see savepoint_quoting_test.odin / row_mapping_partial_leak_test.odin /
	// error_sql_leak_test.odin.
	{"test_savepoint_name_with_injection_payload",     test_savepoint_name_with_injection_payload},
	{"test_savepoint_name_with_embedded_double_quote", test_savepoint_name_with_embedded_double_quote},
	{"test_savepoint_name_with_nul_byte",              test_savepoint_name_with_nul_byte},
	{"test_stmt_scan_struct_partial_failure_leaks_earlier_text_field", test_stmt_scan_struct_partial_failure_leaks_earlier_text_field},
	{"test_conn_query_one_struct_error_clones_sql_and_leaks", test_conn_query_one_struct_error_clones_sql_and_leaks},
	{"test_cache_handle_survives_map_grow",                test_cache_handle_survives_map_grow},
	{"test_conn_rollback_to_error_sql_is_owned",             test_conn_rollback_to_error_sql_is_owned},

	// Audit tier 2: input validation, NULL/empty distinction, wide rows, sized-int binders.
	{"test_prepare_rejects_sql_with_embedded_nul",            test_prepare_rejects_sql_with_embedded_nul},
	{"test_prepare_first_rejects_sql_with_embedded_nul",      test_prepare_first_rejects_sql_with_embedded_nul},
	{"test_database_open_rejects_path_with_embedded_nul",     test_database_open_rejects_path_with_embedded_nul},
	{"test_database_open_rejects_features_with_embedded_nul", test_database_open_rejects_features_with_embedded_nul},
	{"test_param_position_returns_not_found_for_nul_name",    test_param_position_returns_not_found_for_nul_name},
	{"test_get_text_ok_distinguishes_null_from_empty",        test_get_text_ok_distinguishes_null_from_empty},
	{"test_get_blob_ok_distinguishes_null_from_empty",        test_get_blob_ok_distinguishes_null_from_empty},
	{"test_bind_bool_roundtrip",                              test_bind_bool_roundtrip},
	{"test_bind_small_int_widens",                            test_bind_small_int_widens},
	{"test_bind_u64_wraps_to_i64",                            test_bind_u64_wraps_to_i64},
	{"test_bind_f32_widens_to_f64",                           test_bind_f32_widens_to_f64},
	{"test_stmt_scan_struct_handles_more_than_stack_cols",    test_stmt_scan_struct_handles_more_than_stack_cols},

	// Concurrency stress: exercises the setup() seqlock + atomic logger from
	// two threads. Iteration count scales with -define:TURSO_TSAN_STRESS so
	// the same test serves the cheap default and the long TSAN run.
	{"test_setup_seqlock_stress",                             test_setup_seqlock_stress},
	// One Database, two Connections, two threads. Validates the documented
	// Send+Sync contract on Database under TSAN and confirms cross-connection
	// state visibility on a normal build.
	{"test_two_connections_two_threads",                      test_two_connections_two_threads},

	// Value boundaries (value_boundary_test.odin).
	{"test_bind_int_boundary_i64_min",        test_bind_int_boundary_i64_min},
	{"test_bind_int_boundary_i64_max",        test_bind_int_boundary_i64_max},
	{"test_bind_double_special_values",       test_bind_double_special_values},
	{"test_bind_double_nan_does_not_crash",   test_bind_double_nan_does_not_crash},
	{"test_bind_blob_one_mb_roundtrip",       test_bind_blob_one_mb_roundtrip},

	// Text handling (text_handling_test.odin).
	{"test_bind_text_unicode_roundtrip",              test_bind_text_unicode_roundtrip},
	{"test_bind_text_with_embedded_nul_roundtrip",    test_bind_text_with_embedded_nul_roundtrip},
	{"test_column_name_utf8_alias",                   test_column_name_utf8_alias},

	// Closed-handle MISUSE (closed_handle_test.odin).
	{"test_step_on_closed_statement_returns_misuse",       test_step_on_closed_statement_returns_misuse},
	{"test_bind_on_closed_statement_returns_misuse",       test_bind_on_closed_statement_returns_misuse},
	{"test_prepare_on_closed_connection_returns_misuse",   test_prepare_on_closed_connection_returns_misuse},
	{"test_exec_on_closed_connection_returns_misuse",      test_exec_on_closed_connection_returns_misuse},
	{"test_connect_on_closed_database_returns_misuse",     test_connect_on_closed_database_returns_misuse},

	// Index bounds (index_bounds_test.odin).
	{"test_stmt_get_int_negative_index_returns_zero",          test_stmt_get_int_negative_index_returns_zero},
	{"test_stmt_get_text_negative_index_returns_empty",        test_stmt_get_text_negative_index_returns_empty},
	{"test_stmt_column_name_negative_index_returns_empty",     test_stmt_column_name_negative_index_returns_empty},
	{"test_stmt_param_name_non_positive_index_returns_empty",  test_stmt_param_name_non_positive_index_returns_empty},

	// Constraint violations (constraint_test.odin).
	{"test_unique_constraint_violation_returns_constraint_code",    test_unique_constraint_violation_returns_constraint_code},
	{"test_not_null_constraint_violation_returns_constraint_code",  test_not_null_constraint_violation_returns_constraint_code},
	{"test_check_constraint_violation_returns_constraint_code",     test_check_constraint_violation_returns_constraint_code},
	{"test_constraint_error_carries_failing_sql",                   test_constraint_error_carries_failing_sql},

	// Cache lifetime (cache_lifetime_test.odin).
	{"test_cache_destroy_after_connection_close_does_not_crash",  test_cache_destroy_after_connection_close_does_not_crash},
	{"test_cached_statement_survives_schema_change",              test_cached_statement_survives_schema_change},

	// Multi-statement exec (exec_batch_test.odin).
	{"test_exec_batch_runs_ddl_plus_inserts",                  test_exec_batch_runs_ddl_plus_inserts},
	{"test_exec_batch_stops_on_error",                         test_exec_batch_stops_on_error},
	{"test_exec_batch_on_closed_connection_returns_misuse",    test_exec_batch_on_closed_connection_returns_misuse},
	{"test_exec_batch_with_only_whitespace_succeeds",          test_exec_batch_with_only_whitespace_succeeds},
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
