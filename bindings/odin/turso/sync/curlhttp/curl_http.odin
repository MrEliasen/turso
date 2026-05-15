// Built-in libcurl-backed HTTP client for the sync engine.
//
// Opt-in subpackage. Importing turso/sync/curlhttp pulls libcurl + the
// vendor:curl link chain (mbedtls on Linux, system curl + framework link on
// Darwin); sync users who supply their own HTTP transport never import this
// path and pay zero link cost.
//
// Use:
//   import sync "turso/sync"
//   import curlhttp "turso/sync/curlhttp"
//   client := curlhttp.client(token)
//   db, e, ok := sync.database_create(core_cfg, sync_cfg, client)
//
// libsql:// URLs are rewritten to https:// before invocation — the engine
// emits libsql:// in req.url and expects the transport to map it.
//
// Each call creates and tears down an easy handle. That is the simplest
// correct shape (no shared mutable state across calls), and the per-call
// setup is negligible compared to the network roundtrip. A future iteration
// could share a handle through HTTP_Client.user_data with a mutex if
// profiling proves otherwise.
package turso_sync_curlhttp

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import curl "vendor:curl"
import sync "../"

// CONNECT_TIMEOUT_SECONDS bounds the time spent establishing the TCP+TLS handshake
// to the sync endpoint. REQUEST_TIMEOUT_SECONDS bounds the total wall-clock time
// the easy handle spends inside curl_easy_perform. Both are intentionally
// conservative; if the engine ever needs more elasticity, expose them through
// HTTP_Client or accept a configurable client.
CONNECT_TIMEOUT_SECONDS :: 10
REQUEST_TIMEOUT_SECONDS :: 60

// MAX_RESPONSE_BYTES caps the total bytes the client will buffer from a single
// HTTP response. Defends against a misbehaving or malicious remote streaming
// gigabytes of body to force unbounded memory growth inside the sync engine.
// 256 MiB is well above any expected sync payload but small enough to keep
// the process from OOM on a 32-bit host. Callers needing a different cap can
// either reassign this package variable before issuing requests or supply
// their own HTTP_Do via sync.HTTP_Client.roundtrip. The package itself only
// reads this value; tests adjust it under the assumption that no concurrent
// roundtrip is in flight.
MAX_RESPONSE_BYTES: i64 = 256 * 1024 * 1024

@(private="file")
Curl_Write_State :: struct {
	buf:       ^[dynamic]u8,
	allocator: mem.Allocator,
	max_bytes: int,
	ok:        bool,
	too_large: bool,
}

@(private="file")
write_callback :: proc "c" (data: rawptr, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	state := (^Curl_Write_State)(userdata)
	context.allocator = state.allocator
	total := int(size) * int(nmemb)
	if total == 0 { return 0 }
	// Hard cap: if appending this chunk would push the buffer past max_bytes,
	// flag the request and abort the transfer. The remote may have lied about
	// (or omitted) Content-Length, so MAXFILESIZE_LARGE alone is not sufficient.
	if state.max_bytes > 0 && len(state.buf) + total > state.max_bytes {
		state.ok = false
		state.too_large = true
		return 0
	}
	src := ([^]u8)(data)[:total]
	if _, err := append(state.buf, ..src); err != nil {
		state.ok = false
		return 0
	}
	return c.size_t(total)
}

// roundtrip is an HTTP_Do backed by vendor:curl. Use client to obtain an
// HTTP_Client wrapped around it.
roundtrip :: proc(user_data: rawptr, req: sync.HTTP_Request, allocator: mem.Allocator) ->
	(resp: sync.HTTP_Response, message: string, ok: bool) {
	url := req.url
	if strings.has_prefix(url, "libsql://") {
		url = strings.concatenate({"https://", url[len("libsql://"):]}, allocator)
	}

	handle := curl.easy_init()
	if handle == nil {
		return {}, "curl_easy_init returned nil", false
	}
	defer curl.easy_cleanup(handle)

	if rc := curl.easy_setopt(handle, curl.option.URL, strings.clone_to_cstring(url, allocator)); rc != .E_OK {
		return {}, curl_err("CURLOPT_URL", rc, allocator), false
	}
	if rc := curl.easy_setopt(handle, curl.option.NOSIGNAL, c.long(1)); rc != .E_OK {
		return {}, curl_err("CURLOPT_NOSIGNAL", rc, allocator), false
	}
	// Auto-follow is disabled. The sync dispatcher attaches Authorization: Bearer <token>
	// via CURLOPT_HTTPHEADER and libcurl re-sends custom header lists across cross-host
	// redirects, which would leak the credential to whatever the redirect points at.
	// Sync endpoints are not expected to 3xx; if that ever changes the engine should
	// surface the new URL explicitly so the caller (and this client) can validate it.
	if rc := curl.easy_setopt(handle, curl.option.FOLLOWLOCATION, c.long(0)); rc != .E_OK {
		return {}, curl_err("CURLOPT_FOLLOWLOCATION", rc, allocator), false
	}
	// Defence in depth: also set hard wall-clock and connect deadlines so a hung
	// server cannot block sync.push / sync.pull indefinitely from inside
	// curl_easy_perform. Values are conservative defaults; callers needing finer
	// control can supply their own HTTP_Do via sync.HTTP_Client.roundtrip.
	if rc := curl.easy_setopt(handle, curl.option.CONNECTTIMEOUT, c.long(CONNECT_TIMEOUT_SECONDS)); rc != .E_OK {
		return {}, curl_err("CURLOPT_CONNECTTIMEOUT", rc, allocator), false
	}
	if rc := curl.easy_setopt(handle, curl.option.TIMEOUT, c.long(REQUEST_TIMEOUT_SECONDS)); rc != .E_OK {
		return {}, curl_err("CURLOPT_TIMEOUT", rc, allocator), false
	}
	// Server-declared body size cap. curl returns CURLE_FILESIZE_EXCEEDED before
	// transferring if the response advertises Content-Length above this limit.
	// The write_callback hard cap below handles the case where the server lies
	// or omits Content-Length and just streams.
	if rc := curl.easy_setopt(handle, curl.option.MAXFILESIZE_LARGE, curl.off_t(MAX_RESPONSE_BYTES)); rc != .E_OK {
		return {}, curl_err("CURLOPT_MAXFILESIZE_LARGE", rc, allocator), false
	}

	method_upper := strings.to_upper(req.method, allocator)
	switch method_upper {
	case "", "GET":
		// default
	case "POST":
		if rc := curl.easy_setopt(handle, curl.option.POST, c.long(1)); rc != .E_OK {
			return {}, curl_err("CURLOPT_POST", rc, allocator), false
		}
	case:
		if rc := curl.easy_setopt(handle, curl.option.CUSTOMREQUEST, strings.clone_to_cstring(req.method, allocator)); rc != .E_OK {
			return {}, curl_err("CURLOPT_CUSTOMREQUEST", rc, allocator), false
		}
	}

	if len(req.body) > 0 {
		if rc := curl.easy_setopt(handle, curl.option.POSTFIELDSIZE_LARGE, curl.off_t(len(req.body))); rc != .E_OK {
			return {}, curl_err("CURLOPT_POSTFIELDSIZE_LARGE", rc, allocator), false
		}
		if rc := curl.easy_setopt(handle, curl.option.POSTFIELDS, rawptr(raw_data(req.body))); rc != .E_OK {
			return {}, curl_err("CURLOPT_POSTFIELDS", rc, allocator), false
		}
	}

	header_list: ^curl.slist = nil
	defer if header_list != nil { curl.slist_free_all(header_list) }
	for h in req.headers {
		line := fmt.aprintf("%s: %s", h.key, h.value, allocator = allocator)
		next := curl.slist_append(header_list, strings.clone_to_cstring(line, allocator))
		if next == nil {
			return {}, "curl_slist_append returned nil", false
		}
		header_list = next
	}
	if header_list != nil {
		if rc := curl.easy_setopt(handle, curl.option.HTTPHEADER, header_list); rc != .E_OK {
			return {}, curl_err("CURLOPT_HTTPHEADER", rc, allocator), false
		}
	}

	body_buf := make([dynamic]u8, 0, 4096, allocator)
	state := Curl_Write_State{
		buf       = &body_buf,
		allocator = allocator,
		max_bytes = int(MAX_RESPONSE_BYTES),
		ok        = true,
	}
	if rc := curl.easy_setopt(handle, curl.option.WRITEFUNCTION, write_callback); rc != .E_OK {
		return {}, curl_err("CURLOPT_WRITEFUNCTION", rc, allocator), false
	}
	if rc := curl.easy_setopt(handle, curl.option.WRITEDATA, rawptr(&state)); rc != .E_OK {
		return {}, curl_err("CURLOPT_WRITEDATA", rc, allocator), false
	}

	if rc := curl.easy_perform(handle); rc != .E_OK {
		// Two defence layers can reject an oversize response:
		//   1. CURLOPT_MAXFILESIZE_LARGE catches a declared Content-Length above
		//      the cap before any body bytes are transferred and surfaces
		//      CURLE_FILESIZE_EXCEEDED.
		//   2. The write_callback hard cap aborts the transfer mid-stream when
		//      the server lies about (or omits) Content-Length, which curl
		//      surfaces as CURLE_WRITE_ERROR.
		// Both paths produce the same typed message so callers can branch on
		// "response too large" without inspecting libcurl error codes.
		if state.too_large || rc == .E_FILESIZE_EXCEEDED {
			return {}, fmt.aprintf("response exceeded MAX_RESPONSE_BYTES (%d) - server returned too much data", MAX_RESPONSE_BYTES, allocator = allocator), false
		}
		return {}, curl_err("curl_easy_perform", rc, allocator), false
	}
	if !state.ok {
		if state.too_large {
			return {}, fmt.aprintf("response exceeded MAX_RESPONSE_BYTES (%d) - server returned too much data", MAX_RESPONSE_BYTES, allocator = allocator), false
		}
		return {}, "curl write callback ran out of memory", false
	}

	status_long: c.long
	if rc := curl.easy_getinfo(handle, curl.INFO.RESPONSE_CODE, &status_long); rc != .E_OK {
		return {}, curl_err("CURLINFO_RESPONSE_CODE", rc, allocator), false
	}

	return sync.HTTP_Response{status = i32(status_long), body = body_buf[:]}, "", true
}

// client returns an HTTP_Client wired to roundtrip. auth_token, if non-empty,
// is injected by the sync dispatcher as Authorization: Bearer <token>.
client :: proc(auth_token: string = "") -> sync.HTTP_Client {
	return sync.HTTP_Client{roundtrip = roundtrip, auth_token = auth_token}
}

@(private="file")
curl_err :: proc(op: string, code: curl.code, allocator: mem.Allocator) -> string {
	desc := curl.easy_strerror(code)
	desc_s := desc != nil ? string(desc) : "(no description)"
	return fmt.aprintf("%s: %s (code=%d)", op, desc_s, int(code), allocator = allocator)
}
