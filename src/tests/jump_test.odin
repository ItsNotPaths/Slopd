package tests

import app "../slopd"
import "core:fmt"
import "core:os"
import "core:testing"
import "../txt"
import "../edit"

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

// The way back a jump leaves behind (jump_to + cl_history_jump): one `:j` line, newest in the
// command line's history, so Alt+C then Up is the return trip. No location stack, no new chord.
@(test)
test_jump_records_the_way_back :: proc(t: ^testing.T) {
    a: app.App
    edit.editor_init(&a.editor)
    app.cl_init(&a.cl)
    defer {edit.editor_destroy(&a.editor);app.cl_destroy(&a)}

    b := edit.editor_current(&a.editor)
    txt.doc_set_text(&b.doc, "one\ntwo\nthree\nfour\nfive")
    txt.doc_reset_cursor(&b.doc, txt.Pos{3, 0})

    // Inside one file the line alone names the way back, and it is 1-based as `:j` reads it.
    app.jump_to(&a, "", 1, 0)
    testing.expect_value(t, len(a.cl.history), 1)
    testing.expect_value(t, a.cl.history[0], ":j 4")

    // Landing where the caret already is is not a jump, and leaves nothing.
    app.jump_to(&a, "", 1, 0)
    testing.expect_value(t, len(a.cl.history), 1)
}

// Across files the line carries the path it left, so the return trip opens that file again.
@(test)
test_jump_records_the_file_it_left :: proc(t: ^testing.T) {
    from, to := "slopd_jump_from.tmp", "slopd_jump_to.tmp"
    testing.expect(t, os.write_entire_file(from, transmute([]u8)string("a\nb\nc\n")) == nil)
    testing.expect(t, os.write_entire_file(to, transmute([]u8)string("x\ny\n")) == nil)
    defer {os.remove(from);os.remove(to)}

    a: app.App
    edit.editor_init(&a.editor)
    app.cl_init(&a.cl)
    defer {edit.editor_destroy(&a.editor);app.cl_destroy(&a)}

    app.open_file(&a, from)
    txt.doc_reset_cursor(&edit.editor_current(&a.editor).doc, txt.Pos{2, 0})

    app.jump_to(&a, to, 0, 0)
    testing.expect_value(t, len(a.cl.history), 1)
    testing.expect_value(t, a.cl.history[0], fmt.tprintf(":j %s 3", from))

    // A buffer with no file cannot be named by a `:j` line, so nothing is recorded for one.
    scratch: edit.Buffer
    txt.doc_init(&scratch.doc)
    append(&a.editor.buffers, scratch)
    a.editor.active = len(a.editor.buffers) - 1
    app.jump_to(&a, to, 1, 0)
    testing.expect_value(t, len(a.cl.history), 1)
}
