package main

import "core:math"
import "core:strconv"
import clay "../bindings/clay"

// The editor pane's UI half. **Clay owns the frame, we own the body:** the text body is a 2D
// per-glyph surface, so the pane declares ONE `Custom` and the painter fills the box Clay
// reserves. Everything the phases must agree about lives in `Editor_View`, so where a glyph is
// PAINTED and where a pixel READS BACK as a Pos cannot drift; the command-list test asserts
// the Custom's box IS the area the view was built from. The view is computed TWICE, either
// side of the click, because a click that moves the caret re-aims the scroll animation.

// Extra vertical padding per row, in logical pixels — the twin of FT_ROW_PAD / GREP_ROW_PAD.
EDITOR_ROW_PAD :: 2

// Narrowest line-number gutter, in digits. A file under ten lines still gets two, so the
// text column does not jitter one cell to the left in a scratch buffer.
EDITOR_GUTTER_MIN :: 2

// How far past the end of a folded header's text its collapse marker may be clicked, in
// cells. Deliberately wider than the paint (three dots in about one cell): the alternative
// to hitting it is putting the caret at end-of-line, a harmless miss either way.
EDITOR_FOLD_HIT_CELLS :: 2

// The content area inside the focus ring, the row height, and how many whole rows fit; the
// buffer-dependent half (gutter, animated top) is editor_view. `rows` is at least 1 even in a
// pane too short — the clip keeps an overflowing row inside the pane, not the count.
editor_geom :: proc(pane: Rect, scale: f32, line_h: f32) -> (area: Rect, row_h: i32, rows: int) {
    area = inset(pane, i32(2 * scale))
    row_h = i32(line_h) + i32(EDITOR_ROW_PAD * scale)
    if area.w <= 0 || area.h <= 0 || row_h <= 0 {
        return area, row_h, 0
    }
    rows = max(1, int(area.h / row_h))
    return
}

// The line-number gutter's width in digits — wide enough for the last line number, never
// under EDITOR_GUTTER_MIN. The painter and editor_pos_at both size the text column from this
// one call, which is what stops a click landing one cell out in a thousand-line file.
editor_gutter_w :: proc(b: ^Buffer) -> int {
    return max(EDITOR_GUTTER_MIN, num_digits(len(b.lines)))
}

// Where column 0 starts with the view at home: a one-cell left margin, the gutter, then a
// one-cell gap. One proc because its two callers are the paint and the hit test, and a text
// column that means something different to each is a whole class of bug. This is also the
// GUTTER/TEXT BOUNDARY the painter's two clips meet at — the gutter never scrolls sideways,
// so the horizontal offset is subtracted from the result, never folded in here.
editor_text_x :: proc(area_x: i32, gutter: int, cw: f32) -> f32 {
    return f32(area_x) + f32(gutter + 2) * cw
}

// How many whole COLUMNS of text the window shows — the region right of the gutter, in cells.
// The horizontal policy's `cols` and the painter's cull window come from this one call, for
// the reason editor_text_x is one call: a policy framing a caret into a width the painter
// does not draw would settle on a column and then hide it.
editor_cols :: proc(area: Rect, gutter: int, cw: f32) -> int {
    if cw <= 0 {
        return 0
    }
    return max(0, int((f32(area.x + area.w) - editor_text_x(area.x, gutter, cw)) / cw))
}

// The widest line the window is about to draw, in columns — what bounds the column axis.
// Measured over the DRAWN lines rather than the whole file: it is O(rows) instead of O(lines)
// every frame, and scrolling down into short lines should bring the view back toward home
// rather than leave it parked over the blank space right of them.
editor_longest_visible :: proc(b: ^Buffer, top, count: int) -> int {
    n := 0
    for line in editor_visible_lines(b, top, count) {
        n = max(n, line_len(&b.lines[line]))
    }
    return n
}

// The box, the row grid, the text column, and where the view IS this instant. `top` is the
// ANIMATED top, not b.scroll (which is where the viewport is heading); `off` is the sub-row
// remainder shifting every row up by a fraction. Row ids downstream are view indices off `top`.
Editor_View :: struct {
    area:   Rect,
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

// Build the view — and RE-AIM both scroll animations, which is why it is not a pure query.
// smooth_scroll is what makes anim_active true and app_next_wake schedules off that, so a
// frame moving b.scroll or b.hscroll without reaching here again leaves the view frozen
// part-scrolled.
//
// `text_x` carries the horizontal offset ALREADY SUBTRACTED. That is the whole trick: every
// column-to-pixel conversion downstream — the caret, the selection bars, both hit tests, the
// fold marker's reach — is `text_x + cw * col` and keeps working untouched, so there is no
// second place where a scrolled column could be turned back into the wrong one.
editor_view :: proc(b: ^Buffer, f: ^Font, area: Rect, row_h: i32, rows: int, now: f64) -> Editor_View {
    top, off := smooth_scroll(&b.scroll_anim, b.scroll, now, row_h)
    gutter := editor_gutter_w(b)
    hoff := smooth_hscroll(&b.hscroll_anim, b.hscroll, now, f.cell_w)
    return Editor_View {
        area   = area,
        row_h  = row_h,
        rows   = rows,
        top    = top,
        off    = off,
        gutter = gutter,
        text_x = editor_text_x(area.x, gutter, f.cell_w) - hoff,
        cols   = editor_cols(area, gutter, f.cell_w),
        hoff   = hoff,
        cw     = f.cell_w,
        lh     = f.line_height,
    }
}

// The lines the window shows, in paint order: down from `top`, skipping folded-away lines.
// The visual row index counts only drawn lines while the line indices skip hidden ones, which
// is why a screen row cannot be turned back into a line by arithmetic. Temp-allocated.
editor_visible_lines :: proc(b: ^Buffer, top, count: int) -> []int {
    out := make([dynamic]int, 0, max(0, count), context.temp_allocator)
    for i := max(0, top); i < len(b.lines) && len(out) < count; i += 1 {
        if !buffer_line_hidden(b, i) {
            append(&out, i)
        }
    }
    return out[:]
}

// The line drawn at visual row `vrow`, or ok=false past the end of the buffer. The walk,
// not arithmetic: `top + vrow` is only the answer when no fold sits between them.
editor_line_at_row :: proc(b: ^Buffer, top, vrow: int) -> (line: int, ok: bool) {
    if vrow < 0 {
        return 0, false
    }
    lines := editor_visible_lines(b, top, vrow + 1)
    if len(lines) <= vrow {
        return 0, false
    }
    return lines[vrow], true
}

// A framebuffer point as a document position — the inverse of the painter's arithmetic. The
// column ROUNDS, so a character's right half puts the caret after it; the gutter clamps to 0.
// ok=false below the last drawn row, or a click in empty space would jump to end-of-file.
editor_pos_at :: proc(b: ^Buffer, v: Editor_View, x, y: i32) -> (p: Pos, ok: bool) {
    if v.row_h <= 0 || len(b.lines) == 0 {
        return {}, false
    }
    line, got := editor_line_at_row(b, v.top, editor_row_at(v, y))
    if !got {
        return {}, false
    }
    return Pos{line, clamp(editor_caret_col(v, x), 0, line_len(&b.lines[line]))}, true
}

// The visible ROW a framebuffer y falls on, or -1 above the window — the one place the row
// grid is divided out, so editor_pos_at and editor_drag_pos cannot disagree about where a row
// is. The window is shifted up by `off`, so the point moves down by it to compensate.
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

// The caret BOUNDARY column under x — rounded, and unclamped to any line, so its two callers
// (editor_pos_at inside the pane, editor_drag_pos past its edges) round it the one way.
editor_caret_col :: proc(v: Editor_View, x: i32) -> int {
    if v.cw <= 0 {
        return 0
    }
    return int(math.round((f32(x) - v.text_x) / v.cw))
}

// The column of the GLYPH under the pointer — floored, where editor_pos_at rounds. One pixel,
// two questions: a caret column is a BOUNDARY, a word selection names a CHARACTER. Pointing at
// the last `o` of "foo.bar" must select "foo", where the rounded boundary is 3 — the '.'.
editor_glyph_col :: proc(v: Editor_View, x: i32) -> int {
    if v.cw <= 0 {
        return 0
    }
    return max(0, int(math.floor((f32(x) - v.text_x) / v.cw)))
}

// What the pointer is over. Two kinds, so the answer is tagged rather than a Pos with a
// sentinel: a fold marker is a BUTTON that happens to sit at the end of a line, and
// resolving it as "the caret goes here" would make expanding a block a caret move as well.
Editor_Hit_Kind :: enum {
    None,
    Text,
    Fold, // the collapse marker of a folded header; `pos.line` is the header
}

Editor_Hit :: struct {
    kind:  Editor_Hit_Kind,
    pos:   Pos, // the caret boundary: where a single click puts the insertion point
    glyph: int, // the character actually pointed at; what a double click selects
}

// Resolve the pointer against the editor body. A single Custom with no per-row boxes, so
// where-in-the-text is ours; whether-in-the-pane is a rect test, since rect_hit is half-open
// and needs no tree. The fold marker is tested BEFORE the text, only on a line that has one.
editor_hit :: proc(a: ^App, b: ^Buffer, v: Editor_View) -> Editor_Hit {
    if !a.mouse_on || !a.mouse.known || a.main != .Text {
        return {}
    }
    // Deliberately NOT gated on a.mouse.stood_down: standing down suppresses HOVER, never a
    // click. A press wakes the pointer before any pane can claim it, so refusing hits here
    // would only discard a click the user aimed.
    if !rect_hit(v.area, a.mouse.x, a.mouse.y) {
        return {}
    }
    p, ok := editor_pos_at(b, v, a.mouse.x, a.mouse.y)
    if !ok {
        return {}
    }
    if buffer_fold_index(b, p.line) >= 0 {
        end := f32(line_len(&b.lines[p.line]))
        mx := f32(a.mouse.x)
        if mx >= v.text_x + v.cw * end && mx < v.text_x + v.cw * (end + EDITOR_FOLD_HIT_CELLS) {
            return Editor_Hit{kind = .Fold, pos = p}
        }
    }
    return Editor_Hit{kind = .Text, pos = p, glyph = editor_glyph_col(v, a.mouse.x)}
}

// Apply a pending click. The verbs, and each one's keyboard twin:
//
//   click                place the caret          any motion key
//   Shift+click          extend the selection     Shift + a motion
//   Alt+click            drop a cursor there      Alt+A, then walk it over
//   double click         select the word          Alt+A-free: Ctrl+Left, Shift+Ctrl+Right
//   triple click         select the line          Home, Shift+End
//   click a fold marker  expand the block         Ctrl+Enter on the header
//
// "Single selects, double activates" is a rule about LISTS; here every count is a grade of one
// verb. Claiming the press re-attaches this buffer's view if the wheel had detached it, and
// clears b.scroll_detached DIRECTLY rather than stamping the global a.last_input_at — the aux
// panes re-attach off that too, so a click here would snap a scrolled filetree back.
editor_click :: proc(a: ^App, hit: Editor_Hit, now: f64) {
    if hit.kind == .None {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    b := editor_current(&a.editor)
    // Both axes: a press is an aim, and a view that kept a sideways offset the pointer did not
    // ask for would put the caret somewhere other than where it was clicked. Re-attaching here
    // also gives the drag its horizontal autoscroll for free — editor_drag walks the caret to
    // the end of a line dragged past the right edge, and the column policy follows it.
    b.scroll_detached = 0
    b.hscroll_detached = 0
    a.blink_base = now

    if hit.kind == .Fold {
        if i := buffer_fold_index(b, hit.pos.line); i >= 0 {
            unordered_remove(&b.folds, i)
        }
        return // a marker is a BUTTON, and a button is not something you drag out of
    }

    // The press is now a CAPTURE: every motion until the button comes up belongs to this
    // buffer, at the grade fixed here. Begun for EVERY text click — whether a press is a drag
    // is not something the press can know, and a zero-length one re-derives what it set.
    drag_begin(a, .Editor_Text, a.editor.active, count, hit.pos, hit.glyph)

    d := &b.doc
    switch {
    case count >= 3:
        doc_select_line(d, hit.pos.line)
    case count == 2:
        // The GLYPH pointed at, not the caret boundary — see editor_glyph_col.
        doc_select_word(d, Pos{hit.pos.line, hit.glyph})
    case a.mouse.click_alt:
        doc_add_cursor(d, hit.pos)
    case a.mouse.click_shift:
        doc_set_head(d, hit.pos, true)
    case:
        doc_reset_cursor(d, doc_clamp_pos(d, hit.pos))
    }
}

// Where a DRAG points — a different question from editor_hit's. A hit is REFUSED outside the
// pane; a drag under capture resolves wherever the pointer went, and below the last DRAWN row
// means "to the end". The clamp is on the ROW, not the pixel: the pane's bottom edge sits
// mid-row, and a drag must not aim at a line never put on screen.
editor_drag_pos :: proc(b: ^Buffer, v: Editor_View, x, y: i32) -> (p: Pos, glyph: int) {
    if v.row_h <= 0 || v.rows <= 0 || len(b.lines) == 0 {
        return {}, 0
    }
    glyph = editor_glyph_col(v, x)
    line, ok := editor_line_at_row(b, v.top, clamp(editor_row_at(v, y), 0, v.rows - 1))
    if !ok {
        line = buffer_prev_visible(b, len(b.lines) - 1)
    }
    return Pos{line, clamp(editor_caret_col(v, x), 0, line_len(&b.lines[line]))}, glyph
}

// The line a drag extends to: the pointer's own inside the pane, the autoscroll's walk past an
// edge. Past one the pointer has stopped naming a line, so Drag.over does — seeded from the
// edge row it left over. The tick is spent only once the pointer is established outside.
editor_drag_line :: proc(a: ^App, b: ^Buffer, v: Editor_View, line: int, now: f64) -> int {
    past, dir := 0, 0
    switch {
    case a.mouse.y < v.area.y:
        past, dir = int(v.area.y - a.mouse.y), -1
    case a.mouse.y >= v.area.y + v.area.h:
        past, dir = int(a.mouse.y - (v.area.y + v.area.h) + 1), 1
    }
    if dir == 0 {
        a.drag.over_on = false // back inside: the pointer names its own line again
        return line
    }
    if !a.drag.over_on {
        a.drag.over, a.drag.over_on = line, true
    }
    // Walking past an edge asks the VIEWPORT POLICY to follow, so it re-attaches the view as
    // a click does. A detached view does not chase the caret, so without this a drag off the
    // bottom would extend the selection somewhere nobody can see.
    b.scroll_detached = 0
    if drag_tick(a, now) {
        step := drag_scroll_step(past, int(v.row_h))
        a.drag.over =
            dir < 0 \
            ? buffer_back_visible(b, a.drag.over, step) \
            : buffer_fwd_visible(b, a.drag.over, step)
    }
    return a.drag.over
}

// Extend a live text drag, beside editor_click because a gesture that walks the caret
// off-screen must scroll in the frame that moved it. **Nothing here writes b.scroll**:
// autoscroll walks the SELECTION and the policy follows, in whichever scroll_mode is set.
editor_drag :: proc(a: ^App, b: ^Buffer, v: Editor_View, now: f64) {
    if !a.mouse_on || !a.mouse.known || a.main != .Text || len(b.lines) == 0 {
        return
    }
    // The target comparison is the capture invariant: a buffer switched with the button
    // still down leaves the drag held but inert, rather than pointing it at another file's
    // text (drag.odin).
    if !drag_live(a, .Editor_Text, a.editor.active) {
        return
    }
    p, glyph := editor_drag_pos(b, v, a.mouse.x, a.mouse.y)
    if line := editor_drag_line(a, b, v, p.line, now); line != p.line {
        p = Pos{line, clamp(p.col, 0, line_len(&b.lines[line]))}
    }
    a.blink_base = now // the caret stays solid through the gesture, as it does through typing

    d := &b.doc
    if a.drag.grade >= 2 {
        anchor, head := doc_drag_span(d, a.drag.grade, Pos{a.drag.anchor.line, a.drag.anchor_glyph}, Pos{p.line, glyph})
        doc_select_span(d, anchor, head)
        return
    }
    doc_set_head(d, p, true)
}

// What the body's Custom needs to paint itself. Handed to the bridge as `customData`, so it
// must outlive EndLayout — it lives in the frame's temp arena, like every other pane's.
Editor_Body :: struct {
    b:   ^Buffer,
    v:   Editor_View,
    now: f64,
}

// Declare the pane. The tree is deliberately thin — no gutter or row elements, which would put
// a second copy of the row grid in the tree to buy hit targets the surface already resolves.
//   ed_pane    the content area inside the focus ring, clipping its own content
//     ed_body    the text surface, as a Custom — the element editor_hit points at
editor_declare :: proc(a: ^App, f: ^Font, pane: Rect, v: Editor_View, now: f64) {
    b := editor_current(&a.editor)
    area := v.area

    body := new(Editor_Body, context.temp_allocator)
    body^ = Editor_Body{b = b, v = v, now = now}
    cu := new(ClayCustom, context.temp_allocator)
    cu^ = ClayCustom{paint = editor_paint_body, user = body}

    // No backgroundColor: panel() already filled the pane, and Clay's transparent default
    // emits no Rectangle — so the command list is the Custom inside the pane's clip.
    if clay.UI(clay.ID("ed_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("ed_body"))(
            {
                layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                custom = {customData = cu},
            },
        ) {}
    }
}

// The text surface: gutter, lines with syntax colour, current-line bar, selections, indent
// guides, whitespace and fold markers, a caret per cursor. Positions come from `r`, the box the
// solver resolved, NOT v.area — tests/editor_ui_test.odin pins the equality. Drawn in two
// scissored passes, the scrolling text and the fixed gutter; see the split below.
editor_paint_body :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    e := (^Editor_Body)(user)
    if e == nil || e.b == nil {
        return
    }
    b := e.b
    v := e.v
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    row_h := v.row_h
    edge := editor_text_x(r.x, v.gutter, cw) // the gutter/text boundary, where the two clips meet
    text_x := edge - v.hoff // …and where column 0 actually lands

    // The body paints in TWO passes, split at that boundary. The gutter does not scroll
    // sideways — a line number that slid off with its line would leave you reading a long line
    // with no way to tell which one — so the text is drawn shifted and scissored to its own
    // half, then the numbers are drawn over their own. Two passes because a scissor belongs to
    // a flush (see flush_pane), and culling alone cannot do the job: the column at the cull
    // edge is only PART way past the boundary, and would hang half-drawn in the gap.
    gx := i32(edge)
    text_clip := clay_isect(clip, Rect{gx, r.y, r.x + r.w - gx, r.h})
    gutter_clip := clay_isect(clip, Rect{r.x, r.y, gx - r.x, r.h})

    // The columns the text region can reach, one either side so a part-scrolled cell is drawn
    // rather than popping in at the edge. Everything outside is off the clip and not queued: a
    // four-thousand-character line is otherwise four thousand glyph quads for the hundred you
    // can see, and a horizontal scroll makes that the ordinary case rather than the odd one.
    first_col := max(0, int(v.hoff / max(cw, 1)) - 1)
    last_col := first_col + v.cols + 2

    cur_line := b.cursors[b.primary].head.line // primary cursor drives the gutter + the bar

    unit := indent_unit(a.indent)
    scope: Scope
    if a.show_guides {
        scope = buffer_active_scope(b, cur_line, unit)
    }

    // The visible lines, plus the partial rows a mid-scroll offset exposes top and bottom.
    draw_lines := editor_visible_lines(b, v.top, v.rows + 2)

    // Highlight over the absolute span the drawn lines occupy (hl is indexed by line-top, so
    // folded gaps inside the span are simply never read).
    span := len(draw_lines) > 0 ? draw_lines[len(draw_lines) - 1] - v.top + 1 : 0
    hl := highlight_visible(a, b, v.top, span)

    for line, vrow in draw_lines {
        l := &b.lines[line]
        y := r.y + i32(vrow) * row_h - v.off
        ty := f32(y) + (f32(row_h) - lh) / 2
        on_cur_line := line == cur_line

        if on_cur_line {
            fill(t, Rect{r.x, y, r.w, row_h}, th.line_highlight) // current-line bar
        }

        // Selection spans: highlight each cursor's selection that covers this line
        // (first/last line clip to the cursor's columns, interior lines fill out).
        for c in b.cursors {
            if !cursor_has_selection(c) {
                continue
            }
            lo, hi := cursor_range(c)
            if line < lo.line || line > hi.line {
                continue
            }
            start := line == lo.line ? lo.col : 0
            end := line == hi.line ? hi.col : len(l.text)
            if end > start {
                sx := i32(text_x + cw * f32(start))
                fill(t, Rect{sx, y, i32(cw * f32(end - start)), row_h}, th.selection)
            }
        }

        draw_find_marks(t, &a.find, line, text_x, y, row_h, cw, th)

        // Indent guides: a thin vertical rail at each indent level, the cursor's
        // scope drawn in the active colour. Then the ghosted whitespace markers.
        if a.show_guides {
            draw_indent_guides(t, b, line, text_x, y, row_h, cw, unit, th, scope)
        }
        if a.show_whitespace {
            draw_whitespace(t, l, text_x, f32(y), row_h, cw, a.scale, th.whitespace)
        }

        // The line's runes, culled to the visible columns. The colour row is sliced with them
        // — one array per rune, so the same window indexes both — and only once its length is
        // known to match, since a mismatched row cannot be sliced by a column at all.
        k := line - v.top // index into the highlight rows (absolute-line based)
        row := hl != nil && k < len(hl) ? hl[k] : nil
        lo := min(first_col, len(l.text))
        hi := min(last_col, len(l.text))
        rx := text_x + cw * f32(lo)
        if len(row) == len(l.text) {
            draw_runes_colored(t, l.text[lo:hi], row[lo:hi], rx, ty, th.fg)
        } else {
            text_draw_runes(t, l.text[lo:hi], rx, ty, th.fg)
        }

        // A folded header carries a marker after its text so the collapse is visible.
        if buffer_fold_index(b, line) >= 0 {
            draw_fold_marker(t, text_x + cw * (f32(len(l.text)) + 0.5), f32(y), lh, a.scale, th.accent)
        }

        // A caret for every cursor sitting on this line (single-cursor = one), shown
        // on the blink's "on" phase.
        if caret_blink_on(a, e.now) {
            for c in b.cursors {
                if c.head.line == line {
                    // Align the caret with the glyph cell (at ty), not the padded row top.
                    caret(t, Rect{i32(text_x + cw * f32(c.head.col)), i32(ty), i32(2 * a.scale), i32(lh)}, th.fg)
                }
            }
        }
    }

    // Pass one done: everything that moves sideways, clipped to the text half.
    flush_pane(t, text_clip, win_w, win_h)

    // Pass two: the fixed gutter. The current-line bar is queued again at full row width and
    // the scissor keeps this half of it, which is why the bar reads as one unbroken band across
    // a boundary neither pass draws over.
    for line, vrow in draw_lines {
        y := r.y + i32(vrow) * row_h - v.off
        ty := f32(y) + (f32(row_h) - lh) / 2
        on_cur_line := line == cur_line
        if on_cur_line {
            fill(t, Rect{r.x, y, r.w, row_h}, th.line_highlight)
        }
        buf: [12]u8
        s := strconv.write_int(buf[:], i64(line_number(a.line_numbers, line, cur_line)), 10)
        nx := f32(r.x) + cw + f32(v.gutter - len(s)) * cw // right-align in gutter
        text_draw(t, s, nx, ty, on_cur_line ? th.fg : th.muted)
    }

    // The painter owns its region and ends with its own flush (the ClayCustom contract).
    // `clip` arrives already intersected with the box, and the two halves cover it between
    // them, so this is the whole obligation.
    flush_pane(t, gutter_clip, win_w, win_h)
}

// The editor pane. Scrolls to keep the cursor visible on BOTH axes — there is no soft wrap,
// so a long line is reached by moving the window sideways — the view easing toward the target
// top line and left column together. (Tabs currently advance one cell — fine for the
// space-indent default; proper tab width is a TODO, and it is the one thing that would make a
// column stop being a rune index.) See editor_view for why the view is built twice.
editor_frame :: proc(t: ^Text, a: ^App, pane: Rect, now: f64) {
    b := editor_current(&a.editor)
    area, row_h, rows := editor_geom(pane, a.scale, t.font.line_height)
    if area.w <= 0 || area.h <= 0 {
        return
    }
    buffer_sync_folds(b) // drop folds invalidated by an edit; keep the scroll on a real line

    // The window the LAST frame painted is what the pointer is over, so the click resolves
    // against a view built before this frame's scroll policy runs.
    v := editor_view(b, &t.font, area, row_h, rows, now)
    editor_click(a, editor_hit(a, b, v), now)
    editor_drag(a, b, v, now) // and extend a capture the press already made

    // Then move the viewport, so a click that put the caret off-screen scrolls in the same
    // frame it was made, and rebuild the view over the result. Rows first: the column policy
    // reads whether the page is still following the caret, and measures its bound over the
    // lines the page settled on (see buffer_hscroll_apply).
    buffer_scroll_apply(b, rows, a.scroll_mode == .Middle, a.last_input_at)
    buffer_hscroll_apply(b, v.cols, editor_longest_visible(b, b.scroll, rows + 2), a.last_input_at)
    v = editor_view(b, &t.font, area, row_h, rows, now)

    editor_declare(a, &t.font, pane, v, now)
}

// Test-facing wrapper; see filetree_layout.
editor_layout :: proc(
    a: ^App,
    f: ^Font,
    pane: Rect,
    win_w, win_h: i32,
    v: Editor_View,
    now: f64,
) -> clay.ClayArray(clay.RenderCommand) {
    clay_window_begin(win_w, win_h)
    if clay.UI(clay.ID(WIN_ROOT))(clay_window_root(win_w, win_h)) {
        editor_declare(a, f, pane, v, now)
    }
    return clay.EndLayout(0)
}

// --- painters ---

// Indent guides for one line: a thin vertical rail at the left edge of each indent
// level the line sits at. The rail of the cursor's enclosing scope (sc_level, over
// rows [sc_lo, sc_hi]) is drawn in the active colour so the current block stands out.
@(private = "file")
draw_indent_guides :: proc(t: ^Text, b: ^Buffer, line: int, text_x: f32, y, row_h: i32, cw: f32, unit: int, th: ^Theme, scope: Scope) {
    levels := buffer_indent_levels(b, line, unit)
    gw := max(i32(1), i32(cw) / 16) // hairline, ~1px
    aw := gw * 2 // the active scope rail is a touch thicker so it reads as the focus
    for lvl in 0 ..< levels {
        // Sit the rail half a cell into the indentation it marks, not hard against the
        // glyph grid — it reads as a guide between columns rather than under them.
        gx := i32(text_x + cw * (f32(lvl * unit) + 0.5))
        if scope_highlights(scope, line, lvl) {
            fill(t, Rect{gx - (aw - gw) / 2, y, aw, row_h}, th.indent_guide_active) // centred on the rail
        } else {
            fill(t, Rect{gx, y, gw, row_h}, th.indent_guide)
        }
    }
}

// The live `:f` search marks on one line: a bar behind every hit, the one the caret sits on in
// its own brighter colour. An under-quad like the selection bar, so the glyphs stay on top.
//
// The list is in line order and a paint asks once per visible row, so the row's first hit is
// found by binary search rather than by walking the lot — a common word in a large file is
// thousands of matches, and only the handful on this line can be drawn.
@(private = "file")
draw_find_marks :: proc(t: ^Text, f: ^Find, line: int, text_x: f32, y, row_h: i32, cw: f32, th: ^Theme) {
    if !f.show {
        return
    }
    for i := find_first_on_line(f.matches[:], line); i < len(f.matches); i += 1 {
        m := f.matches[i]
        if m.line != line {
            break
        }
        color := i == f.cur ? th.find_current : th.find_match
        fill(t, Rect{i32(text_x + cw * f32(m.col)), y, i32(cw * f32(m.n)), row_h}, color)
    }
}

// Ghosted whitespace markers over a line's LEADING indentation: a small centred dot
// per space, a short horizontal stroke per tab. Only the indent run is marked — inner
// spacing between words stays clean. y is the row top; row_h the padded row height.
@(private = "file")
draw_whitespace :: proc(t: ^Text, l: ^Line, text_x, y: f32, row_h: i32, cw, scale: f32, color: [3]f32) {
    for r, col in l.text {
        if r != ' ' && r != '\t' {
            break
        }
        cx := text_x + cw * f32(col)
        if r == ' ' {
            d := max(i32(2), i32(2 * scale)) // a small square dot
            dx := i32(cx + (cw - f32(d)) / 2)
            dy := i32(y) + (row_h - d) / 2
            fill(t, Rect{dx, dy, d, d}, color)
        } else { // tab: a short stroke across the cell, vertically centred
            h := max(i32(1), i32(scale))
            sx := i32(cx + cw * 0.2)
            sy := i32(y) + (row_h - h) / 2
            fill(t, Rect{sx, sy, i32(cw * 0.6), h}, color)
        }
    }
}

// The collapsed-block marker: three dots trailing a folded header line, in accent.
@(private = "file")
draw_fold_marker :: proc(t: ^Text, x, y, lh: f32, scale: f32, color: [3]f32) {
    d := max(i32(2), i32(2 * scale))
    cy := i32(y + lh / 2) - d / 2
    for k in 0 ..< 3 {
        dx := i32(x + f32(k) * (f32(d) + 2 * scale))
        fill(t, Rect{dx, cy, d, d}, color)
    }
}

// Draws a line's runes split into runs of one colour each (syntax highlighting).
// Monospace makes each run's x pure arithmetic. Falls back to a single fallback-colour
// draw if the colour count doesn't match (belt-and-suspenders; they always match).
@(private = "file")
draw_runes_colored :: proc(t: ^Text, runes: []rune, colors: Row_Colors, x, y: f32, fallback: [3]f32) {
    if len(colors) != len(runes) {
        text_draw_runes(t, runes, x, y, fallback)
        return
    }
    cw := t.font.cell_w
    for i := 0; i < len(runes); {
        j := i + 1
        for j < len(runes) && colors[j] == colors[i] {
            j += 1
        }
        text_draw_runes(t, runes[i:j], x + cw * f32(i), y, colors[i])
        i = j
    }
}

// Digits in a non-negative integer — the gutter's width, and nothing else uses it.
@(private = "file")
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
    return line + 1 // absolute (and the cursor line under relative/hybrid)
}
