package tests

import app "../slopd"
import "core:testing"
import "vendor:glfw"
import "../txt"
import "../pty"

@(private = "file")
mkdoc :: proc(s: string) -> txt.Doc {
    d: txt.Doc
    txt.doc_set_text(&d, s)
    return d
}

@(private = "file")
ln :: proc(d: ^txt.Doc, i: int) -> string {
    return string(txt.doc_line(d, i, context.temp_allocator))
}

@(test)
test_copy_selection :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer txt.doc_destroy(&d)
    txt.doc_move(&d, .Home)
    txt.doc_move(&d, .Right, true)
    txt.doc_move(&d, .Right, true) // select "he"
    joined, pieces := txt.doc_copy(&d, context.temp_allocator)
    testing.expect_value(t, joined, "he")
    testing.expect_value(t, len(pieces), 1)
}

@(test)
test_copy_line_when_no_selection :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer txt.doc_destroy(&d)
    joined, _ := txt.doc_copy(&d, context.temp_allocator)
    testing.expect_value(t, joined, "hello\n") // whole line + newline
}

// ^C is ONE bind everywhere and the terminal is the one surface that can decline it: with a span
// it copies, and with nothing selected the chord is the job's interrupt instead. `term_has_span`
// is the question both halves ask, so the copy and the fall-through can never disagree.
@(test)
test_term_has_span_decides_copy_or_interrupt :: proc(t: ^testing.T) {
    term: pty.Terminal
    testing.expect(t, !app.term_has_span(&term), "a fresh session has nothing to copy")

    term.sel_active = true // the keyboard's line range
    testing.expect(t, app.term_has_span(&term))

    term.sel_active = false
    term.msel_on = true // the mouse's span, collapsed — still nothing to copy
    testing.expect(t, !app.term_has_span(&term))
}

@(test)
test_paste_at_caret :: proc(t: ^testing.T) {
    d := mkdoc("ab")
    defer txt.doc_destroy(&d)
    txt.doc_paste(&d, "XY")
    testing.expect_value(t, ln(&d, 0), "XYab")
}

// Equal-count multi-cursor paste distributes one piece per caret (document order).
@(test)
test_paste_pieces :: proc(t: ^testing.T) {
    d := mkdoc("ab\ncd")
    defer txt.doc_destroy(&d)
    clear(&d.cursors)
    append(&d.cursors, txt.Cursor{head = {0, 0}, anchor = {0, 0}})
    append(&d.cursors, txt.Cursor{head = {1, 0}, anchor = {1, 0}})
    txt.doc_paste_pieces(&d, []string{"X", "Y"})
    testing.expect_value(t, ln(&d, 0), "Xab")
    testing.expect_value(t, ln(&d, 1), "Ycd")
}

@(test)
test_cut_selection :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer txt.doc_destroy(&d)
    txt.doc_move(&d, .Home)
    txt.doc_move(&d, .Right, true)
    txt.doc_move(&d, .Right, true) // select "he"
    txt.doc_cut(&d)
    testing.expect_value(t, ln(&d, 0), "llo")
}

// With no selection, cut removes the whole line.
@(test)
test_cut_line :: proc(t: ^testing.T) {
    d := mkdoc("ab\ncd")
    defer txt.doc_destroy(&d)
    txt.doc_cut(&d)
    testing.expect_value(t, txt.doc_line_count(&d), 1)
    testing.expect_value(t, ln(&d, 0), "cd")
}
