package main

import "core:math"
import "core:strings"
import "vendor:glfw"
import clay "../bindings/clay"

// Field — the one-line text box, and the only one: the config pane's search row and free-text
// setting, and the file browser's path bar when the buttons are a line. A live `Doc` (so every
// motion, delete and selection op is the editor's own) drawn by ONE painter, because a caret is
// an over-quad and a selection is an under-quad — neither is a thing Clay lays out, and a
// Rectangle would paint beneath the glyphs it is meant to sit on.
//
// **Columns here are CELLS.** A field is a strip of the glyph grid — `off`, the box width, every
// press column — while a Doc counts bytes, so `doc_cells` bridges the two at each entry point and
// nothing in between has to think about it.
//
// The WINDOW is the field's other half: `off` is the first rune drawn, so a value longer than
// the box shows its tail with a '…' in the first cell. The path bar drives one (a path is read
// from its end); the config rows leave it at 0 and show the head, which is where a setting's
// meaning is. field_scroll is the policy, and it is pure — the frame that owns the field runs it.
//
// The POINTER half is the editor's, one line deep: a press captures through drag.odin, the grade
// fixes what a motion extends by, and the window follows the caret out of either edge. The KEYS
// are the Text binds (bind.odin) — motion, deletes, cut, copy, paste — so a field is a text box in
// the ways a text box is expected to be, in whichever pane it is standing.

// What the painter needs. Temp-allocated by field_declare, so it outlives EndLayout.
Field :: struct {
    doc:   ^Doc,
    off:   int,
    now:   f64,
    caret: bool, // the pane owns the keys, so this field may blink
}

// Declare the field as a Custom filling its parent. `id` is the caller's, so a pane keys its
// fields the way it keys its rows.
field_declare :: proc(id: clay.ElementId, f: Field) {
    cu := new(ClayCustom, context.temp_allocator)
    fd := new(Field, context.temp_allocator)
    fd^ = f
    cu^ = {paint = field_paint, user = fd}
    if clay.UI(id)(
        {layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, custom = {customData = cu}},
    ) {}
}

// How many cells the field's box holds.
field_cells :: proc(r: Rect, cell_w: f32) -> int {
    if cell_w <= 0 {
        return 0
    }
    return max(0, int(f32(r.w) / cell_w))
}

// The first rune to SHOW, given where it was showing from, how long the line is and where the
// caret sits. Cuts the HEAD and keeps the tail, and MOVES AS LITTLE AS IT CAN: a window re-aimed
// on every keystroke would slide the whole line sideways under a caret walking back through it.
//
// One cell is held back for the leading '…' and one for the caret past the last rune, which is
// what the two in `cells - 2` are. Below the width of the line it is 0: nothing is cut.
field_scroll :: proc(off, n, cur, cells: int) -> int {
    if cells <= 2 || n < cells {
        return 0
    }
    o := min(off, n - cells + 2) // never leave a gap at the right edge
    o = clamp(o, cur - cells + 2, cur) // and never let the caret off either end
    return max(0, o)
}

// Where a rune is DRAWN, in cells from the box's left edge: the ellipsis takes the first one
// whenever the head is cut. field_index is the same sum rearranged — a press's column back to a
// rune — so a click lands on the character it points at, cut head or not.
field_col :: proc(off, cur: int) -> int {
    return cur - off + (off > 0 ? 1 : 0)
}

field_index :: proc(off, col, n: int) -> int {
    return clamp(col - (off > 0 ? 1 : 0) + off, 0, n)
}

// --- the pointer ---

// The field as a PRESS sees it: which Doc, which capture it belongs to, and where the box
// landed. Built by the pane that owns the field — only it knows the box — and handed to the
// three procs below so they cannot be given three different ideas of the same field.
Field_Box :: struct {
    doc:    ^Doc,
    target: int, // drag.odin's target: FIELD_PATH, or the config row's index
    r:      Rect,
    off:    int,
    cw:     f32,
}

// The path line is one of a kind; a config field would be its ROW index, which is >= 0 — so a
// capture can never be mistaken for the other pane's.
FIELD_PATH :: -1

// The rune BOUNDARY under x, rounded: a caret sits BETWEEN characters. Its twin is floored,
// because pointing at the last `o` of "foo.bar" must select "foo" (editor_caret_col, same
// pixel, same two questions). Both are unclamped by the BOX — a drag runs past either edge.
field_boundary_at :: proc(f: Field_Box, x: i32, n: int) -> int {
    if f.cw <= 0 {
        return 0
    }
    return field_index(f.off, int(math.round((f32(x) - f32(f.r.x)) / f.cw)), n)
}

field_glyph_at :: proc(f: Field_Box, x: i32, n: int) -> int {
    if f.cw <= 0 {
        return 0
    }
    return field_index(f.off, int(math.floor((f32(x) - f32(f.r.x)) / f.cw)), n)
}

// A press inside the field: CAPTURE, then place the caret, select the word, or select the whole
// value — the grade the run of presses fixed, one line deep (a field's "line" is its value, so
// the editor's triple-click IS its select-all). Begun for every press, as the editor's is:
// whether a press is a drag is not something the press can know.
field_press :: proc(a: ^App, f: Field_Box, count: int) {
    d := f.doc
    if d == nil || doc_line_count(d) == 0 {
        return
    }
    cells := doc_cells(d, 0)
    n := cells_count(cells)
    at := cells_off(cells, field_boundary_at(f, a.mouse.click_x, n))
    glyph := cells_off(cells, field_glyph_at(f, a.mouse.click_x, n))
    drag_begin(a, .Field_Text, f.target, count, Pos{0, at}, glyph)
    switch {
    case count >= 3:
        doc_select_line(d, 0)
    case count == 2:
        doc_select_word(d, Pos{0, glyph})
    case a.mouse.click_shift:
        doc_set_head(d, Pos{0, at}, true)
    case:
        doc_reset_cursor(d, Pos{0, at})
    }
}

// Extend a live drag — called every frame by the pane that owns the field, beside its click.
// **No autoscroll timer**: past an edge the column simply keeps counting, so the selection walks
// by how far past the pointer is and field_scroll brings the window after it.
field_drag :: proc(a: ^App, f: Field_Box, now: f64) {
    d := f.doc
    if !a.mouse_on || !a.mouse.known || d == nil || doc_line_count(d) == 0 {
        return
    }
    if !drag_live(a, .Field_Text, f.target) {
        return
    }
    cells := doc_cells(d, 0)
    n := cells_count(cells)
    a.blink_base = now // the caret stays solid through the gesture, as it does through typing
    if a.drag.grade >= 2 {
        anchor, head := doc_drag_span(
            d,
            a.drag.grade,
            Pos{0, a.drag.anchor_glyph},
            Pos{0, cells_off(cells, field_glyph_at(f, a.mouse.x, n))},
        )
        doc_select_span(d, anchor, head)
        return
    }
    doc_set_head(d, Pos{0, cells_off(cells, field_boundary_at(f, a.mouse.x, n))}, true)
}

// --- the clipboard ---

// What a copy or a cut ACTS ON: the selection, or — with nothing selected — the whole value.
// That default is the field's own: the editor's "copy this line" would put a stray newline on
// the clipboard, and a field is a value rather than a line of a document.
field_span :: proc(d: ^Doc) -> (lo, hi: Pos) {
    if doc_line_count(d) == 0 {
        return {}, {}
    }
    c := d.cursors[d.primary]
    if cursor_has_selection(c) {
        return cursor_range(c)
    }
    return Pos{0, 0}, Pos{0, doc_line_len(d, 0)}
}

// Copy the span out, and for a cut delete it too. doc_cut's own no-selection case is already
// "the line", which in a one-line field is the same whole value.
field_copy :: proc(a: ^App, d: ^Doc, cut: bool) -> (changed: bool) {
    if doc_line_count(d) == 0 {
        return false
    }
    lo, hi := field_span(d)
    if text := doc_text(d, lo, hi); text != "" {
        clipboard_set(a, text, nil) // takes ownership of the clone
    }
    return cut ? doc_cut(d) : false
}

// Paste, cut at the first newline: the field is ONE line, and a second one would be text you
// can neither see nor delete.
field_paste :: proc(a: ^App, d: ^Doc) -> bool {
    clip := glfw.GetClipboardString(a.window)
    if i := strings.index_byte(clip, '\n'); i >= 0 {
        clip = clip[:i]
    }
    return doc_paste(d, clip)
}

// The field's runes at the box's left edge, with per-cursor selection spans under them and
// carets over them. Only the window is drawn: a rune off either edge is not queued at all.
field_paint :: proc(t: ^Text, r, clip: Rect, win_w, win_h: i32, a: ^App, user: rawptr) {
    e := (^Field)(user)
    if e == nil || e.doc == nil || doc_line_count(e.doc) == 0 {
        return
    }
    th := &a.theme
    cw := t.font.cell_w
    lh := t.font.line_height
    ex := f32(r.x)
    ty := f32(r.y) + (f32(r.h) - lh) / 2
    y := i32(ty) // selection / caret share the glyph cell's top

    cells := doc_cells(e.doc, 0)
    n := cells_count(cells)
    off := clamp(e.off, 0, n)
    lead := off > 0 ? 1 : 0 // the cell the ellipsis takes
    hi := clamp(off + max(0, field_cells(r, cw) - lead), off, n)

    for c in e.doc.cursors {
        if !cursor_has_selection(c) {
            continue
        }
        lo, up := cursor_range(c)
        s0 := clamp(cells_col(cells, lo.col), off, hi)
        s1 := clamp(cells_col(cells, up.col), off, hi)
        if s1 > s0 {
            x := ex + cw * f32(field_col(off, s0))
            fill(t, Rect{i32(x), y, i32(cw * f32(s1 - s0)), i32(lh)}, th.selection)
        }
    }
    if lead == 1 {
        text_draw(t, "…", ex, ty, th.muted)
    }
    text_draw_runes(t, cells.runes[off:hi], ex + cw * f32(lead), ty, th.fg)
    // `caret` is the gate the blink phase alone cannot be: a pane not being typed into stops
    // redrawing, so a caret drawn there would freeze mid-blink rather than go out.
    if e.caret && caret_blink_on(a, e.now) {
        for c in e.doc.cursors {
            cx := ex + cw * f32(field_col(off, clamp(cells_col(cells, c.head.col), off, hi)))
            caret(t, Rect{i32(cx), y, i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
    // The painter owns its region and ends with its own flush (the ClayCustom contract).
    // `clip` arrives already intersected with the box, so this is the whole obligation.
    flush_pane(t, clip, win_w, win_h)
}
