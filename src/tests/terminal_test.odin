package tests

import app ".."
import "core:testing"

// Phase 1: prove the libvterm core wiring — bytes fed in (terminal_feed) land in
// the cell grid (terminal_cell) and move the cursor as the VT spec dictates. No
// GL, no shell, no PTY: just the pure state machine.

@(private = "file")
mkterm :: proc(rows, cols: int) -> app.Terminal {
    t: app.Terminal
    app.terminal_vt_init(&t, rows, cols)
    return t
}

@(private = "file")
feed :: proc(t: ^app.Terminal, s: string) {
    app.terminal_feed(t, transmute([]u8)s)
}

@(test)
test_terminal_plain_text :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)

    feed(&term, "hi")
    testing.expect_value(t, app.terminal_cell_rune(&term, 0, 0), 'h')
    testing.expect_value(t, app.terminal_cell_rune(&term, 0, 1), 'i')
    testing.expect_value(t, app.terminal_cell_rune(&term, 0, 2), rune(0)) // blank

    // The cursor advances one cell per printed glyph.
    row, col := app.terminal_cursor(&term)
    testing.expect_value(t, row, 0)
    testing.expect_value(t, col, 2)
}

@(test)
test_terminal_crlf_wraps_to_next_row :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)

    feed(&term, "a\r\nb")
    testing.expect_value(t, app.terminal_cell_rune(&term, 0, 0), 'a')
    testing.expect_value(t, app.terminal_cell_rune(&term, 1, 0), 'b')

    row, col := app.terminal_cursor(&term)
    testing.expect_value(t, row, 1)
    testing.expect_value(t, col, 1)
}

@(test)
test_terminal_cursor_escape :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)

    // Print "abc" (cursor at col 3), then CUB 2 (move left two columns).
    feed(&term, "abc\x1b[2D")
    row, col := app.terminal_cursor(&term)
    testing.expect_value(t, row, 0)
    testing.expect_value(t, col, 1)
}

@(test)
test_terminal_out_of_range_cell :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)

    _, ok := app.terminal_cell(&term, 99, 99)
    testing.expect(t, !ok, "cell outside the grid should report ok=false")
}

@(test)
test_terminal_sgr_color_attr :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)

    // SGR 7 = reverse video, then a glyph: the cell should carry the attr.
    feed(&term, "\x1b[7mX")
    cell, ok := app.terminal_cell(&term, 0, 0)
    testing.expect(t, ok, "cell (0,0) should be in range")
    testing.expect_value(t, rune(cell.chars[0]), 'X')
    testing.expect(t, cell.attrs.reverse, "SGR 7 should set the reverse attribute")
}

// Phase 2: the keyboard line-selection + scrollback over the cell grid. These drive
// the same procs the input layer does — no GL, no shell.

// Line-selection within the live grid: the first move enters select mode off the
// bottom, Shift extends a span, and the gathered text is the selected rows trimmed.
@(test)
test_terminal_line_selection :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)

    feed(&term, "l0\r\nl1\r\nl2") // rows 0..2 (row 3 is the empty bottom)
    testing.expect(t, !term.sel_active, "no selection until a move")

    app.terminal_sel_move(&term, -1, false) // off the bottom (row 3) up to row 2
    testing.expect(t, term.sel_active, "first move enters select mode")
    testing.expect_value(t, term.sel_head, 2)
    testing.expect_value(t, term.sel_anchor, 2) // no span yet

    app.terminal_sel_move(&term, -1, true) // Shift: extend up to row 1
    lo, hi := app.terminal_sel_range(&term)
    testing.expect_value(t, lo, 1)
    testing.expect_value(t, hi, 2)

    text := app.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "l1\nl2")
}

// Moving back down to the bottom with no span drops out of select mode (the hidden
// "inputting stuff" line).
@(test)
test_terminal_selection_collapse_at_bottom :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)

    feed(&term, "a\r\nb")
    app.terminal_sel_move(&term, -1, false) // enter at row 2
    testing.expect(t, term.sel_active, "in select mode")
    app.terminal_sel_move(&term, 1, false) // back to the bottom row 3
    testing.expect(t, !term.sel_active, "returning to the bottom leaves select mode")
}

// Lines scrolling off the top are captured, stay readable through the view, and the
// copy cursor can select across the history boundary.
@(test)
test_terminal_scrollback_capture_and_select :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term) // on the settled local, not inside mkterm

    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4") // 2-row grid: L0..L2 scroll off
    testing.expect_value(t, term.sb_total, 3) // three lines pushed to scrollback

    // Absolute line 0 is the oldest scrollback line; lines 3..4 are the live rows.
    sb00, ok00 := app.terminal_view_cell(&term, 0, 0)
    testing.expect(t, ok00, "oldest scrollback line should be readable")
    testing.expect_value(t, rune(sb00.chars[0]), 'L')
    sb01, _ := app.terminal_view_cell(&term, 0, 1)
    testing.expect_value(t, rune(sb01.chars[0]), '0')
    live41, _ := app.terminal_view_cell(&term, 4, 1)
    testing.expect_value(t, rune(live41.chars[0]), '4')

    // Select from the live grid up into scrollback: head 4 -> 1, anchor pinned at 3.
    app.terminal_sel_move(&term, -1, false) // enter at line 3
    app.terminal_sel_move(&term, -1, true) // line 2
    app.terminal_sel_move(&term, -1, true) // line 1
    lo, hi := app.terminal_sel_range(&term)
    testing.expect_value(t, lo, 1)
    testing.expect_value(t, hi, 3)

    text := app.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "L1\nL2\nL3")
}

// A full-screen TUI on the alt screen (DECSET 1049) must NOT spill its redraws into our
// scrollback — that was the "mangled history" bug. The settermprop callback tracks the
// switch (so PageUp can route to the TUI), and the alt buffer keeps its own grid, so
// sb_total is frozen while it's up and the primary history survives intact.
@(test)
test_terminal_altscreen_isolates_scrollback :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term) // also wires settermprop

    // Primary screen: P0,P1 scroll off into our scrollback.
    feed(&term, "P0\r\nP1\r\nP2\r\nP3")
    testing.expect_value(t, term.sb_total, 2)
    testing.expect(t, !term.on_altscreen, "starts on the primary screen")

    // A TUI takes over the alt screen, then floods it with output.
    feed(&term, "\x1b[?1049h")
    testing.expect(t, term.on_altscreen, "1049h switches to the alt screen")
    feed(&term, "A0\r\nA1\r\nA2\r\nA3\r\nA4\r\nA5")
    testing.expect_value(t, term.sb_total, 2) // unchanged: the alt screen has no scrollback of ours

    // Back to the primary: the flag clears and the captured history is still there.
    feed(&term, "\x1b[?1049l")
    testing.expect(t, !term.on_altscreen, "1049l returns to the primary screen")
    testing.expect_value(t, term.sb_total, 2)
}

// On the alt screen the line-selector stays within the live grid: it must NOT descend
// into the pre-TUI primary scrollback (that content is behind the TUI, not part of it).
// The cursor pins at the top live row; driving the TUI's own scroll happens via the PTY
// (a no-op on this headless core, so we only assert the clamp here).
@(test)
test_terminal_altscreen_selector_pins_to_live_grid :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term)

    feed(&term, "P0\r\nP1\r\nP2\r\nP3") // two lines into the primary scrollback
    testing.expect_value(t, term.sb_total, 2)
    feed(&term, "\x1b[?1049h") // a TUI takes over
    testing.expect(t, term.on_altscreen, "on the alt screen")

    // Push the copy cursor well past the top of the live grid; it must stop at sb_total
    // (the top live row), never reaching terminal_oldest (absolute 0, in primary history).
    for _ in 0 ..< 10 {
        app.terminal_sel_move(&term, -1, true)
    }
    testing.expect_value(t, term.sel_head, term.sb_total) // == 2, not 0
}
