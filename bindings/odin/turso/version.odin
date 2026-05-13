package turso

import "core:strings"
import raw "raw"

// version returns the Turso semver string. The underlying C string is static
// per turso.h:70-72 - no free required. The returned Odin string is allocator-owned.
version :: proc(allocator := context.allocator) -> string {
	c := raw.turso_version()
	if c == nil {
		return ""
	}
	return strings.clone_from_cstring(c, allocator)
}
