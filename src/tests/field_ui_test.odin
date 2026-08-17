package tests

import app ".."
import "core:testing"

// The shared one-line text field. What is testable without a window is the WINDOW — which runes
// show and where a column falls — pinned here rather than in either pane's tests.

// Cut at the head, with a window that follows the caret and moves as little as it can: one
// re-aimed on every keystroke would slide the line sideways under a caret walking back.
@(test)
test_field_window :: proc(t: ^testing.T) {
    N :: 40 // a 40-rune path in a 20-cell box
    W :: 20

    // Short enough to fit: nothing is cut, whatever the window was left at.
    testing.expect_value(t, app.field_scroll(0, 12, 12, W), 0)
    testing.expect_value(t, app.field_scroll(9, 19, 0, W), 0)

    // Caret at the end: the tail shows, one cell held back for the '…' and one for the caret.
    off := app.field_scroll(0, N, N, W)
    testing.expect_value(t, off, 22)
    testing.expect_value(t, app.field_col(off, N), 19)

    // Walking left inside the window does not move it; off the left edge moves it the minimum.
    testing.expect_value(t, app.field_scroll(off, N, 30, W), 22)
    testing.expect_value(t, app.field_scroll(off, N, 22, W), 22)
    testing.expect_value(t, app.field_scroll(off, N, 20, W), 20)

    // Home puts the head back on screen, and with nothing cut there is no ellipsis cell.
    home := app.field_scroll(off, N, 0, W)
    testing.expect_value(t, home, 0)
    testing.expect_value(t, app.field_col(home, 0), 0)

    // A press resolves a column back to a rune, the same sum rearranged, so a click lands on
    // the character it points at under a cut head too.
    testing.expect_value(t, app.field_index(22, 19, N), 40)
    testing.expect_value(t, app.field_index(22, 1, N), 22)
    testing.expect_value(t, app.field_index(0, 7, N), 7)
    testing.expect_value(t, app.field_index(0, 99, N), N) // past the text: its end
    testing.expect_value(t, app.field_index(0, -3, N), 0)

    // A box too narrow for an ellipsis, a caret and a rune shows the head and clips.
    testing.expect_value(t, app.field_scroll(5, N, N, 2), 0)

    // The box divided by the advance, and a zero advance is not divided by.
    testing.expect_value(t, app.field_cells(app.Rect{0, 0, 205, 26}, 10), 20)
    testing.expect_value(t, app.field_cells(app.Rect{0, 0, 205, 26}, 0), 0)
}

// A 20-cell box at x = 100, the synthetic font's 10px cell. Torn down by the caller.
@(private = "file")
fake_field :: proc(d: ^app.Doc, text: string, off := 0) -> app.Field_Box {
    app.doc_set_text(d, text)
    return {doc = d, target = app.FIELD_PATH, r = app.Rect{100, 0, 200, 26}, off = off, cw = 10}
}

// A press is a CAPTURE at a fixed grade, and every motion until the button comes up extends
// from it: the editor's gesture, one line deep.
@(test)
test_field_press_and_drag :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    a.mouse.known = true
    a.mouse.down = true // drag_begin refuses a press whose button is already up
    d: app.Doc
    defer app.doc_destroy(&d)
    f := fake_field(&d, "/home/me/src") // 12 runes

    // A single press places the caret and captures. The boundary rounds: half a cell past the
    // fourth rune is the boundary after it.
    a.mouse.click_x = 100 + 45
    app.field_press(&a, f, 1)
    testing.expect_value(t, d.cursors[0].head.col, 5)
    testing.expect(t, app.drag_live(&a, .Field_Text, app.FIELD_PATH), "the press did not capture")

    // Motion extends from the press, wherever the pointer has since gone.
    a.mouse.x = 100 + 95
    app.field_drag(&a, f, 0)
    testing.expect_value(t, d.cursors[0].anchor.col, 5)
    testing.expect_value(t, d.cursors[0].head.col, 10)

    // Past the right edge the column keeps counting, so a drag off the end selects to the end
    // of the VALUE, the runes the window has no room for included.
    a.mouse.x = 100 + 900
    app.field_drag(&a, f, 0)
    testing.expect_value(t, d.cursors[0].head.col, 12)

    // And past the left edge it walks back to the start.
    a.mouse.x = -400
    app.field_drag(&a, f, 0)
    testing.expect_value(t, d.cursors[0].head.col, 0)

    // A drag whose capture is not ours is inert.
    a.drag = {}
    a.mouse.x = 100 + 45
    app.field_drag(&a, f, 0)
    testing.expect_value(t, d.cursors[0].head.col, 0)

    // Grade 2 selects the word and grows by whole words; grade 3 takes the whole value, which
    // is what a field's "line" is.
    a.mouse.down = true
    a.mouse.click_x = 100 + 25 // inside "home"
    app.field_press(&a, f, 2)
    testing.expect_value(t, d.cursors[0].anchor.col, 1)
    testing.expect_value(t, d.cursors[0].head.col, 5)

    a.mouse.click_x = 100 + 25
    app.field_press(&a, f, 3)
    testing.expect_value(t, d.cursors[0].anchor.col, 0)
    testing.expect_value(t, d.cursors[0].head.col, 12)

    // Under a cut head the press resolves through the window: the first cell is the '…', so
    // column 1 is the first rune SHOWN.
    cut := fake_field(&d, "/home/me/src", 6)
    a.mouse.click_x = 100 + 15
    app.field_press(&a, cut, 1)
    testing.expect_value(t, d.cursors[0].head.col, 7)
}

// The whole-value default is the field's own: the editor's copy-this-line would put a trailing
// newline on the clipboard. The write itself is glfw's, so it is not exercised here.
@(test)
test_field_clipboard_span :: proc(t: ^testing.T) {
    d: app.Doc
    defer app.doc_destroy(&d)
    app.doc_set_text(&d, "/home/me/src")

    // Nothing selected: the whole value, with no newline in it.
    lo, hi := app.field_span(&d)
    testing.expect_value(t, lo, app.Pos{0, 0})
    testing.expect_value(t, hi, app.Pos{0, 12})
    testing.expect_value(t, app.doc_text(&d, lo, hi, context.temp_allocator), "/home/me/src")

    // With a selection: exactly that, whichever way it was made.
    app.doc_select_span(&d, app.Pos{0, 1}, app.Pos{0, 5})
    lo, hi = app.field_span(&d)
    testing.expect_value(t, app.doc_text(&d, lo, hi, context.temp_allocator), "home")

    // A cut takes the selection out; with none it empties the value, the same span.
    app.doc_cut(&d)
    testing.expect_value(t, app.doc_string(&d, context.temp_allocator), "//me/src")
    app.doc_cut(&d)
    testing.expect_value(t, app.doc_string(&d, context.temp_allocator), "")
}

// A field's columns are CELLS while its Doc counts bytes, so doc_cells bridges the two at each
// entry point. On an ASCII value the two agree and nothing above would notice a missing
// conversion.
//
//   / h ô(2) m e / s r c    9 cells over 10 bytes
@(test)
test_field_press_multibyte :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    a.mouse.known = true
    a.mouse.down = true
    d: app.Doc
    defer app.doc_destroy(&d)
    f := fake_field(&d, "/hôme/src")

    testing.expect_value(t, app.doc_line_len(&d, 0), 10) // bytes
    testing.expect_value(t, app.cells_count(app.doc_cells(&d, 0, context.temp_allocator)), 9)

    // Every cell boundary reads back as that glyph's byte column.
    cells := app.doc_cells(&d, 0, context.temp_allocator)
    for k in 0 ..= 9 {
        a.mouse.click_x = 100 + i32(10 * k)
        app.field_press(&a, f, 1)
        testing.expect_value(t, d.cursors[0].head.col, app.cells_off(cells, k))
    }

    // A word grade over the accented run selects it whole.
    a.mouse.click_x = 100 + 35 // floored: cell 3, the 'm'
    app.field_press(&a, f, 2)
    testing.expect_value(t, d.cursors[0].anchor.col, 1) // 'h'
    testing.expect_value(t, d.cursors[0].head.col, 6) // past the 'e'
    lo, hi := app.cursor_range(d.cursors[0])
    testing.expect_value(t, app.doc_text(&d, lo, hi, context.temp_allocator), "hôme")

    // Dragging past the right edge selects to the end of the value, in bytes.
    a.mouse.click_x = 100
    app.field_press(&a, f, 1)
    a.mouse.x = 100 + 900
    app.field_drag(&a, f, 0)
    testing.expect_value(t, d.cursors[0].head.col, 10)
}
