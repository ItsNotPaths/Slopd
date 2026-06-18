package tests

import app ".."
import "core:testing"

// The `j`/jump line-spec parser (parse_line_spec) shared by the `j` builtin and the
// Alt+Enter file-path follow. Path resolution (jump_resolve_path) touches the filesystem,
// so it's left to the integration/screenshot pass; this covers the pure parsing.

@(test)
test_parse_line_spec_absolute :: proc(t: ^testing.T) {
    n, ok := app.parse_line_spec("5", 0) // 1-based -> 0-based
    testing.expect(t, ok)
    testing.expect_value(t, n, 4)
}

@(test)
test_parse_line_spec_relative :: proc(t: ^testing.T) {
    n, ok := app.parse_line_spec("+3", 10)
    testing.expect(t, ok)
    testing.expect_value(t, n, 13)

    n, ok = app.parse_line_spec("-2", 10)
    testing.expect(t, ok)
    testing.expect_value(t, n, 8)
}

@(test)
test_parse_line_spec_rejects_nonnumeric :: proc(t: ^testing.T) {
    _, ok := app.parse_line_spec("foo.odin", 0)
    testing.expect(t, !ok)
}
