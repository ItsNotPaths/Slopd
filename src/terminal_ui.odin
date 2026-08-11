package main

import "core:math"
import "vendor:glfw"
import clay "../bindings/clay"

// The terminal pane's UI half. **Clay owns the frame, we own the body:** a 200x60 grid is 12k
// cells, so the pane declares ONE `Custom` and the painter fills the box Clay reserves.
// Everything the phases must agree about lives in `Terminal_View`; the two writes that are not
// painting live in terminal_sync, before anything is declared.
//
// **Two mouse behaviours, and which is live is the TUI's choice.** A TUI with mouse tracking
// on (`t.mouse_on`) means the pointer is ITS input; otherwise a click is ours, as a
// per-character selection built on terminal.odin's msel verbs. Where a click goes:
//
//   plain, TUI has the mouse      forwarded — the TUI decides what a click there means
//   plain, TUI does not           local: place the selection at that character
//   Shift, TUI has the mouse      LOCAL — Shift is the override (xterm's convention)
//   Shift, TUI does not           local, EXTENDING the selection from its anchor
//   Ctrl                          forwarded as MOD_CTRL on the forward path; ignored local
//   Alt                           nothing at all
//
// Shift does both jobs at once, which is one condition rather than two rival meanings
// (alacritty: `shift_key() || !mouse_mode()`). Keyed on `t.mouse_on` alone, never on whether
// this click COULD have been forwarded — the user cannot see what scrolled into history.
// Alt is global here as it is to the keyboard.

// The box, the cell grid, and which absolute line is drawn at the top row. `cols`/`rows` are
// the PANE's, not the session's: they agree for the whole frame after terminal_sync, but not
// before, so the two differ for exactly one frame after a resize and the hit test must care.
Terminal_View :: struct {
    area:  Rect,
    cw:    f32,
    row_h: i32,
    cols:  int,
    rows:  int,
    top:   int, // absolute line at the top row (terminal_view_top: live bottom, or scrolled)
}

// The content area inside the focus ring and the cell grid that fits it. No row padding — a
// terminal's rows are the line height exactly, so box-drawing characters meet. A degenerate
// pane reports ZERO rows (unlike the list panes' one): `rows` goes out via TIOCSWINSZ.
terminal_geom :: proc(pane: Rect, scale: f32, line_h: f32, cell_w: f32) -> (area: Rect, row_h: i32, cols, rows: int) {
    area = inset(pane, i32(2 * scale))
    row_h = max(1, i32(line_h))
    if area.w <= 0 || area.h <= 0 || cell_w <= 0 {
        return area, row_h, 0, 0
    }
    cols = max(1, int(f32(area.w) / cell_w))
    rows = max(1, int(area.h / row_h))
    return
}

// Tell the session how big the pane is (a no-op when unchanged, and the ioctl the child
// watches for SIGWINCH) and re-seed the default colours so a theme or font change follows.
// GL-free, and runs before anything is declared rather than as a side effect of painting.
terminal_sync :: proc(term: ^Terminal, th: ^Theme, cols, rows: int) {
    terminal_resize(term, rows, cols)
    terminal_set_default_colors(term, th.fg, th.bg)
}

// Build the view. Pure, unlike the editor's — the terminal's viewport is an integer line, so
// there is no tween to re-aim. terminal_frame still calls it twice, for its own reason.
terminal_view :: proc(term: ^Terminal, area: Rect, row_h: i32, cw: f32, cols, rows: int) -> Terminal_View {
    return Terminal_View {
        area  = area,
        cw    = cw,
        row_h = row_h,
        cols  = cols,
        rows  = rows,
        top   = terminal_view_top(term),
    }
}

// What the pointer is over. `live` gates forwarding — the TUI has no idea our scrollback
// exists. `bcol` is the nearest BOUNDARY where `col` is the cell it is inside: a selection
// end needs one, a cell report the other.
Terminal_Hit :: struct {
    ok:   bool,
    row:  int,
    col:  int, // the cell the pointer is INSIDE — floored; what a TUI is told
    bcol: int, // the boundary it is NEAREST — rounded; where a selection ends
    line: int,
    live: bool,
}

// Resolve the pointer against the grid. Not clay.PointerOver — one box, one comparison. `col`
// FLOORS because a mouse report names a CELL; `bcol` rounds beside it for selection. The
// sub-cell remainder is not a cell and so not a hit.
terminal_hit :: proc(a: ^App, term: ^Terminal, v: Terminal_View) -> Terminal_Hit {
    if !a.mouse_on || !a.mouse.known || term == nil || v.rows <= 0 || v.cols <= 0 || v.row_h <= 0 || v.cw <= 0 {
        return {}
    }
    // Not gated on a.mouse.stood_down: standing the pointer down suppresses HOVER, never a
    // click (mouse.odin), and this pane paints no hover at all — the cells belong to the
    // child process, which is not ours to tint.
    if !rect_hit(v.area, a.mouse.x, a.mouse.y) {
        return {}
    }
    row := int((a.mouse.y - v.area.y) / v.row_h)
    col := int(f32(a.mouse.x - v.area.x) / v.cw)
    if row >= v.rows || col >= v.cols {
        return {} // the sub-cell remainder along the bottom / right edge
    }
    bcol := terminal_boundary_col(v, a.mouse.x)
    n := v.top + row
    // The view's row count is the PANE's and the session's is what the last resize left, so
    // for one frame after the window grows there are screen rows with no grid row behind
    // them. Those resolve as history rather than as a cell the TUI does not have.
    live := n >= term.sb_total && n - term.sb_total < term.rows
    return Terminal_Hit{ok = true, row = row, col = col, bcol = bcol, line = n, live = live}
}

// The cell BOUNDARY nearest x, in 0..=cols — rounded, where the hit's `col` floors, and
// clamped to the grid so a drag out the side of the pane ends cleanly at an edge rather than
// off it. The twin of editor_caret_col, and the reason this pane needed no `side` field.
terminal_boundary_col :: proc(v: Terminal_View, x: i32) -> int {
    if v.cw <= 0 {
        return 0
    }
    return clamp(int(math.round(f32(x - v.area.x) / v.cw)), 0, v.cols)
}

// Keep a mouse-tracking TUI's pointer where ours is. Every frame the pane draws: libvterm
// drops an unchanged cell and emits nothing unless the TUI asked for motion, so doing it
// unconditionally costs one comparison in C. Not gated on focus — hover is about position.
terminal_track :: proc(term: ^Terminal, hit: Terminal_Hit) {
    if term == nil || !term.mouse_on || !hit.ok || !hit.live {
        return
    }
    terminal_mouse_at(term, hit.line - term.sb_total, hit.col)
}

// Apply a pending click — the table at the top of this file, in code. Alt is checked BEFORE
// the claim: "Alt+click does nothing here" rather than "is swallowed here", since the
// switcher may want that press. The COUNT chooses GRANULARITY, not the verb.
terminal_click :: proc(a: ^App, term: ^Terminal, hit: Terminal_Hit) {
    if !hit.ok || term == nil {
        return
    }
    if a.mouse.click_alt {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    if term.mouse_on && !a.mouse.click_shift && hit.live {
        terminal_mouse_tap(term, hit.line - term.sb_total, hit.col, a.mouse.click_ctrl)
        return
    }
    // Local from here. The press captures, so the rest of the gesture is this session's
    // however far the pointer roams — and the grade goes in with it, because a
    // double-click-drag has to keep expanding by whole words.
    drag_begin(a, .Terminal_Sel, a.term_active, count, Pos{hit.line, hit.bcol}, hit.col)

    bound := Pos{hit.line, hit.bcol}
    cell := Pos{hit.line, hit.col}
    switch {
    case count >= 2:
        anchor, head := terminal_grade_span(term, count, cell, cell)
        terminal_msel_set(term, anchor, head)
    case a.mouse.click_shift:
        terminal_msel_head(term, bound)
    case:
        terminal_msel_set(term, bound, bound)
    }
}

// Where a drag POINTS, which is not where a hit lands — the split the editor draws. A hit
// outside the pane is refused; a drag under capture answers wherever the pointer went. The
// ROW is clamped rather than the pixel, or the sub-cell remainder would take the selection.
terminal_drag_pos :: proc(a: ^App, v: Terminal_View) -> (bound, cell: Pos) {
    if v.rows <= 0 || v.cols <= 0 || v.row_h <= 0 || v.cw <= 0 {
        return {}, {}
    }
    // Both divisions truncate toward zero, so a pointer above or left of the pane lands on
    // 0 or just below it and the clamps finish the job — there is no "above the window"
    // answer to distinguish here the way editor_row_at has to.
    row := clamp(int((a.mouse.y - v.area.y) / v.row_h), 0, v.rows - 1)
    col := clamp(int(f32(a.mouse.x - v.area.x) / v.cw), 0, v.cols - 1)
    n := v.top + row
    return Pos{n, terminal_boundary_col(v, a.mouse.x)}, Pos{n, col}
}

// The absolute line a drag extends to: the pointer's inside the pane, the autoscroll's walk
// past an edge. **This pane scrolls the view ITSELF**, where the editor leaves it to a policy
// that chases the caret — nothing chases anything here, so the walk moves `view_top`.
terminal_drag_line :: proc(a: ^App, term: ^Terminal, v: Terminal_View, line: int, now: f64) -> int {
    past, dir := 0, 0
    switch {
    case a.mouse.y < v.area.y:
        past, dir = int(v.area.y - a.mouse.y), -1
    case a.mouse.y >= v.area.y + v.area.h:
        past, dir = int(a.mouse.y - (v.area.y + v.area.h) + 1), 1
    }
    if dir == 0 {
        a.drag.over_on = false
        return line
    }
    if !a.drag.over_on {
        a.drag.over, a.drag.over_on = line, true
    }
    if drag_tick(a, now) {
        floor := term.on_altscreen ? term.sb_total : terminal_oldest(term)
        a.drag.over = clamp(a.drag.over + dir * drag_scroll_step(past, int(v.row_h)), floor, terminal_bottom(term))
        if a.drag.over < term.view_top {
            term.view_top = a.drag.over
        } else if a.drag.over > term.view_top + v.rows - 1 {
            term.view_top = a.drag.over - v.rows + 1
        }
        term.view_top = clamp(term.view_top, floor, term.sb_total)
    }
    return a.drag.over
}

// Extend a live selection drag, run beside terminal_click because both can change which lines
// are on screen. Only the LOCAL half drags: a forwarded click is a tap, and dragging over a
// mouse-tracking TUI is its own business (terminal_track already feeds it every motion).
terminal_drag :: proc(a: ^App, term: ^Terminal, v: Terminal_View, now: f64) {
    if !a.mouse_on || !a.mouse.known || term == nil {
        return
    }
    if !drag_live(a, .Terminal_Sel, a.term_active) {
        return
    }
    bound, cell := terminal_drag_pos(a, v)
    line := terminal_drag_line(a, term, v, bound.line, now)

    if a.drag.grade >= 2 {
        anchor, head := terminal_grade_span(
            term,
            a.drag.grade,
            Pos{a.drag.anchor.line, a.drag.anchor_glyph},
            Pos{line, cell.col},
        )
        terminal_msel_set(term, anchor, head)
        return
    }
    terminal_msel_head(term, Pos{line, bound.col})
}

// What the grid's Custom needs to paint itself. Handed to the bridge as `customData`, so it
// must outlive EndLayout — it lives in the frame's temp arena, like every other pane's.
Terminal_Body :: struct {
    term: ^Terminal,
    v:    Terminal_View,
}

// Declare the pane into the window's tree. The Custom covers the whole content area, not the
// whole-cell grid inside it, so the painter's box IS the box the hit test sized itself from.
//   term_pane    the content area inside the focus ring, clipping its own content
//     term_grid    the cell grid, as a Custom — the element terminal_hit points at
//     sw_col       the Alt-held switcher (overlay_ui.odin), a floating child over the grid
terminal_declare :: proc(a: ^App, f: ^Font, term: ^Terminal, v: Terminal_View, now: f64 = 0) {
    area := v.area

    body := new(Terminal_Body, context.temp_allocator)
    body^ = Terminal_Body{term = term, v = v}
    cu := new(ClayCustom, context.temp_allocator)
    cu^ = ClayCustom{paint = terminal_paint_grid, user = body}

    // No backgroundColor: panel() already filled the pane, and Clay's transparent default
    // emits no Rectangle — so the command list is the Custom inside the pane's clip.
    if clay.UI(clay.ID("term_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("term_grid"))(
            {
                layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                custom = {customData = cu},
            },
        ) {}

        // After the grid and inside the pane: a floating child, so it inherits the pane's
        // clip and paints in its own group. It would survive without one here (a Custom
        // flushes on the way out), but that is an accident of this pane's shape.
        if switcher_shown(a) {
            switcher_declare(a, f, area, now)
        }
    }
}

// The absolute lines the KEYBOARD's copy cursor highlights, half-open; empty when there is no
// span. Out of the painter for terminal_msel_row_span's reason — a headless test cannot
// follow one, so this is where the boundary-versus-line reading becomes assertable.
terminal_sel_row_span :: proc(term: ^Terminal) -> (lo, hi: int) {
    if !term.sel_active {
        return 0, 0
    }
    a, b := terminal_sel_range(term)
    return a, b
}

// Whether absolute line `n` is inside that highlight — the COMPARISON, not just the range,
// because `n <= hi` and `n < hi` are the bug and the fix. Per row, so it can afford to be a
// call; the mouse's per-CELL test stays inline, running 12k times a frame.
terminal_sel_row_shown :: proc(term: ^Terminal, n: int) -> bool {
    lo, hi := terminal_sel_row_span(term)
    return n >= lo && n < hi
}

// The columns of absolute line `n` the mouse selection covers, half-open and empty on every
// line it does not reach: first line from lo.col, last to hi.col, interior filled — the clip
// editor_paint_body applies to a text selection. Out of the painter so it is assertable.
terminal_msel_row_span :: proc(term: ^Terminal, n, cols: int) -> (lo, hi: int) {
    if !terminal_msel_has_span(term) {
        return 0, 0
    }
    a, b := cursor_range(term.msel)
    if n < a.line || n > b.line {
        return 0, 0
    }
    lo = n == a.line ? a.col : 0
    hi = n == b.line ? b.col : cols
    return clamp(lo, 0, cols), clamp(hi, 0, cols)
}

// The cell grid: the default background in one quad, then per cell a fill only where it
// differs, the glyph, and a reverse-video block at the cursor. Positions come from `r`, the
// box the solver resolved, not v.area — tests/terminal_ui_test.odin pins the equality.
terminal_paint_grid :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    g := (^Terminal_Body)(user)
    if g == nil || g.term == nil {
        return
    }
    term := g.term
    v := g.v
    th := &a.theme
    cw := v.cw
    rh := v.row_h

    fill(t, r, th.bg) // default background for the whole grid in one quad
    cur_row, cur_col := terminal_cursor(term)

    // Scroll-aware view: each on-screen row maps to an absolute line (top + row),
    // pulling from the live grid or scrollback. While selecting, the block cursor is
    // suppressed and the selected line range tints with th.selection.

    glyph: [1]rune
    for row in 0 ..< v.rows {
        n := v.top + row
        row_sel := terminal_sel_row_shown(term, n)
        msel_a, msel_b := terminal_msel_row_span(term, n, v.cols)
        cy := r.y + i32(row) * rh
        for col in 0 ..< v.cols {
            cell := terminal_view_cell(term, n, col) or_continue

            fg, fdef := terminal_color(term, cell.fg)
            if fdef {
                fg = th.fg
            }
            bg, bdef := terminal_color(term, cell.bg)
            if bdef {
                bg = th.bg
            }
            // The block cursor is reverse video (live grid only, not while scrolling);
            // XOR with the cell's own reverse attr.
            is_cursor := !term.sel_active && n == term.sb_total + cur_row && col == cur_col
            if cell.attrs.reverse != is_cursor {
                fg, bg = bg, fg
            }
            if row_sel || (col >= msel_a && col < msel_b) { // the glyph stays on top
                bg = th.selection
            }

            // Tile cell x-edges off the same fractional grid as the glyphs so the bg
            // fills meet exactly (no seams, no overlap).
            x0 := i32(f32(r.x) + cw * f32(col))
            x1 := i32(f32(r.x) + cw * f32(col + 1))
            if bg != th.bg {
                fill(t, Rect{x0, cy, x1 - x0, rh}, bg)
            }
            if ch := rune(cell.chars[0]); ch >= 0x20 {
                glyph[0] = ch
                text_draw_runes(t, glyph[:], f32(x0), f32(cy), fg)
            }
        }
    }

    // The copy cursor: a thin line drawn at the top edge of its line (sitting between
    // it and the line above), marking where a copy reads from. Hidden at the bottom
    // input line (sel_active off).
    if term.sel_active {
        if sr := term.sel_head - v.top; sr >= 0 && sr < v.rows {
            caret(t, Rect{r.x, r.y + i32(sr) * rh, r.w, max(1, i32(2 * a.scale))}, th.accent)
        }
    }

    // The painter owns its region and ends with its own flush (the ClayCustom contract).
    // `clip` arrives already intersected with the box, so this is the whole obligation.
    flush_pane(t, clip, win_w, win_h)
}

// The terminal pane: the active session's libvterm cell grid. The view is built twice, not to
// re-aim a tween but because the click can change WHICH lines are on screen — clicking the
// live bottom leaves select mode, and terminal_view_top answers differently the moment it does.
terminal_frame :: proc(t: ^Text, a: ^App, pane: Rect, now: f64) {
    area, row_h, cols, rows := terminal_geom(pane, a.scale, t.font.line_height, t.font.cell_w)
    if cols == 0 || rows == 0 {
        return
    }
    term := term_current(a)
    if term == nil { // pane shown before a session exists (shouldn't happen — lazy spawn)
        return // declaring nothing leaves the pane as panel() painted it
    }

    // The grid the LAST frame painted is what the pointer is over, so the click resolves
    // against a view built before this frame's resize reaches the session.
    v := terminal_view(term, area, row_h, t.font.cell_w, cols, rows)
    hit := terminal_hit(a, term, v)
    terminal_click(a, term, hit)
    terminal_drag(a, term, v, glfw.GetTime()) // and extend a capture the press already made
    terminal_track(term, hit)

    terminal_sync(term, &a.theme, cols, rows)
    v = terminal_view(term, area, row_h, t.font.cell_w, cols, rows)

    // `now` is the switcher's fade and nothing else — the grid does not animate.
    terminal_declare(a, &t.font, term, v, now)
}

// Test-facing wrapper; see filetree_layout.
terminal_layout :: proc(
    a: ^App,
    f: ^Font,
    term: ^Terminal,
    win_w, win_h: i32,
    v: Terminal_View,
    now: f64 = 0,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        terminal_declare(a, f, term, v, now)
    }
    return clay.EndLayout(0)
}
