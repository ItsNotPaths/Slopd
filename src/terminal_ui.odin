package main

import "core:math"
import "vendor:glfw"
import clay "../bindings/clay"

// The terminal pane's UI half — C7b, and the second surface on the far side of the boundary
// docs/clay-refactor.md draws: **Clay owns the frame, we own the body.** A 200x60 grid is
// 12k cells with per-cell foreground, background and reverse video; one widget per cell is
// absurd, so the pane declares ONE `Custom` element and the existing painter fills the box
// Clay reserves. Nothing about how a cell is drawn changed here; it is a straight port, the
// same way C7a ported the editor.
//
// What the port buys is the same thing it bought there — the geometry. draw_terminal used
// to compute the content area, the cell size, the column and row counts as locals and throw
// them away, which is why a click had nothing to resolve against. All of it is
// `Terminal_View` now, and the two things that must agree — where a cell is PAINTED and
// which cell a pixel is READ BACK as — are derived from the same fields.
//
// It also moves a write out of the paint. draw_terminal called terminal_resize and
// terminal_set_default_colors as a side effect of drawing, which is precisely the shape the
// list panes' `.scroll` writes had; both live in terminal_sync now and run before anything
// is declared.
//
// **The pane has two mouse behaviours, and which one is live is the TUI's choice, not
// ours.** A full-screen application that has enabled mouse tracking (`t.mouse_on`, set from
// libvterm's PROP_MOUSE) means the pointer is ITS input, so a click is encoded and written
// to the PTY. Otherwise the click is ours. Shift is the override between them, which is
// xterm's convention and the one every terminal user already has in their fingers.
//
// THE LOCAL HALF IS INTERIM AND KNOWN WRONG — see the click table below and C7d in
// docs/clay-refactor.md. It drives the keyboard's row-granular copy cursor, and a pointer
// addresses a CHARACTER; the replacement is per-character selection on top of C7c's drag
// machine. It ships in the meantime because a coarse pointer beats a dead one.

// Where a click goes, and why the modifiers are spent the way they are:
//
//   plain, TUI has the mouse      forwarded — the TUI decides what a click there means
//   plain, TUI does not           local  [interim: the copy cursor's line; C7d: a character]
//   Shift, TUI has the mouse      LOCAL — Shift is the override (xterm)
//   Shift, TUI does not           local, EXTENDING the selection from the anchor
//   Ctrl                          forwarded as MOD_CTRL on the forward path; ignored local
//   Alt                           nothing at all
//
// **Shift is the override, and at C7d it extends as well — those are not rival meanings.**
// This code spends Shift on ONE of the two jobs (`click_shift && !term.mouse_on` below), on
// the reasoning that a modifier cannot mean two things at once. That reasoning is wrong, and
// only looked right because a row-granular copy cursor has no anchor worth extending:
// alacritty gates both jobs on one condition (`shift_key() || !mouse_mode()`), so Shift+click
// over a mouse-tracking TUI keeps the click local AND extends. C7d composes them.
//
// What is right about the rule and survives: it is keyed on `t.mouse_on` alone, never on
// whether this particular click COULD have been forwarded. The user can see which
// application is running and cannot see whether the line under the pointer happens to have
// scrolled into our history, so a Shift that behaved differently for that reason would be
// unpredictable from something invisible on screen.
//
// **Alt is global here for the same reason it is global to the keyboard.** input.odin
// handles Alt-chords before the shell ever sees them, so an Alt+click that reached the TUI
// would be the one place the rule broke — and while Alt is held the switcher overlay is up
// over this pane anyway, so a press belongs to whatever C8 makes of that. Until then it is
// simply not claimed.

// Everything the pane's phases need to agree about: the box, the cell grid, and which
// absolute line is drawn at the top row.
//
// `cols` and `rows` are the pane's, not the session's. They are the same number for the
// whole frame after terminal_sync runs, and deliberately not before: the click resolves
// against the grid the LAST frame painted, so the two can differ for exactly one frame
// after a resize, and the hit test is the half that has to be careful about it.
Terminal_View :: struct {
    area:  Rect,
    cw:    f32,
    row_h: i32,
    cols:  int,
    rows:  int,
    top:   int, // absolute line at the top row (terminal_view_top: live bottom, or scrolled)
}

// The pane's fixed geometry: the content area inside the focus ring, and the cell grid that
// fits in it. Pure, and the same shape as every other pane's `_geom`.
//
// There is no row padding — the twin of EDITOR_ROW_PAD is deliberately absent. A terminal's
// rows are the font's line height exactly, because the child process is drawing a grid and
// box-drawing characters have to meet across it.
//
// A degenerate pane reports zero rows AND zero columns, where the list panes report at
// least one row: `rows` here is a number Slopd hands to another process through TIOCSWINSZ,
// so "one row so the clip has something to cut" would be a lie told to a shell rather than
// a rounding convenience. draw_terminal bails instead.
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

// The writes that used to be side effects of painting: tell the session how big the pane is
// (a no-op when unchanged, and the ioctl the child watches for SIGWINCH) and re-seed the
// default colours so a theme or font change follows. GL-free, and runs before anything is
// declared — the same move C3/C5 made for each list pane's `.scroll`.
terminal_sync :: proc(term: ^Terminal, th: ^Theme, cols, rows: int) {
    terminal_resize(term, rows, cols)
    terminal_set_default_colors(term, th.fg, th.bg)
}

// Build the view. Pure, unlike the editor's — there is no tween to re-aim, because the
// terminal's viewport is an integer line and always has been (the copy cursor moves it in
// whole lines and the live grid is bottom-aligned). draw_terminal still calls it twice, but
// for a different reason: see there.
terminal_view :: proc(term: ^Terminal, area: Rect, row_h: i32, cw: f32, cols, rows: int) -> Terminal_View {
    return Terminal_View {
        area = area,
        cw = cw,
        row_h = row_h,
        cols = cols,
        rows = rows,
        top = terminal_view_top(term),
    }
}

// What the pointer is over: a cell of the grid, named three ways because three different
// things want it.
//
//   row/col   the on-screen cell, which is what the paint uses
//   line      its ABSOLUTE line, which is what the copy cursor walks (scrollback included)
//   live      whether that line is a row of the live grid rather than captured history
//
// `live` is the gate on forwarding and nothing else: the TUI has no idea our scrollback
// exists, so a click on a line that scrolled off has no cell to report and must stay local.
//
// C7d added the fourth, `bcol`: the BOUNDARY between cells the pointer is nearest, where
// `col` is the cell it is inside. A selection end needs the boundary — that is what lets it
// include the character you are pointing at — and a cell report to a TUI needs the cell.
//
// alacritty carries the same information as `Anchor { point, side: Left | Right }`, computed
// against the half-cell width. A boundary column in 0..=cols says it in one number, and the
// number is directly comparable, so `cursor_range` orders a pair of these unmodified. Same
// fact, one less field to keep consistent.
Terminal_Hit :: struct {
    ok:   bool,
    row:  int,
    col:  int, // the cell the pointer is INSIDE — floored; what a TUI is told
    bcol: int, // the boundary it is NEAREST — rounded; where a selection ends
    line: int,
    live: bool,
}

// Resolve the pointer against the grid. As in C7a this is DELIBERATELY NOT clay.PointerOver
// — the body is one element, so there is no tree question to ask, and asking one would tie
// the pane to being the last to declare (invariant 11, docs/clay-refactor.md). Here that
// happens to be true, since the terminal IS the aux pane and the aux pane draws last; the
// rect is used anyway, because "correct only while nothing draws after me" is not a property
// worth depending on when the alternative is one comparison.
//
// The column FLOORS for `col`, because a terminal mouse report names a CELL — a TUI is told
// which character the pointer is on, and there is no insertion point between two cells for
// that answer to land on. **And that is the whole truth for FORWARDING and only half of it
// for SELECTION**, which this comment denied until the integration pass: C7a's
// boundary-versus-glyph split does recur here, it just never touched the forwarding path
// that C7b's eighteen mutations all tested. A selection end needs the BOUNDARY or it cannot
// include the character you are pointing at, so `bcol` rounds beside the floor (C7d).
//
// A pane taller or wider than a whole number of cells has a remainder strip at its bottom
// and right edge. That strip is not a cell, so it is not a hit — under a row height it is
// invisible either way, and inventing the nearest cell would report a click the user did
// not make to somebody else's program.
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
    // The clamp gate, the twin of doc_clamp_pos (C7a): the view's row count is the PANE's
    // and the session's is what the last resize left, so for one frame after the window
    // grows there are screen rows with no grid row behind them. Those resolve as history
    // rather than as a cell the TUI does not have.
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

// Keep a mouse-tracking TUI's pointer where ours is. Called every frame the pane draws,
// which is every frame a motion event arrives; libvterm drops the call when the cell has
// not changed and emits nothing unless the TUI asked for motion, so the cost of doing this
// unconditionally is one comparison in C (terminal_mouse_at).
//
// It is not gated on focus. Hover in a TUI is a property of where the pointer IS, not of
// which pane owns the keyboard — and focus-follows-click is C8's question for every pane at
// once, not one this pane gets to answer early by itself.
terminal_track :: proc(term: ^Terminal, hit: Terminal_Hit) {
    if term == nil || !term.mouse_on || !hit.ok || !hit.live {
        return
    }
    terminal_mouse_at(term, hit.line - term.sb_total, hit.col)
}

// Apply a pending click — the table at the top of this file, in code.
//
// The press is claimed only when a cell was actually hit, so a press aimed at another pane
// is not eaten. Alt is checked BEFORE the claim rather than after, which is the difference
// between "Alt+click does nothing here" and "Alt+click is swallowed here": the switcher
// overlay is up while Alt is held and C8 may well want that press.
//
// Nothing is stamped and nothing is re-attached, unlike C7a's editor click. The terminal
// keeps its view and its selection apart already (wheel_apply says the same thing from the
// other side), so there is no detached state for a click to resume from, and the block
// cursor is the child process's, not a blinking caret of ours.
//
// The click COUNT chooses the GRANULARITY, not the verb (C7d). There is one verb here —
// selection — and single / double / triple are character, word and line, which is
// alacritty's `Simple` / `Semantic` / `Lines`. C7b left the count unused on the reasoning
// that a terminal line has no Enter verb for a double click to reach; true, and it answered
// the wrong question. What that code did for a SINGLE click is what a TRIPLE click should
// do, which was the tell that the model underneath it was the keyboard's.
//
// On the forward path the count is still not ours to interpret, and that part stands: xterm
// sends one press per physical press and the application does its own timing. See
// terminal_mouse_tap.
//
// **Shift both overrides mouse mode and extends**, which C7b said it could not. alacritty
// gates the two on one condition (`shift_key() || !mouse_mode()`) because they are not rival
// meanings — "keep this click local" and "grow the existing selection" compose fine. They
// only looked rival while the local half had a row-granular cursor with no anchor worth
// extending.
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
    // however far the pointer roams (C7c) — and the grade goes in with it, because a
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

// Where a drag POINTS, which is not where a hit lands — the same split C7a and C7c drew in
// the editor, arriving here unchanged. A hit outside the pane is refused because a press
// there belongs to somebody else; a drag under capture answers wherever the pointer went.
//
// The ROW is clamped rather than the pixel, for the editor's reason: the pane's bottom edge
// sits inside a row that was never painted (the sub-cell remainder), and a pixel clamp would
// aim the selection at it.
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

// The absolute line a drag should be extending to — the pointer's own while it is inside the
// pane, and the autoscroll's walk while it is past an edge (C7c's `Drag.over`, in this
// client's units).
//
// **This pane scrolls the view ITSELF, where the editor's client does not**, and the
// difference is not a taste one. The editor has a viewport policy that chases the caret, so
// walking the selection is enough and `b.scroll` is left to it. Nothing chases anything
// here: `view_top` is moved explicitly or not at all. So the walk moves it, using
// terminal_sel_move's own idiom for keeping a cursor on screen — which is where that
// arithmetic already lived.
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

// Extend a live selection drag — the pointer's per-frame verb, run beside terminal_click for
// C7a's reason: the click can change which lines are on screen, and so can this.
//
// Only the LOCAL half of the pane drags. A click forwarded to a mouse-tracking TUI is a tap
// (move, press, release) and dragging over it is the TUI's own business — terminal_track
// already feeds it every motion, and libvterm filters by the mode it asked for. So no
// capture is begun on the forward path and none is consumed here.
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

// Declare the pane and hand back the frame's command list. Three elements, the same shape
// C7a settled on:
//
//   term_root  full-window container, padded to the pane's origin
//     term_pane  the content area inside the focus ring (painted by panel(), not here)
//       term_grid  the cell grid, as a Custom — and the element terminal_hit points at
//
// The Custom covers the whole content area rather than the whole-cell grid inside it, so
// the box the painter is handed is the box the hit test sized itself from. The sub-cell
// remainder is inside that box, painted with the default background like every other blank
// cell, and rejected by the hit test rather than by the geometry.
terminal_layout :: proc(a: ^App, term: ^Terminal, pane: Rect, win_w, win_h: i32, v: Terminal_View) -> clay.ClayArray(clay.RenderCommand) {
    area := v.area

    body := new(Terminal_Body, context.temp_allocator)
    body^ = Terminal_Body{term = term, v = v}
    cu := new(ClayCustom, context.temp_allocator)
    cu^ = ClayCustom{paint = terminal_paint_grid, user = body}

    clay_resize(win_w, win_h)
    clay.BeginLayout()

    if clay.UI(clay.ID("term_root"))(
        {
            layout = {
                sizing = {clay.SizingFixed(f32(win_w)), clay.SizingFixed(f32(win_h))},
                padding = {left = u16(max(0, area.x)), top = u16(max(0, area.y))},
            },
        },
    ) {
        // No backgroundColor: panel() has already filled the pane and drawn its focus ring,
        // and Clay's transparent default emits no Rectangle at all — so this pane's command
        // list is the Custom and nothing else, which is what the test asserts.
        if clay.UI(clay.ID("term_pane"))(
            {
                layout = {
                    sizing = {clay.SizingFixed(f32(area.w)), clay.SizingFixed(f32(area.h))},
                    layoutDirection = .TopToBottom,
                },
            },
        ) {
            if clay.UI(clay.ID("term_grid"))(
                {
                    layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                    custom = {customData = cu},
                },
            ) {}
        }
    }

    return clay.EndLayout(0)
}

// The absolute lines the KEYBOARD's copy cursor highlights, as a half-open range — empty
// when there is no span to draw. Out of the painter for terminal_msel_row_span's reason: a
// painter is where a headless test cannot follow, so arithmetic left inside it is arithmetic
// nothing can assert, and this is where the boundary-versus-line reading shows on screen.
terminal_sel_row_span :: proc(term: ^Terminal) -> (lo, hi: int) {
    if !term.sel_active {
        return 0, 0
    }
    a, b := terminal_sel_range(term)
    return a, b
}

// Whether absolute line `n` is inside that highlight. The COMPARISON and not just the range,
// because `n <= hi` and `n < hi` are the bug and the fix and a proc returning the pair cannot
// tell them apart — the mutation that flips it lives here, so the assertion has to as well.
//
// Per row, which is why it can afford to be a call. The mouse selection's per-CELL test stays
// inline against terminal_msel_row_span's pair: that one runs 12k times a frame, and it is a
// direct application of a half-open span whose ends are themselves asserted.
terminal_sel_row_shown :: proc(term: ^Terminal, n: int) -> bool {
    lo, hi := terminal_sel_row_span(term)
    return n >= lo && n < hi
}

// The columns of absolute line `n` covered by the mouse selection, as a half-open span —
// empty (lo == hi) on every line it does not reach. The first line starts at lo.col, the
// last stops at hi.col, the interior fills: the same clip editor_paint_body applies to a
// text selection, which is one of the four things the shared vocabulary was chosen for.
//
// Pulled out of the painter rather than written inline, and not for tidiness: a painter is
// the one place in this refactor a headless test cannot follow, so the arithmetic inside it
// is the arithmetic nothing can assert. Out here it is a value, and the row-versus-cell
// distinction that C7d is entirely about can be pinned directly.
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

// The cell grid: the default background in one quad, then each cell — a per-cell background
// fill only when it differs from the default (terminals are mostly default-bg, so that
// stays cheap), the glyph on top, and a reverse-video block at the cursor. Colours come from
// the session (theme fg/bg for default cells); the reverse attr swaps fg and bg. Unchanged
// from the draw_terminal that lived in render.odin, beyond taking its box from Clay instead
// of computing one.
//
// Positions come from `r`, the box the solver resolved, and not from v.area, even though the
// two are equal by construction — reading the box is the contract, and the equality is what
// tests/terminal_ui_test.odin pins.
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

// The terminal pane: the active session's libvterm cell grid.
//
// The order is the template's, and the view is built twice for a reason of this pane's own.
// It is not C5c's re-aim — nothing tweens here — it is that the click can change WHICH lines
// are on screen: clicking the live bottom line leaves select mode, and terminal_view_top
// reports the live bottom rather than the scrolled top the moment it does. Declaring from
// the pre-click view would paint one frame of the state the user just left.
draw_terminal :: proc(t: ^Text, pane: Rect, win_w, win_h: i32, a: ^App) {
    area, row_h, cols, rows := terminal_geom(pane, a.scale, t.font.line_height, t.font.cell_w)
    if cols == 0 || rows == 0 {
        return
    }
    term := term_current(a)
    if term == nil { // pane shown before a session exists (shouldn't happen — lazy spawn)
        flush_pane(t, area, win_w, win_h)
        return
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

    cmds := terminal_layout(a, term, pane, win_w, win_h, v)
    clay_paint(t, a, &cmds, area, win_w, win_h)
}
