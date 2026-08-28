package main

import "core:math"
import "vendor:glfw"
import clay "../../bindings/clay"
import vt "../../bindings/libvterm"
import "../txt"
import "../gfx"
import "../ui"
import "../pty"
import "../clock"

// The terminal pane's UI half. Clay owns the frame, we own the body: a 200x60 grid is 12k
// cells, so the pane declares one `Custom` and the painter fills the box Clay reserves.
// Everything the phases must agree about lives in `Terminal_View`.
//
// Two mouse behaviours, and the TUI chooses which is live. Where a click goes:
//   plain, TUI has the mouse      forwarded
//   plain, TUI does not           local: place the selection at that character
//   Shift, TUI has the mouse      LOCAL — Shift is the override (xterm's convention)
//   Shift, TUI does not           local, extending the selection from its anchor
//   Ctrl                          forwarded as MOD_CTRL; ignored local
//   Alt                           nothing at all
//
// Shift does both jobs at once, so it is one condition rather than two rival meanings. Keyed
// on `t.mouse_on` alone, never on whether this click COULD have been forwarded.

// `cols`/`rows` are the PANE's, not the session's: they agree after terminal_sync, so the two
// differ for exactly one frame after a resize and the hit test must care.
Terminal_View :: struct {
    area:  gfx.Rect,
    cw:    f32,
    row_h: i32,
    cols:  int,
    rows:  int,
    top:   int, // absolute line at the top row (terminal_view_top)
}

// No row padding: a terminal's rows are the line height exactly, so box-drawing characters
// meet. A degenerate pane reports ZERO rows, unlike the list panes — `rows` goes out via
// TIOCSWINSZ.
terminal_geom :: proc(pane: gfx.Rect, line_h: f32, cell_w: f32) -> (area: gfx.Rect, row_h: i32, cols, rows: int) {
    area = ui.inset(pane, gfx.edge(line_h))
    row_h = max(1, i32(line_h))
    if area.w <= 0 || area.h <= 0 || cell_w <= 0 {
        return area, row_h, 0, 0
    }
    cols = max(1, int(f32(area.w) / cell_w))
    rows = max(1, int(area.h / row_h))
    return
}

// Size the session to the pane (the ioctl the child watches for SIGWINCH) and re-seed the
// default colours. GL-free, and before anything is declared rather than a side effect of paint.
terminal_sync :: proc(term: ^pty.Terminal, th: ^gfx.Theme, cols, rows: int) {
    pty.terminal_resize(term, rows, cols)
    pty.terminal_set_default_colors(term, th.fg, th.bg)
}

// Pure, unlike the editor's: the viewport is an integer line, so there is no tween to re-aim.
terminal_view :: proc(term: ^pty.Terminal, area: gfx.Rect, row_h: i32, cw: f32, cols, rows: int) -> Terminal_View {
    return Terminal_View {
        area  = area,
        cw    = cw,
        row_h = row_h,
        cols  = cols,
        rows  = rows,
        top   = pty.terminal_view_top(term),
    }
}

// `live` gates forwarding — the TUI has no idea our scrollback exists. A selection end needs
// `bcol`, a cell report needs `col`.
Terminal_Hit :: struct {
    ok:   bool,
    row:  int,
    col:  int, // the cell the pointer is INSIDE, floored; what a TUI is told
    bcol: int, // the boundary it is NEAREST, rounded; where a selection ends
    line: int,
    live: bool,
}

// Not clay.PointerOver: one box, one comparison. The sub-cell remainder is not a cell, so not
// a hit.
terminal_hit :: proc(u: ui.UI_Ctx, term: ^pty.Terminal, v: Terminal_View) -> Terminal_Hit {
    if !u.mouse_on || !u.mouse.known || term == nil || v.rows <= 0 || v.cols <= 0 || v.row_h <= 0 || v.cw <= 0 {
        return {}
    }
    // Not gated on u.mouse.stood_down: that suppresses hover, and this pane paints none — the
    // cells belong to the child process.
    if !gfx.rect_hit(v.area, u.mouse.x, u.mouse.y) {
        return {}
    }
    row := int((u.mouse.y - v.area.y) / v.row_h)
    col := int(f32(u.mouse.x - v.area.x) / v.cw)
    if row >= v.rows || col >= v.cols {
        return {} // the sub-cell remainder along the bottom / right edge
    }
    bcol := terminal_boundary_col(v, u.mouse.x)
    n := v.top + row
    // For one frame after the window grows there are screen rows with no grid row behind them.
    // Those resolve as history rather than as a cell the TUI does not have.
    live := n >= term.sb_total && n - term.sb_total < term.rows
    return Terminal_Hit{ok = true, row = row, col = col, bcol = bcol, line = n, live = live}
}

// Rounded, where the hit's `col` floors, and clamped so a drag out the side of the pane ends
// at an edge. editor_caret_col's twin.
terminal_boundary_col :: proc(v: Terminal_View, x: i32) -> int {
    if v.cw <= 0 {
        return 0
    }
    return clamp(int(math.round(f32(x - v.area.x) / v.cw)), 0, v.cols)
}

// Every frame the pane draws: libvterm drops an unchanged cell and emits nothing unless the TUI
// asked for motion, so this costs one comparison in C. Not gated on focus.
terminal_track :: proc(term: ^pty.Terminal, hit: Terminal_Hit) {
    if term == nil || !term.mouse_on || !hit.ok || !hit.live {
        return
    }
    pty.terminal_mouse_at(term, hit.line - term.sb_total, hit.col)
}

// The table at the top of this file, in code. Alt is checked BEFORE the claim, so the press is
// left for the switcher rather than swallowed. The count chooses granularity, not the verb.
// `active` names the session the capture belongs to, so a drag survives a switch.
terminal_click :: proc(u: ui.UI_Ctx, term: ^pty.Terminal, active: int, hit: Terminal_Hit) {
    if !hit.ok || term == nil {
        return
    }
    if u.mouse.click_alt {
        return
    }
    count, ok := ui.mouse_take_click(u)
    if !ok {
        return
    }
    if term.mouse_on && !u.mouse.click_shift && hit.live {
        pty.terminal_mouse_tap(term, hit.line - term.sb_total, hit.col, u.mouse.click_ctrl)
        return
    }
    // Local from here. The press captures, and the grade goes in with it, because a
    // double-click-drag has to keep expanding by whole words.
    ui.drag_begin(u, .Terminal_Sel, active, count, txt.Pos{hit.line, hit.bcol}, hit.col)

    bound := txt.Pos{hit.line, hit.bcol}
    cell := txt.Pos{hit.line, hit.col}
    switch {
    case count >= 2:
        anchor, head := pty.terminal_grade_span(term, count, cell, cell)
        pty.terminal_msel_set(term, anchor, head)
    case u.mouse.click_shift:
        pty.terminal_msel_head(term, bound)
    case:
        pty.terminal_msel_set(term, bound, bound)
    }
}

// A hit outside the pane is refused; a drag under capture answers wherever the pointer went.
// The row is clamped rather than the pixel, or the sub-cell remainder would take the selection.
terminal_drag_pos :: proc(u: ui.UI_Ctx, v: Terminal_View) -> (bound, cell: txt.Pos) {
    if v.rows <= 0 || v.cols <= 0 || v.row_h <= 0 || v.cw <= 0 {
        return {}, {}
    }
    // Both divisions truncate toward zero, so a pointer above or left lands on 0 and the
    // clamps finish the job — no "above the window" case to distinguish.
    row := clamp(int((u.mouse.y - v.area.y) / v.row_h), 0, v.rows - 1)
    col := clamp(int(f32(u.mouse.x - v.area.x) / v.cw), 0, v.cols - 1)
    n := v.top + row
    return txt.Pos{n, terminal_boundary_col(v, u.mouse.x)}, txt.Pos{n, col}
}

// The pointer's line inside the pane, the autoscroll's walk past an edge. This pane scrolls the
// view itself: nothing chases a caret here, so the walk moves `view_top`.
terminal_drag_line :: proc(u: ui.UI_Ctx, term: ^pty.Terminal, v: Terminal_View, line: int, now: f64) -> int {
    past, dir := 0, 0
    switch {
    case u.mouse.y < v.area.y:
        past, dir = int(v.area.y - u.mouse.y), -1
    case u.mouse.y >= v.area.y + v.area.h:
        past, dir = int(u.mouse.y - (v.area.y + v.area.h) + 1), 1
    }
    if dir == 0 {
        u.drag.over_on = false
        return line
    }
    if !u.drag.over_on {
        u.drag.over, u.drag.over_on = line, true
    }
    if ui.drag_tick(u, now) {
        floor := term.on_altscreen ? term.sb_total : pty.terminal_oldest(term)
        u.drag.over = clamp(u.drag.over + dir * ui.drag_scroll_step(past, int(v.row_h)), floor, pty.terminal_bottom(term))
        if u.drag.over < term.view_top {
            term.view_top = u.drag.over
        } else if u.drag.over > term.view_top + v.rows - 1 {
            term.view_top = u.drag.over - v.rows + 1
        }
        term.view_top = clamp(term.view_top, floor, term.sb_total)
    }
    return u.drag.over
}

// Beside terminal_click, because both can change which lines are on screen. Only the local half
// drags: a forwarded click is a tap, and terminal_track already feeds the TUI every motion.
terminal_drag :: proc(u: ui.UI_Ctx, term: ^pty.Terminal, v: Terminal_View, active: int, now: f64) {
    if !u.mouse_on || !u.mouse.known || term == nil {
        return
    }
    if !ui.drag_live(u, .Terminal_Sel, active) {
        return
    }
    bound, cell := terminal_drag_pos(u, v)
    line := terminal_drag_line(u, term, v, bound.line, now)

    if u.drag.grade >= 2 {
        anchor, head := pty.terminal_grade_span(
            term,
            u.drag.grade,
            txt.Pos{u.drag.anchor.line, u.drag.anchor_glyph},
            txt.Pos{line, cell.col},
        )
        pty.terminal_msel_set(term, anchor, head)
        return
    }
    pty.terminal_msel_head(term, txt.Pos{line, bound.col})
}

// Handed to the bridge as `customData`, so it lives in the frame's temp arena.
Terminal_Body :: struct {
    term: ^pty.Terminal,
    v:    Terminal_View,
}

// The Custom covers the whole content area, not the whole-cell grid inside it, so the painter's
// box IS the box the hit test sized itself from.
//   term_pane    the content area inside the focus ring, clipping its own content
//     term_grid    the cell grid, as a Custom — the element terminal_hit points at
//     sw_col       the Alt-held switcher (overlay_ui.odin), a floating child over the grid
// `a` only for the session switcher, which must be declared INSIDE the pane to inherit its
// clip. The grid itself knows nothing of the application.
terminal_declare :: proc(u: ui.UI_Ctx, a: ^App, face: gfx.Face, term: ^pty.Terminal, v: Terminal_View, now: f64 = 0) {
    area := v.area

    body := new(Terminal_Body, context.temp_allocator)
    body^ = Terminal_Body{term = term, v = v}
    cu := new(ui.ClayCustom, context.temp_allocator)
    cu^ = ui.ClayCustom{paint = terminal_paint_grid, user = body}

    // No backgroundColor: panel() filled the pane, and the transparent default emits no
    // Rectangle, so the command list is just the Custom inside the clip.
    if clay.UI(clay.ID("term_pane"))(ui.clay_pane_box(area)) {
        if clay.UI(clay.ID("term_grid"))(
            {
                layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                custom = {customData = cu},
            },
        ) {}

        // After the grid and inside the pane, so it inherits the clip and paints in its own
        // group. It would survive without one here, but only by accident of this pane's shape.
        if switcher_shown(a) {
            switcher_declare(u, a.terminals[:], a.term_active, &a.switcher_anim, face, area, now)
        }
    }
}

// Half-open; empty when there is no span. Out of the painter so a headless test can assert the
// boundary-versus-line reading.
terminal_sel_row_span :: proc(term: ^pty.Terminal) -> (lo, hi: int) {
    if !term.sel_active {
        return 0, 0
    }
    a, b := pty.terminal_sel_range(term)
    return a, b
}

// The comparison, not just the range: `n <= hi` and `n < hi` are the bug and the fix. Per row,
// so it can afford a call; the mouse's per-cell test stays inline.
terminal_sel_row_shown :: proc(term: ^pty.Terminal, n: int) -> bool {
    lo, hi := terminal_sel_row_span(term)
    return n >= lo && n < hi
}

// Half-open, and empty on every line it does not reach: first line from lo.col, last to hi.col,
// interior filled. Out of the painter so it is assertable.
terminal_msel_row_span :: proc(term: ^pty.Terminal, n, cols: int) -> (lo, hi: int) {
    if !pty.terminal_msel_has_span(term) {
        return 0, 0
    }
    a, b := txt.cursor_range(term.msel)
    if n < a.line || n > b.line {
        return 0, 0
    }
    lo = n == a.line ? a.col : 0
    hi = n == b.line ? b.col : cols
    return clamp(lo, 0, cols), clamp(hi, 0, cols)
}

// A one-entry memo over terminal_color: every miss crosses into libvterm, twice per cell —
// 24k FFI calls a repaint at 200x60. Output comes in runs of one colour, so this skips nearly
// all of them.
@(private = "file")
Color_Memo :: struct {
    key:        vt.Color,
    rgb:        [3]f32,
    is_default: bool,
    valid:      bool, // a zeroed key is a legitimate colour (RGB black)
}

@(private = "file")
memo_color :: proc(m: ^Color_Memo, term: ^pty.Terminal, col: vt.Color) -> (rgb: [3]f32, is_default: bool) {
    if m.valid && m.key == col {
        return m.rgb, m.is_default
    }
    rgb, is_default = pty.terminal_color(term, col)
    m^ = {key = col, rgb = rgb, is_default = is_default, valid = true}
    return
}

// The default background in one quad, then per cell a fill only where it differs, the glyph,
// and a reverse-video block at the cursor. Positions come from `r`, the box the solver
// resolved, not v.area — tests/terminal_ui_test.odin pins the equality.
terminal_paint_grid :: proc(t: ^gfx.Draw, r, clip: gfx.Rect, win_w, win_h: i32, host: rawptr, user: rawptr) {
    a := (^App)(host)
    u := ctx_of(a)
    g := (^Terminal_Body)(user)
    if g == nil || g.term == nil {
        return
    }
    term := g.term
    v := g.v
    th := &a.theme
    cw := v.cw
    rh := v.row_h

    gfx.fill(t, r, th.bg) // the whole grid's default background, in one quad
    cur_row, cur_col := pty.terminal_cursor(term)

    // Each on-screen row maps to an absolute line, from the live grid or scrollback. While
    // selecting, the block cursor is suppressed and the selected range tints.

    glyph: [1]rune
    fg_memo, bg_memo: Color_Memo
    for row in 0 ..< v.rows {
        n := v.top + row
        row_sel := terminal_sel_row_shown(term, n)
        msel_a, msel_b := terminal_msel_row_span(term, n, v.cols)
        cy := r.y + i32(row) * rh
        for col in 0 ..< v.cols {
            cell := pty.terminal_view_cell(term, n, col) or_continue

            fg, fdef := memo_color(&fg_memo, term, cell.fg)
            if fdef {
                fg = th.fg
            }
            bg, bdef := memo_color(&bg_memo, term, cell.bg)
            if bdef {
                bg = th.bg
            }
            // Reverse video, live grid only; XOR with the cell's own reverse attr.
            is_cursor := !term.sel_active && n == term.sb_total + cur_row && col == cur_col
            if cell.attrs.reverse != is_cursor {
                fg, bg = bg, fg
            }
            if row_sel || (col >= msel_a && col < msel_b) { // the glyph stays on top
                bg = th.selection
            }

            // Off the same fractional grid as the glyphs, so the fills meet exactly.
            x0 := i32(f32(r.x) + cw * f32(col))
            x1 := i32(f32(r.x) + cw * f32(col + 1))
            if bg != th.bg {
                gfx.fill(t, gfx.Rect{x0, cy, x1 - x0, rh}, bg)
            }
            if ch := rune(cell.chars[0]); ch >= 0x20 {
                glyph[0] = ch
                gfx.text_draw_runes(t, glyph[:], f32(x0), f32(cy), fg)
            }
        }
    }

    // The copy cursor: a thin line at the top edge of its line, marking where a copy reads
    // from. Hidden at the bottom input line.
    if term.sel_active {
        if sr := term.sel_head - v.top; sr >= 0 && sr < v.rows {
            gfx.caret(t, gfx.Rect{r.x, r.y + i32(sr) * rh, r.w, max(1, gfx.hairline(f32(rh)))}, th.accent)
        }
    }

    // The ClayCustom contract: the painter ends with its own flush.
    gfx.flush_pane(t, clip, win_w, win_h)
}

// The active session's cell grid. The view is built twice, not to re-aim a tween but because
// the click can change WHICH lines are on screen: clicking the live bottom leaves select mode,
// and terminal_view_top then answers differently.
terminal_frame :: proc(t: ^gfx.Draw, a: ^App, pane: gfx.Rect, now: f64) {
    u := ctx_of(a)
    area, row_h, cols, rows := terminal_geom(pane, gfx.face(t).line_height, gfx.face(t).cell_w)
    if cols == 0 || rows == 0 {
        return
    }
    term := term_current(a)
    if term == nil { // the pane shown before a session exists
        return // declaring nothing leaves the pane as panel() painted it
    }

    // The pointer is over the grid the LAST frame painted, so the click resolves against a view
    // built before this frame's resize reaches the session.
    v := terminal_view(term, area, row_h, gfx.face(t).cell_w, cols, rows)
    hit := terminal_hit(u, term, v)
    terminal_click(u, term, a.term_active, hit)
    terminal_drag(u, term, v, a.term_active, clock.now()) // extend a capture the press already made
    terminal_track(term, hit)

    terminal_sync(term, &a.theme, cols, rows)
    v = terminal_view(term, area, row_h, gfx.face(t).cell_w, cols, rows)

    // `now` is the switcher's fade; the grid does not animate.
    terminal_declare(u, a, gfx.face(t), term, v, now)
}

// Test-facing wrapper; see filetree_layout.
terminal_layout :: proc(
    a: ^App,
    face: gfx.Face,
    term: ^pty.Terminal,
    win_w, win_h: i32,
    v: Terminal_View,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        terminal_declare(ctx_of(a), a, face, term, v, now)
    }
    return clay.EndLayout(0)
}
