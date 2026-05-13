package turso_sync

import "core:mem"
import "core:strings"
import raw "raw"
import turso "../"

// drive_op_until_done runs the Turso sync IO loop until the operation reports
// TURSO_DONE or an error. It is the single entry point used by every public
// sync operation. The caller still owns `op` on success — extract the result
// then call turso_sync_operation_deinit.
//
// Loop body mirrors driver_sync.go:driveOpUntilDone:
//   - TURSO_DONE  → return result kind
//   - TURSO_IO    → drain the IO queue via take_item, dispatch each item,
//                   then step_callbacks, then resume
//   - TURSO_OK    → resume again (engine reports OK between IO ticks)
//   - anything else → propagate as an error
@(private)
drive_op_until_done :: proc(
	db: raw.Database_Ptr,
	op: raw.Operation_Ptr,
	client: HTTP_Client,
	base_url: string,
	auth_token: string,
	op_name: string,
) -> (kind: raw.Op_Result_Kind, err: turso.Error, ok: bool) {
	for {
		c_err: cstring
		code := raw.turso_sync_operation_resume(op, &c_err)
		#partial switch code {
		case .DONE:
			if c_err != nil { raw.turso_str_deinit(c_err) }
			return raw.turso_sync_operation_result_kind(op), turso.error_none(), true
		case .IO:
			if c_err != nil { raw.turso_str_deinit(c_err); c_err = nil }
			drain_err, drain_ok := drain_io_queue(db, client, base_url, auth_token, op_name)
			if !drain_ok {
				return .NONE, drain_err, false
			}
			step_err: cstring
			if scode := raw.turso_sync_database_io_step_callbacks(db, &step_err); scode != .OK {
				return .NONE, turso.error_from_status(scode, step_err, "turso_sync_database_io_step_callbacks", "", op_name), false
			}
			if step_err != nil { raw.turso_str_deinit(step_err) }
			continue
		case .OK:
			if c_err != nil { raw.turso_str_deinit(c_err) }
			continue
		}
		return .NONE, turso.error_from_status(code, c_err, "turso_sync_operation_resume", "", op_name), false
	}
}

@(private)
drain_io_queue :: proc(
	db: raw.Database_Ptr,
	client: HTTP_Client,
	base_url: string,
	auth_token: string,
	op_name: string,
) -> (err: turso.Error, ok: bool) {
	for {
		item: raw.Io_Item_Ptr
		c_err: cstring
		code := raw.turso_sync_database_io_take_item(db, &item, &c_err)
		if code != .OK {
			return turso.error_from_status(code, c_err, "turso_sync_database_io_take_item", "", op_name), false
		}
		if c_err != nil { raw.turso_str_deinit(c_err) }
		if item == nil {
			return turso.error_none(), true
		}
		dispatch_item(item, client, base_url, auth_token)
		raw.turso_sync_database_io_done(item)
		raw.turso_sync_database_io_item_deinit(item)
	}
}

@(private)
dispatch_item :: proc(item: raw.Io_Item_Ptr, client: HTTP_Client, base_url: string, auth_token: string) {
	switch raw.turso_sync_database_io_request_kind(item) {
	case .HTTP:
		dispatch_http(item, client, base_url, auth_token)
	case .FULL_READ:
		internal_do_full_read(item)
	case .FULL_WRITE:
		internal_do_full_write(item)
	case .NONE:
		// nothing to do
	}
}

@(private)
dispatch_http :: proc(item: raw.Io_Item_Ptr, client: HTTP_Client, base_url: string, auth_token: string) {
	if client.roundtrip == nil {
		poison_with_message(item, "sync: HTTP_Client.do is nil; cannot satisfy HTTP request")
		return
	}

	hreq: raw.Http_Request
	if code := raw.turso_sync_database_io_request_http(item, &hreq); code != .OK {
		poison_with_message(item, "turso_sync_database_io_request_http failed")
		return
	}

	scratch_arena: mem.Arena
	scratch_buf: [128 * 1024]u8
	mem.arena_init(&scratch_arena, scratch_buf[:])
	scratch := mem.arena_allocator(&scratch_arena)

	url := resolve_url(base_url, slice_to_string(hreq.url), slice_to_string(hreq.path), scratch)
	method := strings.clone(slice_to_string(hreq.method), scratch)
	body := slice_to_bytes(hreq.body)

	hdr_count := int(hreq.headers)
	extra := 0
	if auth_token != "" { extra = 1 }
	headers := make([]HTTP_Header, hdr_count + extra, scratch)
	for i in 0 ..< hdr_count {
		h: raw.Http_Header
		if hcode := raw.turso_sync_database_io_request_http_header(item, uint(i), &h); hcode != .OK {
			poison_with_message(item, "turso_sync_database_io_request_http_header failed")
			return
		}
		headers[i] = HTTP_Header{
			key   = strings.clone(slice_to_string(h.key), scratch),
			value = strings.clone(slice_to_string(h.value), scratch),
		}
	}
	if auth_token != "" {
		headers[hdr_count] = HTTP_Header{
			key   = "Authorization",
			value = strings.concatenate({"Bearer ", auth_token}, scratch),
		}
	}

	req := HTTP_Request{url = url, method = method, headers = headers, body = body}
	resp, msg, ok := client.roundtrip(client.user_data, req, scratch)
	if !ok {
		fail := msg
		if fail == "" { fail = "HTTP client returned ok=false without a message" }
		poison_with_message(item, fail)
		return
	}

	raw.turso_sync_database_io_status(item, resp.status)
	if len(resp.body) > 0 {
		buf := bytes_to_slice_ref(resp.body)
		raw.turso_sync_database_io_push_buffer(item, &buf)
	}
}
