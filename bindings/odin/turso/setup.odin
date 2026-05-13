package turso

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:sync"
import raw "raw"

@(private)
g_setup_mu: sync.Mutex

// g_logger holds the user-supplied callback. Read by logger_trampoline through
// the atomic helpers below so a setup() call swapping the value cannot tear
// the read on the emitting thread.
@(private)
g_logger: Logger_Proc

// g_setup_ctx captures the context active at setup() time so the trampoline
// can install it before invoking the user callback. "c" procs do not carry an
// Odin context.
//
// runtime.Context is a struct (allocator, temp_allocator, logger, user_ptr,
// random_generator, assertion handler) so it is too wide for a single atomic
// load. We pair it with a seqlock counter (g_setup_ctx_seq): writers bracket
// the bytewise copy with two atomic increments, readers bracket the bytewise
// read with two atomic loads and retry on disagreement. While a writer is
// active the trampoline drops the log event rather than reading torn state.
// Writers are serialized by g_setup_mu so the counter never wraps oddly.
@(private)
g_setup_ctx: runtime.Context

@(private)
g_setup_ctx_seq: u64  // even = stable, odd = writer in progress

@(private)
g_logger_store :: proc(p: Logger_Proc) {
	intrinsics.atomic_store(&g_logger, p)
}

@(private)
g_logger_load :: proc "contextless" () -> Logger_Proc {
	return intrinsics.atomic_load(&g_logger)
}

// g_setup_ctx_store publishes a new Context for the trampoline to install.
// Caller must hold g_setup_mu so that two writers cannot interleave their
// bracket increments and corrupt the parity invariant.
@(private)
g_setup_ctx_store :: proc(ctx: runtime.Context) {
	s := intrinsics.atomic_load(&g_setup_ctx_seq)
	intrinsics.atomic_store(&g_setup_ctx_seq, s + 1)  // odd: writer entered
	g_setup_ctx = ctx
	intrinsics.atomic_store(&g_setup_ctx_seq, s + 2)  // even: writer exited
}

// g_setup_ctx_load returns the latest published Context, or ok=false when a
// writer is mid-publish (and the trampoline should drop the event rather than
// risk a torn read). Bounded retries so a misbehaving writer cannot pin the
// trampoline in a spin.
@(private)
g_setup_ctx_load :: proc "contextless" () -> (runtime.Context, bool) {
	MAX_RETRIES :: 8
	for _ in 0 ..< MAX_RETRIES {
		s1 := intrinsics.atomic_load(&g_setup_ctx_seq)
		if s1 & 1 == 1 { continue }
		ctx := g_setup_ctx
		s2 := intrinsics.atomic_load(&g_setup_ctx_seq)
		if s1 == s2 { return ctx, true }
	}
	return runtime.Context{}, false
}

@(private)
logger_trampoline :: proc "c" (log: ^raw.Log_Struct) {
	if log == nil { return }
	ctx, ok := g_setup_ctx_load()
	if !ok { return }  // setup writer was active; skip this event
	context = ctx
	fn := g_logger_load()
	if fn == nil { return }
	event := Log_Event{
		message   = log.message != nil ? string(log.message) : "",
		target    = log.target  != nil ? string(log.target)  : "",
		file      = log.file    != nil ? string(log.file)    : "",
		timestamp = log.timestamp,
		line      = log.line,
		level     = log.level,
	}
	fn(event)
}

// Setup_Options configures global Turso initialization. All fields are optional.
//
// NOTE: log_level is locked in by the first call to setup(). Subsequent calls can
// swap the logger but cannot change the level.
Setup_Options :: struct {
	// log_level: "error" | "warn" | "info" | "debug" | "trace", or "" for env-default
	log_level: string,

	// logger: optional callback invoked for every log record at or above log_level.
	// Strings in the Log_Event are borrowed and must be cloned to outlive the call.
	logger: Logger_Proc,
}

// setup performs Turso global initialization. Optional - only required if you want
// non-default logging behavior. Safe to call multiple times to swap the logger.
//
// log_level is validated up front for embedded NUL; if the string would
// truncate when converted to a C-string the call fails with a typed MISUSE
// error rather than handing a wrong-length level to the engine.
setup :: proc(opts: Setup_Options = {}) -> (Error, bool) {
	if e, ok := must_be_nul_free(opts.log_level, "setup", "Setup_Options.log_level"); !ok {
		return e, false
	}

	sync.mutex_lock(&g_setup_mu)
	defer sync.mutex_unlock(&g_setup_mu)

	g_setup_ctx_store(context)
	g_logger_store(opts.logger)

	c_level: cstring
	level_owned: cstring
	if opts.log_level != "" {
		level_owned = strings.clone_to_cstring(opts.log_level, context.allocator)
		c_level = level_owned
	}
	defer if level_owned != nil { delete(level_owned) }

	cfg := raw.Setup_Config{
		logger    = opts.logger != nil ? rawptr(logger_trampoline) : nil,
		log_level = c_level,
	}
	c_err: cstring
	code := raw.turso_setup(&cfg, &c_err)
	if code != .OK {
		return error_from_status(code, c_err, "turso_setup"), false
	}
	if c_err != nil {
		raw.turso_str_deinit(c_err)
	}
	return error_none(), true
}
