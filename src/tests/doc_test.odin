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
    return string(app.doc_line(d, i, context.temp_allocator))
}

// Cursor i's head, as a pair to compare.
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
    testing.expect_value(t, app.doc_line_count(&d), 2)
    testing.expect_value(t, dline(&d, 0), "he")
    testing.expect_value(t, dline(&d, 1), "llo")
    l, c := head(&d);testing.expect_value(t, l, 1);testing.expect_value(t, c, 0)

    app.doc_backspace(&d) // at col 0 -> join back
    testing.expect_value(t, app.doc_line_count(&d), 1)
    testing.expect_value(t, dline(&d, 0), "hello")
    l, c = head(&d);testing.expect_value(t, l, 0);testing.expect_value(t, c, 2)
}

// The back-to-front driver keeps the later cursor valid after the earlier edit shifts it.
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
    testing.expect_value(t, app.doc_line_count(&d), 4)
    testing.expect_value(t, dline(&d, 0), "a")
    testing.expect_value(t, dline(&d, 1), "b")
    testing.expect_value(t, dline(&d, 2), "c")
    testing.expect_value(t, dline(&d, 3), "d")
    // The second cursor tracked past the first's inserted line.
    l1, c1 := head(&d, 1);testing.expect_value(t, l1, 3);testing.expect_value(t, c1, 0)
}

// Movement moves only the primary; the dropped cursor stays put, and collapse keeps the caret.
@(test)
test_doc_drop_anchor :: proc(t: ^testing.T) {
    d := mkdoc("hello\nworld\nfoo")
    defer app.doc_destroy(&d)

    app.doc_drop_anchor(&d) // anchor at {0,0}, coincident with the caret
    app.doc_move(&d, .Down) // free caret -> {1,0}; the anchor stays at {0,0}
    app.doc_move(&d, .Down) // free caret -> {2,0}
    testing.expect_value(t, len(d.cursors), 2)
    l, c := head(&d, d.primary);testing.expect_value(t, l, 2);testing.expect_value(t, c, 0)

    // The other cursor is the anchor, still at the origin.
    other := d.cursors[1 - d.primary].head
    testing.expect_value(t, other.line, 0);testing.expect_value(t, other.col, 0)

    app.doc_collapse_to_primary(&d) // Esc: keep the caret
    testing.expect_value(t, len(d.cursors), 1)
    l, c = head(&d, 0);testing.expect_value(t, l, 2);testing.expect_value(t, c, 0)
}

// ^a: one selection over the whole document, its head at the very end so a following
// Shift+motion grows from where the eye is.
@(test)
test_doc_select_all :: proc(t: ^testing.T) {
    d := mkdoc("abc\ndefg\nhi")
    defer app.doc_destroy(&d)
    app.doc_reset_cursor(&d, app.Pos{1, 2})
    app.doc_drop_anchor(&d) // a trail: select-all is one selection whatever it finds

    app.doc_select_all(&d)
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, d.cursors[0].head, app.Pos{2, 2})

    app.doc_insert_rune(&d, 'x') // the selection is what an edit replaces
    testing.expect_value(t, app.doc_line_count(&d), 1)
    testing.expect_value(t, dline(&d, 0), "x")
}

// ^l takes the line's TEXT, not its break — Home then Shift+End — at EVERY cursor, so a trail
// laid with Alt+A survives it. Two cursors sharing a line fuse into one.
@(test)
test_doc_select_lines :: proc(t: ^testing.T) {
    d := mkdoc("abc\ndefg\nhi")
    defer app.doc_destroy(&d)
    app.doc_reset_cursor(&d, app.Pos{0, 1})
    app.doc_add_cursor(&d, app.Pos{1, 3})
    app.doc_add_cursor(&d, app.Pos{1, 0}) // the second line twice

    app.doc_select_lines(&d)
    testing.expect_value(t, len(d.cursors), 2) // the pair on line 1 fused
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, d.cursors[0].head, app.Pos{0, 3})
    testing.expect_value(t, d.cursors[1].anchor, app.Pos{1, 0})
    testing.expect_value(t, d.cursors[1].head, app.Pos{1, 4})

    app.doc_delete(&d) // both lines' text goes, the breaks stay
    testing.expect_value(t, app.doc_line_count(&d), 3)
    testing.expect_value(t, dline(&d, 0), "")
    testing.expect_value(t, dline(&d, 1), "")
    testing.expect_value(t, dline(&d, 2), "hi")
}

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

// Deleted as one range, joining the endpoints.
@(test)
test_doc_select_multiline_delete :: proc(t: ^testing.T) {
    d := mkdoc("abc\ndef")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Right) // {0,1}
    app.doc_move(&d, .Right, true) // select "b" -> head {0,2}
    app.doc_move(&d, .Down, true) // extend down to {1,2}: selection "bc\nde"
    app.doc_delete(&d)
    testing.expect_value(t, app.doc_line_count(&d), 1)
    testing.expect_value(t, dline(&d, 0), "af")
}

// Every cursor together (the Alt+M prefix); Shift extends each selection, then an edit replaces
// all of them.
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

// A caret resting on a dropped anchor edits the spot once, not twice.
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

// Every other cursor op answers "where next, from where I am"; these take an absolute position,
// which is what a pointer knows and no keystroke can say. The clamp is load-bearing: a Pos from
// a pixel is only as good as the geometry that made it.
@(test)
test_doc_pointer_cursors :: proc(t: ^testing.T) {
    d := mkdoc("alpha bravo\ncharlie")
    defer app.doc_destroy(&d)

    // Extending keeps the anchor, so a shift-click grows the selection.
    app.doc_set_head(&d, app.Pos{0, 2}, false)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{0, 2})
    app.doc_set_head(&d, app.Pos{1, 3}, true)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{0, 2})
    testing.expect_value(t, d.cursors[0].head, app.Pos{1, 3})
    testing.expect_value(t, d.cursors[0].goal, 3) // the sticky column follows the head

    // Out of range in both axes, from every entry point.
    app.doc_set_head(&d, app.Pos{99, 99}, false)
    testing.expect_value(t, d.cursors[0].head, app.Pos{1, 7}) // last line, its length
    app.doc_set_head(&d, app.Pos{-4, -4}, false)
    testing.expect_value(t, d.cursors[0].head, app.Pos{0, 0})

    // A dropped cursor becomes the ROAMING one, since the pointer named where it goes.
    // doc_drop_anchor is the other way round: the keyboard has to walk somewhere first.
    app.doc_add_cursor(&d, app.Pos{1, 2})
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[d.primary].head, app.Pos{1, 2})

    // The run containing the position, head at its end so a following extend grows forward.
    app.doc_select_word(&d, app.Pos{0, 8}) // inside "bravo"
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{0, 6})
    testing.expect_value(t, d.cursors[0].head, app.Pos{0, 11})

    // Exactly what Home then Shift+End selects: the break is not included.
    app.doc_select_line(&d, 1)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{1, 0})
    testing.expect_value(t, d.cursors[0].head, app.Pos{1, 7})
    app.doc_select_line(&d, 99) // clamped, not out of bounds
    testing.expect_value(t, d.cursors[0].head.line, 1)
}

// The drag algebra, a Doc question rather than a pixel one, and pinned here because the
// terminal grid reuses it.
//
// The property is that BOTH ends are re-derived every frame: a double-click-drag has to keep
// expanding by whole words, and crossing back over the press point has to move the ANCHOR from
// one end of the pressed word to the other. A fixed anchor cannot express the second half.
@(test)
test_doc_drag_span :: proc(t: ^testing.T) {
    d: app.Doc
    app.doc_init(&d)
    defer app.doc_destroy(&d)
    app.doc_set_text(&d, "alpha bravo\ncharlie delta")

    // Word grade, forward: the start of the pressed run to the end of the pointed-at one.
    anchor, head := app.doc_drag_span(&d, 2, app.Pos{0, 7}, app.Pos{1, 10}) // "bravo" -> "delta"
    testing.expect_value(t, anchor, app.Pos{0, 6})
    testing.expect_value(t, head, app.Pos{1, 13})

    // Backward past the press: the anchor flips to the far END of "bravo".
    anchor, head = app.doc_drag_span(&d, 2, app.Pos{0, 7}, app.Pos{0, 2}) // -> "alpha"
    testing.expect_value(t, anchor, app.Pos{0, 11})
    testing.expect_value(t, head, app.Pos{0, 0})

    // Held still inside the pressed word, it is what the double click alone gives.
    anchor, head = app.doc_drag_span(&d, 2, app.Pos{0, 7}, app.Pos{0, 8})
    testing.expect_value(t, anchor, app.Pos{0, 6})
    testing.expect_value(t, head, app.Pos{0, 11})

    // Line grade compares LINES: dragging left within the pressed line has not reversed the
    // gesture, so this stays forward.
    anchor, head = app.doc_drag_span(&d, 3, app.Pos{1, 9}, app.Pos{1, 1})
    testing.expect_value(t, anchor, app.Pos{1, 0})
    testing.expect_value(t, head, app.Pos{1, 13})

    // …and upward it is whole lines the other way about.
    anchor, head = app.doc_drag_span(&d, 3, app.Pos{1, 9}, app.Pos{0, 3})
    testing.expect_value(t, anchor, app.Pos{1, 13})
    testing.expect_value(t, head, app.Pos{0, 0})

    // Both ends are clamped: a resize between the press and the frame applying it costs a
    // selection end in the wrong place, never an index off the end.
    anchor, head = app.doc_drag_span(&d, 3, app.Pos{99, 99}, app.Pos{-5, -5})
    testing.expect_value(t, anchor, app.Pos{1, 13})
    testing.expect_value(t, head, app.Pos{0, 0})

    // doc_select_span keeps the gesture's order rather than normalising it, so the head stays
    // the end the eye is at.
    app.doc_select_span(&d, app.Pos{1, 5}, app.Pos{0, 2})
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{1, 5})
    testing.expect_value(t, d.cursors[0].head, app.Pos{0, 2})
    testing.expect_value(t, d.cursors[0].goal, 2) // the goal follows the head
    lo, hi := app.cursor_range(d.cursors[0])
    testing.expect_value(t, lo, app.Pos{0, 2}) // ordered on READ
    testing.expect_value(t, hi, app.Pos{1, 5})
}

// A Pos column counts BYTES while the painter counts CELLS, so a confusion shows up here as a
// truncated or mis-joined string. Exercises the splice, the cross-line read and the bridge.
//
//   h é(2) l l o ␣ →(3) ␣ w ö(2) r l d      bytes: 0 1 3 4 5 6 7 10 11 12 14 15 16, len 17
@(test)
test_doc_multibyte_roundtrip :: proc(t: ^testing.T) {
    d := mkdoc("héllo → wörld\nsecond ✓ line")
    defer app.doc_destroy(&d)

    // The whole document, newlines and all: what the highlighter parses.
    testing.expect_value(t, app.doc_string(&d, context.temp_allocator), "héllo → wörld\nsecond ✓ line")
    testing.expect_value(t, app.doc_line_len(&d, 0), 17) // BYTES

    testing.expect_value(t, app.doc_text(&d, app.Pos{0, 7}, app.Pos{0, 10}, context.temp_allocator), "→")

    // Crossing the break: tail of line 0, the newline, head of line 1.
    testing.expect_value(t, app.doc_text(&d, app.Pos{0, 11}, app.Pos{1, 6}, context.temp_allocator), "wörld\nsecond")

    // 13 cells over 17 bytes, and the two conversions are inverses on a boundary.
    cells := app.doc_cells(&d, 0, context.temp_allocator)
    testing.expect_value(t, app.cells_count(cells), 13)
    testing.expect_value(t, app.doc_cell_col(&d, app.Pos{0, 11}), 8) // the 'w'
    testing.expect_value(t, app.doc_byte_col(&d, 0, 8), 11)
    testing.expect_value(t, app.cells_off(cells, 6), 7) // the arrow
    testing.expect_value(t, app.cells_col(cells, 7), 6)

    // A column landing inside a rune snaps back to its start: the one gate, doc_clamp_pos.
    testing.expect_value(t, app.doc_clamp_pos(&d, app.Pos{0, 8}), app.Pos{0, 7})
    testing.expect_value(t, app.doc_clamp_pos(&d, app.Pos{0, 9}), app.Pos{0, 7})

    // Within the line, where the splice replaces the rebuild.
    app.doc_reset_cursor(&d, app.Pos{0, 1})
    app.doc_insert_rune(&d, 'ü')
    testing.expect_value(t, dline(&d, 0), "hüéllo → wörld")
    app.doc_backspace(&d)
    testing.expect_value(t, dline(&d, 0), "héllo → wörld")
    testing.expect_value(t, app.doc_line_count(&d), 2) // a same-line edit leaves the array
}

// CRLF collapsed to LF, and one trailing newline dropped, which Buffer puts back on save. The
// order matters: trimming the '\n' of a final "\r\n" first would leave the '\r' behind.
@(test)
test_doc_normalizes_on_load :: proc(t: ^testing.T) {
    lf := mkdoc("a\nb\n")
    defer app.doc_destroy(&lf)
    testing.expect_value(t, app.doc_line_count(&lf), 2)
    testing.expect_value(t, app.doc_string(&lf, context.temp_allocator), "a\nb")

    crlf := mkdoc("a\r\nb\r\n")
    defer app.doc_destroy(&crlf)
    testing.expect_value(t, app.doc_line_count(&crlf), 2)
    testing.expect_value(t, app.doc_string(&crlf, context.temp_allocator), "a\nb")
    testing.expect_value(t, dline(&crlf, 1), "b") // and not "b\r"

    // No trailing newline: nothing is dropped, and a lone CR is content, not a break.
    bare := mkdoc("a\rb")
    defer app.doc_destroy(&bare)
    testing.expect_value(t, app.doc_line_count(&bare), 1)
    testing.expect_value(t, app.doc_string(&bare, context.temp_allocator), "a\rb")
}

// The sticky column is a CELL, not a byte: stepping down from past a multi-byte rune must land
// under the same GLYPH, where a byte goal drifts sideways by one column per extra byte above it.
//
//   line 0:  é(2) é(2) é(2) ␣ a b c    7 cells over 10 bytes
//   line 1:  x x x x x x x             7 cells over 7 bytes
@(test)
test_doc_vertical_goal_is_a_cell :: proc(t: ^testing.T) {
    d := mkdoc("ééé abc\nxxxxxxx")
    defer app.doc_destroy(&d)
    testing.expect_value(t, app.doc_line_len(&d, 0), 10)
    testing.expect_value(t, app.doc_cell_count(&d, 0), 7)

    app.doc_reset_cursor(&d, app.Pos{0, 8}) // the 'b': byte 8, cell 5
    testing.expect_value(t, d.cursors[0].goal, 5)

    app.doc_move(&d, .Down)
    l, c := head(&d)
    testing.expect_value(t, l, 1)
    testing.expect_value(t, c, 5) // cell 5 of an ASCII line is byte 5, not byte 8

    app.doc_move(&d, .Up) // back under the same glyph it left
    l, c = head(&d)
    testing.expect_value(t, l, 0)
    testing.expect_value(t, c, 8)

    // Past the end of a shorter line the goal is kept for the next step.
    app.doc_reset_cursor(&d, app.Pos{1, 7}) // cell 7, past the end of line 0's 7
    app.doc_move(&d, .Up)
    l, c = head(&d)
    testing.expect_value(t, l, 0)
    testing.expect_value(t, c, 10) // clamped to the line's byte length
}

// Home is two places, not one: the indentation, then column 0, and back. A line that is all
// whitespace has only the one, so it lands at its end and then at its start.
@(test)
test_doc_home_toggles_at_the_indentation :: proc(t: ^testing.T) {
    d := mkdoc("    hello")
    defer app.doc_destroy(&d)

    app.doc_move(&d, .End)
    app.doc_move(&d, .Home)
    _, c := head(&d);testing.expect_value(t, c, 4) // the text, not the margin
    app.doc_move(&d, .Home)
    _, c = head(&d);testing.expect_value(t, c, 0)
    app.doc_move(&d, .Home)
    _, c = head(&d);testing.expect_value(t, c, 4) // and back, so both stay reachable

    // Selecting the indentation is Shift+Home from the text, which the toggle must not break.
    app.doc_move(&d, .Home) // to 0
    app.doc_move(&d, .End)
    app.doc_move(&d, .Home, true)
    testing.expect(t, app.cursor_has_selection(d.cursors[0]))
    _, c = head(&d);testing.expect_value(t, c, 4)

    bare := mkdoc("   ")
    defer app.doc_destroy(&bare)
    app.doc_move(&bare, .Home)
    _, c = head(&bare);testing.expect_value(t, c, 3)
    app.doc_move(&bare, .Home)
    _, c = head(&bare);testing.expect_value(t, c, 0)
}

// The ends of the document, which no motion reached before: the top, and the last line's end.
@(test)
test_doc_start_and_end_motions :: proc(t: ^testing.T) {
    d := mkdoc("one\ntwo\nthree")
    defer app.doc_destroy(&d)

    app.doc_reset_cursor(&d, app.Pos{1, 1})
    app.doc_move(&d, .Doc_End)
    l, c := head(&d);testing.expect_value(t, l, 2);testing.expect_value(t, c, 5)

    app.doc_move(&d, .Doc_Start)
    l, c = head(&d);testing.expect_value(t, l, 0);testing.expect_value(t, c, 0)

    // Extending reaches the whole document, which is what makes Shift+Ctrl+End a sweep.
    app.doc_move(&d, .Doc_End, true)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{0, 0})
    testing.expect_value(t, d.cursors[0].head, app.Pos{2, 5})
}
