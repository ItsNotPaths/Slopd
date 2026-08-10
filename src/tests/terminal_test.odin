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

    // No span yet: the cursor is a BOUNDARY, so anchor == head selects nothing at all.
    testing.expect_value(t, app.terminal_selection_text(&term), "")

    app.terminal_sel_move(&term, -1, true) // Shift: extend up over row 1
    lo, hi := app.terminal_sel_range(&term)
    testing.expect_value(t, lo, 1)
    testing.expect_value(t, hi, 2) // half-open: line 1, and ONLY line 1

    // One Shift press selects ONE line. It selected two until a bug report, because the
    // range was read as inclusive while the marker was drawn as a boundary — so the anchor's
    // own line came along, which from the live bottom is the empty line you type on.
    text := app.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "l1")

    // A second press grows it by exactly one more.
    app.terminal_sel_move(&term, -1, true)
    more := app.terminal_selection_text(&term)
    defer delete(more)
    testing.expect_value(t, more, "l0\nl1")
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
    testing.expect_value(t, hi, 3) // half-open: lines 1 and 2, the anchor's own line excluded

    text := app.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "L1\nL2")
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

// A resize that lands while a non-default SGR pen is active (e.g. a streaming TUI mid
// diff-line, when draw_terminal resizes the grid every frame) must NOT paint the newly
// exposed cells with that pen's background. libvterm's clearcell is patched to clear to
// the default colours instead (patches/libvterm-resize-default-bg.patch); without it the
// diff's green/red smears across the blank grid and persists. Regression guard.
@(test)
test_terminal_resize_under_active_pen_stays_default :: proc(t: ^testing.T) {
    term := mkterm(6, 20)
    defer app.terminal_vt_destroy(&term)

    // Activate a green background, write one short cell, then DON'T reset — exactly the
    // state a frame-boundary resize catches a TUI in mid-line.
    feed(&term, "\x1b[48;2;0;255;0mX")
    // Grow then shrink the grid while that green pen is still active.
    app.terminal_resize(&term, 10, 24)
    app.terminal_resize(&term, 6, 20)

    // Every cell except the one explicit 'X' must read default bg — the resize must not
    // have back-filled the new rows/cols with green.
    for row in 0 ..< 6 {
        for col in 0 ..< 20 {
            if row == 0 && col == 0 do continue // the written 'X' legitimately carries green
            c, _ := app.terminal_cell(&term, row, col)
            _, def := app.terminal_color(&term, c.bg)
            testing.expectf(t, def, "cell (%d,%d) exposed by resize must be default bg, not the active pen", row, col)
        }
    }
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

// A diff line's coloured background (Claude Code's red/green) must stay confined to the
// cells it was painted on as the line crosses from the live grid into scrollback — no
// bleeding into the trailing default-bg cells, no leaking onto neighbouring lines.
@(test)
test_terminal_bg_color_confined_across_scrollback :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term)

    // RGB-green bg behind "GG", reset, then two more lines so the green one scrolls off.
    feed(&term, "\x1b[48;2;0;255;0mGG\x1b[0m\r\nplain\r\nlast")
    testing.expect_value(t, term.sb_total, 1) // only the green line scrolled off

    // Absolute line 0 = the green line, now captured in scrollback.
    g0, _ := app.terminal_view_cell(&term, 0, 0)
    bg0, def0 := app.terminal_color(&term, g0.bg)
    testing.expect(t, !def0, "painted cell bg should not be default")
    testing.expectf(t, bg0.g > 0.5 && bg0.r < 0.2 && bg0.b < 0.2, "expected green bg, got %v", bg0)

    // The cell just past "GG" was never painted: it must read default bg, not green.
    g2, _ := app.terminal_view_cell(&term, 0, 2)
    _, def2 := app.terminal_color(&term, g2.bg)
    testing.expect(t, def2, "trailing cells of the diff line must stay default bg (no spill)")

    // And the next line ("plain", absolute 1) must be entirely default bg.
    p0, _ := app.terminal_view_cell(&term, 1, 0)
    _, defp := app.terminal_color(&term, p0.bg)
    testing.expect(t, defp, "the following line must not inherit the diff's bg")
}

// The real Claude Code diff: a coloured bg made active, then ERASE-TO-EOL (\e[K) so
// background-colour-erase paints the rest of the row, then a reset and newline. The
// green must NOT leak onto the freshly scrolled-in blank line below it — that's the
// "spaces stay green at the prompt" spill.
@(test)
test_terminal_bce_does_not_leak_to_next_line :: proc(t: ^testing.T) {
    term := mkterm(3, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term)

    // Green bg + "+ add", erase-to-EOL (fills the row green via BCE), reset, newline.
    // Then a couple of plain newlines to bring fresh blank lines onto the grid.
    feed(&term, "\x1b[48;2;0;255;0m+ add\x1b[K\x1b[0m\r\n")
    feed(&term, "\r\n")

    // The erased part of the diff row (col 10, past "+ add") must read green.
    d, _ := app.terminal_cell(&term, 0, 10)
    _, defd := app.terminal_color(&term, d.bg)
    testing.expect(t, !defd, "BCE should have painted the erased diff cells green")

    // The blank lines that came after the reset must be DEFAULT bg, every column.
    for row in 1 ..< 3 {
        for col in 0 ..< 20 {
            c, _ := app.terminal_cell(&term, row, col)
            _, def := app.terminal_color(&term, c.bg)
            testing.expectf(t, def, "cell (%d,%d) after reset must be default bg, not green", row, col)
        }
    }
}

// Background resets we depend on for diff-bg confinement: SGR 0 (full reset) and SGR
// 49 (reset background only) must both drop the pen back to default bg, including on
// the alt screen where Claude Code renders. (Note: a scroll/erase under a still-active
// non-default pen legitimately inherits that pen's bg — that is xterm bce behaviour, so
// it is the app's job to reset before scrolling, not ours to suppress.)
@(test)
test_terminal_bg_reset_paths :: proc(t: ^testing.T) {
    check_default :: proc(t: ^testing.T, term: ^app.Terminal, row, col: int, what: string) {
        c, _ := app.terminal_cell(term, row, col)
        _, def := app.terminal_color(term, c.bg)
        testing.expectf(t, def, "%s: cell (%d,%d) must be default bg, not a leaked colour", what, row, col)
    }

    { // SGR 49 (reset background only) must drop the pen back to default bg.
        term := mkterm(3, 20)
        defer app.terminal_vt_destroy(&term)
        feed(&term, "\x1b[42mX\x1b[49m\x1b[K\r\nplain")
        check_default(t, &term, 0, 5, "sgr-49 reset")
        check_default(t, &term, 1, 0, "sgr-49 reset next line")
    }
    { // On the alt screen: green + erase-to-EOL, reset, newline — next line default.
        term := mkterm(3, 20)
        defer app.terminal_vt_destroy(&term)
        app.terminal_enable_scrollback(&term)
        feed(&term, "\x1b[?1049h")
        testing.expect(t, term.on_altscreen, "entered alt screen")
        feed(&term, "\x1b[48;2;0;255;0m+ add\x1b[K\x1b[0m\r\n\r\n")
        check_default(t, &term, 1, 0, "alt-screen after reset")
        check_default(t, &term, 2, 7, "alt-screen after reset")
    }
}

// --- C7d: soft wrap, and the copy bug that predates the mouse entirely ---
//
// A shell line longer than the grid occupies two ROWS but is one LINE, and the copy path
// used to join every row with a newline — so Ctrl+Shift+C handed back a command that could
// not be pasted. That is shipped KEYBOARD behaviour, wrong since the copy cursor landed, and
// the terminal integration pass is what found it.
//
// libvterm knew the answer the whole time. This test asserts the premise as loudly as the
// conclusion: if a future libvterm stops flagging continuations, the first expect fails with
// a message saying so rather than the copy quietly splitting again.
@(test)
test_terminal_continuation_flag :: proc(t: ^testing.T) {
    term := mkterm(4, 10)
    defer app.terminal_vt_destroy(&term)
    feed(&term, "0123456789abcd") // 14 chars into a 10-wide grid: wraps onto row 1

    testing.expect(t, !app.terminal_continuation(&term, 0), "the first row continues nothing")
    testing.expect(
        t,
        app.terminal_continuation(&term, 1),
        "premise changed: libvterm no longer flags a wrapped row as a continuation",
    )
    testing.expect(t, !app.terminal_continuation(&term, 2), "a row nothing wrapped onto")

    // The logical line is the run of rows the one command occupies, from either end of it.
    first, last := app.terminal_logical_line(&term, 1)
    testing.expect_value(t, first, 0)
    testing.expect_value(t, last, 1)
    first, last = app.terminal_logical_line(&term, 0)
    testing.expect_value(t, first, 0)
    testing.expect_value(t, last, 1)
}

// The fix, end to end, on the KEYBOARD's path — which is the one that has been wrong.
@(test)
test_terminal_copy_rejoins_a_wrapped_line :: proc(t: ^testing.T) {
    term := mkterm(4, 10)
    defer app.terminal_vt_destroy(&term)
    // Two logical lines, the first of which wraps: rows 0+1 are one line, row 2 is another.
    feed(&term, "0123456789abcd\r\nsecond")

    term.sel_active = true
    term.sel_anchor, term.sel_head = 0, 3 // half-open: lines 0..2, i.e. both logical lines
    text := app.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "0123456789abcd\nsecond")
}

// ... and once the wrapped line has scrolled off into history, where the flag has to have
// been captured on the way past rather than asked for after the fact. This is what the
// sb_pushline4 opt-in buys; the three-argument callback drops the bit here.
@(test)
test_terminal_copy_rejoins_a_wrapped_scrollback_line :: proc(t: ^testing.T) {
    term := mkterm(3, 10)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term)
    feed(&term, "0123456789abcd\r\nb\r\nc\r\nd\r\ne")

    testing.expect(t, term.sb_total >= 2, "the wrapped rows scrolled into history")
    testing.expect(t, term.scrollback[1].continuation, "the flag rode in on sb_pushline4")

    term.sel_active = true
    term.sel_anchor, term.sel_head = 0, 2 // half-open: the wrapped line's two rows
    text := app.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "0123456789abcd")
}

// The range walk clips per line and trims only where a segment runs to the row's own edge —
// the blanks a terminal pads a row with are not part of what you dragged over, but the ones
// you did drag over are.
@(test)
test_terminal_range_text_clips_and_trims :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)
    feed(&term, "alpha bravo\r\ncharlie delta")

    // Mid-line to mid-line, across a line break.
    a := app.terminal_range_text(&term, app.Pos{0, 6}, app.Pos{1, 7})
    defer delete(a)
    testing.expect_value(t, a, "bravo\ncharlie")

    // A segment that stops short keeps the spaces inside it...
    b := app.terminal_range_text(&term, app.Pos{0, 4}, app.Pos{0, 8})
    defer delete(b)
    testing.expect_value(t, b, "a br")

    // ... while one that runs to the edge is trimmed of the row's padding.
    c := app.terminal_range_text(&term, app.Pos{0, 0}, app.Pos{0, 20})
    defer delete(c)
    testing.expect_value(t, c, "alpha bravo")
}

// The word span over a grid is line.odin's word_span, which is what makes a terminal double
// click and an editor double click agree about what a word is.
@(test)
test_terminal_word_span :: proc(t: ^testing.T) {
    term := mkterm(4, 20)
    defer app.terminal_vt_destroy(&term)
    feed(&term, "alpha bravo")

    lo, hi := app.terminal_word_span(&term, 0, 8) // inside "bravo"
    testing.expect_value(t, lo, 6)
    testing.expect_value(t, hi, 11)

    lo, hi = app.terminal_word_span(&term, 0, 5) // the space between them is a run too
    testing.expect_value(t, lo, 5)
    testing.expect_value(t, hi, 6)

    // Past the written text, the blanks are one run out to the row's width — a cell that was
    // never written is whitespace, not a class of its own.
    lo, hi = app.terminal_word_span(&term, 0, 15)
    testing.expect_value(t, lo, 11)
    testing.expect_value(t, hi, 20)
}

// --- the wheel scrolls the VIEW, and only the view ---
//
// This pane was the last place C7c's rule 10 did not hold. Our scrollback used to be
// reachable only by dragging the keyboard's copy cursor around, so a wheel notch moved a
// cursor — putting a keyboard-only marker on screen that nobody asked for and dragging a
// selection's anchor under it. The view has its own detach now, like every other pane's.
@(test)
test_terminal_wheel_scrolls_the_view_only :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term)
    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4") // 2-row grid: L0..L2 into history

    app.terminal_scroll_by(&term, -2)
    testing.expect_value(t, app.terminal_view_top(&term), 1)
    testing.expect(t, !term.sel_active, "scrolling must not conjure a copy cursor")
    testing.expect_value(t, term.sel_head, 0) // and must not move one either
    testing.expect_value(t, app.terminal_selection_text(&term), "")

    // Clamped at both ends: never past the oldest retained line, never below the live grid.
    app.terminal_scroll_by(&term, -99)
    testing.expect_value(t, app.terminal_view_top(&term), 0)
    app.terminal_scroll_by(&term, 99)
    testing.expect_value(t, app.terminal_view_top(&term), term.sb_total)

    // A keystroke to the shell re-attaches, exactly as it does in every list pane.
    app.terminal_scroll_by(&term, -2)
    testing.expect(t, term.view_detached)
    app.terminal_sel_reset(&term)
    testing.expect_value(t, app.terminal_view_top(&term), term.sb_total)
}

// A mouse selection SURVIVES a scroll — which is what both reference terminals do, and what
// you want when the thing you are selecting runs off the top of the pane. It could not,
// while the wheel was a copy-cursor move: that dropped the selection on every notch.
@(test)
test_terminal_wheel_keeps_a_mouse_selection :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term)
    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4")

    app.terminal_msel_set(&term, app.Pos{3, 0}, app.Pos{4, 2})
    app.terminal_scroll_by(&term, -2)
    testing.expect(t, term.msel_on, "a notch is not a new selection gesture")
    testing.expect_value(t, term.msel.anchor, app.Pos{3, 0})
    testing.expect_value(t, app.terminal_view_top(&term), 1)
}

// Reaching for the keyboard after a wheel scroll starts the copy cursor at the bottom of
// what is ON SCREEN, not at the live bottom — otherwise the first Shift+Alt+Up yanks the
// view back to where you were not looking.
@(test)
test_terminal_keyboard_selects_from_the_scrolled_view :: proc(t: ^testing.T) {
    term := mkterm(2, 20)
    defer app.terminal_vt_destroy(&term)
    app.terminal_enable_scrollback(&term)
    feed(&term, "L0\r\nL1\r\nL2\r\nL3\r\nL4")

    app.terminal_scroll_by(&term, -3) // view_top 0: showing L0, L1
    app.terminal_sel_move(&term, -1, true) // Shift: select the bottom visible line
    testing.expect_value(t, term.sel_anchor, 1) // the boundary below L1...
    testing.expect_value(t, term.sel_head, 0) // ... and the one above it

    text := app.terminal_selection_text(&term)
    defer delete(text)
    testing.expect_value(t, text, "L0")
    testing.expect_value(t, app.terminal_view_top(&term), 0) // the view stayed put
}
