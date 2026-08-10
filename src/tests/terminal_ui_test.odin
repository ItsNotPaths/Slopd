package tests

import app ".."
import clay "../../bindings/clay"
import vt "../../bindings/libvterm"
import "core:c"
import "core:testing"

// C7b: the terminal pane declared in Clay, its cell grid painted through a Custom. The
// claim under test has two halves, and the second is the one nothing else in this refactor
// has had to make: a pixel becomes a CELL, and that cell is either handed to a child process
// as protocol bytes or used to drive a selection of our own. The first half is the same seam
// C7a tested for the editor; the second is testable end to end, because libvterm's output
// callback is where the encoded click comes out, and a headless VT core has one.
//
// **The local half of these tests pins INTERIM behaviour** — a click placing the keyboard's
// row-granular copy cursor — which C7d replaces with per-character selection. Those cases
// are marked below and are expected to be rewritten; the forwarding cases are not, and are
// the ones worth protecting.
//
// Worth knowing before adding to this file: every mutation run against it passed the claim
// that a terminal pixel has only ONE answer (the cell), because every mutation exercised the
// forwarding path where that is true. A selection boundary needs the other answer too. An
// assertion suite is only evidence about the paths it walks.
//
// The pane used throughout is {100, 50, 300, 200} at scale 1, which insets to a content area
// of {102, 52, 296, 196}. The synthetic font is 10x16, so the grid is 29 columns (290px, 6
// left over) by 12 rows (192px, 4 left over) — both remainders deliberately non-zero, since
// the strip they leave is the case a naive hit test reports as a cell that is not there.

@(private = "file")
PANE :: app.Rect{100, 50, 300, 200}
@(private = "file")
AREA :: app.Rect{102, 52, 296, 196}
@(private = "file")
ROW_H :: 16
@(private = "file")
COLS :: 29
@(private = "file")
ROWS :: 12

// A headless session at the pane's grid size, with the scrollback + settermprop callbacks
// wired (that is what makes term.mouse_on track a TUI's DECSET 1000).
@(private = "file")
mkterm :: proc(rows := ROWS, cols := COLS) -> ^app.Terminal {
    term := new(app.Terminal)
    app.terminal_vt_init(term, rows, cols)
    app.terminal_enable_scrollback(term)
    return term
}

@(private = "file")
killterm :: proc(term: ^app.Terminal) {
    app.terminal_vt_destroy(term)
    free(term)
}

@(private = "file")
feed :: proc(term: ^app.Terminal, s: string) {
    app.terminal_feed(term, transmute([]u8)s)
}

// An App whose pointer is live and whose aux pane is the terminal.
@(private = "file")
fake_app :: proc(a: ^app.App) {
    a.scale = 1
    a.mouse_on = true
    a.mouse.known = true
    a.aux_mode = .Terminal
}

// A view built by hand, so the hit tests need no font and no frame. Mirrors what
// terminal_view produces for the pane above at cw = 10 / line height 16.
@(private = "file")
mkview :: proc(top := 0) -> app.Terminal_View {
    return app.Terminal_View{area = AREA, cw = 10, row_h = ROW_H, cols = COLS, rows = ROWS, top = top}
}

// Where the pointer is, in framebuffer pixels: the middle-ish of cell (row, col).
@(private = "file")
point_at :: proc(a: ^app.App, row, col: int) {
    a.mouse.x = AREA.x + i32(col) * 10 + 3
    a.mouse.y = AREA.y + i32(row) * ROW_H + 3
}

@(private = "file")
press :: proc(a: ^app.App, count := 1, shift := false, ctrl := false, alt := false) {
    a.mouse.click = true
    a.mouse.click_count = count
    a.mouse.click_shift = shift
    a.mouse.click_ctrl = ctrl
    a.mouse.click_alt = alt
}

// --- the TUI's side of the wire -------------------------------------------------------
//
// libvterm writes a forwarded click to its output callback, which in the app is the PTY
// master (terminal.odin) and here is this buffer. Asserting the BYTES rather than a flag is
// the point: the protocol is 1-based where our grid is 0-based, and an off-by-one there is
// a click that lands one cell away inside somebody else's program, which no amount of
// internal-state checking would catch.

@(private = "file")
Sink :: struct {
    buf: [256]u8,
    n:   int,
}

@(private = "file")
sink_cb :: proc "c" (s: [^]u8, n: c.size_t, user: rawptr) {
    sk := (^Sink)(user)
    for i in 0 ..< int(n) {
        if sk.n < len(sk.buf) {
            sk.buf[sk.n] = s[i]
            sk.n += 1
        }
    }
}

@(private = "file")
sink_text :: proc(sk: ^Sink) -> string {
    return string(sk.buf[:sk.n])
}

// Turn on mouse tracking the way a TUI does — SGR encoding (1006) so the reports are
// readable, then the tracking mode itself — and start capturing from a clean buffer.
@(private = "file")
tui_wants_mouse :: proc(term: ^app.Terminal, sk: ^Sink, mode := "1000") {
    feed(term, "\x1b[?1006h")
    feed(term, "\x1b[?")
    feed(term, mode)
    feed(term, "h")
    vt.output_set_callback(term.term, sink_cb, sk)
    sk.n = 0
}

// Every phase of the frame sizes itself from this one proc.
@(test)
test_terminal_geom :: proc(t: ^testing.T) {
    area, row_h, cols, rows := app.terminal_geom(PANE, 1, 16, 10)
    testing.expect_value(t, area, AREA) // inside the 2px focus ring
    testing.expect_value(t, row_h, i32(ROW_H)) // no row padding: a terminal row IS the line height
    testing.expect_value(t, cols, COLS) // 296 / 10, floored
    testing.expect_value(t, rows, ROWS) // 196 / 16, floored

    // A hidden pane is a zero rect (compute_layout leaves them so) and must report NO grid —
    // not one row, the way the list panes round up. This number is handed to a child process
    // through TIOCSWINSZ; draw_terminal bails instead of lying to a shell about its size.
    _, _, ncols, nrows := app.terminal_geom(app.Rect{}, 1, 16, 10)
    testing.expect_value(t, ncols, 0)
    testing.expect_value(t, nrows, 0)

    // DPI scale reaches the inset and the row height both, so the grid stays on the pixel
    // grid at 2x.
    area2, row_h2, cols2, rows2 := app.terminal_geom(PANE, 2, 32, 20)
    testing.expect_value(t, area2, app.Rect{104, 54, 292, 192})
    testing.expect_value(t, row_h2, i32(32))
    testing.expect_value(t, cols2, 14) // 292 / 20
    testing.expect_value(t, rows2, 6) // 192 / 32
}

// The resize that used to be a side effect of painting.
@(test)
test_terminal_sync_resizes_the_session :: proc(t: ^testing.T) {
    term := mkterm(4, 10)
    defer killterm(term)
    th: app.Theme

    app.terminal_sync(term, &th, COLS, ROWS)
    testing.expect_value(t, term.rows, ROWS)
    testing.expect_value(t, term.cols, COLS)
}

// A pixel becomes a cell. The column FLOORS — a terminal report names a cell, and there is
// no insertion point between two of them for C7a's caret-boundary rounding to land on.
@(test)
test_terminal_hit :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    v := mkview()

    point_at(&a, 0, 0)
    hit := app.terminal_hit(&a, term, v)
    testing.expect(t, hit.ok)
    testing.expect_value(t, hit.row, 0)
    testing.expect_value(t, hit.col, 0)
    testing.expect_value(t, hit.line, 0)
    testing.expect(t, hit.live, "a row of the live grid is forwardable")

    point_at(&a, 3, 7)
    hit = app.terminal_hit(&a, term, v)
    testing.expect_value(t, hit.row, 3)
    testing.expect_value(t, hit.col, 7)

    // The right half of a cell is still that cell, not the next one.
    a.mouse.x = AREA.x + 7 * 10 + 9
    testing.expect_value(t, app.terminal_hit(&a, term, v).col, 7)

    // The sub-cell remainder along the bottom and right edges is inside the pane but is not
    // a cell, so it is not a hit: 12 rows of 16 leave 4px, 29 columns of 10 leave 6px.
    a.mouse.x, a.mouse.y = AREA.x + 5, AREA.y + ROWS * ROW_H + 1
    testing.expect(t, !app.terminal_hit(&a, term, v).ok, "the bottom remainder strip is not a cell")
    a.mouse.x, a.mouse.y = AREA.x + COLS * 10 + 1, AREA.y + 5
    testing.expect(t, !app.terminal_hit(&a, term, v).ok, "the right remainder strip is not a cell")

    // Off the pane entirely, and with the pointer configured off.
    a.mouse.x, a.mouse.y = 10, 10
    testing.expect(t, !app.terminal_hit(&a, term, v).ok)
    point_at(&a, 1, 1)
    a.mouse_on = false
    testing.expect(t, !app.terminal_hit(&a, term, v).ok, "`mouse: off` costs convenience, never capability")
}

// SCROLLED, which is the case that separates the two things a hit has to name. The screen
// row is where the paint goes; the absolute line is what the copy cursor walks; and only a
// line the live grid still holds can be forwarded to a TUI, because the TUI has no idea our
// scrollback exists.
@(test)
test_terminal_hit_scrollback_is_not_live :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)

    // 20 lines through a 12-row grid: 8 scroll off into our history.
    for i in 0 ..< 20 {
        feed(term, i == 0 ? "L" : "\r\nL")
    }
    testing.expect_value(t, term.sb_total, 8)

    // Scrolled back so the top row is absolute line 4 — four rows of history, then the grid.
    term.sel_active = true
    term.view_top = 4
    v := mkview(app.terminal_view_top(term))
    testing.expect_value(t, v.top, 4)

    point_at(&a, 0, 0)
    hit := app.terminal_hit(&a, term, v)
    testing.expect_value(t, hit.line, 4)
    testing.expect(t, !hit.live, "absolute line 4 is captured history, not a grid row")

    point_at(&a, 5, 0)
    hit = app.terminal_hit(&a, term, v)
    testing.expect_value(t, hit.line, 9)
    testing.expect(t, hit.live, "absolute line 9 is live grid row 1")

    // The clamp gate: a pane that grew this frame has screen rows the session has not been
    // resized into yet, and those must resolve as not-forwardable rather than as a cell the
    // TUI does not have. (The area grows with the row count — the hit is rejected by the
    // pane rect first, and this is a test about the row BEHIND the pixel.)
    tall := mkview(app.terminal_view_top(term))
    tall.rows = ROWS + 6
    tall.area.h = i32(tall.rows) * ROW_H
    a.mouse.y = AREA.y + i32(ROWS + 4) * ROW_H + 3
    hit = app.terminal_hit(&a, term, tall)
    testing.expect(t, hit.ok)
    testing.expect(t, !hit.live, "a screen row past the session's grid is not a cell yet")
}

// The declaration. The terminal's whole command list is ONE Custom — no rectangles, no text
// — because everything visible is painted behind the hatch, and its box IS the content area,
// which is what lets terminal_hit size itself from `area` while the painter positions from
// the resolved box.
@(test)
test_terminal_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)

    area, row_h, cols, rows := app.terminal_geom(PANE, 1, f.line_height, f.cell_w)
    v := app.terminal_view(term, area, row_h, f.cell_w, cols, rows)
    cmds := app.terminal_layout(&a, term, PANE, 500, 300, v)

    customs, others := 0, 0
    box: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
            box = app.clay_rect(c.boundingBox)
        case .None:
        case:
            others += 1
        }
    }
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, others, 0) // panel() paints the frame; this tree declares no fill
    testing.expect_value(t, box, AREA)
}

// With no TUI holding the mouse, a click is ours: it puts the copy cursor on the line under
// the pointer. Shift extends the span from the anchor, exactly as Shift+Up does.
//
// **INTERIM — C7d rewrites this test.** Line granularity is the keyboard's model; a click
// should select the CHARACTER under the pointer, and what this asserts for one click is what
// a triple click should do. The claim/no-claim rules at the end and the stale-view clamp are
// the parts that outlive the rewrite.
@(test)
test_terminal_click_moves_the_copy_cursor :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    feed(term, "l0\r\nl1\r\nl2\r\nl3\r\nl4")
    v := mkview()

    point_at(&a, 2, 0)
    press(&a)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect(t, term.sel_active, "a click enters select mode")
    testing.expect_value(t, term.sel_head, 2)
    testing.expect_value(t, term.sel_anchor, 2) // no span yet
    testing.expect(t, !a.mouse.click, "a click on a cell must be claimed")

    // Shift+click extends: the anchor stays where the first click put it.
    point_at(&a, 4, 0)
    press(&a, shift = true)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    lo, hi := app.terminal_sel_range(term)
    testing.expect_value(t, lo, 2)
    testing.expect_value(t, hi, 4)

    text := app.terminal_selection_text(term)
    defer delete(text)
    testing.expect_value(t, text, "l2\nl3\nl4")

    // A double click repeats the single one and does nothing more. INTERIM: the count is not
    // choosing a verb here (a terminal line has no Enter, which is what rule 7 asked), it is
    // choosing GRANULARITY, and this pane has only one granularity to offer until C7d gives
    // it character and word.
    point_at(&a, 1, 0)
    press(&a, count = 2)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect_value(t, term.sel_head, 1)
    testing.expect_value(t, term.sel_anchor, 1)

    // Clicking the live bottom line leaves select mode: there is nothing to copy there, and
    // it is how the copy cursor is dismissed with the pointer.
    point_at(&a, ROWS - 1, 0)
    press(&a)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect(t, !term.sel_active, "the bottom input line dismisses the cursor")

    // A press that hit no cell is left for whoever else is drawing.
    a.mouse.x, a.mouse.y = 10, 10
    press(&a)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")

    // A STALE view — the window shrank between the press and the frame that claims it, so
    // the pointer's row names a line past the end of the session. The clamp is what makes
    // that cost a cursor on the wrong line rather than an index off the end of the history.
    stale := mkview(8)
    point_at(&a, 10, 0) // absolute line 18, where the bottom is 11
    press(&a)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, stale))
    testing.expect_value(t, term.sel_head, 11)
    testing.expect(t, !term.sel_active, "clamped onto the bottom line, which has nothing to copy")
}

// The forward path, asserted as the bytes that reach the child process. SGR reports are
// 1-based, our grid is 0-based, and the press/release pair is what keeps the TUI from
// believing the button is still held (see terminal_mouse_tap).
@(test)
test_terminal_click_forwards_to_the_tui :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    sk: Sink
    tui_wants_mouse(term, &sk)
    testing.expect(t, term.mouse_on, "DECSET 1000 should reach term.mouse_on via settermprop")
    v := mkview()

    point_at(&a, 3, 7)
    press(&a)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect_value(t, sink_text(&sk), "\x1b[<0;8;4M\x1b[<0;8;4m")
    testing.expect(t, !term.sel_active, "a forwarded click is not a copy-cursor move")
    testing.expect(t, !a.mouse.click, "a forwarded click is still claimed")

    // Ctrl rides along as MOD_CTRL (4 << 2 = 16 in the report's code field) — the one
    // modifier a TUI gets to see.
    sk.n = 0
    point_at(&a, 0, 0)
    press(&a, ctrl = true)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect_value(t, sink_text(&sk), "\x1b[<16;1;1M\x1b[<16;1;1m")

    // SHIFT IS THE OVERRIDE (xterm): the click stays ours and nothing reaches the TUI. That
    // half is permanent. The anchor-follows-head half is INTERIM — this code spends Shift on
    // the override alone, where alacritty has it override AND extend; C7d composes the two,
    // and this assertion flips to "the anchor stayed put".
    sk.n = 0
    point_at(&a, 5, 2)
    press(&a, shift = true)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect(t, term.sel_active, "Shift+click keeps the click local")
    testing.expect_value(t, term.sel_head, 5)
    testing.expect_value(t, term.sel_anchor, 5)

    // Alt is global everywhere in this program, so it neither forwards nor selects — and it
    // does not CLAIM the press either, since the switcher overlay is up while Alt is held.
    sk.n = 0
    point_at(&a, 6, 1)
    press(&a, alt = true)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect_value(t, term.sel_head, 5) // unmoved
    testing.expect(t, a.mouse.click, "Alt+click is left unclaimed for the overlay")
}

// A TUI that never asked for the mouse gets nothing, however the click is modified: this is
// the invariant that keeps a click in a plain shell from spraying escape bytes at it.
@(test)
test_terminal_click_without_tracking_sends_nothing :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    sk: Sink
    vt.output_set_callback(term.term, sink_cb, &sk)
    v := mkview()

    testing.expect(t, !term.mouse_on, "a plain shell has not enabled tracking")
    point_at(&a, 4, 4)
    press(&a)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect_value(t, term.sel_head, 4) // it drove the copy cursor instead
}

// A TUI holding the mouse still cannot be sent a click on a line that scrolled out of its
// grid — there is no cell there to report — so those stay local.
@(test)
test_terminal_click_on_scrollback_stays_local :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    for i in 0 ..< 20 {
        feed(term, i == 0 ? "L" : "\r\nL")
    }
    sk: Sink
    tui_wants_mouse(term, &sk)

    term.sel_active = true
    term.view_top = 4
    v := mkview(app.terminal_view_top(term))

    point_at(&a, 0, 0) // absolute line 4: history
    press(&a)
    app.terminal_click(&a, term, app.terminal_hit(&a, term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect_value(t, term.sel_head, 4)
}

// Motion. libvterm filters by the TUI's own mode, which is why terminal_track forwards
// unconditionally rather than tracking the mode bits itself — 1003 (any-motion) reports,
// 1000 (click-only) does not, and neither costs us a branch.
@(test)
test_terminal_track_forwards_motion :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    v := mkview()

    // Click-only tracking: a move over the grid must stay silent.
    click_only := mkterm()
    defer killterm(click_only)
    sk1: Sink
    tui_wants_mouse(click_only, &sk1, "1000")
    point_at(&a, 2, 3)
    app.terminal_track(click_only, app.terminal_hit(&a, click_only, v))
    testing.expect_value(t, sink_text(&sk1), "")

    // Any-motion tracking: the same move reports, 1-based. The code is 35, not 32 — xterm's
    // motion flag (0x20) over button 4, which is how "moved with no button held" is spelled;
    // a drag would carry the held button's code instead.
    moving := mkterm()
    defer killterm(moving)
    sk2: Sink
    tui_wants_mouse(moving, &sk2, "1003")
    point_at(&a, 2, 3)
    app.terminal_track(moving, app.terminal_hit(&a, moving, v))
    testing.expect_value(t, sink_text(&sk2), "\x1b[<35;4;3M")

    // The same cell again is not a new position, so nothing more goes out — which is what
    // makes calling this every frame free.
    sk2.n = 0
    a.mouse.x += 2
    app.terminal_track(moving, app.terminal_hit(&a, moving, v))
    testing.expect_value(t, sink_text(&sk2), "")

    // And a TUI that never asked gets nothing at all.
    quiet := mkterm()
    defer killterm(quiet)
    sk3: Sink
    vt.output_set_callback(quiet.term, sink_cb, &sk3)
    point_at(&a, 1, 1)
    app.terminal_track(quiet, app.terminal_hit(&a, quiet, v))
    testing.expect_value(t, sink_text(&sk3), "")

    // A line that scrolled out of the grid has NO cell to report. Forwarding it anyway would
    // send the TUI a row index off the top of its own screen — a negative one, once the
    // scrollback is deeper than the view is scrolled — so the liveness gate is the whole
    // reason terminal_track asks for more than "the pointer is in the pane".
    back := mkterm()
    defer killterm(back)
    for i in 0 ..< 20 {
        feed(back, i == 0 ? "L" : "\r\nL")
    }
    sk4: Sink
    tui_wants_mouse(back, &sk4, "1003")
    back.sel_active = true
    back.view_top = 4
    scrolled := mkview(app.terminal_view_top(back))
    point_at(&a, 0, 0) // absolute line 4, four lines deep in captured history
    app.terminal_track(back, app.terminal_hit(&a, back, scrolled))
    testing.expect_value(t, sink_text(&sk4), "")
}
