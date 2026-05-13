package sync_tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import sync_pkg "../../turso/sync"

// curl-shellout HTTP_Client. Test-only — not part of the public turso/sync
// package. Useful for cloud E2E tests where pulling in a vendored HTTP lib
// is overkill. Requires `curl` on PATH.
//
// Each call:
//   1. Writes the request body to a tempfile (if non-empty)
//   2. Runs `curl -sS -X METHOD [-H ...] [--data-binary @body] -o resp -w '%{http_code}' URL`
//   3. Reads the response body file and returns it alongside the parsed status
//
// libsql:// URLs are transparently rewritten to https:// before invocation.

@(private)
curl_seq: u64

@(private)
curl_seq_mu: sync.Mutex

curl_roundtrip :: proc(user_data: rawptr, req: sync_pkg.HTTP_Request, allocator: mem.Allocator) ->
	(resp: sync_pkg.HTTP_Response, message: string, ok: bool) {
	url := req.url
	if strings.has_prefix(url, "libsql://") {
		url = strings.concatenate({"https://", url[len("libsql://"):]}, allocator)
	}

	base := "/tmp"
	seq := curl_next_seq()
	req_body_path: string
	if len(req.body) > 0 {
		req_body_path, _ = filepath.join({base, fmt.tprintf("odin_curl_req_%d_%d", os.get_current_thread_id(), seq)}, allocator)
		if werr := os.write_entire_file(req_body_path, req.body); werr != nil {
			return {}, fmt.tprintf("curl: write request body: %v", werr), false
		}
	}
	resp_body_path, _ := filepath.join({base, fmt.tprintf("odin_curl_resp_%d_%d", os.get_current_thread_id(), seq)}, allocator)
	// Block-scoped defer in Odin would remove these too early — clean up at
	// function exit instead.
	defer {
		if req_body_path != "" { os.remove(req_body_path) }
		os.remove(resp_body_path)
	}

	args: [dynamic]string
	args.allocator = allocator
	append(&args, "curl", "-sS", "-X", req.method)
	for h in req.headers {
		append(&args, "-H", fmt.tprintf("%s: %s", h.key, h.value))
	}
	if req_body_path != "" {
		append(&args, "--data-binary", strings.concatenate({"@", req_body_path}, allocator))
	}
	append(&args, "-o", resp_body_path)
	append(&args, "-w", "%{http_code}")
	append(&args, url)

	state, stdout, stderr, perr := os.process_exec(os.Process_Desc{command = args[:]}, allocator)
	if perr != nil {
		return {}, fmt.tprintf("curl: process_exec failed: %v", perr), false
	}
	if state.exit_code != 0 {
		return {}, fmt.tprintf("curl: exit=%d stderr=%q", state.exit_code, string(stderr)), false
	}
	_ = stderr

	status_str := strings.trim_space(string(stdout))
	status_val, parsed := strconv.parse_int(status_str, 10)
	if !parsed {
		return {}, fmt.tprintf("curl: unparseable status %q", status_str), false
	}

	body: []u8
	if os.exists(resp_body_path) {
		read_bytes, rerr := os.read_entire_file(resp_body_path, allocator)
		if rerr != nil {
			return {}, fmt.tprintf("curl: read response body: %v", rerr), false
		}
		body = read_bytes
	}
	return sync_pkg.HTTP_Response{status = i32(status_val), body = body}, "", true
}

curl_client :: proc(auth_token: string = "") -> sync_pkg.HTTP_Client {
	return sync_pkg.HTTP_Client{roundtrip = curl_roundtrip, auth_token = auth_token}
}

@(private)
curl_next_seq :: proc() -> u64 {
	sync.lock(&curl_seq_mu)
	defer sync.unlock(&curl_seq_mu)
	curl_seq += 1
	return curl_seq
}
