package sync_tests

import "core:mem"
import "core:strings"
import sync "../../turso/sync"

// Stub_Response is what the stub returns for a given (method, url) pair.
Stub_Response :: struct {
	status: i32,
	body:   []u8,
}

// Stub_Call records one HTTP call the engine made. method, url, and body are
// owned by the stub and freed in stub_destroy. body is capped at
// STUB_CAPTURE_BODY_MAX bytes to keep memory predictable when large pushes
// happen; tests only need a substring check, not the whole payload.
Stub_Call :: struct {
	method: string,
	url:    string,
	body:   []u8,
}

STUB_CAPTURE_BODY_MAX :: 8 * 1024

// Stub_Handler computes a response from the inbound request. Used when an
// endpoint needs to react to the request body (e.g. mirroring the number of
// requests in a Hrana pipeline batch). The allocator is the per-call scratch;
// returned body must live until stub_roundtrip returns.
Stub_Handler :: proc(req: sync.HTTP_Request, allocator: mem.Allocator) -> (status: i32, body: []u8, ok: bool)

// Stub_State is the user_data the HTTP_Client points at. Holds canned
// responses (exact "METHOD URL" match), dynamic path-suffix handlers, and
// records every call.
Stub_State :: struct {
	responses:      map[string]Stub_Response,
	path_handlers:  map[string]Stub_Handler,
	calls:          [dynamic]Stub_Call,
	default_status: i32,
	default_body:   []u8,
}

stub_init :: proc(s: ^Stub_State) {
	s.responses = make(map[string]Stub_Response)
	s.path_handlers = make(map[string]Stub_Handler)
	s.calls = make([dynamic]Stub_Call)
	s.default_status = 200
	s.default_body = nil
}

stub_destroy :: proc(s: ^Stub_State) {
	for call in s.calls {
		delete(call.method)
		delete(call.url)
		if call.body != nil { delete(call.body) }
	}
	delete(s.calls)
	for key, _ in s.responses {
		delete(key)
	}
	delete(s.responses)
	for key, _ in s.path_handlers {
		delete(key)
	}
	delete(s.path_handlers)
}

stub_set :: proc(s: ^Stub_State, method: string, url: string, status: i32, body: []u8) {
	key := strings.concatenate({method, " ", url})
	s.responses[key] = Stub_Response{status = status, body = body}
}

// stub_set_handler installs a Stub_Handler keyed by path suffix. The roundtrip
// matches by `strings.has_suffix(req.url, suffix)`, so "/v2/pipeline" matches
// any base. The handler takes priority over exact-URL responses.
stub_set_handler :: proc(s: ^Stub_State, path_suffix: string, handler: Stub_Handler) {
	key := strings.clone(path_suffix)
	s.path_handlers[key] = handler
}

stub_call_count :: proc(s: ^Stub_State, method: string, url: string) -> int {
	count := 0
	for call in s.calls {
		if call.method == method && call.url == url {
			count += 1
		}
	}
	return count
}

// stub_path_call_count counts how many recorded calls had a URL ending in the
// given suffix. Useful when the test only knows the path, not the base.
stub_path_call_count :: proc(s: ^Stub_State, path_suffix: string) -> int {
	count := 0
	for call in s.calls {
		if strings.has_suffix(call.url, path_suffix) {
			count += 1
		}
	}
	return count
}

// stub_last_body returns the captured body of the most recent call whose URL
// ends in path_suffix, or nil if no such call was recorded. Borrowed.
stub_last_body :: proc(s: ^Stub_State, path_suffix: string) -> []u8 {
	for i := len(s.calls) - 1; i >= 0; i -= 1 {
		if strings.has_suffix(s.calls[i].url, path_suffix) {
			return s.calls[i].body
		}
	}
	return nil
}

@(private)
clone_capture_body :: proc(body: []u8) -> []u8 {
	if len(body) == 0 { return nil }
	n := len(body)
	if n > STUB_CAPTURE_BODY_MAX { n = STUB_CAPTURE_BODY_MAX }
	out := make([]u8, n)
	copy(out, body[:n])
	return out
}

@(private)
stub_roundtrip :: proc(user_data: rawptr, req: sync.HTTP_Request, allocator: mem.Allocator) ->
	(resp: sync.HTTP_Response, message: string, ok: bool) {
	s := cast(^Stub_State)user_data
	append(&s.calls, Stub_Call{
		method = strings.clone(req.method),
		url    = strings.clone(req.url),
		body   = clone_capture_body(req.body),
	})

	for suffix, handler in s.path_handlers {
		if strings.has_suffix(req.url, suffix) {
			status, body, hok := handler(req, allocator)
			if !hok {
				return sync.HTTP_Response{}, "stub handler returned ok=false", false
			}
			return sync.HTTP_Response{status = status, body = body}, "", true
		}
	}

	key := strings.concatenate({req.method, " ", req.url}, allocator)
	if r, found := s.responses[key]; found {
		return sync.HTTP_Response{status = r.status, body = r.body}, "", true
	}
	return sync.HTTP_Response{status = s.default_status, body = s.default_body}, "", true
}

stub_client :: proc(s: ^Stub_State, auth_token: string = "") -> sync.HTTP_Client {
	return sync.HTTP_Client{
		user_data  = s,
		roundtrip  = stub_roundtrip,
		auth_token = auth_token,
	}
}
