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
