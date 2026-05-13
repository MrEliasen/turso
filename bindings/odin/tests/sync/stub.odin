package sync_tests

import "core:mem"
import "core:strings"
import sync "../../turso/sync"

// Stub_Response is what the stub returns for a given (method, url) pair.
Stub_Response :: struct {
	status: i32,
	body:   []u8,
}

// Stub_Call records one HTTP call the engine made. Both fields owned by the
// stub; freed in stub_destroy.
Stub_Call :: struct {
	method: string,
	url:    string,
}

// Stub_State is the user_data the HTTP_Client points at. Holds canned
// responses (matched by exact "METHOD URL" key) and records every call.
Stub_State :: struct {
	responses:      map[string]Stub_Response,
	calls:          [dynamic]Stub_Call,
	default_status: i32,
	default_body:   []u8,
}

stub_init :: proc(s: ^Stub_State) {
	s.responses = make(map[string]Stub_Response)
	s.calls = make([dynamic]Stub_Call)
	s.default_status = 200
	s.default_body = nil
}

stub_destroy :: proc(s: ^Stub_State) {
	for call in s.calls {
		delete(call.method)
		delete(call.url)
	}
	delete(s.calls)
	for key, _ in s.responses {
		delete(key)
	}
	delete(s.responses)
}

stub_set :: proc(s: ^Stub_State, method: string, url: string, status: i32, body: []u8) {
	key := strings.concatenate({method, " ", url})
	s.responses[key] = Stub_Response{status = status, body = body}
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

@(private)
stub_roundtrip :: proc(user_data: rawptr, req: sync.HTTP_Request, allocator: mem.Allocator) ->
	(resp: sync.HTTP_Response, message: string, ok: bool) {
	s := cast(^Stub_State)user_data
	append(&s.calls, Stub_Call{method = strings.clone(req.method), url = strings.clone(req.url)})

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
