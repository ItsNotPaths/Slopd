package tests

import app ".."
import "core:testing"
import "vendor:glfw"

@(private = "file")
mkdoc :: proc(s: string) -> app.Doc {
    d: app.Doc
    app.doc_set_text(&d, s)
    return d
}

@(private = "file")
ln :: proc(d: ^app.Doc, i: int) -> string {
    return app.line_string(&d.lines[i], context.temp_allocator)
}

@(test)
test_copy_selection :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Home)
    app.doc_move(&d, .Right, true)
    app.doc_move(&d, .Right, true) // select "he"
    joined, pieces := app.doc_copy(&d, context.temp_allocator)
    testing.expect_value(t, joined, "he")
    testing.expect_value(t, len(pieces), 1)
}

@(test)
test_copy_line_when_no_selection :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer app.doc_destroy(&d)
    joined, _ := app.doc_copy(&d, context.temp_allocator)
    testing.expect_value(t, joined, "hello\n") // whole line + newline
}

// The terminal's copy chord is one of the Ctrl+C / Ctrl+Shift+C pair, and `term_ctrl_c` says
// which. The other half must fall through in BOTH modes — that is what reaches the shell.
@(test)
test_term_clip_chord_swaps_with_config :: proc(t: ^testing.T) {
    CTRL :: i32(glfw.MOD_CONTROL)
    SHIFT :: i32(glfw.MOD_SHIFT)
    a: app.App

    a.term_ctrl_c = .Stop
    testing.expect(t, app.term_clip_chord(&a, CTRL | SHIFT)) // ^Shift+C copies
    testing.expect(t, !app.term_clip_chord(&a, CTRL)) // ^C is the job's

    a.term_ctrl_c = .Copy
    testing.expect(t, app.term_clip_chord(&a, CTRL)) // ^C copies
    testing.expect(t, !app.term_clip_chord(&a, CTRL | SHIFT)) // ^Shift+C is the job's

    // No Ctrl, no chord — in either mode a bare or Shift-only key is text.
    testing.expect(t, !app.term_clip_chord(&a, 0))
    testing.expect(t, !app.term_clip_chord(&a, SHIFT))
}

@(test)
test_parse_term_ctrl_c :: proc(t: ^testing.T) {
    m, ok := app.parse_term_ctrl_c("copy")
    testing.expect(t, ok)
    testing.expect_value(t, m, app.Term_Ctrl_C.Copy)

    m, ok = app.parse_term_ctrl_c("stop")
    testing.expect(t, ok)
    testing.expect_value(t, m, app.Term_Ctrl_C.Stop)

    _, ok = app.parse_term_ctrl_c("yes") // junk keeps the old value: ok=false
    testing.expect(t, !ok)
}

@(test)
test_paste_at_caret :: proc(t: ^testing.T) {
    d := mkdoc("ab")
    defer app.doc_destroy(&d)
    app.doc_paste(&d, "XY")
    testing.expect_value(t, ln(&d, 0), "XYab")
}

// Equal-count multi-cursor paste distributes one piece per caret (document order).
@(test)
test_paste_pieces :: proc(t: ^testing.T) {
    d := mkdoc("ab\ncd")
    defer app.doc_destroy(&d)
    clear(&d.cursors)
    append(&d.cursors, app.Cursor{head = {0, 0}, anchor = {0, 0}})
    append(&d.cursors, app.Cursor{head = {1, 0}, anchor = {1, 0}})
    app.doc_paste_pieces(&d, []string{"X", "Y"})
    testing.expect_value(t, ln(&d, 0), "Xab")
    testing.expect_value(t, ln(&d, 1), "Ycd")
}

@(test)
test_cut_selection :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Home)
    app.doc_move(&d, .Right, true)
    app.doc_move(&d, .Right, true) // select "he"
    app.doc_cut(&d)
    testing.expect_value(t, ln(&d, 0), "llo")
}

// With no selection, cut removes the whole line.
@(test)
test_cut_line :: proc(t: ^testing.T) {
    d := mkdoc("ab\ncd")
    defer app.doc_destroy(&d)
    app.doc_cut(&d)
    testing.expect_value(t, len(d.lines), 1)
    testing.expect_value(t, ln(&d, 0), "cd")
}
