package main

import "core:math"
import "core:strconv"
import clay "../bindings/clay"

// The editor pane's UI half — C7, and the first surface on the far side of the boundary
// docs/clay-refactor.md draws: **Clay owns the frame, we own the body.** The text body is a
// 2D per-glyph surface — folds, per-glyph syntax colour, multi-cursor carets, selection
// spans, indent guides, whitespace markers — and one widget per glyph is absurd, so the
// pane declares ONE `Custom` element and the existing painter fills the box Clay reserves.
// Nothing about how a line is drawn changed here; it is a straight port.
//
// So what does the port buy, if the painting is untouched? The geometry. draw_editor used
// to compute the content area, the row height, the gutter width, the text column and the
// animated top as locals and throw them away, which is exactly why a click had nothing to
// resolve against. All of it is `Editor_View` now, computed once per phase from one proc,
// and the two things that must agree — where a glyph is PAINTED and where a pixel is READ
// BACK as a Pos — are derived from the same fields by the same helpers. editor_pos_at is
// the inverse of the painter's row/column arithmetic and cannot drift from it without the
// command-list test failing, because the test asserts the Custom's box IS the area the view
// was built from.
//
// The frame order is the template's, and the editor adds one wrinkle to it (see
// editor_view): the window is computed TWICE, either side of the click, because a click
// that moves the caret re-aims the scroll animation and that re-aim has to happen in the
// frame that caused it — C5c's rule 9, arriving here for the same reason procmon hit it.

// Extra vertical padding per row, in logical pixels — the twin of FT_ROW_PAD and
// GREP_ROW_PAD, and the value draw_editor has always used.
EDITOR_ROW_PAD :: 2

// Narrowest line-number gutter, in digits. A file under ten lines still gets two, so the
// text column does not jitter one cell to the left in a scratch buffer.
EDITOR_GUTTER_MIN :: 2

// How far past the end of a folded header's text its collapse marker may be clicked, in
// cells. The marker itself is three dots inside about one cell (draw_fold_marker); the
// target is deliberately wider than the paint, because the alternative to hitting it is
// putting the caret at end-of-line — a harmless miss either way, so the generous span
// costs nothing and a pixel-exact one would be a nuisance to hit.
EDITOR_FOLD_HIT_CELLS :: 2

// The pane's fixed geometry: the content area inside the focus ring, the row height, and
// how many whole rows fit. Pure, and the same shape as every other pane's `_geom` — the
// buffer-dependent half (the gutter, the animated top) is editor_view below.
//
// `rows` is at least 1 in a pane too short to hold one, exactly as the list panes report:
// the clip is what keeps an overflowing row inside the pane, not the count.
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
// under EDITOR_GUTTER_MIN. Both the painter and editor_pos_at size the text column from
// this one call, which is what stops a click landing one cell out in a thousand-line file.
editor_gutter_w :: proc(b: ^Buffer) -> int {
    return max(EDITOR_GUTTER_MIN, num_digits(len(b.lines)))
}

// Where column 0 starts: a one-cell left margin, the gutter, then a one-cell gap. The
// formula lives here rather than at its two call sites because those two are the paint and
// the hit test, and a text column that means one thing to each is the whole class of bug
// this refactor exists to delete.
editor_text_x :: proc(area_x: i32, gutter: int, cw: f32) -> f32 {
    return f32(area_x) + f32(gutter + 2) * cw
}

// Everything the editor's phases need to agree about: the box, the row grid, the text
// column and where the view actually IS this instant.
//
// `top` is the ANIMATED top, not b.scroll — b.scroll is where the viewport is heading and
// smooth_scroll says where it has got to — and `off` is the sub-row remainder that shifts
// every row up by a fraction of one. Row ids downstream are view indices off `top`.
Editor_View :: struct {
    area:   Rect,
    row_h:  i32,
    rows:   int, // whole rows that fit
    top:    int, // first line of the window (may be hidden; the walk skips forward)
    off:    i32, // sub-row pixel offset, subtracted from every row's y
    gutter: int, // line-number digits
    text_x: f32, // x of column 0
    cw:     f32,
    lh:     f32,
}

// Build the view — and RE-AIM the scroll animation, which is why this is not a pure query
// and why editor_frame calls it twice.
//
// smooth_scroll is what makes anim_active true, and app_next_wake schedules the next frame
// off exactly that (scroll.odin). The loop is WaitEvents-driven, so a frame that moves
// b.scroll — which is any frame a click lands a caret off-screen — and does not reach here
// again leaves nothing to wake the loop, and the view sits frozen part-scrolled until an
// unrelated event arrives. C5c found this with procmon's list; the editor tweens the same
// way, so it inherits the same rule rather than a special case.
editor_view :: proc(b: ^Buffer, f: ^Font, area: Rect, row_h: i32, rows: int, now: f64) -> Editor_View {
    top, off := smooth_scroll(&b.scroll_anim, b.scroll, now, row_h)
    gutter := editor_gutter_w(b)
    return Editor_View {
        area   = area,
        row_h  = row_h,
        rows   = rows,
        top    = top,
        off    = off,
        gutter = gutter,
        text_x = editor_text_x(area.x, gutter, f.cell_w),
        cw     = f.cell_w,
        lh     = f.line_height,
    }
}

// The lines the window shows, in paint order: walk down from `top` skipping folded-away
// lines, taking `count` of them. The visual row index counts only drawn lines while the
// line indices skip the hidden ones, which is the whole reason a screen row cannot be
// turned back into a line by arithmetic.
//
// One definition, two callers — the painter (which needs the list, for the highlight span
// as well as the rows) and editor_line_at_row (which needs the nth). Allocated in the
// frame's temp arena, freed wholesale by the main loop.
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

// A framebuffer point inside the pane, as a document position. The inverse of the painter's
// row/column arithmetic: the row grid backwards through the fold walk, the column by
// dividing out the cell advance.
//
// The column ROUNDS rather than truncating, so the caret lands on whichever side of the
// glyph the pointer is nearer — clicking the right half of a character puts the caret after
// it, which is what every editor does and what makes selecting up to end-of-word possible
// without overshooting. A point left of the text column (in the gutter or the margin)
// clamps to column 0 rather than reporting a miss: clicking the gutter means "this line",
// which is exactly where Home would put you.
//
// ok=false means the point is below the last drawn row — there is no line there, and
// inventing the last one would make a click in empty space jump the caret to the end of the
// file. Above the top row cannot happen: y is inside the area by the time we are called.
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

// The visible ROW a framebuffer y falls on, or -1 above the window. The one place the row
// grid is divided out, so editor_pos_at (which refuses a row past the last line) and
// editor_drag_pos (which clamps to the last DRAWN row) cannot come to different views about
// where a row is.
//
// The window is shifted up by `off`, so the point moves down by it to compensate.
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

// The caret BOUNDARY column under x — rounded, and unclamped to any line, so the two callers
// that need it (editor_pos_at inside the pane, editor_drag_pos past its edges) round it the
// one way. Its twin is editor_glyph_col below, and the pair is the whole of C7a's
// one-pixel-two-questions finding in two procs.
editor_caret_col :: proc(v: Editor_View, x: i32) -> int {
    if v.cw <= 0 {
        return 0
    }
    return int(math.round((f32(x) - v.text_x) / v.cw))
}

// The column of the GLYPH under the pointer — floored, where editor_pos_at rounds.
//
// One pixel, two different questions, and conflating them is a bug with exactly one cell of
// slop, which is the kind that survives a casual look. A caret column is a BOUNDARY between
// glyphs, so it rounds: the right half of a character means "after it". A word selection
// names a CHARACTER, so it floors: pointing anywhere in the last `o` of "foo.bar" must
// select "foo", where the rounded boundary would be 3 — the '.' — and select that instead.
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

// Resolve the pointer against the editor body: is it in the pane, and if so, where in the
// text. The body is a single Custom with no per-row boxes, so the second half is ours to
// compute — that division is the boundary working as intended, Clay routing to the surface
// and the surface reading its own pixels.
//
// THE FIRST HALF IS NOT clay.PointerOver, and the reason changed at C8a. It used to be
// forced: Clay held one tree, every pane declared its own, and the tree standing when a frame
// started was whichever pane declared LAST — so the editor, which declares FIRST, got `false`
// from PointerOver("ed_body") no matter where the pointer was. Clicks that simply never
// happened, with nothing in a command list to show for it. That was invariant 11
// (docs/clay-refactor.md) and it is retired: the window declares one tree, the editor is in
// it, and PointerOver would answer correctly today (tests/window_ui_test.odin pins that).
//
// The rect stays because it is the better tool for ONE box, not because Clay is unsafe:
// wheel_target answers the same question the same way (mouse.odin), rect_hit is half-open so
// a pane boundary cannot be claimed twice, and it needs no tree at all — which keeps
// editor_hit callable from a test that never declares anything.
//
// The fold marker is tested BEFORE the text, and only on a line that actually has one, so
// the ordinary case pays one array scan of the fold list (usually empty).
editor_hit :: proc(a: ^App, b: ^Buffer, v: Editor_View) -> Editor_Hit {
    if !a.mouse_on || !a.mouse.known || a.main != .Text {
        return {}
    }
    // Deliberately NOT gated on a.mouse.stood_down (mouse.odin). Standing the pointer down
    // suppresses HOVER, never a click: a press wakes the pointer before any pane can claim
    // it, so refusing hits here would only ever discard a click the user aimed — and would
    // make this pane behave differently from the four that resolve their rows regardless.
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
// "Single selects, double activates" is a rule about LISTS (C5b, C5c) and there is no list
// here: every count is a different grade of the same verb, selection, which is what a click
// in text has meant since before any of this. So a double click is not swallowed — the
// single click that preceded it placed a caret inside the word the double click then
// selects, and the two read as one gesture.
//
// The press is claimed only when something was actually hit, so a click in another pane is
// left for whoever else is drawing.
//
// Claiming it re-attaches this buffer's view if the wheel had detached it — a click IS a
// deliberate caret placement, so the policy resuming from it cannot move the view anywhere
// surprising (the line you clicked is on screen by definition), and leaving it detached
// would mean the arrows you press next scroll a view that no longer tracks them.
//
// It does that by clearing b.scroll_detached DIRECTLY rather than by stamping
// a.last_input_at, which is the obvious way and is wrong. That timestamp is global and the
// aux panes re-attach off it too (pane_input_at, scroll.odin) — gated on the aux pane
// holding FOCUS, which it may well be doing while you click in the editor. render draws the
// editor first, so the stamp would land before the aux pane read it, and clicking in the
// editor would snap a wheel-scrolled filetree back to its selection: action at a distance,
// the exact thing pane_input_at was introduced to prevent. blink_base is stamped, because
// holding the caret solid where you just clicked is a display nicety with no such reach.
editor_click :: proc(a: ^App, hit: Editor_Hit, now: f64) {
    if hit.kind == .None {
        return
    }
    count, ok := mouse_take_click(a)
    if !ok {
        return
    }
    b := editor_current(&a.editor)
    b.scroll_detached = 0
    a.blink_base = now

    if hit.kind == .Fold {
        if i := buffer_fold_index(b, hit.pos.line); i >= 0 {
            unordered_remove(&b.folds, i)
        }
        return // a marker is a BUTTON, and a button is not something you drag out of
    }

    // The press is now a CAPTURE (C7c): until the button comes up, every motion belongs to
    // this buffer's selection whatever pane the pointer wanders over. The grade goes in with
    // it and is not re-read per frame — that is the whole reason the machine stores it, and
    // it is what makes a double-click-drag keep growing by whole words (drag.odin).
    //
    // Begun for EVERY text click, including the plain single one, because the difference
    // between a click and a drag is not something the press can know: it is whether the
    // pointer moves before the release. A drag that never moves re-derives the position the
    // click already set, which is why the machine needs no motion threshold.
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

// Where a DRAG points, which is a different question from the one editor_hit answers and
// must be answered differently. A hit is REFUSED outside the pane, because a press there
// belongs to somebody else. A drag under capture must resolve a position wherever the
// pointer went, because the gesture already belongs to this pane (drag.odin) — and the
// moment it is most obviously still in use is the moment it leaves.
//
// So the ROW is clamped into the window and a point below the last DRAWN row (a buffer
// shorter than its pane) resolves to the last visible line rather than to "no line":
// dragging off the bottom means "to the end", never "nothing".
//
// The clamp is on the row and not on the pixel, because the pane's bottom edge sits in the
// MIDDLE of a row — 196px of 18px rows leaves a 16px strip the painter never fills — and a
// drag must not aim at a line that was never put on screen. x needs no clamp at all:
// editor_caret_col rounds a negative offset to a negative column and the line length clamps
// it, which is the same "the gutter means column 0" rule editor_pos_at already has.
//
// Both columns come back, exactly as Editor_Hit carries both: the caret boundary a
// character-grade drag extends to, and the glyph a word-grade drag expands around.
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

// The line a drag should be extending to, given the one the pointer resolved to — the same
// line while the pointer is inside the pane, and the autoscroll's own walk while it is past
// an edge.
//
// Past an edge the pointer has stopped naming a line, so Drag.over does (see the field for
// why it must be state rather than a per-frame derivation). It is SEEDED from the edge row
// the pointer left over, so a drag that runs off the bottom continues from the last line the
// user could see rather than from wherever it happened to press.
//
// The tick is spent only once the pointer is established as being outside, which is what
// makes leaving the pane act on the very next frame rather than up to DRAG_SCROLL_S later.
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
    // Walking past an edge is a request for the VIEWPORT POLICY to follow, so it re-attaches
    // the view the way a click does (and directly, for the same reason: last_input_at is
    // global and the aux panes re-attach off it). The wheel is free to detach the view
    // mid-drag while the pointer is still inside the pane — scroll with one hand, extend with
    // the other — but a detached view does not chase the caret, so a drag off the bottom edge
    // would otherwise extend the selection somewhere nobody can see.
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

// Extend a live text drag to wherever the pointer is now — the pointer's per-frame verb and
// the sibling of editor_click, run right beside it and for its reason: a gesture that walks
// the caret off-screen has to scroll in the frame that moved it, and buffer_scroll_apply
// comes after both.
//
// **Nothing here writes b.scroll.** Autoscroll walks the SELECTION past the visible window
// and the existing viewport policy follows it, which is the difference between adding a
// feature and adding a second thing that moves the view. It also means the drag scrolls in
// whichever scroll_mode the user chose, without this proc knowing there are two.
//
// The grades split where doc.odin splits them: a character drag is doc_set_head, which keeps
// whatever anchor the click established (a Shift+click's anchor is not the press position,
// and an Alt+click's cursor is the new one), while word and line re-derive BOTH ends every
// frame through doc_drag_span, because crossing back over the press point moves the anchor
// from one end of the pressed run to the other.
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

// Declare the pane and hand back the frame's command list. Three elements: the root that
// puts the pane where compute_layout decided it goes, the pane box, and the body — which is
// the whole content area as one Custom.
//
// The tree is deliberately this thin. There is no gutter element, no row elements: the
// current-line bar spans the gutter and the text as one strip, every row shares one
// sub-pixel scroll offset, and the line numbers ride the same walk as the glyphs. Declaring
// them separately would put a second copy of the row grid in the tree for Clay to solve —
// the exact duplication the refactor removes — to buy hit targets the surface already
// resolves for itself. The Custom hatch is for pixels no widget tree wants, and 60 rows of
// per-glyph colour is the case it was reserved for (docs/clay-refactor.md, the boundary).
//
//   ed_pane  the content area inside the focus ring, floating at the pane's own rect and
//            clipping its own content (painted by panel(), not here)
//     ed_body  the text surface, as a Custom — and the element editor_hit points at
editor_declare :: proc(a: ^App, f: ^Font, pane: Rect, v: Editor_View, now: f64) {
    b := editor_current(&a.editor)
    area := v.area

    body := new(Editor_Body, context.temp_allocator)
    body^ = Editor_Body{b = b, v = v, now = now}
    cu := new(ClayCustom, context.temp_allocator)
    cu^ = ClayCustom{paint = editor_paint_body, user = body}

    // No backgroundColor: panel() has already filled the pane and drawn its focus ring, and
    // Clay's transparent default emits no Rectangle at all — so this pane's command list is
    // the Custom bracketed by the pane's own clip, and nothing else.
    if clay.UI(clay.ID("ed_pane"))(clay_pane_box(area)) {
        if clay.UI(clay.ID("ed_body"))(
            {
                layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
                custom = {customData = cu},
            },
        ) {}
    }
}

// The text surface: a line-number gutter, the buffer's lines with syntax colour, the
// current-line bar, selection spans, indent guides, whitespace markers, fold markers and a
// caret per cursor. Unchanged from the draw_editor that lived in render.odin, beyond taking
// its box from Clay instead of computing one — which is the point of the checkpoint.
//
// Positions come from `r`, the box the solver resolved, and NOT from v.area, even though
// the two are equal by construction (ed_body fills ed_pane, which is sized to the area).
// Reading the box is the contract; the equality is what tests/editor_ui_test.odin pins, so
// a declaration that ever stopped honouring it would fail there rather than silently paint
// the body one place and hit-test it another.
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
    text_x := editor_text_x(r.x, v.gutter, cw)

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

        // Indent guides: a thin vertical rail at each indent level, the cursor's
        // scope drawn in the active colour. Then the ghosted whitespace markers.
        if a.show_guides {
            draw_indent_guides(t, b, line, text_x, y, row_h, cw, unit, th, scope)
        }
        if a.show_whitespace {
            draw_whitespace(t, l, text_x, f32(y), row_h, cw, a.scale, th.whitespace)
        }

        buf: [12]u8
        s := strconv.write_int(buf[:], i64(line_number(a.line_numbers, line, cur_line)), 10)
        nx := f32(r.x) + cw + f32(v.gutter - len(s)) * cw // right-align in gutter
        text_draw(t, s, nx, ty, on_cur_line ? th.fg : th.muted)

        k := line - v.top // index into the highlight rows (absolute-line based)
        if hl != nil && k < len(hl) && hl[k] != nil {
            draw_runes_colored(t, l.text[:], hl[k], text_x, ty, th.fg)
        } else {
            text_draw_runes(t, l.text[:], text_x, ty, th.fg)
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

    // The painter owns its region and ends with its own flush (the ClayCustom contract).
    // `clip` arrives already intersected with the box, so this is the whole obligation.
    flush_pane(t, clip, win_w, win_h)
}

// The editor pane. Scrolls to keep the cursor visible, the view sliding smoothly toward the
// target top line. (Tabs currently advance one cell — fine for the space-indent default;
// proper tab width is a TODO.)
//
// The order is the template's, and the doubled editor_view is the editor's own wrinkle —
// see that proc for why the second call is load-bearing rather than tidy.
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
    editor_drag(a, b, v, now) // and extend a capture the press already made (C7c)

    // Then move the viewport, so a click that put the caret off-screen scrolls in the same
    // frame it was made, and rebuild the view over the result.
    buffer_scroll_apply(b, rows, a.scroll_mode == .Middle, a.last_input_at)
    v = editor_view(b, &t.font, area, row_h, rows, now)

    editor_declare(a, &t.font, pane, v, now)
}

// The pane alone in a window, as a command list: the test-facing wrapper (see
// filetree_layout for why every pane keeps one).
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

// --- painters, moved wholesale from render.odin with the pane they serve ---

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
