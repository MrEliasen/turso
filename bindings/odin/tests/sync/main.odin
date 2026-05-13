package sync_tests

import "core:fmt"
import "core:mem"

Test_Entry :: struct {
	name: string,
	fn:   proc(),
}

ALL_TESTS := [?]Test_Entry{
	{"test_sync_link",                          test_sync_link},
	{"test_sync_database_create_close",         test_sync_database_create_close},
	{"test_sync_database_open_without_setup",   test_sync_database_open_without_setup},
	{"test_sync_database_close_idempotent",     test_sync_database_close_idempotent},
	{"test_sync_connect_and_query",             test_sync_connect_and_query},
	{"test_sync_changes_close_idempotent",      test_sync_changes_close_idempotent},
	{"test_sync_stats_destroy_idempotent",      test_sync_stats_destroy_idempotent},
	{"test_sync_stats_local_only",              test_sync_stats_local_only},
	{"test_sync_push_returns_error_when_client_fails", test_sync_push_returns_error_when_client_fails},
	{"test_sync_push_returns_error_on_http_401",       test_sync_push_returns_error_on_http_401},
	{"test_sync_push_returns_error_on_http_500",       test_sync_push_returns_error_on_http_500},
	{"test_sync_push_pipeline_ok_handler_emits_valid_request", test_sync_push_pipeline_ok_handler_emits_valid_request},
	{"test_sync_push_pipeline_stub_propagates_server_error",   test_sync_push_pipeline_stub_propagates_server_error},
	{"test_sync_pull_with_empty_protobuf_handler",             test_sync_pull_with_empty_protobuf_handler},
	{"test_curlhttp_get_returns_status_and_body",              test_curlhttp_get_returns_status_and_body},
	{"test_curlhttp_post_with_body_and_header",                test_curlhttp_post_with_body_and_header},
	{"test_curlhttp_returns_non_2xx_status_without_error",     test_curlhttp_returns_non_2xx_status_without_error},
	{"test_curlhttp_custom_method_delete",                     test_curlhttp_custom_method_delete},
	{"test_http_response_chunks_empty_body",                   test_http_response_chunks_empty_body},
	{"test_http_response_chunks_smaller_than_chunk",           test_http_response_chunks_smaller_than_chunk},
	{"test_http_response_chunks_exact_multiple",               test_http_response_chunks_exact_multiple},
	{"test_http_response_chunks_uneven_split",                 test_http_response_chunks_uneven_split},
	{"test_http_response_chunks_zero_chunk_size_falls_back_to_single", test_http_response_chunks_zero_chunk_size_falls_back_to_single},
	{"test_http_response_chunks_reassembly_matches_body",      test_http_response_chunks_reassembly_matches_body},
	{"test_encode_pull_updates_response_empty",                test_encode_pull_updates_response_empty},
	{"test_encode_pull_updates_response_with_db_size",         test_encode_pull_updates_response_with_db_size},
	{"test_encode_pull_updates_response_with_one_page",        test_encode_pull_updates_response_with_one_page},
	{"test_encode_pull_updates_response_with_three_pages",     test_encode_pull_updates_response_with_three_pages},
	{"test_pull_updates_with_pages_handler_returns_installed_bytes", test_pull_updates_with_pages_handler_returns_installed_bytes},
	{"test_sync_bootstrap_from_captured_pages",                test_sync_bootstrap_from_captured_pages},
	{"test_sync_cloud_e2e",                     test_sync_cloud_e2e},

	// New audit tests
	{"test_http_client_auth_token_is_forwarded", test_http_client_auth_token_is_forwarded},

	// Audit tier 2: auth_token must reject bytes that would let a caller
	// smuggle additional headers or split the HTTP request.
	{"test_sync_config_auth_token_rejects_crlf",         test_sync_config_auth_token_rejects_crlf},
	{"test_sync_config_auth_token_rejects_nul",          test_sync_config_auth_token_rejects_nul},
	{"test_sync_client_auth_token_rejects_crlf",         test_sync_client_auth_token_rejects_crlf},
	{"test_curlhttp_does_not_auto_follow_redirects",     test_curlhttp_does_not_auto_follow_redirects},
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
