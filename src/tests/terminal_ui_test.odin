package tests

import app "../slopd"
import clay "../../bindings/clay"
import vt "../../bindings/libvterm"
import "core:c"
import "core:testing"
import "../txt"
import "../gfx"
import "../ui"
import "../pty"

// The terminal pane declared in Clay, its cell grid painted through a Custom. Two claims: a
// pixel becomes a CELL, and that cell is either handed to a child process as protocol bytes or
// drives a selection of our own. The second is testable end to end, because libvterm's output
// callback is where the encoded click comes out.
//
// Note before adding here: every mutation run against this file passed the claim that a
// terminal pixel has only ONE answer, because every mutation walked the forwarding path where
// that is true. A selection boundary needs the other answer too.
//
// The pane is {100, 50, 300, 200} at scale 1, insetting to {102, 52, 296, 196}. The synthetic
// font is 10x16, so the grid is 29 columns (6px left over) by 12 rows (4px left over) — both
// remainders deliberately non-zero, since that strip is what a naive hit test calls a cell.

@(private = "file")
PANE :: gfx.Rect{100, 50, 300, 200}
@(private = "file")
AREA :: gfx.Rect{102, 52, 296, 196}
@(private = "file")
ROW_H :: 16
@(private = "file")
COLS :: 29
@(private = "file")
ROWS :: 12

// With the scrollback and settermprop callbacks wired, which is what makes term.mouse_on track
// a TUI's DECSET 1000.
@(private = "file")
mkterm :: proc(rows := ROWS, cols := COLS) -> ^pty.Terminal {
    term := new(pty.Terminal)
    pty.terminal_vt_init(term, rows, cols)
    pty.terminal_enable_scrollback(term)
    return term
}

@(private = "file")
killterm :: proc(term: ^pty.Terminal) {
    pty.terminal_vt_destroy(term)
    free(term)
}

@(private = "file")
feed :: proc(term: ^pty.Terminal, s: string) {
    pty.terminal_feed(term, transmute([]u8)s)
}

@(private = "file")
fake_app :: proc(a: ^app.App) {
    a.scale = 1
    a.face = clay_test_face()
    a.mouse_on = true
    a.mouse.known = true
    a.aux_mode = .Terminal
}

// By hand, so the hit tests need no font and no frame.
@(private = "file")
mkview :: proc(top := 0) -> app.Terminal_View {
    return app.Terminal_View{area = AREA, cw = 10, row_h = ROW_H, cols = COLS, rows = ROWS, top = top}
}

// The middle-ish of cell (row, col), in framebuffer pixels.
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

// --- the TUI's side of the wire --- libvterm writes a forwarded click to its output callback,
// which in the app is the PTY master and here is this buffer. Asserting the BYTES is the point:
// the protocol is 1-based where our grid is 0-based, and an off-by-one is a click landing one
// cell away inside somebody else's program.

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

// As a TUI does: SGR encoding (1006) so the reports are readable, then the tracking mode.
@(private = "file")
tui_wants_mouse :: proc(term: ^pty.Terminal, sk: ^Sink, mode := "1000") {
    feed(term, "\x1b[?1006h")
    feed(term, "\x1b[?")
    feed(term, mode)
    feed(term, "h")
    vt.output_set_callback(term.term, sink_cb, sk)
    sk.n = 0
}

@(test)
test_terminal_geom :: proc(t: ^testing.T) {
    area, row_h, cols, rows := app.terminal_geom(PANE, 16, 10)
    testing.expect_value(t, area, AREA) // inside the 2px focus ring
    testing.expect_value(t, row_h, i32(ROW_H)) // no padding: a row IS the line height
    testing.expect_value(t, cols, COLS) // 296 / 10, floored
    testing.expect_value(t, rows, ROWS) // 196 / 16, floored

    // A hidden pane is a zero rect and must report NO grid, not one row the way the list panes
    // round up: this number goes to a child process through TIOCSWINSZ.
    _, _, ncols, nrows := app.terminal_geom(gfx.Rect{}, 16, 10)
    testing.expect_value(t, ncols, 0)
    testing.expect_value(t, nrows, 0)

    // DPI scale reaches the inset and the row height both.
    area2, row_h2, cols2, rows2 := app.terminal_geom(PANE, 32, 20)
    testing.expect_value(t, area2, gfx.Rect{104, 54, 292, 192})
    testing.expect_value(t, row_h2, i32(32))
    testing.expect_value(t, cols2, 14) // 292 / 20
    testing.expect_value(t, rows2, 6) // 192 / 32
}

@(test)
test_terminal_sync_resizes_the_session :: proc(t: ^testing.T) {
    term := mkterm(4, 10)
    defer killterm(term)
    th: gfx.Theme

    app.terminal_sync(term, &th, COLS, ROWS)
    testing.expect_value(t, term.rows, ROWS)
    testing.expect_value(t, term.cols, COLS)
}

// The column FLOORS: a terminal report names a cell, with no insertion point between two of
// them for the editor's caret-boundary rounding to land on.
@(test)
test_terminal_hit :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    v := mkview()

    point_at(&a, 0, 0)
    hit := app.terminal_hit(app.ctx_of(&a), term, v)
    testing.expect(t, hit.ok)
    testing.expect_value(t, hit.row, 0)
    testing.expect_value(t, hit.col, 0)
    testing.expect_value(t, hit.line, 0)
    testing.expect(t, hit.live, "a row of the live grid is forwardable")

    point_at(&a, 3, 7)
    hit = app.terminal_hit(app.ctx_of(&a), term, v)
    testing.expect_value(t, hit.row, 3)
    testing.expect_value(t, hit.col, 7)

    a.mouse.x = AREA.x + 7 * 10 + 9
    testing.expect_value(t, app.terminal_hit(app.ctx_of(&a), term, v).col, 7)

    // The sub-cell remainder along the bottom and right edges is inside the pane but is not a
    // cell: 12 rows of 16 leave 4px, 29 columns of 10 leave 6px.
    a.mouse.x, a.mouse.y = AREA.x + 5, AREA.y + ROWS * ROW_H + 1
    testing.expect(t, !app.terminal_hit(app.ctx_of(&a), term, v).ok, "the bottom remainder strip is not a cell")
    a.mouse.x, a.mouse.y = AREA.x + COLS * 10 + 1, AREA.y + 5
    testing.expect(t, !app.terminal_hit(app.ctx_of(&a), term, v).ok, "the right remainder strip is not a cell")

    a.mouse.x, a.mouse.y = 10, 10
    testing.expect(t, !app.terminal_hit(app.ctx_of(&a), term, v).ok)
    point_at(&a, 1, 1)
    a.mouse_on = false
    testing.expect(t, !app.terminal_hit(app.ctx_of(&a), term, v).ok, "`mouse: off` costs convenience, never capability")
}

// Scrolled, the case that separates the two things a hit names: the screen row is where the
// paint goes, the absolute line is what the copy cursor walks, and only a line the live grid
// still holds can be forwarded.
@(test)
test_terminal_hit_scrollback_is_not_live :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)

    for i in 0 ..< 20 {
        feed(term, i == 0 ? "L" : "\r\nL")
    }
    testing.expect_value(t, term.sb_total, 8)

    // Top row at absolute line 4: four rows of history, then the grid.
    term.sel_active = true
    term.view_top = 4
    v := mkview(pty.terminal_view_top(term))
    testing.expect_value(t, v.top, 4)

    point_at(&a, 0, 0)
    hit := app.terminal_hit(app.ctx_of(&a), term, v)
    testing.expect_value(t, hit.line, 4)
    testing.expect(t, !hit.live, "absolute line 4 is captured history, not a grid row")

    point_at(&a, 5, 0)
    hit = app.terminal_hit(app.ctx_of(&a), term, v)
    testing.expect_value(t, hit.line, 9)
    testing.expect(t, hit.live, "absolute line 9 is live grid row 1")

    // A pane that grew this frame has screen rows the session is not resized into yet, and
    // those must resolve as not-forwardable rather than as a cell the TUI does not have.
    tall := mkview(pty.terminal_view_top(term))
    tall.rows = ROWS + 6
    tall.area.h = i32(tall.rows) * ROW_H
    a.mouse.y = AREA.y + i32(ROWS + 5) * ROW_H + 3
    hit = app.terminal_hit(app.ctx_of(&a), term, tall)
    testing.expect(t, hit.ok)
    testing.expect(t, !hit.live, "a screen row past the session's grid is not a cell yet")
}

// The whole command list is ONE Custom, no rectangles and no text, and its box IS the content
// area — which is what lets terminal_hit size itself from `area` while the painter positions
// from the resolved box.
@(test)
test_terminal_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)

    area, row_h, cols, rows := app.terminal_geom(PANE, f.line_height, f.cell_w)
    v := app.terminal_view(term, area, row_h, f.cell_w, cols, rows)
    cmds := app.terminal_layout(&a, f, term, 500, 300, v)

    customs, others, scissors := 0, 0, 0
    box, clip: gfx.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .Custom:
            customs += 1
            box = ui.clay_rect(c.boundingBox)
        case .ScissorStart:
            scissors += 1
            if c.id == clay.ID("term_pane").id {
                clip = ui.clay_rect(c.boundingBox)
            }
        case .ScissorEnd:
            scissors += 1
        case .None:
        case:
            others += 1
        }
    }
    testing.expect_value(t, customs, 1)
    testing.expect_value(t, others, 0) // panel() paints the frame; no fill here
    testing.expect_value(t, box, AREA)

    // The pane's own clip, declared where the box is, and what the Custom's painter is handed.
    testing.expect_value(t, scissors, 2)
    testing.expect_value(t, clip, AREA)
}

// With no TUI holding the mouse, a click is ours and selects a CHARACTER. What an earlier
// row-granular version asserted for a single click is what a triple click asserts here: a
// pointer names a character, and only arrow keys have a reason to name a line.
@(test)
test_terminal_click_selects_by_character :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    feed(term, "alpha bravo\r\ncharlie delta\r\nl2\r\nl3\r\nl4")
    v := mkview()

    // A single click is an empty selection at a boundary: a place to extend from, not a span.
    point_at(&a, 2, 0)
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect(t, term.msel_on, "a click starts a mouse selection")
    testing.expect_value(t, term.msel.anchor, txt.Pos{2, 0})
    testing.expect_value(t, term.msel.head, txt.Pos{2, 0})
    testing.expect(t, !pty.terminal_msel_has_span(term), "a bare click selects nothing yet")
    testing.expect(t, !term.sel_active, "the keyboard's copy cursor stands down")
    testing.expect(t, !a.mouse.click, "a click on a cell must be claimed")

    // Shift+click extends: the anchor stays where the first click put it.
    point_at(&a, 4, 0)
    press(&a, shift = true)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, term.msel.anchor, txt.Pos{2, 0})
    testing.expect_value(t, term.msel.head, txt.Pos{4, 0})

    text := pty.terminal_selection_text(term)
    defer delete(text)
    testing.expect_value(t, text, "l2\nl3\n")

    // A double click selects the word: word.odin's word_span, the editor's double click over
    // a grid.
    point_at(&a, 0, 8) // inside "bravo", columns 6..11
    press(&a, count = 2)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, term.msel.anchor, txt.Pos{0, 6})
    testing.expect_value(t, term.msel.head, txt.Pos{0, 11})

    // …and it takes the GLYPH, not the caret boundary: the right half of the last 'a' of
    // "alpha" rounds the boundary to 5, the space, so a word taken from there selects the gap.
    a.mouse.x = AREA.x + 4 * 10 + 6
    a.mouse.y = AREA.y + 3
    press(&a, count = 2)
    hit := app.terminal_hit(app.ctx_of(&a), term, v)
    testing.expect_value(t, hit.col, 4) // the premise: the two columns disagree
    testing.expect_value(t, hit.bcol, 5)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, hit)
    testing.expect_value(t, term.msel.anchor, txt.Pos{0, 0})
    testing.expect_value(t, term.msel.head, txt.Pos{0, 5})

    // A triple click takes the whole line.
    point_at(&a, 1, 3)
    press(&a, count = 3)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, term.msel.anchor, txt.Pos{1, 0})
    testing.expect_value(t, term.msel.head, txt.Pos{1, COLS})

    a.mouse.x, a.mouse.y = 10, 10
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")

    // A stale view: the window shrank between the press and the frame claiming it, so the
    // pointer's row names a line past the end. The clamp makes that cost a selection on the
    // wrong line rather than an index off the end of the history.
    stale := mkview(8)
    point_at(&a, 10, 0) // a row past the end of the stale view
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, stale))
    testing.expect_value(t, term.msel.head.line, ROWS - 1)
}

// By character, with the grade fixed at the press applying for the whole gesture.
@(test)
test_terminal_drag_selects :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    feed(term, "alpha bravo\r\ncharlie delta")
    v := mkview()
    a.mouse.down = true

    // Press inside "alpha", drag into "bravo" on the same row.
    point_at(&a, 0, 2)
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect(t, ui.drag_live(app.ctx_of(&a), .Terminal_Sel, 0), "a local press captures")

    point_at(&a, 0, 8)
    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 100)
    testing.expect_value(t, term.msel.anchor, txt.Pos{0, 2})
    testing.expect_value(t, term.msel.head, txt.Pos{0, 8})

    // Down a row and back left: the anchor holds.
    point_at(&a, 1, 1)
    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 101)
    testing.expect_value(t, term.msel.anchor, txt.Pos{0, 2})
    testing.expect_value(t, term.msel.head, txt.Pos{1, 1})

    // A word-grade drag keeps expanding by whole words.
    point_at(&a, 0, 8) // in "bravo"
    press(&a, count = 2)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    point_at(&a, 1, 10) // into "delta" on the next row
    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 102)
    testing.expect_value(t, term.msel.anchor, txt.Pos{0, 6}) // the start of "bravo"
    testing.expect_value(t, term.msel.head, txt.Pos{1, 13}) // the end of "delta"

    // Back over the press and the anchor flips to the far end of the pressed word.
    point_at(&a, 0, 2) // into "alpha"
    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 103)
    testing.expect_value(t, term.msel.anchor, txt.Pos{0, 11})
    testing.expect_value(t, term.msel.head, txt.Pos{0, 0})

    // A drag serves the session it started in: switching mid-gesture leaves it held but inert.
    a.term_active = 1
    point_at(&a, 1, 5)
    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 104)
    testing.expect_value(t, term.msel.head, txt.Pos{0, 0})
}

// Past the bottom edge the drag scrolls the view itself: there is no viewport policy here to
// follow the selection, so the walk moves view_top.
@(test)
test_terminal_drag_autoscrolls :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    for i in 0 ..< 30 {
        feed(term, i == 0 ? "L0" : "\r\nL")
    }
    a.mouse.down = true

    term.sel_active = true
    term.view_top = 5
    v := mkview(pty.terminal_view_top(term))
    point_at(&a, 0, 0)
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, term.msel.anchor.line, 5)
    testing.expect_value(t, pty.terminal_view_top(term), 5) // the click did not snap the view

    // Above the pane: the walk goes up into history and drags the view with it.
    a.mouse.y = AREA.y - ROW_H
    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 100)
    testing.expect_value(t, term.msel.head.line, 3)
    testing.expect_value(t, term.view_top, 3)

    // Held still inside the same tick, the line holds rather than snapping back.
    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 100)
    testing.expect_value(t, term.msel.head.line, 3)

    app.terminal_drag(app.ctx_of(&a), term, v, a.term_active, 100 + ui.DRAG_SCROLL_S)
    testing.expect_value(t, term.msel.head.line, 1)
    testing.expect_value(t, term.view_top, 1)
}

// Asserted as the bytes that reach the child. SGR reports are 1-based where our grid is 0-based,
// and the press/release pair is what keeps the TUI from believing the button is still held.
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

    // The RIGHT half of cell 7, where the boundary rounds to 8: a report names the cell the
    // pointer is inside, and reaching for the selection's boundary instead would land one cell
    // over inside somebody else's program.
    a.mouse.x = AREA.x + 7 * 10 + 6
    a.mouse.y = AREA.y + 3 * ROW_H + 3
    press(&a)
    hit3 := app.terminal_hit(app.ctx_of(&a), term, v)
    testing.expect_value(t, hit3.col, 7)
    testing.expect_value(t, hit3.bcol, 8)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, hit3)
    testing.expect_value(t, sink_text(&sk), "\x1b[<0;8;4M\x1b[<0;8;4m")
    testing.expect(t, !term.msel_on, "a forwarded click starts no selection of ours")
    testing.expect(t, !a.mouse.click, "a forwarded click is still claimed")

    // Ctrl rides along as MOD_CTRL (16 in the code field): the one modifier a TUI sees.
    sk.n = 0
    point_at(&a, 0, 0)
    press(&a, ctrl = true)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, sink_text(&sk), "\x1b[<16;1;1M\x1b[<16;1;1m")

    // Shift is the override: the click stays ours and nothing reaches the TUI — and it
    // extends as well, so over a mouse-tracking TUI the first Shift+click starts a local
    // selection and the second grows it.
    sk.n = 0
    point_at(&a, 5, 2)
    press(&a, shift = true)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect(t, term.msel_on, "Shift+click keeps the click local")
    testing.expect_value(t, term.msel.anchor, txt.Pos{5, 2})

    point_at(&a, 7, 4)
    press(&a, shift = true)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect_value(t, term.msel.anchor, txt.Pos{5, 2}) // pinned where the first put it
    testing.expect_value(t, term.msel.head, txt.Pos{7, 4})

    // Alt is global, so it neither forwards nor selects — and does not claim the press
    // either, since the switcher is up while Alt is held.
    sk.n = 0
    point_at(&a, 6, 1)
    press(&a, alt = true)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect_value(t, term.msel.head, txt.Pos{7, 4}) // unmoved
    testing.expect(t, a.mouse.click, "Alt+click is left unclaimed for the overlay")
}

// However the click is modified. What keeps a click in a plain shell from spraying escape bytes
// at it.
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
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect_value(t, term.msel.head, txt.Pos{4, 4}) // it started a selection instead
}

// There is no cell to report for a line that scrolled out of the grid, so those stay local.
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
    v := mkview(pty.terminal_view_top(term))

    point_at(&a, 0, 0) // absolute line 4: history
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, sink_text(&sk), "")
    testing.expect_value(t, term.msel.head.line, 4)
}

// libvterm filters by the TUI's own mode, which is why terminal_track forwards unconditionally:
// 1003 reports, 1000 does not, and neither costs us a branch.
@(test)
test_terminal_track_forwards_motion :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    v := mkview()

    click_only := mkterm()
    defer killterm(click_only)
    sk1: Sink
    tui_wants_mouse(click_only, &sk1, "1000")
    point_at(&a, 2, 3)
    app.terminal_track(click_only, app.terminal_hit(app.ctx_of(&a), click_only, v))
    testing.expect_value(t, sink_text(&sk1), "")

    // Any-motion: the same move reports, 1-based. The code is 35, not 32 — xterm's motion flag
    // over button 4, which is how "moved with no button held" is spelled.
    moving := mkterm()
    defer killterm(moving)
    sk2: Sink
    tui_wants_mouse(moving, &sk2, "1003")
    point_at(&a, 2, 3)
    app.terminal_track(moving, app.terminal_hit(app.ctx_of(&a), moving, v))
    testing.expect_value(t, sink_text(&sk2), "\x1b[<35;4;3M")

    // The same cell is not a new position, which is what makes calling this every frame free.
    sk2.n = 0
    a.mouse.x += 2
    app.terminal_track(moving, app.terminal_hit(app.ctx_of(&a), moving, v))
    testing.expect_value(t, sink_text(&sk2), "")

    quiet := mkterm()
    defer killterm(quiet)
    sk3: Sink
    vt.output_set_callback(quiet.term, sink_cb, &sk3)
    point_at(&a, 1, 1)
    app.terminal_track(quiet, app.terminal_hit(app.ctx_of(&a), quiet, v))
    testing.expect_value(t, sink_text(&sk3), "")

    // A line that scrolled out has no cell to report; forwarding it would send the TUI a row
    // index off the top of its own screen. Hence the liveness gate.
    back := mkterm()
    defer killterm(back)
    for i in 0 ..< 20 {
        feed(back, i == 0 ? "L" : "\r\nL")
    }
    sk4: Sink
    tui_wants_mouse(back, &sk4, "1003")
    back.sel_active = true
    back.view_top = 4
    scrolled := mkview(pty.terminal_view_top(back))
    point_at(&a, 0, 0) // absolute line 4, deep in captured history
    app.terminal_track(back, app.terminal_hit(app.ctx_of(&a), back, scrolled))
    testing.expect_value(t, sink_text(&sk4), "")
}

// Selects the command, not the row the pointer landed on: the one place the continuation flag
// reaches the selection rather than just the copy.
@(test)
test_terminal_triple_click_takes_the_whole_wrapped_line :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm(ROWS, 10) // 10 wide, so a long command wraps
    defer killterm(term)
    feed(term, "0123456789abcd\r\nsecond")
    v := app.Terminal_View{area = AREA, cw = 10, row_h = ROW_H, cols = 10, rows = ROWS, top = 0}

    // Point at the second row of the wrapped command and take the whole thing.
    point_at(&a, 1, 1)
    press(&a, count = 3)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, term.msel.anchor, txt.Pos{0, 0})
    testing.expect_value(t, term.msel.head, txt.Pos{1, 10})

    // …and it copies back as the one line it was typed as.
    text := pty.terminal_selection_text(term)
    defer delete(text)
    testing.expect_value(t, text, "0123456789abcd")
}

// Alternatives, not layers: taking hold of one drops the other, so there is never a state with
// two selections drawn and Ctrl+Shift+C guessing.
@(test)
test_terminal_selections_are_alternatives :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    feed(term, "alpha\r\nbravo\r\ncharlie")
    v := mkview()

    term.sel_active = true
    term.sel_head, term.sel_anchor = 1, 1
    point_at(&a, 2, 1)
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect(t, !term.sel_active)
    testing.expect(t, term.msel_on)

    // …and a keyboard move retires the click's.
    pty.terminal_sel_move(term, -1, false)
    testing.expect(t, !term.msel_on)
    testing.expect(t, term.sel_active)

    point_at(&a, 0, 0)
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect(t, term.msel_on)
    pty.terminal_sel_reset(term)
    testing.expect(t, !term.msel_on)
    testing.expect(t, !term.sel_active)
}

// What the painter tints, as a value. A selection is per CELL and not per row, and the painter
// is the one place a headless test cannot follow, so the arithmetic was moved out of it.
@(test)
test_terminal_msel_row_span :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    feed(term, "alpha\r\nbravo\r\ncharlie\r\ndelta")

    // Nothing selected paints nothing, and a bare click is nothing.
    lo, hi := app.terminal_msel_row_span(term, 1, COLS)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 0)
    pty.terminal_msel_set(term, txt.Pos{1, 3}, txt.Pos{1, 3})
    lo, hi = app.terminal_msel_row_span(term, 1, COLS)
    testing.expect_value(t, hi, lo)

    // Three lines: the first clipped at its start, the last at its end, the interior full.
    pty.terminal_msel_set(term, txt.Pos{1, 2}, txt.Pos{3, 4})
    lo, hi = app.terminal_msel_row_span(term, 1, COLS)
    testing.expect_value(t, lo, 2)
    testing.expect_value(t, hi, COLS)
    lo, hi = app.terminal_msel_row_span(term, 2, COLS)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, COLS)
    lo, hi = app.terminal_msel_row_span(term, 3, COLS)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 4)
    lo, hi = app.terminal_msel_row_span(term, 0, COLS)
    testing.expect_value(t, hi, lo)
    lo, hi = app.terminal_msel_row_span(term, 4, COLS)
    testing.expect_value(t, hi, lo)

    // Within one line it is a run of cells, which is the case a row tint gets wrong.
    pty.terminal_msel_set(term, txt.Pos{2, 2}, txt.Pos{2, 5})
    lo, hi = app.terminal_msel_row_span(term, 2, COLS)
    testing.expect_value(t, lo, 2)
    testing.expect_value(t, hi, 5)

    // Backwards it is the same run: the pair is ordered on READ, never on write.
    pty.terminal_msel_set(term, txt.Pos{2, 5}, txt.Pos{2, 2})
    lo, hi = app.terminal_msel_row_span(term, 2, COLS)
    testing.expect_value(t, lo, 2)
    testing.expect_value(t, hi, 5)
}

// A click after an escaped scroll must not jump the view back. view_top is stale then, since
// terminal_view_top is reporting the live bottom, so the click reads through it.
@(test)
test_terminal_click_does_not_restore_a_stale_view :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    for i in 0 ..< 30 {
        feed(term, i == 0 ? "L0" : "\r\nL")
    }

    // Scrolled back, then escaped: view_top still holds the old position.
    term.sel_active = true
    term.view_top = 4
    pty.terminal_sel_reset(term)
    testing.expect_value(t, term.view_top, 4) // stale, deliberately
    testing.expect_value(t, pty.terminal_view_top(term), term.sb_total) // the view is live

    v := mkview(pty.terminal_view_top(term))
    point_at(&a, 0, 0)
    press(&a)
    app.terminal_click(app.ctx_of(&a), term, a.term_active, app.terminal_hit(app.ctx_of(&a), term, v))
    testing.expect_value(t, pty.terminal_view_top(term), term.sb_total)
}

// The twin of test_terminal_msel_row_span, for the KEYBOARD's copy cursor.
//
// The half-open reading is the whole assertion: the cursor is drawn as a rule along the TOP edge
// of its line, so anchor and head are boundaries and the lines between them are [min, max).
// Read inclusively, the anchor's own line lights up too — from the live bottom, the empty line
// you are typing on.
@(test)
test_terminal_sel_row_span :: proc(t: ^testing.T) {
    a: app.App
    fake_app(&a)
    term := mkterm()
    defer killterm(term)
    feed(term, "l0\r\nl1\r\nl2\r\nl3")

    lo, hi := app.terminal_sel_row_span(term)
    testing.expect_value(t, hi, lo) // nothing selected paints nothing

    // The marker moved but nothing extended: still no highlight.
    pty.terminal_sel_move(term, -1, false)
    lo, hi = app.terminal_sel_row_span(term)
    testing.expect_value(t, hi, lo)

    // One Shift press lights exactly one line: the one below the marker it left.
    head := term.sel_head
    pty.terminal_sel_move(term, -1, true)
    lo, hi = app.terminal_sel_row_span(term)
    testing.expect_value(t, lo, head - 1)
    testing.expect_value(t, hi, head)
    testing.expect_value(t, hi - lo, 1)

    // The membership test, not just its ends: the anchor's own line is OUT.
    testing.expect(t, app.terminal_sel_row_shown(term, head - 1), "the line under the marker")
    testing.expect(t, !app.terminal_sel_row_shown(term, head), "the anchor's own line is not selected")
    testing.expect(t, !app.terminal_sel_row_shown(term, head - 2), "nor the one above the marker")

    pty.terminal_sel_move(term, -1, true)
    lo, hi = app.terminal_sel_row_span(term)
    testing.expect_value(t, hi - lo, 2)
}
