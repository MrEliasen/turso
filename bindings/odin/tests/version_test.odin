package tests

import turso "../turso"

test_version :: proc() {
	v := turso.version()
	defer delete(v)
	expect_true(len(v) > 0, "version returns non-empty string")
}
