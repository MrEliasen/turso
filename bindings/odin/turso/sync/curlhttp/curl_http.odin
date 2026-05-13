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

@(private="file")
Curl_Write_State :: struct {
	buf:       ^[dynamic]u8,
	allocator: mem.Allocator,
	ok:        bool,
}

@(private="file")
write_callback :: proc "c" (data: rawptr, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	state := (^Curl_Write_State)(userdata)
	context.allocator = state.allocator
	total := int(size) * int(nmemb)
	if total == 0 { return 0 }
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
	if rc := curl.easy_setopt(handle, curl.option.FOLLOWLOCATION, c.long(1)); rc != .E_OK {
		return {}, curl_err("CURLOPT_FOLLOWLOCATION", rc, allocator), false
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
	state := Curl_Write_State{buf = &body_buf, allocator = allocator, ok = true}
	if rc := curl.easy_setopt(handle, curl.option.WRITEFUNCTION, write_callback); rc != .E_OK {
		return {}, curl_err("CURLOPT_WRITEFUNCTION", rc, allocator), false
	}
	if rc := curl.easy_setopt(handle, curl.option.WRITEDATA, rawptr(&state)); rc != .E_OK {
		return {}, curl_err("CURLOPT_WRITEDATA", rc, allocator), false
	}

	if rc := curl.easy_perform(handle); rc != .E_OK {
		return {}, curl_err("curl_easy_perform", rc, allocator), false
	}
	if !state.ok {
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
