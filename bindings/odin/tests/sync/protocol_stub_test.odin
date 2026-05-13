package sync_tests

import "core:strings"
import turso "../../turso"
import sync "../../turso/sync"

// Tests for the protocol-aware HTTP stub. These exercise the JSON
// (/v2/pipeline) and protobuf (/pull-updates) wire formats without a real
// network. Before these tests existed, the only way to validate happy-path
// push/pull was the env-gated cloud E2E.
//
// Each test follows the make_db_with_local_changes pattern from
// error_paths_test.odin: create a synced DB at a temp path, mutate a row,
// then drive a sync operation through the stub.

// test_sync_push_pipeline_ok_handler_emits_valid_request verifies that
// sync.push reaches the /v2/pipeline endpoint with a JSON body the engine
// actually produced (not an EOF stub). The first request the engine makes is
// fetch_last_change_id, which selects from turso_sync_last_change_id — so the
// captured body must contain that table name. We do not require push to
// succeed end-to-end (subsequent calls may fail with the empty-result stub);
// the assertion is on the first serialized request.
test_sync_push_pipeline_ok_handler_emits_valid_request :: proc() {
	dir := make_temp_dir("proto_stub_push_ok")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)
	stub_set_handler(&stub, "/v2/pipeline", pipeline_ok_handler)

	db := make_db_with_local_changes(dir, stub_client(&stub))
	defer sync.database_close(&db)

	// sync.push may succeed or fail depending on how the empty-result stub
	// interacts with downstream replay logic. Either is acceptable; we assert
	// only that the engine actually reached the HTTP layer with a real Hrana
	// JSON payload.
	e, _ := sync.push(db)
	turso.error_destroy(&e)

	expect_true(
		stub_path_call_count(&stub, "/v2/pipeline") >= 1,
		"expected at least one /v2/pipeline call",
	)
	body := stub_last_body(&stub, "/v2/pipeline")
	expect_true(
		strings.contains(string(body), "turso_sync_last_change_id"),
		"captured /v2/pipeline body should reference turso_sync_last_change_id",
	)
}

// test_sync_push_pipeline_stub_propagates_server_error verifies that when the
// stub returns a structurally-valid PipelineRespBody with an Error result,
// the engine deserializes it cleanly (no JSON parse error) and surfaces the
// stub's error message to the caller. This is the strongest single proof
// that the JSON wire format is correct: a wire-format bug would manifest as
// "EOF while parsing a value" rather than the stub's message.
test_sync_push_pipeline_stub_propagates_server_error :: proc() {
	dir := make_temp_dir("proto_stub_push_err")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)
	stub_set_handler(&stub, "/v2/pipeline", pipeline_error_handler)

	db := make_db_with_local_changes(dir, stub_client(&stub))
	defer sync.database_close(&db)

	e, ok := sync.push(db)
	expect_err(e, ok, "sync.push must fail when stub returns Pipeline error result")
	expect_true(
		strings.contains(e.message, "intentional stub failure") ||
			strings.contains(e.message, "STUB_ERROR"),
		"engine should have deserialized the stub's error payload and surfaced its message",
	)
	turso.error_destroy(&e)
}

// test_sync_pull_with_empty_protobuf_handler verifies that the protobuf
// /pull-updates wire path works. The stub responds with a single
// length-prefixed PullUpdatesRespProtoBody message and no PageData entries,
// modelling "server has nothing new". sync.pull may fail in surrounding
// metadata-SQL phases (we don't fully simulate the cloud), but at least one
// /pull-updates HTTP call must have been recorded with the engine's protobuf
// request payload.
test_sync_pull_with_empty_protobuf_handler :: proc() {
	dir := make_temp_dir("proto_stub_pull_empty")
	defer remove_temp_dir(dir)

	stub: Stub_State
	stub_init(&stub)
	defer stub_destroy(&stub)
	stub_set_handler(&stub, "/v2/pipeline", pipeline_ok_handler)
	stub_set_handler(&stub, "/pull-updates", pull_updates_empty_handler)

	db := make_db_with_local_changes(dir, stub_client(&stub))
	defer sync.database_close(&db)

	_, e, _ := sync.pull(db)
	turso.error_destroy(&e)

	expect_true(
		stub_path_call_count(&stub, "/pull-updates") >= 1,
		"expected at least one /pull-updates call",
	)
}
