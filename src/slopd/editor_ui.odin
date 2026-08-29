package main

import "core:math"
import "core:strconv"
import clay "../../bindings/clay"
import "../txt"
import "../gfx"
import "../ui"
import "../edit"

// The editor pane's UI half. Clay owns the frame, we own the body: the text is a 2D per-glyph
// surface, so the pane declares one `Custom` and the painter fills the box Clay reserves.
// Everything the phases must agree about lives in `Editor_View`, so where a glyph is painted
// and where a pixel reads back as a Pos cannot drift. The view is built twice, either side of
// the click, because a click that moves the caret re-aims the scroll animation.

// Digits. A file under ten lines still gets two, so the text column does not jitter.
EDITOR_GUTTER_MIN :: 2

// Cells past the end of a folded header its marker may be clicked. Wider than the paint; a
// miss only puts the caret at end-of-line.
EDITOR_FOLD_HIT_CELLS :: 2

// The buffer-dependent half (gutter, animated top) is editor_view. A pane with no room for a
// whole row reports none: the content area is the grid, and half a row is not part of it.
editor_geom :: proc(pane: gfx.Rect, line_h, cell_w: f32) -> (area: gfx.Rect, row_h: i32, rows: int) {
    area = gfx.grid_snap(ui.inset(pane, gfx.edge(line_h)), cell_w, line_h)
    row_h = gfx.row(line_h)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, 0
    }
    rows = max(1, int(area.h / row_h))
    return
}

// Wide enough for the last line number, never under EDITOR_GUTTER_MIN. The painter and
// editor_pos_at both size the text column from this one call.
editor_gutter_w :: proc(b: ^edit.Buffer) -> int {
    return max(EDITOR_GUTTER_MIN, num_digits(txt.doc_line_count(&b.doc)))
}

// Column 0 with the view at home: a one-cell margin, the gutter, a one-cell gap. One proc for
// the paint and the hit test. Also the gutter/text boundary the painter's two clips meet at —
// the gutter never scrolls sideways, so the horizontal offset is subtracted from the result.
editor_text_x :: proc(area_x: i32, gutter: int, cw: f32) -> f32 {
    return f32(area_x) + f32(gutter + 2) * cw
}

// The region right of the gutter, in cells. The horizontal policy's `cols` and the painter's
// cull window come from this one call, or the policy could frame a caret the painter hides.
editor_cols :: proc(area: gfx.Rect, gutter: int, cw: f32) -> int {
    if cw <= 0 {
        return 0
    }
    return max(0, int((f32(area.x + area.w) - editor_text_x(area.x, gutter, cw)) / cw))
}

// Bounds the column axis. Over the DRAWN lines, not the file: O(rows) per frame, and scrolling
// into short lines should bring the view back toward home. Cells, not bytes.
editor_longest_visible :: proc(b: ^edit.Buffer, top, count: int) -> int {
    n := 0
    for line in editor_visible_lines(b, top, count) {
        n = max(n, txt.doc_cell_count(&b.doc, line))
    }
    return n
}

// Where the view IS this instant. `top` is the ANIMATED top, not b.scroll (where the viewport
// is heading); `off` is the sub-row remainder. Row ids downstream are view indices off `top`.
Editor_View :: struct {
    area:   gfx.Rect,
    row_h:  i32,
    rows:   int, // whole rows that fit
    top:    int, // first line of the window (may be hidden; the walk skips forward)
    off:    i32, // sub-row pixel offset, subtracted from every row's y
    gutter: int, // line-number digits
    text_x: f32, // x of column 0, WITH the horizontal scroll already taken off it
    cols:   int, // whole columns of text that fit right of the gutter
    hoff:   f32, // pixels the text column is shifted left; the animated twin of b.hscroll
    cw:     f32,
    lh:     f32,
}

// Re-aims both scroll animations, which is why it is not a pure query: smooth_scroll is what
// makes anim_active true, so a frame that moves b.scroll without reaching here again leaves the
// view frozen part-scrolled.
//
// `text_x` carries the horizontal offset already subtracted, so every column-to-pixel
// conversion downstream stays `text_x + cw * col`.
editor_view :: proc(b: ^edit.Buffer, face: gfx.Face, area: gfx.Rect, row_h: i32, rows: int, now: f64) -> Editor_View {
    top, off := ui.smooth_scroll(&b.scroll_anim, b.scroll, now, row_h)
    gutter := editor_gutter_w(b)
    hoff := ui.smooth_hscroll(&b.hscroll_anim, b.hscroll, now, face.cell_w)
    return Editor_View {
        area   = area,
        row_h  = row_h,
        rows   = rows,
        top    = top,
        off    = off,
        gutter = gutter,
        text_x = editor_text_x(area.x, gutter, face.cell_w) - hoff,
        cols   = editor_cols(area, gutter, face.cell_w),
        hoff   = hoff,
        cw     = face.cell_w,
        lh     = face.line_height,
    }
}

// Down from `top`, skipping folded-away lines. The visual row index counts only drawn lines,
// which is why a screen row cannot be turned back into a line by arithmetic. Temp-allocated.
editor_visible_lines :: proc(b: ^edit.Buffer, top, count: int) -> []int {
    out := make([dynamic]int, 0, max(0, count), context.temp_allocator)
    for i := max(0, top); i < txt.doc_line_count(&b.doc) && len(out) < count; i += 1 {
        if !edit.buffer_line_hidden(b, i) {
            append(&out, i)
        }
    }
    return out[:]
}

// A walk, not arithmetic: `top + vrow` is only the answer when no fold sits between them.
editor_line_at_row :: proc(b: ^edit.Buffer, top, vrow: int) -> (line: int, ok: bool) {
    if vrow < 0 {
        return 0, false
    }
    lines := editor_visible_lines(b, top, vrow + 1)
    if len(lines) <= vrow {
        return 0, false
    }
    return lines[vrow], true
}

// The inverse of the painter's arithmetic. The column rounds, so a character's right half puts
// the caret after it. ok=false below the last drawn row, or a click in empty space would jump
// to end-of-file. One of the two places (with editor_drag_pos) that crosses cells to bytes.
editor_pos_at :: proc(b: ^edit.Buffer, v: Editor_View, x, y: i32) -> (p: txt.Pos, ok: bool) {
    if v.row_h <= 0 || txt.doc_line_count(&b.doc) == 0 {
        return {}, false
    }
    line, got := editor_line_at_row(b, v.top, editor_row_at(v, y))
    if !got {
        return {}, false
    }
    return txt.Pos{line, txt.doc_byte_col(&b.doc, line, max(0, editor_caret_col(v, x)))}, true
}

// -1 above the window. The one place the row grid is divided out. The window is shifted up by
// `off`, so the point moves down by it.
editor_row_at :: proc(v: Editor_View, y: i32) -> int {
    if v.row_h <= 0 {
        return -1
    }
    dy := int(y - v.area.y + v.off)
    if dy < 0 {
        return -1
    }
    return dy / int(v.row_h)
}

// Rounded, and unclamped to any line, so both callers round it the one way.
editor_caret_col :: proc(v: Editor_View, x: i32) -> int {
    if v.cw <= 0 {
        return 0
    }
    return int(math.round((f32(x) - v.text_x) / v.cw))
}

// Floored, where editor_pos_at rounds: a caret column is a boundary, a word selection names a
// character. Pointing at the last `o` of "foo.bar" must select "foo", not the '.' at boundary 3.
editor_glyph_col :: proc(v: Editor_View, x: i32) -> int {
    if v.cw <= 0 {
        return 0
    }
    return max(0, int(math.floor((f32(x) - v.text_x) / v.cw)))
}

// Tagged rather than a Pos with a sentinel: a fold marker is a button that happens to sit at
// the end of a line, and expanding a block must not also move the caret.
Editor_Hit_Kind :: enum {
    None,
    Text,
    Fold, // the collapse marker of a folded header; `pos.line` is the header
}

Editor_Hit :: struct {
    kind:  Editor_Hit_Kind,
    pos:   txt.Pos, // the caret boundary: where a single click puts the insertion point
    glyph: int, // BYTE column of the character actually pointed at; what a double click selects
}

// One Custom with no per-row boxes, so where-in-the-text is ours and whether-in-the-pane is a
// rect test. The fold marker is tested before the text, only on a line that has one.
editor_hit :: proc(a: ^App, b: ^edit.Buffer, v: Editor_View) -> Editor_Hit {
    if !a.mouse_on || !a.mouse.known || a.main != .Text {
        return {}
    }
    // Not gated on a.mouse.stood_down: standing down suppresses hover, never a click.
    if !gfx.rect_hit(v.area, a.mouse.x, a.mouse.y) {
        return {}
    }
    p, ok := editor_pos_at(b, v, a.mouse.x, a.mouse.y)
    if !ok {
        return {}
    }
    if edit.buffer_fold_index(b, p.line) >= 0 {
        end := f32(txt.doc_cell_count(&b.doc, p.line))
        mx := f32(a.mouse.x)
        if mx >= v.text_x + v.cw * end && mx < v.text_x + v.cw * (end + EDITOR_FOLD_HIT_CELLS) {
            return Editor_Hit{kind = .Fold, pos = p}
        }
    }
    glyph := txt.doc_byte_col(&b.doc, p.line, editor_glyph_col(v, a.mouse.x))
    return Editor_Hit{kind = .Text, pos = p, glyph = glyph}
}

// Apply a pending click. The verbs, and each one's keyboard twin:
//
//   click                place the caret          any motion key
//   Shift+click          extend the selection     Shift + a motion
//   Alt+click            drop a cursor there      Alt+A, then walk it over
//   double click         select the word          Ctrl+Left, Shift+Ctrl+Right
//   triple click         select the line          Home, Shift+End
//   click a fold marker  expand the block         Ctrl+Enter on the header
//
// Every count is a grade of one verb, not "single selects, double activates". Claiming the
// press clears b.scroll_detached directly rather than stamping the global a.last_input_at —
// the aux panes re-attach off that too, so a click here would snap a scrolled filetree back.
editor_click :: proc(a: ^App, hit: Editor_Hit, now: f64) {
    u := ctx_of(a)
    if hit.kind == .None {
        return
    }
    count, ok := ui.mouse_take_click(u)
    if !ok {
        return
    }
    b := edit.editor_current(&a.editor)
    // Both axes: a press is an aim, and a kept sideways offset would put the caret elsewhere.
    // This also gives the drag its horizontal autoscroll for free.
    b.scroll_detached = 0
    b.hscroll_detached = 0
    a.blink_base = now

    if hit.kind == .Fold {
        if i := edit.buffer_fold_index(b, hit.pos.line); i >= 0 {
            unordered_remove(&b.folds, i)
        }
        return // a marker is a button, not something you drag out of
    }

    // The press is now a capture, at the grade fixed here. Begun for every text click — a press
    // cannot know whether it is a drag, and a zero-length one re-derives what it set.
    ui.drag_begin(u, .Editor_Text, a.editor.active, count, hit.pos, hit.glyph)

    d := &b.doc
    switch {
    case count >= 3:
        txt.doc_select_line(d, hit.pos.line)
    case count == 2:
        // The glyph pointed at, not the caret boundary — see editor_glyph_col.
        txt.doc_select_word(d, txt.Pos{hit.pos.line, hit.glyph})
    case a.mouse.click_alt:
        txt.doc_add_cursor(d, hit.pos)
    case a.mouse.click_shift:
        txt.doc_set_head(d, hit.pos, true)
    case:
        txt.doc_reset_cursor(d, txt.doc_clamp_pos(d, hit.pos))
    }
}

// A hit is refused outside the pane; a drag under capture resolves wherever the pointer went,
// and below the last drawn row means "to the end". The clamp is on the row, not the pixel: the
// pane's bottom edge sits mid-row, and a drag must not aim at a line never put on screen.
editor_drag_pos :: proc(b: ^edit.Buffer, v: Editor_View, x, y: i32) -> (p: txt.Pos, glyph: int) {
    if v.row_h <= 0 || v.rows <= 0 || txt.doc_line_count(&b.doc) == 0 {
        return {}, 0
    }
    line, ok := editor_line_at_row(b, v.top, clamp(editor_row_at(v, y), 0, v.rows - 1))
    if !ok {
        line = edit.buffer_prev_visible(b, txt.doc_line_count(&b.doc) - 1)
    }
    glyph = txt.doc_byte_col(&b.doc, line, editor_glyph_col(v, x))
    return txt.Pos{line, txt.doc_byte_col(&b.doc, line, max(0, editor_caret_col(v, x)))}, glyph
}

// The pointer's own line inside the pane, the autoscroll's walk past an edge — past one the
// pointer names no line, so Drag.over does, seeded from the edge row it left over.
editor_drag_line :: proc(a: ^App, b: ^edit.Buffer, v: Editor_View, line: int, now: f64) -> int {
    past, dir := 0, 0
    switch {
    case a.mouse.y < v.area.y:
        past, dir = int(v.area.y - a.mouse.y), -1
    case a.mouse.y >= v.area.y + v.area.h:
        past, dir = int(a.mouse.y - (v.area.y + v.area.h) + 1), 1
    }
    if dir == 0 {
        a.drag.over_on = false // back inside: the pointer names its own line
        return line
    }
    if !a.drag.over_on {
        a.drag.over, a.drag.over_on = line, true
    }
    // Re-attach, as a click does: a detached view does not chase the caret, so a drag off the
    // bottom would extend the selection out of sight.
    b.scroll_detached = 0
    if ui.drag_tick(ctx_of(a), now) {
        step := ui.drag_scroll_step(past, int(v.row_h))
        a.drag.over =
            dir < 0 \
            ? edit.buffer_back_visible(b, a.drag.over, step) \
            : edit.buffer_fwd_visible(b, a.drag.over, step)
    }
    return a.drag.over
}

// Beside editor_click because a gesture that walks the caret off-screen must scroll in the
// frame that moved it. Nothing here writes b.scroll: autoscroll walks the selection and the
// policy follows.
editor_drag :: proc(a: ^App, b: ^edit.Buffer, v: Editor_View, now: f64) {
    if !a.mouse_on || !a.mouse.known || a.main != .Text || txt.doc_line_count(&b.doc) == 0 {
        return
    }
    // The capture invariant: a buffer switched mid-drag leaves it held but inert (drag.odin).
    if !ui.drag_live(ctx_of(a), .Editor_Text, a.editor.active) {
        return
    }
    p, glyph := editor_drag_pos(b, v, a.mouse.x, a.mouse.y)
    if line := editor_drag_line(a, b, v, p.line, now); line != p.line {
        p = txt.doc_clamp_pos(&b.doc, txt.Pos{line, p.col})
    }
    a.blink_base = now // the caret stays solid through the gesture

    d := &b.doc
    if a.drag.grade >= 2 {
        anchor, head := txt.doc_drag_span(d, a.drag.grade, txt.Pos{a.drag.anchor.line, a.drag.anchor_glyph}, txt.Pos{p.line, glyph})
        txt.doc_select_span(d, anchor, head)
        return
    }
    txt.doc_set_head(d, p, true)
}

// Handed to the bridge as `customData`, so it lives in the frame's temp arena.
Editor_Body :: struct {
    b:   ^edit.Buffer,
    v:   Editor_View,
    now: f64,
}

// Declare the pane. Thin on purpose: no gutter or row elements, which would put a second copy
// of the row grid in the tree for hit targets the surface already resolves.
//   ed_pane    the content area inside the focus ring, clipping its own content
//     ed_body    the text surface, as a Custom — the element editor_hit points at
editor_declare :: proc(a: ^App, face: gfx.Face, pane: gfx.Rect, v: Editor_View, now: f64) {
    b := edit.editor_current(&a.editor)
    area := v.area

    body := new(Editor_Body, context.temp_allocator)
    body^ = Editor_Body{b = b, v = v, now = now}
    cu := new(ui.ClayCustom, context.temp_allocator)
    cu^ = ui.ClayCustom{paint = editor_paint_body, user = body}

    // No backgroundColor: panel() filled the pane, and the transparent default emits no
    // Rectangle, so the command list is just the Custom inside the clip.
    if clay.UI(clay.ID("ed_pane"))(ui.clay_pane_box(area)) {
        if clay.UI(clay.ID("ed_body"))(
            {
                layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                custom = {customData = cu},
            },
        ) {}
    }
}

// Gutter, coloured lines, current-line bar, selections, indent guides, whitespace, fold markers
// and a caret per cursor. Positions come from `r`, the box the solver resolved, not v.area
// (tests/editor_ui_test.odin pins the equality). Two scissored passes; see the split below.
editor_paint_body :: proc(t: ^gfx.Draw, r, clip: gfx.Rect, win_w, win_h: i32, host: rawptr, user: rawptr) {
    a := (^App)(host)
    e := (^Editor_Body)(user)
    if e == nil || e.b == nil {
        return
    }
    b := e.b
    v := e.v
    th := &a.theme
    cw := gfx.face(t).cell_w
    lh := gfx.face(t).line_height
    row_h := v.row_h
    edge := editor_text_x(r.x, v.gutter, cw) // gutter/text boundary, where the two clips meet
    text_x := edge - v.hoff // where column 0 actually lands

    // Two passes, split at that boundary, because the gutter does not scroll sideways. Two and
    // not one because a scissor belongs to a flush (flush_pane), and culling alone leaves the
    // column at the cull edge hanging half-drawn in the gap.
    gx := i32(edge)
    text_clip := ui.clay_isect(clip, gfx.Rect{gx, r.y, r.x + r.w - gx, r.h})
    gutter_clip := ui.clay_isect(clip, gfx.Rect{r.x, r.y, gx - r.x, r.h})

    // One column either side so a part-scrolled cell is drawn rather than popping in.
    // Everything outside is off the clip and not queued — a 4000-character line is otherwise
    // 4000 glyph quads for the hundred you can see.
    first_col := max(0, int(v.hoff / max(cw, 1)) - 1)
    last_col := first_col + v.cols + 2

    cur_line := b.cursors[b.primary].head.line // drives the gutter and the bar

    // Plus the partial rows a mid-scroll offset exposes top and bottom.
    draw_lines := editor_visible_lines(b, v.top, v.rows + 2)

    // The scope walk is bounded to the DRAWN lines, so it comes after them: a fold means the
    // last drawn line is not v.top + rows.
    unit := edit.indent_unit(a.indent)
    scope: edit.Scope
    if a.show_guides && len(draw_lines) > 0 {
        scope = edit.buffer_active_scope(b, cur_line, unit, draw_lines[0], draw_lines[len(draw_lines) - 1])
    }

    // hl is indexed by line-top, so folded gaps inside the span are never read.
    span := len(draw_lines) > 0 ? draw_lines[len(draw_lines) - 1] - v.top + 1 : 0
    hl := highlight_visible(a, b, v.top, span)

    for line, vrow in draw_lines {
        // Runes plus the byte offset each starts at. Built once and shared by everything below
        // that positions on the grid: a Pos counts bytes, the grid counts cells.
        cells := txt.doc_cells(&b.doc, line)
        ncells := txt.cells_count(cells)
        y := r.y + i32(vrow) * row_h - v.off
        ty := f32(y) + (f32(row_h) - lh) / 2
        on_cur_line := line == cur_line

        if on_cur_line {
            gfx.fill(t, gfx.Rect{r.x, y, r.w, row_h}, th.line_highlight) // current-line bar
        }

        // First/last line clip to the cursor's columns; interior lines fill out.
        for c in b.cursors {
            if !txt.cursor_has_selection(c) {
                continue
            }
            lo, hi := txt.cursor_range(c)
            if line < lo.line || line > hi.line {
                continue
            }
            start := line == lo.line ? txt.cells_col(cells, lo.col) : 0
            end := line == hi.line ? txt.cells_col(cells, hi.col) : ncells
            if end > start {
                sx := i32(text_x + cw * f32(start))
                gfx.fill(t, gfx.Rect{sx, y, i32(cw * f32(end - start)), row_h}, th.selection)
            }
        }

        draw_find_marks(t, &a.find, line, cells, text_x, y, row_h, cw, th)

        if a.show_guides {
            draw_indent_guides(t, b, line, text_x, y, row_h, cw, unit, th, scope)
        }
        // Culled to the visible columns. The colour row is one entry per rune, so the same
        // window indexes both — but only once its length is known to match.
        k := line - v.top // highlight rows are absolute-line based
        row := hl != nil && k < len(hl) ? hl[k] : nil
        lo := min(first_col, ncells)
        hi := min(last_col, ncells)
        rx := text_x + cw * f32(lo)
        if len(row) == ncells {
            draw_runes_colored(t, cells.runes[lo:hi], row[lo:hi], rx, ty, th.fg)
        } else {
            gfx.text_draw_runes(t, cells.runes[lo:hi], rx, ty, th.fg)
        }

        // AFTER the line, not before it: these are glyphs now, and the line's own spaces would
        // overwrite them in a grid where the last rune written to a cell is the one you see.
        if a.show_whitespace {
            draw_whitespace(t, cells.runes, text_x, f32(y), cw, th.whitespace)
        }

        if edit.buffer_fold_index(b, line) >= 0 {
            draw_fold_marker(t, text_x + cw * (f32(ncells) + 0.5), f32(y), th.accent)
        }

        if ui.caret_blink_on(ctx_of(a), e.now) {
            for c in b.cursors {
                if c.head.line == line {
                    // Align with the glyph cell (ty), not the padded row top.
                    cx := text_x + cw * f32(txt.cells_col(cells, c.head.col))
                    gfx.caret(t, gfx.Rect{i32(cx), i32(ty), max(1, gfx.hairline(lh)), i32(lh)}, th.fg)
                }
            }
        }
    }

    gfx.flush_pane(t, text_clip, win_w, win_h)

    // Pass two: the fixed gutter. The current-line bar is queued again at full row width and
    // the scissor keeps this half, so the bar reads as one unbroken band.
    for line, vrow in draw_lines {
        y := r.y + i32(vrow) * row_h - v.off
        ty := f32(y) + (f32(row_h) - lh) / 2
        on_cur_line := line == cur_line
        if on_cur_line {
            gfx.fill(t, gfx.Rect{r.x, y, r.w, row_h}, th.line_highlight)
        }
        buf: [12]u8
        s := strconv.write_int(buf[:], i64(line_number(a.line_numbers, line, cur_line)), 10)
        nx := f32(r.x) + cw + f32(v.gutter - len(s)) * cw // right-align in gutter
        gfx.text_draw(t, s, nx, ty, on_cur_line ? th.fg : th.muted)
    }

    // The ClayCustom contract: the painter ends with its own flush. The two halves cover the
    // clip between them.
    gfx.flush_pane(t, gutter_clip, win_w, win_h)
}

// Keeps the cursor visible on both axes — there is no soft wrap, so a long line is reached
// sideways. Tabs advance one cell; proper tab width is a TODO, and it is the one thing that
// would stop a column being a rune index. See editor_view for why the view is built twice.
editor_frame :: proc(t: ^gfx.Draw, a: ^App, pane: gfx.Rect, now: f64) {
    b := edit.editor_current(&a.editor)
    area, row_h, rows := editor_geom(pane, gfx.face(t).line_height, gfx.face(t).cell_w)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    edit.buffer_sync_folds(b) // drop folds an edit invalidated

    // The pointer is over what the LAST frame painted, so the click resolves against a view
    // built before this frame's scroll policy runs.
    v := editor_view(b, gfx.face(t), area, row_h, rows, now)
    editor_click(a, editor_hit(a, b, v), now)
    editor_drag(a, b, v, now) // extend a capture the press already made

    // Move the viewport, so a click that put the caret off-screen scrolls in the same frame,
    // then rebuild the view. Rows first: the column policy measures its bound over the lines
    // the page settled on (buffer_hscroll_apply).
    edit.buffer_scroll_apply(b, rows, a.scroll_mode == .Middle, a.last_input_at)
    edit.buffer_hscroll_apply(b, v.cols, editor_longest_visible(b, b.scroll, rows + 2), a.last_input_at)
    v = editor_view(b, gfx.face(t), area, row_h, rows, now)

    editor_declare(a, gfx.face(t), pane, v, now)
}

// Test-facing wrapper; see filetree_layout.
editor_layout :: proc(
    a: ^App,
    face: gfx.Face,
    pane: gfx.Rect,
    win_w, win_h: i32,
    v: Editor_View,
    now: f64,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        editor_declare(a, face, pane, v, now)
    }
    return clay.EndLayout(0)
}

// --- painters ---

// A thin rail at each indent level the line sits at; the cursor's enclosing scope is drawn in
// the active colour.
@(private = "file")
draw_indent_guides :: proc(t: ^gfx.Draw, b: ^edit.Buffer, line: int, text_x: f32, y, row_h: i32, cw: f32, unit: int, th: ^gfx.Theme, scope: edit.Scope) {
    levels := edit.buffer_indent_levels(b, line, unit)
    gw := max(i32(1), i32(cw) / 16) // hairline, ~1px
    aw := gw * 2 // the active rail is thicker so it reads as the focus
    for lvl in 0 ..< levels {
        // Half a cell into the indentation, so it reads as a guide between columns.
        gx := i32(text_x + cw * (f32(lvl * unit) + 0.5))
        if edit.scope_highlights(scope, line, lvl) {
            gfx.fill(t, gfx.Rect{gx - (aw - gw) / 2, y, aw, row_h}, th.indent_guide_active) // centred
        } else {
            gfx.fill(t, gfx.Rect{gx, y, gw, row_h}, th.indent_guide)
        }
    }
}

// A bar behind every hit, the caret's in a brighter colour, under the glyphs like the selection
// bar. The list is in line order, so the row's first hit comes from a binary search — a common
// word in a large file is thousands of matches and only this line's can be drawn.
@(private = "file")
draw_find_marks :: proc(t: ^gfx.Draw, f: ^Find, line: int, cells: txt.Cells, text_x: f32, y, row_h: i32, cw: f32, th: ^gfx.Theme) {
    if !f.show {
        return
    }
    for i := find_first_on_line(f.matches[:], line); i < len(f.matches); i += 1 {
        m := f.matches[i]
        if m.line != line {
            break
        }
        // A match is a byte span; the bar is on the cell grid.
        lo := txt.cells_col(cells, m.col)
        hi := txt.cells_col(cells, m.col + m.n)
        color := i == f.cur ? th.find_current : th.find_match
        gfx.fill(t, gfx.Rect{i32(text_x + cw * f32(lo)), y, i32(cw * f32(hi - lo)), row_h}, color)
    }
}

// A dot per space, a stroke per tab, over a line's LEADING indentation only. GLYPHS rather than
// small filled rects: a grid's smallest rect is a whole cell, so the dots came out as solid
// blocks the width of the character they were marking.
WS_DOT :: '·'
WS_TAB :: '─'

@(private = "file")
draw_whitespace :: proc(t: ^gfx.Draw, runes: []rune, text_x, y, cw: f32, color: [3]f32) {
    marks: [1]rune
    for r, col in runes {
        if r != ' ' && r != '\t' {
            break
        }
        marks[0] = r == ' ' ? WS_DOT : WS_TAB
        gfx.text_draw_runes(t, marks[:], text_x + cw * f32(col), y, color)
    }
}

// Trailing a folded header line. Three separate dots rather than the one ellipsis glyph, so it
// reads at the same weight as the whitespace marks.
@(private = "file")
draw_fold_marker :: proc(t: ^gfx.Draw, x, y: f32, color: [3]f32) {
    marks := [3]rune{WS_DOT, WS_DOT, WS_DOT}
    gfx.text_draw_runes(t, marks[:], x, y, color)
}

// Runs of one colour each; monospace makes each run's x pure arithmetic. A mismatched colour
// count falls back to a single plain draw.
@(private = "file")
draw_runes_colored :: proc(t: ^gfx.Draw, runes: []rune, colors: Row_Colors, x, y: f32, fallback: [3]f32) {
    if len(colors) != len(runes) {
        gfx.text_draw_runes(t, runes, x, y, fallback)
        return
    }
    cw := gfx.face(t).cell_w
    for i := 0; i < len(runes); {
        j := i + 1
        for j < len(runes) && colors[j] == colors[i] {
            j += 1
        }
        gfx.text_draw_runes(t, runes[i:j], x + cw * f32(i), y, colors[i])
        i = j
    }
}

// Digits in a number: the gutter's width here, the switcher column's in overlay_ui.
num_digits :: proc(n: int) -> int {
    d := 1
    for m := n; m >= 10; m /= 10 {
        d += 1
    }
    return d
}

@(private = "file")
line_number :: proc(mode: Line_Numbers, line, cursor: int) -> int {
    if mode == .Relative && line != cursor {
        return abs(line - cursor)
    }
    return line + 1 // absolute, and the cursor line under relative/hybrid
}
