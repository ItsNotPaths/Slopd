package tests

import app ".."
import "core:os"
import "core:strings"
import "core:testing"

// The config file's line syntax: `key: value` with '#' comments. Both directions matter —
// load_config reads through config_strip_comment, and the Config pane writes back through
// config_set — and the two must agree on where a comment starts.

// A trailing comment is not part of the value. Every shipped line documents itself with
// one, so keeping it would hand parse_on_off "on   # on | off" (no match, silent fallback
// to the default) or, where the value is free text, make the comment BE the value.
@(test)
test_config_strip_comment :: proc(t: ^testing.T) {
    testing.expect_value(t, app.config_strip_comment("mouse: on             # on | off"), "mouse: on")
    testing.expect_value(t, app.config_strip_comment("git_tool: lazygit  # e.g. lazygit"), "git_tool: lazygit")

    // A key with no value but a comment comes back empty after the colon rather than
    // carrying the comment — this is the one that would launch "# e.g. lazygit".
    testing.expect_value(t, app.config_strip_comment("git_tool:             # e.g. lazygit"), "git_tool:")

    // Whole-line comments and blanks collapse to "", which the load loop skips.
    testing.expect_value(t, app.config_strip_comment("# a heading"), "")
    testing.expect_value(t, app.config_strip_comment("   # indented"), "")
    testing.expect_value(t, app.config_strip_comment("\t# tab-indented"), "")
    testing.expect_value(t, app.config_strip_comment("   "), "")

    // No comment: just trimmed. The common case must not be disturbed.
    testing.expect_value(t, app.config_strip_comment("  theme: themes/default.theme  "), "theme: themes/default.theme")
}

// A '#' glued to a token is part of the value, not a comment — the ini/git-config rule.
// git_tool is free text handed to a shell, so `foo#bar` is a plausible argument, and a
// theme name is arbitrary. Only a '#' at line start or after whitespace opens a comment.
@(test)
test_config_glued_hash_is_value :: proc(t: ^testing.T) {
    testing.expect_value(t, app.config_strip_comment("git_tool: sh -c foo#bar"), "git_tool: sh -c foo#bar")
    testing.expect_value(t, app.config_strip_comment("theme: my#theme"), "theme: my#theme")

    // ...and a glued one still doesn't shield a later, spaced one.
    testing.expect_value(t, app.config_strip_comment("theme: my#theme  # the good one"), "theme: my#theme")

    // The split reports the comment verbatim, with the body's length as its column.
    body, comment := app.config_split_comment("mouse: on   # on | off")
    testing.expect_value(t, body, "mouse: on   ")
    testing.expect_value(t, comment, "# on | off")

    body, comment = app.config_split_comment("mouse: on")
    testing.expect_value(t, body, "mouse: on")
    testing.expect_value(t, comment, "")
}

// Writeback preserves the file: other lines verbatim, and the edited line's own comment,
// re-aligned to the column it sat at. That comment documents the setting ("# on | off"),
// not its current value, so dropping it would strip the config's documentation one
// setting at a time as the pane is used. An unknown key is appended.
@(test)
test_config_set_keeps_comments :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_set_test.config"
    src := `# Slopd config — simple ` + "`key: value`" + `, '#' comments.
theme: themes/default.theme

mouse: on             # on | off
git_tool:             # e.g. lazygit
# mouse: on           <- a commented-out setting is not a match
`
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    defer os.remove(path)

    old := os.get_env("SLOPD_CONFIG", context.temp_allocator)
    os.set_env("SLOPD_CONFIG", path)
    defer os.set_env("SLOPD_CONFIG", old)

    testing.expect(t, app.config_set("mouse", "off"))
    testing.expect(t, app.config_set("git_tool", "lazygit"))
    testing.expect(t, app.config_set("jump_lines", "20")) // absent -> appended

    out, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    got := string(out)

    // Edited lines keep their comment at its original column.
    testing.expect(t, strings.contains(got, "mouse: off            # on | off\n"))
    testing.expect(t, strings.contains(got, "git_tool: lazygit     # e.g. lazygit\n"))

    // Untouched lines — including the commented-out `mouse` line, which must not have
    // been mistaken for the key — survive verbatim, and the new key lands at the end.
    testing.expect(t, strings.contains(got, "theme: themes/default.theme\n"))
    testing.expect(t, strings.contains(got, "# mouse: on           <- a commented-out setting is not a match\n"))
    testing.expect(t, strings.has_suffix(got, "jump_lines: 20\n"))

    // And the round trip: what was written reads back as what was set.
    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.mouse, false)
    testing.expect_value(t, cfg.git_tool, "lazygit")
    testing.expect_value(t, cfg.jump_lines, 20)
}

// A setting cleared back to empty writes a bare `key:`, like the shipped file — not
// `key: ` with a trailing space — and reads back as unset.
@(test)
test_config_set_empty_value :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_empty_test.config"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("git_tool: lazygit  # e.g. lazygit\n")) == nil)
    defer os.remove(path)

    old := os.get_env("SLOPD_CONFIG", context.temp_allocator)
    os.set_env("SLOPD_CONFIG", path)
    defer os.set_env("SLOPD_CONFIG", old)

    testing.expect(t, app.config_set("git_tool", ""))

    out, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, rerr, nil)
    testing.expect_value(t, string(out), "git_tool:          # e.g. lazygit\n")

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.git_tool, "")
}

// git_term is a dropdown and a dropdown cannot offer a blank row, so the pane writes
// "detached" where this file leaves the value empty; it has to read back as 0. (git_tool
// needs no such token — it is a text field, and an empty one writes an empty value.)
@(test)
test_config_git_detached_token :: proc(t: ^testing.T) {
    path := "/tmp/slopd_config_git_test.config"
    src := "git_tool:\ngit_term: detached\n"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
    defer os.remove(path)

    old := os.get_env("SLOPD_CONFIG", context.temp_allocator)
    os.set_env("SLOPD_CONFIG", path)
    defer os.set_env("SLOPD_CONFIG", old)

    cfg := app.load_config()
    defer app.config_destroy(&cfg)
    testing.expect_value(t, cfg.git_tool, "")
    testing.expect_value(t, cfg.git_term, 0)
}
