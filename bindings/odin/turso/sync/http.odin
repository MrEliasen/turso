package turso_sync

import "core:mem"
import "core:strings"
import raw "raw"

// HTTP_Header is one request header. Both fields are borrowed and only valid
// for the duration of the HTTP_Do call.
HTTP_Header :: struct {
	key:   string,
	value: string,
}

// HTTP_Request is what the IO dispatcher hands to a user-supplied HTTP client.
// All slices are borrowed and valid only for the duration of the HTTP_Do call.
// `url` is the fully-resolved request URL (the dispatcher combines the engine-
// reported url/path with the Config.remote_url base).
HTTP_Request :: struct {
	url:     string,
	method:  string,
	headers: []HTTP_Header,
	body:    []u8,
}

// HTTP_Response is the HTTP roundtrip result the client returns to the
// dispatcher. body is borrowed for the duration of the call; the dispatcher
// copies the bytes via push_buffer before returning.
HTTP_Response :: struct {
	status: i32,
	body:   []u8,
}

// HTTP_Do is the caller-supplied HTTP roundtrip. Return ok=true to deliver
// status + body to the engine; return ok=false with a non-empty message to
// poison the IO item (the engine sees the operation as failed). The allocator
// is the per-request scratch allocator; allocations on it are valid until
// after the dispatcher pushes data into the engine.
HTTP_Do :: proc(user_data: rawptr, req: HTTP_Request, allocator: mem.Allocator) ->
	(resp: HTTP_Response, message: string, ok: bool)

// HTTP_Client bundles the user's HTTP impl with optional auth state.
// auth_token, when non-empty, is injected as "Authorization: Bearer <token>"
// on every request after the engine-provided headers.
HTTP_Client :: struct {
	user_data:  rawptr,
	roundtrip:  HTTP_Do,
	auth_token: string,
}

@(private)
slice_to_string :: proc(s: raw.Slice_Ref) -> string {
	if s.ptr == nil || s.len == 0 { return "" }
	return string(([^]u8)(s.ptr)[:s.len])
}

@(private)
slice_to_bytes :: proc(s: raw.Slice_Ref) -> []u8 {
	if s.ptr == nil || s.len == 0 { return nil }
	return ([^]u8)(s.ptr)[:s.len]
}

@(private)
bytes_to_slice_ref :: proc(buf: []u8) -> raw.Slice_Ref {
	if len(buf) == 0 { return raw.Slice_Ref{ptr = nil, len = 0} }
	return raw.Slice_Ref{ptr = rawptr(raw_data(buf)), len = uint(len(buf))}
}

@(private)
string_to_slice_ref :: proc(s: string) -> raw.Slice_Ref {
	if len(s) == 0 { return raw.Slice_Ref{ptr = nil, len = 0} }
	return raw.Slice_Ref{ptr = rawptr(raw_data(s)), len = uint(len(s))}
}

// Build a fully-qualified URL from the engine-supplied URL/path and the
// Config-supplied base. The engine emits:
//   - url  : the base (scheme + host) extracted from the saved metadata
//            (often equal to the Config-supplied remote_url). When set, it
//            takes priority over base_url.
//   - path : the request path (e.g. "/v2/pipeline"). Must always be appended.
// libsql:// stays libsql:// — the HTTP client is responsible for the
// libsql→https transport mapping.
@(private)
resolve_url :: proc(base_url: string, engine_url: string, engine_path: string, allocator := context.allocator) -> string {
	base := engine_url
	if base == "" {
		base = base_url
	}
	base = strings.trim_suffix(base, "/")

	path := engine_path
	if path != "" && !strings.has_prefix(path, "/") {
		path = strings.concatenate({"/", path}, allocator)
	}

	if base == "" { return strings.clone(path, allocator) }
	if path == "" { return strings.clone(base, allocator) }
	return strings.concatenate({base, path}, allocator)
}
