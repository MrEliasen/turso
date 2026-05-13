package sync_tests

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import sync_pkg "../../turso/sync"
import curlhttp "../../turso/sync/curlhttp"

// The libcurl client must NOT auto-follow 3xx redirects. CURLOPT_HTTPHEADER is
// re-sent verbatim across cross-host redirects, so a malicious or misconfigured
// remote that issues a 302 to an attacker-controlled host would otherwise leak
// the Authorization: Bearer <token> the dispatcher attaches. With auto-follow
// off the caller (engine) sees the 3xx response and decides what to do.

@(private="file")
Redirect_Server :: struct {
	listener:           net.TCP_Socket,
	mu:                 sync.Mutex,
	requests_seen:      int,
	first_request_dump: [dynamic]u8,
}

@(private="file")
redirect_server_run :: proc(s: ^Redirect_Server) {
	client, _, accept_err := net.accept_tcp(s.listener)
	if accept_err != nil { return }
	defer net.close(client)

	buf: [16 * 1024]u8
	captured: [dynamic]u8
	defer delete(captured)
	for {
		n, rerr := net.recv_tcp(client, buf[:])
		if n > 0 { append(&captured, ..buf[:n]) }
		if rerr != nil || n == 0 { break }
		// Header-only request: end on \r\n\r\n.
		if len(captured) >= 4 {
			tail := captured[len(captured)-4:]
			if tail[0]=='\r' && tail[1]=='\n' && tail[2]=='\r' && tail[3]=='\n' { break }
		}
		if has_header_terminator(captured[:]) { break }
	}
	sync.lock(&s.mu)
	s.requests_seen += 1
	if len(s.first_request_dump) == 0 {
		append(&s.first_request_dump, ..captured[:])
	}
	sync.unlock(&s.mu)

	// Send a 302 redirect to an obviously different host. If FOLLOWLOCATION
	// were on, libcurl would chase this (and our Authorization header would
	// travel with it). With it off, the caller sees the 302 directly.
	body := "moved"
	hdr := fmt.tprintf(
		"HTTP/1.1 302 Found\r\nLocation: http://example.invalid/redirected\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		len(body), body,
	)
	net.send_tcp(client, transmute([]u8)hdr)
}

@(private="file")
has_header_terminator :: proc(buf: []u8) -> bool {
	if len(buf) < 4 { return false }
	for i in 0 ..< (len(buf) - 3) {
		if buf[i] == '\r' && buf[i+1] == '\n' && buf[i+2] == '\r' && buf[i+3] == '\n' {
			return true
		}
	}
	return false
}

@(private="file")
start_redirect_server :: proc() -> (^Redirect_Server, ^thread.Thread, int) {
	s := new(Redirect_Server)
	s.first_request_dump = make([dynamic]u8)
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil { test_fail(format = "listen_tcp: %v", args = []any{lerr}) }
	s.listener = listener
	ep, berr := net.bound_endpoint(listener)
	if berr != nil { test_fail(format = "bound_endpoint: %v", args = []any{berr}) }
	t := thread.create_and_start_with_poly_data(s, redirect_server_run)
	return s, t, ep.port
}

@(private="file")
stop_redirect_server :: proc(s: ^Redirect_Server, t: ^thread.Thread) {
	thread.join(t)
	thread.destroy(t)
	net.close(s.listener)
	delete(s.first_request_dump)
	free(s)
}

test_curlhttp_does_not_auto_follow_redirects :: proc() {
	s, t, port := start_redirect_server()
	defer stop_redirect_server(s, t)

	headers := []sync_pkg.HTTP_Header{{key = "Authorization", value = "Bearer secret-token"}}
	req := sync_pkg.HTTP_Request{
		url     = fmt.tprintf("http://127.0.0.1:%d/api/sync", port),
		method  = "GET",
		headers = headers,
	}
	resp, msg, ok := curlhttp.roundtrip(nil, req, context.temp_allocator)
	expect_true(ok, fmt.tprintf("roundtrip failed: %s", msg))

	// The 302 is surfaced directly because FOLLOWLOCATION is disabled. If
	// libcurl had chased the redirect to example.invalid the call would have
	// either errored out or returned a different status.
	expect_eq(resp.status, i32(302), "302 must be returned as-is without auto-follow")
	expect_eq(s.requests_seen, 1, "server must be hit exactly once (no follow)")

	first := string(s.first_request_dump[:])
	expect_true(strings.contains(first, "Authorization: Bearer secret-token"),
		"first request must carry the bearer header so we know the test setup is realistic")
}
