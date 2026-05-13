package sync_tests

import "core:fmt"

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
	{"test_sync_cloud_e2e",                     test_sync_cloud_e2e},
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
