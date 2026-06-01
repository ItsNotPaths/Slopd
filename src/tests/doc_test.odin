package tests

import app ".."
import "core:testing"

@(private = "file")
mkdoc :: proc(s: string) -> app.Doc {
    d: app.Doc
    app.doc_set_text(&d, s)
    return d
}

@(private = "file")
dline :: proc(d: ^app.Doc, i: int) -> string {
    return app.line_string(&d.lines[i], context.temp_allocator)
}

// head position of cursor i, as a convenient pair to compare.
@(private = "file")
head :: proc(d: ^app.Doc, i := 0) -> (line, col: int) {
    return d.cursors[i].head.line, d.cursors[i].head.col
}

@(test)
test_doc_word_motion :: proc(t: ^testing.T) {
    d := mkdoc("foo.bar baz")
    defer app.doc_destroy(&d)

    app.doc_move(&d, .Word_Right);l, c := head(&d);testing.expect_value(t, c, 3) // after foo
    app.doc_move(&d, .Word_Right);l, c = head(&d);testing.expect_value(t, c, 4) // after .
    app.doc_move(&d, .Word_Right);l, c = head(&d);testing.expect_value(t, c, 7) // after bar
    app.doc_move(&d, .Word_Right);l, c = head(&d);testing.expect_value(t, c, 11) // after baz
    app.doc_move(&d, .Word_Left);l, c = head(&d);testing.expect_value(t, c, 8) // start of baz
    _ = l
}

@(test)
test_doc_insert_replaces_selection :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Home)
    app.doc_move(&d, .Right, true) // select "h"
    app.doc_move(&d, .Right, true) // select "he"
    testing.expect(t, app.cursor_has_selection(d.cursors[0]))

    app.doc_insert_rune(&d, 'H') // typing replaces the selection
    testing.expect_value(t, dline(&d, 0), "Hllo")
    testing.expect(t, !app.cursor_has_selection(d.cursors[0]))
    _, c := head(&d);testing.expect_value(t, c, 1)
}

@(test)
test_doc_move_collapses_selection :: proc(t: ^testing.T) {
    d := mkdoc("abcdef")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Home)
    for _ in 0 ..< 3 {
        app.doc_move(&d, .Right, true) // select "abc": head 3, anchor 0
    }
    app.doc_move(&d, .Left) // plain move collapses to the left edge
    testing.expect(t, !app.cursor_has_selection(d.cursors[0]))
    _, c := head(&d);testing.expect_value(t, c, 0)
}

@(test)
test_doc_delete_word_back :: proc(t: ^testing.T) {
    d := mkdoc("alpha beta")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .End)
    app.doc_delete_word_back(&d) // removes "beta"
    testing.expect_value(t, dline(&d, 0), "alpha ")
    app.doc_delete_word_back(&d) // removes " alpha" back to start
    testing.expect_value(t, dline(&d, 0), "")
}

@(test)
test_doc_newline_and_join :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Right)
    app.doc_move(&d, .Right) // col 2
    app.doc_newline(&d) // split into "he" / "llo"
    testing.expect_value(t, len(d.lines), 2)
    testing.expect_value(t, dline(&d, 0), "he")
    testing.expect_value(t, dline(&d, 1), "llo")
    l, c := head(&d);testing.expect_value(t, l, 1);testing.expect_value(t, c, 0)

    app.doc_backspace(&d) // at col 0 -> join back
    testing.expect_value(t, len(d.lines), 1)
    testing.expect_value(t, dline(&d, 0), "hello")
    l, c = head(&d);testing.expect_value(t, l, 0);testing.expect_value(t, c, 2)
}

// Two cursors on one line: the back-to-front driver must keep the later cursor
// valid after the earlier edit shifts it.
@(test)
test_doc_multi_cursor_same_line :: proc(t: ^testing.T) {
    d := mkdoc("abcd")
    defer app.doc_destroy(&d)
    clear(&d.cursors)
    append(&d.cursors, app.Cursor{head = {0, 1}, anchor = {0, 1}})
    append(&d.cursors, app.Cursor{head = {0, 3}, anchor = {0, 3}})

    app.doc_insert_rune(&d, 'X') // -> "aXbcXd"
    testing.expect_value(t, dline(&d, 0), "aXbcXd")
    testing.expect_value(t, len(d.cursors), 2)
    l0, c0 := head(&d, 0);testing.expect_value(t, c0, 2);_ = l0
    l1, c1 := head(&d, 1);testing.expect_value(t, c1, 5);_ = l1
}

// Two cursors on different lines, each splitting its line independently.
@(test)
test_doc_multi_cursor_newline :: proc(t: ^testing.T) {
    d := mkdoc("ab\ncd")
    defer app.doc_destroy(&d)
    clear(&d.cursors)
    append(&d.cursors, app.Cursor{head = {0, 1}, anchor = {0, 1}})
    append(&d.cursors, app.Cursor{head = {1, 1}, anchor = {1, 1}})

    app.doc_newline(&d) // -> "a" / "b" / "c" / "d"
    testing.expect_value(t, len(d.lines), 4)
    testing.expect_value(t, dline(&d, 0), "a")
    testing.expect_value(t, dline(&d, 1), "b")
    testing.expect_value(t, dline(&d, 2), "c")
    testing.expect_value(t, dline(&d, 3), "d")
    // The second cursor tracked down past the first cursor's inserted line.
    l1, c1 := head(&d, 1);testing.expect_value(t, l1, 3);testing.expect_value(t, c1, 0)
}

// Drop an anchor, then the free caret roams alone leaving it behind. Movement
// moves only the primary; the dropped cursor stays put. Collapse keeps the caret.
@(test)
test_doc_drop_anchor :: proc(t: ^testing.T) {
    d := mkdoc("hello\nworld\nfoo")
    defer app.doc_destroy(&d)

    app.doc_drop_anchor(&d) // anchor at {0,0}, coincident with the caret
    app.doc_move(&d, .Down) // free caret -> {1,0}; the anchor stays at {0,0}
    app.doc_move(&d, .Down) // free caret -> {2,0}
    testing.expect_value(t, len(d.cursors), 2)
    l, c := head(&d, d.primary);testing.expect_value(t, l, 2);testing.expect_value(t, c, 0)

    // The other cursor is the anchor still sitting at the origin.
    other := d.cursors[1 - d.primary].head
    testing.expect_value(t, other.line, 0);testing.expect_value(t, other.col, 0)

    app.doc_collapse_to_primary(&d) // Esc: keep the caret
    testing.expect_value(t, len(d.cursors), 1)
    l, c = head(&d, 0);testing.expect_value(t, l, 2);testing.expect_value(t, c, 0)
}

// Shift-select then backspace removes the whole selection.
@(test)
test_doc_select_delete :: proc(t: ^testing.T) {
    d := mkdoc("hello")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Right, true) // select "h"
    app.doc_move(&d, .Right, true) // select "he"
    testing.expect(t, app.cursor_has_selection(d.cursors[0]))
    app.doc_backspace(&d) // deletes the selection
    testing.expect_value(t, dline(&d, 0), "llo")
    testing.expect(t, !app.cursor_has_selection(d.cursors[0]))
}

// A selection spanning lines is deleted as one range, joining the endpoints.
@(test)
test_doc_select_multiline_delete :: proc(t: ^testing.T) {
    d := mkdoc("abc\ndef")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Right) // {0,1}
    app.doc_move(&d, .Right, true) // select "b" -> head {0,2}
    app.doc_move(&d, .Down, true) // extend down to {1,2}: selection "bc\nde"
    app.doc_delete(&d)
    testing.expect_value(t, len(d.lines), 1)
    testing.expect_value(t, dline(&d, 0), "af")
}

// doc_move_all moves every cursor together (the Alt+M prefix); Shift extends each
// selection, then an edit replaces all of them.
@(test)
test_doc_move_all :: proc(t: ^testing.T) {
    d := mkdoc("abc\ndef")
    defer app.doc_destroy(&d)
    clear(&d.cursors)
    append(&d.cursors, app.Cursor{head = {0, 0}, anchor = {0, 0}})
    append(&d.cursors, app.Cursor{head = {1, 0}, anchor = {1, 0}})

    app.doc_move_all(&d, .Right, true)
    app.doc_move_all(&d, .Right, true) // both select two chars
    testing.expect(t, app.cursor_has_selection(d.cursors[0]))
    testing.expect(t, app.cursor_has_selection(d.cursors[1]))

    app.doc_insert_rune(&d, 'X') // replaces both selections
    testing.expect_value(t, dline(&d, 0), "Xc")
    testing.expect_value(t, dline(&d, 1), "Xf")
}

// A caret resting on a dropped anchor (coincident) edits the spot once, not twice.
@(test)
test_doc_coincident_edit :: proc(t: ^testing.T) {
    d := mkdoc("ab")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Right) // caret at {0,1}
    app.doc_drop_anchor(&d) // anchor at {0,1} too (coincident)
    testing.expect_value(t, len(d.cursors), 2)

    app.doc_insert_rune(&d, 'X') // one insert, not two
    testing.expect_value(t, dline(&d, 0), "aXb")
    testing.expect_value(t, len(d.cursors), 1)
}
