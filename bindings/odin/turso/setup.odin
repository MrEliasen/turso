package turso

import "core:strings"
import "core:sync"
import raw "raw"

@(private)
g_setup_done: bool

@(private)
g_setup_mu: sync.Mutex

@(private)
g_setup_err: Error

@(private)
g_setup_ok: bool = true

// setup performs Turso global initialization (logging level). Safe to call repeatedly;
// only the first call invokes the C-side setup. v1 never installs a logger.
//
// log_level: "error" | "warn" | "info" | "debug" | "trace", or "" to leave unset.
setup :: proc(log_level: string = "") -> (Error, bool) {
	sync.mutex_lock(&g_setup_mu)
	defer sync.mutex_unlock(&g_setup_mu)
	if g_setup_done {
		return g_setup_err, g_setup_ok
	}
	g_setup_done = true

	c_level: cstring
	level_owned: cstring
	if log_level != "" {
		level_owned = strings.clone_to_cstring(log_level, context.allocator)
		c_level = level_owned
	}
	defer if level_owned != nil { delete(level_owned) }

	cfg := raw.Setup_Config{logger = nil, log_level = c_level}
	c_err: cstring
	code := raw.turso_setup(&cfg, &c_err)
	if code != .OK {
		g_setup_err = error_from_status(code, c_err, "turso_setup")
		g_setup_ok = false
	} else if c_err != nil {
		// OK with non-nil err string: free it to avoid leaking.
		raw.turso_str_deinit(c_err)
	}
	return g_setup_err, g_setup_ok
}
