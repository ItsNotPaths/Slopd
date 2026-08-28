package tests

import vt "../../bindings/libvterm"
import "core:c"
import "core:testing"
import "../txt"
import "../pty"

// The libvterm core wiring: bytes fed in land in the cell grid and move the cursor as the VT
// spec dictates. No GL, no shell, no PTY.

@(private = "file")
mkterm :: proc(rows, cols: int) -> pty.Terminal {
    t: pty.Terminal
    pty.terminal_vt_init(&t, rows, cols)
    return t
}

@(private = "file")
feed :: proc(t: ^pty.Terminal, s: string) {
    pty.terminal_feed(t, transmute([]u8)s)
}

@(test)
test_terminal_plain_text :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    feed(&term, "hi")
    testing.expect_value(t, pty.terminal_cell_rune(&term, 0, 0), 'h')
    testing.expect_value(t, pty.terminal_cell_rune(&term, 0, 1), 'i')
    testing.expect_value(t, pty.terminal_cell_rune(&term, 0, 2), rune(0)) // blank

    row, col := pty.terminal_cursor(&term)
    testing.expect_value(t, row, 0)
    testing.expect_value(t, col, 2)
}

@(test)
test_terminal_crlf_wraps_to_next_row :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    feed(&term, "a\r\nb")
    testing.expect_value(t, pty.terminal_cell_rune(&term, 0, 0), 'a')
    testing.expect_value(t, pty.terminal_cell_rune(&term, 1, 0), 'b')

    row, col := pty.terminal_cursor(&term)
    testing.expect_value(t, row, 1)
    testing.expect_value(t, col, 1)
}

@(test)
test_terminal_cursor_escape :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    // "abc" (cursor at col 3), then CUB 2.
    feed(&term, "abc\x1b[2D")
    row, col := pty.terminal_cursor(&term)
    testing.expect_value(t, row, 0)
    testing.expect_value(t, col, 1)
}

@(test)
test_terminal_out_of_range_cell :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    _, ok := pty.terminal_cell(&term, 99, 99)
    testing.expect(t, !ok, "cell outside the grid should report ok=false")
}

@(test)
test_terminal_sgr_color_attr :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    // SGR 7 = reverse video, then a glyph.
    feed(&term, "\x1b[7mX")
    cell, ok := pty.terminal_cell(&term, 0, 0)
    testing.expect(t, ok, "cell (0,0) should be in range")
    testing.expect_value(t, rune(cell.chars[0]), 'X')
    testing.expect(t, cell.attrs.reverse, "SGR 7 should set the reverse attribute")
}

// The keyboard line-selection and scrollback over the cell grid, driving the same procs the
// input layer does.

// Within the live grid: the first move enters select mode off the bottom, Shift extends a span,
// and the gathered text is the selected rows trimmed.
@(test)
test_terminal_line_selection :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    feed(&term, "l0\r\nl1\r\nl2") // rows 0..2; row 3 is the empty bottom
    testing.expect(t, !term.sel_active, "no selection until a move")

    pty.terminal_sel_move(&term, -1, false) // off the bottom, up to row 2
    testing.expect(t, term.sel_active, "first move enters select mode")
    testing.expect_value(t, term.sel_head, 2)
    testing.expect_value(t, term.sel_anchor, 2) // no span yet

    // The cursor is a BOUNDARY, so anchor == head selects nothing.
    testing.expect_value(t, pty.terminal_selection_text(&term), "")

    pty.terminal_sel_move(&term, -1, true) // Shift: extend up over row 1
    lo, hi := pty.terminal_sel_range(&term)
    testing.expect_value(t, lo, 1)
    testing.expect_value(t, hi, 2) // half-open: line 1, and only line 1

    // One Shift press selects ONE line. It selected two until a bug report: the range was read
    // as inclusive while the marker was drawn as a boundary.
    text := pty.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "l1")

    pty.terminal_sel_move(&term, -1, true)
    more := pty.terminal_selection_text(&term)
    defer delete(more)
    testing.expect_value(t, more, "l0\nl1")
}

// Back down to the bottom with no span drops out of select mode.
@(test)
test_terminal_selection_collapse_at_bottom :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    feed(&term, "a\r\nb")
    pty.terminal_sel_move(&term, -1, false) // enter at row 2
    testing.expect(t, term.sel_active, "in select mode")
    pty.terminal_sel_move(&term, 1, false) // back to the bottom row
    testing.expect(t, !term.sel_active, "returning to the bottom leaves select mode")
}

// Lines scrolling off the top are captured, stay readable through the view, and the copy
// cursor selects across the history boundary.
@(test)
test_terminal_scrollback_capture_and_select :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term) // on the settled local, not inside mkterm

    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4") // 2-row grid: L0..L2 scroll off
    testing.expect_value(t, term.sb_total, 3) // three lines pushed

    // Absolute line 0 is the oldest; lines 3..4 are the live rows.
    sb00, ok00 := pty.terminal_view_cell(&term, 0, 0)
    testing.expect(t, ok00, "oldest scrollback line should be readable")
    testing.expect_value(t, rune(sb00.chars[0]), 'L')
    sb01, _ := pty.terminal_view_cell(&term, 0, 1)
    testing.expect_value(t, rune(sb01.chars[0]), '0')
    live41, _ := pty.terminal_view_cell(&term, 4, 1)
    testing.expect_value(t, rune(live41.chars[0]), '4')

    // From the live grid up into scrollback: head 4 -> 1, anchor pinned at 3.
    pty.terminal_sel_move(&term, -1, false) // enter at line 3
    pty.terminal_sel_move(&term, -1, true) // line 2
    pty.terminal_sel_move(&term, -1, true) // line 1
    lo, hi := pty.terminal_sel_range(&term)
    testing.expect_value(t, lo, 1)
    testing.expect_value(t, hi, 3) // half-open: lines 1 and 2

    text := pty.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "L1\nL2")
}

// A TUI on the alt screen must not spill its redraws into our scrollback — the "mangled
// history" bug. settermprop tracks the switch, and the alt buffer keeps its own grid, so
// sb_total freezes while it is up.
@(test)
test_terminal_altscreen_isolates_scrollback :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term) // also wires settermprop

    // Primary screen: P0,P1 scroll off into our scrollback.
    feed(&term, "P0\r\nP1\r\nP2\r\nP3")
    testing.expect_value(t, term.sb_total, 2)
    testing.expect(t, !term.on_altscreen, "starts on the primary screen")

    feed(&term, "\x1b[?1049h")
    testing.expect(t, term.on_altscreen, "1049h switches to the alt screen")
    feed(&term, "A0\r\nA1\r\nA2\r\nA3\r\nA4\r\nA5")
    testing.expect_value(t, term.sb_total, 2) // unchanged: the alt screen has none of ours

    // Back to the primary: the flag clears and the history is still there.
    feed(&term, "\x1b[?1049l")
    testing.expect(t, !term.on_altscreen, "1049l returns to the primary screen")
    testing.expect_value(t, term.sb_total, 2)
}

// A resize landing while a non-default SGR pen is active must not paint the newly exposed cells
// with that pen's background. libvterm's clearcell is patched to clear to the defaults
// (patches/libvterm-resize-default-bg.patch); without it a diff's green smears and persists.
@(test)
test_terminal_resize_under_active_pen_stays_default :: proc(t: ^testing.T) {
    term := mkterm(6, 20)
    defer pty.terminal_vt_destroy(&term)

    // Green background, one short cell, no reset: the state a frame-boundary resize catches a
    // TUI in mid-line.
    feed(&term, "\x1b[48;2;0;255;0mX")
    pty.terminal_resize(&term, 10, 24)
    pty.terminal_resize(&term, 6, 20)

    // Every cell bar the explicit 'X' must read default bg.
    for row in 0 ..< 6 {
        for col in 0 ..< 20 {
            if row == 0 && col == 0 do continue // the written 'X' carries green
            c, _ := pty.terminal_cell(&term, row, col)
            _, def := pty.terminal_color(&term, c.bg)
            testing.expectf(t, def, "cell (%d,%d) exposed by resize must be default bg, not the active pen", row, col)
        }
    }
}

// The line-selector stays within the live grid: the pre-TUI primary scrollback is behind the
// TUI, not part of it. The cursor pins at the top live row; driving the TUI's own scroll goes
// through the PTY, a no-op on this headless core.
@(test)
test_terminal_altscreen_selector_pins_to_live_grid :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)

    feed(&term, "P0\r\nP1\r\nP2\r\nP3") // two lines into the primary scrollback
    testing.expect_value(t, term.sb_total, 2)
    feed(&term, "\x1b[?1049h") // a TUI takes over
    testing.expect(t, term.on_altscreen, "on the alt screen")

    // Well past the top of the live grid: it must stop at sb_total, never terminal_oldest.
    for _ in 0 ..< 10 {
        pty.terminal_sel_move(&term, -1, true)
    }
    testing.expect_value(t, term.sel_head, term.sb_total) // 2, not 0
}

// A diff line's coloured background stays confined to the cells it was painted on as the line
// crosses into scrollback: no bleed into trailing default-bg cells, none onto neighbours.
@(test)
test_terminal_bg_color_confined_across_scrollback :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)

    // Green bg behind "GG", reset, then two lines so the green one scrolls off.
    feed(&term, "\x1b[48;2;0;255;0mGG\x1b[0m\r\nplain\r\nlast")
    testing.expect_value(t, term.sb_total, 1) // only the green line scrolled off

    // Absolute line 0 is the green line, now in scrollback.
    g0, _ := pty.terminal_view_cell(&term, 0, 0)
    bg0, def0 := pty.terminal_color(&term, g0.bg)
    testing.expect(t, !def0, "painted cell bg should not be default")
    testing.expectf(t, bg0.g > 0.5 && bg0.r < 0.2 && bg0.b < 0.2, "expected green bg, got %v", bg0)

    // The cell just past "GG" was never painted.
    g2, _ := pty.terminal_view_cell(&term, 0, 2)
    _, def2 := pty.terminal_color(&term, g2.bg)
    testing.expect(t, def2, "trailing cells of the diff line must stay default bg (no spill)")

    // And the next line must be entirely default bg.
    p0, _ := pty.terminal_view_cell(&term, 1, 0)
    _, defp := pty.terminal_color(&term, p0.bg)
    testing.expect(t, defp, "the following line must not inherit the diff's bg")
}

// A coloured bg made active, then erase-to-EOL so background-colour-erase paints the rest of
// the row, then a reset and newline. The green must not leak onto the blank line below — the
// "spaces stay green at the prompt" spill.
@(test)
test_terminal_bce_does_not_leak_to_next_line :: proc(t: ^testing.T) {
    term := mkterm(3, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)

    // Green bg, "+ add", erase-to-EOL (BCE fills the row), reset, newline, then plain
    // newlines to bring fresh blank lines onto the grid.
    feed(&term, "\x1b[48;2;0;255;0m+ add\x1b[K\x1b[0m\r\n")
    feed(&term, "\r\n")

    // The erased part of the diff row must read green.
    d, _ := pty.terminal_cell(&term, 0, 10)
    _, defd := pty.terminal_color(&term, d.bg)
    testing.expect(t, !defd, "BCE should have painted the erased diff cells green")

    // The blank lines after the reset must be default bg, every column.
    for row in 1 ..< 3 {
        for col in 0 ..< 20 {
            c, _ := pty.terminal_cell(&term, row, col)
            _, def := pty.terminal_color(&term, c.bg)
            testing.expectf(t, def, "cell (%d,%d) after reset must be default bg, not green", row, col)
        }
    }
}

// SGR 0 and SGR 49 must both drop the pen back to default bg, the alt screen included. A
// scroll or erase under a still-active non-default pen legitimately inherits that pen's bg —
// xterm bce behaviour, and the app's job to reset before scrolling.
@(test)
test_terminal_bg_reset_paths :: proc(t: ^testing.T) {
    check_default :: proc(t: ^testing.T, term: ^pty.Terminal, row, col: int, what: string) {
        c, _ := pty.terminal_cell(term, row, col)
        _, def := pty.terminal_color(term, c.bg)
        testing.expectf(t, def, "%s: cell (%d,%d) must be default bg, not a leaked colour", what, row, col)
    }

    { // SGR 49, reset background only.
        term := mkterm(3, 20)
        defer pty.terminal_vt_destroy(&term)
        feed(&term, "\x1b[42mX\x1b[49m\x1b[K\r\nplain")
        check_default(t, &term, 0, 5, "sgr-49 reset")
        check_default(t, &term, 1, 0, "sgr-49 reset next line")
    }
    { // On the alt screen: green, erase-to-EOL, reset, newline; next line default.
        term := mkterm(3, 20)
        defer pty.terminal_vt_destroy(&term)
        pty.terminal_enable_scrollback(&term)
        feed(&term, "\x1b[?1049h")
        testing.expect(t, term.on_altscreen, "entered alt screen")
        feed(&term, "\x1b[48;2;0;255;0m+ add\x1b[K\x1b[0m\r\n\r\n")
        check_default(t, &term, 1, 0, "alt-screen after reset")
        check_default(t, &term, 2, 7, "alt-screen after reset")
    }
}

// --- soft wrap, and the copy bug that predates the mouse ---
//
// A shell line longer than the grid is two ROWS but one LINE, and the copy path used to join
// every row with a newline, so Ctrl+Shift+C handed back an unpasteable command.
//
// libvterm knew the answer all along. This asserts the premise as loudly as the conclusion: if
// a future libvterm stops flagging continuations, the first expect fails saying so.
@(test)
test_terminal_continuation_flag :: proc(t: ^testing.T) {
    term := mkterm(4, 10)
    defer pty.terminal_vt_destroy(&term)
    feed(&term, "0123456789abcd") // 14 chars into a 10-wide grid: wraps onto row 1

    testing.expect(t, !pty.terminal_continuation(&term, 0), "the first row continues nothing")
    testing.expect(
        t,
        pty.terminal_continuation(&term, 1),
        "premise changed: libvterm no longer flags a wrapped row as a continuation",
    )
    testing.expect(t, !pty.terminal_continuation(&term, 2), "a row nothing wrapped onto")

    // The logical line is the run of rows the command occupies, from either end.
    first, last := pty.terminal_logical_line(&term, 1)
    testing.expect_value(t, first, 0)
    testing.expect_value(t, last, 1)
    first, last = pty.terminal_logical_line(&term, 0)
    testing.expect_value(t, first, 0)
    testing.expect_value(t, last, 1)
}

// The fix end to end, on the keyboard's path.
@(test)
test_terminal_copy_rejoins_a_wrapped_line :: proc(t: ^testing.T) {
    term := mkterm(4, 10)
    defer pty.terminal_vt_destroy(&term)
    // Two logical lines: rows 0+1 are one, row 2 is another.
    feed(&term, "0123456789abcd\r\nsecond")

    term.sel_active = true
    term.sel_anchor, term.sel_head = 0, 3 // half-open: both logical lines
    text := pty.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "0123456789abcd\nsecond")
}

// …and once the wrapped line has scrolled off, where the flag had to be captured on the way
// past. What the sb_pushline4 opt-in buys: the three-argument callback drops the bit.
@(test)
test_terminal_copy_rejoins_a_wrapped_scrollback_line :: proc(t: ^testing.T) {
    term := mkterm(3, 10)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)
    feed(&term, "0123456789abcd\r\nb\r\nc\r\nd\r\ne")

    testing.expect(t, term.sb_total >= 2, "the wrapped rows scrolled into history")
    testing.expect(t, term.scrollback[1].continuation, "the flag rode in on sb_pushline4")

    term.sel_active = true
    term.sel_anchor, term.sel_head = 0, 2 // the wrapped line's two rows
    text := pty.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "0123456789abcd")
}

// Clips per line and trims only where a segment runs to the row's own edge: the blanks a
// terminal pads a row with are not part of what you dragged over, but the ones you crossed are.
@(test)
test_terminal_range_text_clips_and_trims :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)
    feed(&term, "alpha bravo\r\ncharlie delta")

    a := pty.terminal_range_text(&term, txt.Pos{0, 6}, txt.Pos{1, 7})
    defer delete(a)
    testing.expect_value(t, a, "bravo\ncharlie")

    // A segment that stops short keeps the spaces inside it…
    b := pty.terminal_range_text(&term, txt.Pos{0, 4}, txt.Pos{0, 8})
    defer delete(b)
    testing.expect_value(t, b, "a br")

    // …while one that runs to the edge is trimmed of the row's padding.
    c := pty.terminal_range_text(&term, txt.Pos{0, 0}, txt.Pos{0, 20})
    defer delete(c)
    testing.expect_value(t, c, "alpha bravo")
}

// word.odin's word_span, which is what makes a terminal double click and an editor double
// click agree about what a word is.
@(test)
test_terminal_word_span :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)
    feed(&term, "alpha bravo")

    lo, hi := pty.terminal_word_span(&term, 0, 8) // inside "bravo"
    testing.expect_value(t, lo, 6)
    testing.expect_value(t, hi, 11)

    lo, hi = pty.terminal_word_span(&term, 0, 5) // the space between is a run too
    testing.expect_value(t, lo, 5)
    testing.expect_value(t, hi, 6)

    // Past the written text the blanks are one run out to the row's width.
    lo, hi = pty.terminal_word_span(&term, 0, 15)
    testing.expect_value(t, lo, 11)
    testing.expect_value(t, hi, 20)
}

// --- the wheel scrolls the VIEW, and only the view ---
//
// This pane was the last place rule 10 did not hold: our scrollback used to be reachable only
// by dragging the copy cursor, so a notch moved a cursor. The view has its own detach now.
@(test)
test_terminal_wheel_scrolls_the_view_only :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)
    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4") // 2-row grid: L0..L2 into history

    pty.terminal_scroll_by(&term, -2)
    testing.expect_value(t, pty.terminal_view_top(&term), 1)
    testing.expect(t, !term.sel_active, "scrolling must not conjure a copy cursor")
    testing.expect_value(t, term.sel_head, 0) // and must not move one
    testing.expect_value(t, pty.terminal_selection_text(&term), "")

    // Clamped at both ends: never past the oldest retained line, never below the live grid.
    pty.terminal_scroll_by(&term, -99)
    testing.expect_value(t, pty.terminal_view_top(&term), 0)
    pty.terminal_scroll_by(&term, 99)
    testing.expect_value(t, pty.terminal_view_top(&term), term.sb_total)

    // A keystroke to the shell re-attaches, as in every list pane.
    pty.terminal_scroll_by(&term, -2)
    testing.expect(t, term.view_detached)
    pty.terminal_sel_reset(&term)
    testing.expect_value(t, pty.terminal_view_top(&term), term.sb_total)
}

// The view catches at the live bottom and follows the output again. Both used to freeze the
// pane: `view_top` is an absolute line, so every line pushed off left the parked view one
// further behind.
@(test)
test_terminal_view_follows_the_bottom_again :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)
    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4") // 2-row grid: L0..L2 into history

    // Up into history and back: the notch landing on the bottom re-attaches.
    pty.terminal_scroll_by(&term, -2)
    pty.terminal_scroll_by(&term, 99)
    testing.expect(t, !term.view_detached, "back at the bottom is not scrolled")
    feed(&term, "\r\nL5")
    testing.expect_value(t, pty.terminal_view_top(&term), term.sb_total)

    // A bare click pins the view too, and pinning it at the bottom must not stop it following.
    pty.terminal_msel_set(&term, txt.Pos{term.sb_total, 0}, txt.Pos{term.sb_total, 0})
    feed(&term, "\r\nL6")
    testing.expect_value(t, pty.terminal_view_top(&term), term.sb_total)

    // Parked above the bottom it still holds its line.
    pty.terminal_scroll_by(&term, -2)
    parked := pty.terminal_view_top(&term)
    feed(&term, "\r\nL7")
    testing.expect_value(t, pty.terminal_view_top(&term), parked)
}

// A mouse selection survives a scroll, which is what you want when the thing being selected
// runs off the top of the pane. It could not while the wheel was a copy-cursor move.
@(test)
test_terminal_wheel_keeps_a_mouse_selection :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)
    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4")

    pty.terminal_msel_set(&term, txt.Pos{3, 0}, txt.Pos{4, 2})
    pty.terminal_scroll_by(&term, -2)
    testing.expect(t, term.msel_on, "a notch is not a new selection gesture")
    testing.expect_value(t, term.msel.anchor, txt.Pos{3, 0})
    testing.expect_value(t, pty.terminal_view_top(&term), 1)
}

// The copy cursor starts at the bottom of what is ON SCREEN, not the live bottom — otherwise
// the first Shift+Alt+Up yanks the view back to where you were not looking.
@(test)
test_terminal_keyboard_selects_from_the_scrolled_view :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer pty.terminal_vt_destroy(&term)
    pty.terminal_enable_scrollback(&term)
    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4")

    pty.terminal_scroll_by(&term, -3) // view_top 0: showing L0, L1
    pty.terminal_sel_move(&term, -1, true) // Shift: select the bottom visible line
    testing.expect_value(t, term.sel_anchor, 1) // the boundary below L1…
    testing.expect_value(t, term.sel_head, 0) // …and the one above it

    text := pty.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "L0")
    testing.expect_value(t, pty.terminal_view_top(&term), 0) // the view stayed put
}

// One predicate for "does this pointer event belong to the child?", asked by the wheel and the
// click alike. It used to be two — the wheel asked `on_altscreen`, the click `mouse_on` — and
// all four combinations occur in the wild.
//
// The broken row is the last: a mouse-tracking program that is not full-screen (`fzf --height`
// inline). Its click went to fzf while its wheel scrolled our scrollback.
@(test)
test_terminal_wheel_forwards_is_one_predicate :: proc(t: ^testing.T) {
    plain := pty.Terminal{} // a shell: no alt screen, no mouse tracking
    testing.expect(t, !pty.terminal_wheel_forwards(&plain, false), "a plain shell scrolls OUR view")

    pager := pty.Terminal{on_altscreen = true} // `less`, `man`
    testing.expect(t, pty.terminal_wheel_forwards(&pager, false), "a full-screen pager owns the notch")

    tui := pty.Terminal{on_altscreen = true, mouse_on = true} // vim mouse=a, htop, tmux
    testing.expect(t, pty.terminal_wheel_forwards(&tui, false), "a mouse-tracking TUI owns it too")

    // THE CASE THE OLD PREDICATE GOT WRONG. Mouse tracking without the alt screen — an
    // inline picker — and the click already went to it, so the wheel must as well.
    inline_picker := pty.Terminal{mouse_on = true}
    testing.expect(
        t,
        pty.terminal_wheel_forwards(&inline_picker, false),
        "an inline mouse-tracking program was taking clicks but losing notches",
    )

    // Shift overrides every one, as the click has always done.
    testing.expect(t, !pty.terminal_wheel_forwards(&tui, true), "Shift keeps the notch local")
    testing.expect(t, !pty.terminal_wheel_forwards(&pager, true), "over a pager too")
    testing.expect(t, !pty.terminal_wheel_forwards(&inline_picker, true), "and over an inline one")

    // No session: nothing to forward to, and the caller must not have to check separately.
    testing.expect(t, !pty.terminal_wheel_forwards(nil, false), "no terminal forwards nothing")
}

// --- paste ---

@(private = "file")
sanitized :: proc(s: string) -> string {
    return string(pty.terminal_paste_sanitize(s, context.temp_allocator))
}

// In the app the output callback is the PTY master; here it is this buffer, which is how a
// PTY-less test reads the markers.
@(private = "file")
Out :: struct {
    buf: [64]u8,
    n:   int,
}

@(private = "file")
out_cb :: proc "c" (s: [^]u8, n: c.size_t, user: rawptr) {
    o := (^Out)(user)
    for i in 0 ..< int(n) {
        if o.n < len(o.buf) {
            o.buf[o.n] = s[i]
            o.n += 1
        }
    }
}

// Capture from a clean buffer, and return what has landed since.
@(private = "file")
out_capture :: proc(term: ^pty.Terminal, o: ^Out) {
    vt.output_set_callback(term.term, out_cb, o)
    o.n = 0
}

@(private = "file")
out_text :: proc(o: ^Out) -> string {
    return string(o.buf[:o.n])
}

@(test)
test_terminal_paste_sanitize :: proc(t: ^testing.T) {
    // Every line ending becomes the CR Enter sends, and CRLF is ONE ending: both bytes would
    // submit a blank line after each real one.
    testing.expect_value(t, sanitized("a\nb"), "a\rb")
    testing.expect_value(t, sanitized("a\r\nb"), "a\rb")
    testing.expect_value(t, sanitized("a\rb"), "a\rb")

    // Tabs and UTF-8 pass, the other C0 controls do not. The ESC matters most: left in, it
    // could close the bracket early and run the rest as commands.
    testing.expect_value(t, sanitized("a\tb"), "a\tb")
    testing.expect_value(t, sanitized("héllo→"), "héllo→")
    testing.expect_value(t, sanitized("a\x1b[201~rm -rf /"), "a[201~rm -rf /")
    testing.expect_value(t, sanitized("a\x03\x7fb"), "ab")
}

@(test)
test_terminal_paste_brackets_only_when_asked :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)
    o: Out
    out_capture(&term, &o)

    // A plain shell never enabled DECSET 2004, so the text goes over bare. Only the markers
    // can show up here, and the point is that none do.
    pty.terminal_paste(&term, "ls\n")
    testing.expect_value(t, out_text(&o), "")

    feed(&term, "\x1b[?2004h")
    out_capture(&term, &o)
    pty.terminal_paste(&term, "ls\n")
    testing.expect_value(t, out_text(&o), "\x1b[200~\x1b[201~")

    // An empty clipboard is not a paste: no markers, nothing for the shell.
    out_capture(&term, &o)
    pty.terminal_paste(&term, "")
    testing.expect_value(t, out_text(&o), "")
}

@(test)
test_terminal_paste_returns_to_the_live_bottom :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer pty.terminal_vt_destroy(&term)

    // Pasting is input, so a scrolled-back view snaps forward and drops its selection.
    term.sel_active = true
    term.view_detached = true
    pty.terminal_paste(&term, "ls")
    testing.expect(t, !term.sel_active, "a paste drops the selection, as typing does")
    testing.expect(t, !term.view_detached, "and snaps the view back to the live bottom")
}
