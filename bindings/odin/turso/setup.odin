package turso

import "base:runtime"
import "core:strings"
import "core:sync"
import raw "raw"

@(private)
g_setup_mu: sync.Mutex

// g_logger holds the user-supplied callback. Read by logger_trampoline.
@(private)
g_logger: Logger_Proc

// g_setup_ctx captures the context active at setup() time so the trampoline
// can install it before invoking the user callback. "c" procs don't have an Odin context.
@(private)
g_setup_ctx: runtime.Context

@(private)
logger_trampoline :: proc "c" (log: ^raw.Log_Struct) {
	if log == nil { return }
	context = g_setup_ctx
	if g_logger == nil { return }
	event := Log_Event{
		message   = log.message != nil ? string(log.message) : "",
		target    = log.target  != nil ? string(log.target)  : "",
		file      = log.file    != nil ? string(log.file)    : "",
		timestamp = log.timestamp,
		line      = log.line,
		level     = log.level,
	}
	g_logger(event)
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
setup :: proc(opts: Setup_Options = {}) -> (Error, bool) {
	sync.mutex_lock(&g_setup_mu)
	defer sync.mutex_unlock(&g_setup_mu)

	g_setup_ctx = context
	g_logger = opts.logger

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
