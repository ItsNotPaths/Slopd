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

// The pointer-placed cursor ops (C7). Every other cursor op answers "where next, from where
// I am"; these take an absolute position, which is the one thing a pointer knows and no
// keystroke can say. The clamp is the load-bearing part: a Pos derived from a pixel is only
// as good as the geometry that made it, and a stale window must cost a caret in the wrong
// place, never an index off the end of the buffer.
@(test)
test_doc_pointer_cursors :: proc(t: ^testing.T) {
    d := mkdoc("alpha bravo\ncharlie")
    defer app.doc_destroy(&d)

    // Set head, extending: the anchor stays put, so a shift-click grows the selection.
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

    // A dropped cursor becomes the ROAMING one — the pointer named where it goes, so it is
    // the one that moves on. (doc_drop_anchor is the other way round: the keyboard has to
    // walk somewhere before a drop means anything, so the OLD cursor keeps roaming.)
    app.doc_add_cursor(&d, app.Pos{1, 2})
    testing.expect_value(t, len(d.cursors), 2)
    testing.expect_value(t, d.cursors[d.primary].head, app.Pos{1, 2})

    // Word: the run containing the position, head at its end so a following extend grows
    // forward from where the eye is.
    app.doc_select_word(&d, app.Pos{0, 8}) // inside "bravo"
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{0, 6})
    testing.expect_value(t, d.cursors[0].head, app.Pos{0, 11})

    // Line: exactly what Home then Shift+End selects, so a copy from either path is the
    // same string — the break is NOT included.
    app.doc_select_line(&d, 1)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{1, 0})
    testing.expect_value(t, d.cursors[0].head, app.Pos{1, 7})
    app.doc_select_line(&d, 99) // clamped, not out of bounds
    testing.expect_value(t, d.cursors[0].head.line, 1)
}

// C7c's drag algebra, which is a Doc question rather than a pixel one and is pinned here
// because C7d reuses it over a terminal grid.
//
// The property under test is that BOTH ends are re-derived every frame. A double click
// selects a word and then holds still; a double-click-DRAG has to keep expanding by whole
// words, and crossing back over the press point has to move the ANCHOR from one end of the
// pressed word to the other. An implementation that fixes the anchor when the button goes
// down cannot express the second half at all.
@(test)
test_doc_drag_span :: proc(t: ^testing.T) {
    d: app.Doc
    app.doc_init(&d)
    defer app.doc_destroy(&d)
    app.doc_set_text(&d, "alpha bravo\ncharlie delta")

    // Word grade, forward: the start of the pressed run to the end of the pointed-at one.
    anchor, head := app.doc_drag_span(&d, 2, app.Pos{0, 7}, app.Pos{1, 10}) // in "bravo" -> in "delta"
    testing.expect_value(t, anchor, app.Pos{0, 6})
    testing.expect_value(t, head, app.Pos{1, 13})

    // Word grade, backward past the press: the anchor flips to the far END of "bravo".
    anchor, head = app.doc_drag_span(&d, 2, app.Pos{0, 7}, app.Pos{0, 2}) // -> in "alpha"
    testing.expect_value(t, anchor, app.Pos{0, 11})
    testing.expect_value(t, head, app.Pos{0, 0})

    // Held still inside the pressed word, it is exactly what the double click alone gives.
    anchor, head = app.doc_drag_span(&d, 2, app.Pos{0, 7}, app.Pos{0, 8})
    testing.expect_value(t, anchor, app.Pos{0, 6})
    testing.expect_value(t, head, app.Pos{0, 11})

    // Line grade compares LINES: dragging left within the pressed line has not reversed the
    // gesture, it has not left the line — so this stays forward and selects the whole line.
    anchor, head = app.doc_drag_span(&d, 3, app.Pos{1, 9}, app.Pos{1, 1})
    testing.expect_value(t, anchor, app.Pos{1, 0})
    testing.expect_value(t, head, app.Pos{1, 13})

    // ... and upward it is whole lines the other way about.
    anchor, head = app.doc_drag_span(&d, 3, app.Pos{1, 9}, app.Pos{0, 3})
    testing.expect_value(t, anchor, app.Pos{1, 13})
    testing.expect_value(t, head, app.Pos{0, 0})

    // Both ends are clamped, the twin of doc_clamp_pos everywhere else a pixel becomes a
    // Pos: a resize between the press and the frame that applies it costs a selection end in
    // the wrong place, never an index off the end of the buffer.
    anchor, head = app.doc_drag_span(&d, 3, app.Pos{99, 99}, app.Pos{-5, -5})
    testing.expect_value(t, anchor, app.Pos{1, 13})
    testing.expect_value(t, head, app.Pos{0, 0})

    // doc_select_span keeps the gesture's order rather than normalising it, so the head
    // stays the end the eye is at and a later Shift+click extends from the right place.
    app.doc_select_span(&d, app.Pos{1, 5}, app.Pos{0, 2})
    testing.expect_value(t, len(d.cursors), 1)
    testing.expect_value(t, d.cursors[0].anchor, app.Pos{1, 5})
    testing.expect_value(t, d.cursors[0].head, app.Pos{0, 2})
    testing.expect_value(t, d.cursors[0].goal, 2) // the goal follows the HEAD
    lo, hi := app.cursor_range(d.cursors[0])
    testing.expect_value(t, lo, app.Pos{0, 2}) // ordered on READ, as both references do
    testing.expect_value(t, hi, app.Pos{1, 5})
}

// Multi-byte runes. Columns are RUNE indices while the capture that backs copy/undo/reparse
// sizes itself in BYTES, so a confusion between the two shows up here as a truncated or
// mis-joined string. Exercises the single-line splice and the cross-line capture together.
@(test)
test_doc_multibyte_roundtrip :: proc(t: ^testing.T) {
    d := mkdoc("héllo → wörld\nsecond ✓ line")
    defer app.doc_destroy(&d)

    // The whole document joined with '\n' — the capture the highlighter reparses from.
    testing.expect_value(t, app.doc_string(&d, context.temp_allocator), "héllo → wörld\nsecond ✓ line")

    // A one-line span landing on a 3-byte rune.
    testing.expect_value(t, app.doc_text(&d, app.Pos{0, 6}, app.Pos{0, 7}, context.temp_allocator), "→")

    // A span crossing the break: tail of line 0, the newline, head of line 1.
    testing.expect_value(t, app.doc_text(&d, app.Pos{0, 8}, app.Pos{1, 6}, context.temp_allocator), "wörld\nsecond")

    // Typing and deleting within the line, where the splice replaces the rebuild.
    app.doc_reset_cursor(&d, app.Pos{0, 1})
    app.doc_insert_rune(&d, 'ü')
    testing.expect_value(t, dline(&d, 0), "hüéllo → wörld")
    app.doc_backspace(&d)
    testing.expect_value(t, dline(&d, 0), "héllo → wörld")
    testing.expect_value(t, len(d.lines), 2) // a same-line edit never touches the line array
}
