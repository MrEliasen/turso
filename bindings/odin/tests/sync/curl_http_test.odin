package sync_tests

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import sync_pkg "../../turso/sync"
import curlhttp "../../turso/sync/curlhttp"

// Tests for the libcurl-backed HTTP_Do at turso/sync/curlhttp. Each test spins
// up a single-shot TCP server on 127.0.0.1, lets curlhttp.roundtrip make one
// request, then verifies what the server received and what the client saw.

@(private="file")
Curl_Test_Server :: struct {
	listener:            net.TCP_Socket,
	mu:                  sync.Mutex,
	received:            [dynamic]u8,
	response_status:     int,
	response_body:       string,
	// When true, the response is sent without a Content-Length header and the
	// connection is closed to delimit the body. Lets the size-cap regression
	// tests exercise the write_callback hard cap (which is the defense layer
	// that handles a server lying about or omitting Content-Length).
	omit_content_length: bool,
	accept_err:          bool,
}

@(private="file")
curl_test_server_run :: proc(s: ^Curl_Test_Server) {
	client, _, accept_err := net.accept_tcp(s.listener)
	if accept_err != nil {
		sync.lock(&s.mu)
		s.accept_err = true
		sync.unlock(&s.mu)
		return
	}
	defer net.close(client)

	// Loopback delivers small payloads atomically; loop anyway in case curl
	// splits headers + body across syscalls.
	buf: [64 * 1024]u8
	for {
		n, rerr := net.recv_tcp(client, buf[:])
		if n > 0 {
			sync.lock(&s.mu)
			append(&s.received, ..buf[:n])
			sync.unlock(&s.mu)
		}
		if rerr != nil || n == 0 { break }
		if curl_test_request_complete(s.received[:]) { break }
	}

	body := s.response_body
	hdr: string
	if s.omit_content_length {
		hdr = fmt.tprintf(
			"HTTP/1.1 %d Result\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n",
			s.response_status,
		)
	} else {
		hdr = fmt.tprintf(
			"HTTP/1.1 %d Result\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
			s.response_status, len(body),
		)
	}
	net.send_tcp(client, transmute([]u8)hdr)
	if len(body) > 0 {
		net.send_tcp(client, transmute([]u8)body)
	}
}

@(private="file")
curl_test_request_complete :: proc(buf: []u8) -> bool {
	// Find end-of-headers.
	sep := []u8{'\r', '\n', '\r', '\n'}
	idx := -1
	for i in 0 ..< (len(buf) - len(sep) + 1) {
		if buf[i] == sep[0] && buf[i+1] == sep[1] && buf[i+2] == sep[2] && buf[i+3] == sep[3] {
			idx = i
			break
		}
	}
	if idx == -1 { return false }
	headers := string(buf[:idx])
	body_start := idx + len(sep)
	// Find Content-Length: N. Case-insensitive search not implemented; curl
	// emits lowercase header values but the field name is always exact case.
	cl_key := "Content-Length:"
	cl_pos := strings.index(headers, cl_key)
	if cl_pos == -1 { return true } // no body declared
	rest := headers[cl_pos + len(cl_key):]
	end := strings.index(rest, "\r\n")
	if end == -1 { end = len(rest) }
	cl_str := strings.trim_space(rest[:end])
	expected := 0
	for ch in cl_str {
		if ch < '0' || ch > '9' { return true }
		expected = expected * 10 + int(ch - '0')
	}
	return (len(buf) - body_start) >= expected
}

@(private="file")
start_curl_test_server :: proc(status: int, body: string, omit_content_length: bool = false) -> (^Curl_Test_Server, ^thread.Thread, int) {
	s := new(Curl_Test_Server)
	s.received = make([dynamic]u8)
	s.response_status = status
	s.response_body = body
	s.omit_content_length = omit_content_length

	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil { test_fail(format = "listen_tcp: %v", args = []any{lerr}) }
	s.listener = listener

	ep, berr := net.bound_endpoint(listener)
	if berr != nil { test_fail(format = "bound_endpoint: %v", args = []any{berr}) }

	t := thread.create_and_start_with_poly_data(s, curl_test_server_run)
	return s, t, ep.port
}

@(private="file")
stop_curl_test_server :: proc(s: ^Curl_Test_Server, t: ^thread.Thread) {
	thread.join(t)
	thread.destroy(t)
	net.close(s.listener)
	delete(s.received)
	free(s)
}

test_curlhttp_get_returns_status_and_body :: proc() {
	s, t, port := start_curl_test_server(200, "pong")
	defer stop_curl_test_server(s, t)

	req := sync_pkg.HTTP_Request{
		url    = fmt.tprintf("http://127.0.0.1:%d/ping", port),
		method = "GET",
	}
	resp, msg, ok := curlhttp.roundtrip(nil, req, context.temp_allocator)
	expect_true(ok, fmt.tprintf("roundtrip failed: %s", msg))
	expect_eq(resp.status, i32(200), "GET status")
	expect_eq(string(resp.body), "pong", "GET body")

	got := string(s.received[:])
	expect_true(strings.has_prefix(got, "GET /ping HTTP/1.1\r\n"), "server saw GET /ping request line")
}

test_curlhttp_post_with_body_and_header :: proc() {
	s, t, port := start_curl_test_server(200, "ack")
	defer stop_curl_test_server(s, t)

	body := []u8{'h', 'i'}
	headers := []sync_pkg.HTTP_Header{{key = "X-Test", value = "yes"}}
	req := sync_pkg.HTTP_Request{
		url     = fmt.tprintf("http://127.0.0.1:%d/echo", port),
		method  = "POST",
		body    = body,
		headers = headers,
	}
	resp, msg, ok := curlhttp.roundtrip(nil, req, context.temp_allocator)
	expect_true(ok, fmt.tprintf("roundtrip failed: %s", msg))
	expect_eq(resp.status, i32(200), "POST status")
	expect_eq(string(resp.body), "ack", "POST body")

	got := string(s.received[:])
	expect_true(strings.has_prefix(got, "POST /echo HTTP/1.1\r\n"), "server saw POST request line")
	expect_true(strings.contains(got, "X-Test: yes"), "server saw custom header")
	expect_true(strings.has_suffix(got, "\r\n\r\nhi"), "server saw request body")
}

test_curlhttp_returns_non_2xx_status_without_error :: proc() {
	s, t, port := start_curl_test_server(500, "fail")
	defer stop_curl_test_server(s, t)

	req := sync_pkg.HTTP_Request{
		url    = fmt.tprintf("http://127.0.0.1:%d/", port),
		method = "GET",
	}
	resp, msg, ok := curlhttp.roundtrip(nil, req, context.temp_allocator)
	expect_true(ok, fmt.tprintf("roundtrip should succeed even on 5xx: %s", msg))
	expect_eq(resp.status, i32(500), "5xx status passed through")
	expect_eq(string(resp.body), "fail", "5xx body passed through")
}

test_curlhttp_custom_method_delete :: proc() {
	s, t, port := start_curl_test_server(204, "")
	defer stop_curl_test_server(s, t)

	req := sync_pkg.HTTP_Request{
		url    = fmt.tprintf("http://127.0.0.1:%d/item", port),
		method = "DELETE",
	}
	resp, msg, ok := curlhttp.roundtrip(nil, req, context.temp_allocator)
	expect_true(ok, fmt.tprintf("roundtrip failed: %s", msg))
	expect_eq(resp.status, i32(204), "DELETE status")
	expect_eq(len(resp.body), 0, "DELETE empty body")

	got := string(s.received[:])
	expect_true(strings.has_prefix(got, "DELETE /item HTTP/1.1\r\n"), "server saw DELETE request line")
}

// Regression test for M4. CURLOPT_MAXFILESIZE_LARGE catches a declared
// Content-Length above MAX_RESPONSE_BYTES before any body bytes transfer and
// curl surfaces CURLE_FILESIZE_EXCEEDED. The roundtrip wrapper promotes that
// into the same typed "response exceeded" message the streaming-cap path
// produces, so callers can branch on size violations without inspecting libcurl
// error codes.
test_curlhttp_rejects_response_exceeding_max_bytes_via_content_length :: proc() {
	saved_cap := curlhttp.MAX_RESPONSE_BYTES
	defer curlhttp.MAX_RESPONSE_BYTES = saved_cap
	curlhttp.MAX_RESPONSE_BYTES = 256

	body := strings.repeat("x", 1024, context.temp_allocator)
	s, t, port := start_curl_test_server(200, body)
	defer stop_curl_test_server(s, t)

	req := sync_pkg.HTTP_Request{
		url    = fmt.tprintf("http://127.0.0.1:%d/big", port),
		method = "GET",
	}
	resp, msg, ok := curlhttp.roundtrip(nil, req, context.temp_allocator)
	expect_false(ok, "oversize response should be rejected")
	expect_eq(resp.status, i32(0), "no status on rejected response")
	expect_eq(len(resp.body), 0, "no body buffered on rejected response")
	expect_true(strings.contains(msg, "response exceeded"), fmt.tprintf("expected typed 'response exceeded' message, got: %s", msg))
}

// Regression test for M4. When the server omits Content-Length and just
// streams the body (or lies about it), MAXFILESIZE_LARGE cannot help; the
// write_callback hard cap is the only defence. Aborting the transfer there
// surfaces as CURLE_WRITE_ERROR and the wrapper translates it into the same
// typed "response exceeded" message.
test_curlhttp_rejects_response_exceeding_max_bytes_via_streaming :: proc() {
	saved_cap := curlhttp.MAX_RESPONSE_BYTES
	defer curlhttp.MAX_RESPONSE_BYTES = saved_cap
	curlhttp.MAX_RESPONSE_BYTES = 256

	body := strings.repeat("x", 1024, context.temp_allocator)
	s, t, port := start_curl_test_server(200, body, omit_content_length = true)
	defer stop_curl_test_server(s, t)

	req := sync_pkg.HTTP_Request{
		url    = fmt.tprintf("http://127.0.0.1:%d/big", port),
		method = "GET",
	}
	resp, msg, ok := curlhttp.roundtrip(nil, req, context.temp_allocator)
	expect_false(ok, "oversize streaming response should be rejected")
	expect_eq(resp.status, i32(0), "no status on rejected response")
	expect_eq(len(resp.body), 0, "rejected response must not surface partial body")
	expect_true(strings.contains(msg, "response exceeded"), fmt.tprintf("expected typed 'response exceeded' message, got: %s", msg))
}
