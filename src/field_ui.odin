package main

import "core:math"
import "core:strings"
import "vendor:glfw"
import clay "../bindings/clay"

// The one-line text box, and the only one: the config pane's search row and free-text setting,
// and the browser's path bar when the buttons are a line. A live `Doc`, so every motion, delete
// and selection op is the editor's own, drawn by ONE painter — a caret is an over-quad and a
// selection an under-quad, neither of which Clay lays out.
//
// Columns here are CELLS: a field is a strip of the glyph grid, while a Doc counts bytes, so
// `doc_cells` bridges the two at each entry point.
//
// The WINDOW is the other half: `off` is the first rune drawn, so a long value shows its tail
// behind a '…'. The path bar drives one; the config rows leave it at 0. field_scroll is the
// policy, and it is pure — the frame that owns the field runs it.
//
// The POINTER half is the editor's, one line deep, and the KEYS are the Text binds.

// Temp-allocated by field_declare, so it outlives EndLayout.
Field :: struct {
    doc:   ^Doc,
    off:   int,
    now:   f64,
    caret: bool, // the pane owns the keys, so this field may blink
}

// A Custom filling its parent. `id` is the caller's, so a pane keys its fields as it does rows.
field_declare :: proc(id: clay.ElementId, f: Field) {
    cu := new(ClayCustom, context.temp_allocator)
    fd := new(Field, context.temp_allocator)
    fd^ = f
    cu^ = {paint = field_paint, user = fd}
    if clay.UI(id)(
        {layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, custom = {customData = cu}},
    ) {}
}

field_cells :: proc(r: Rect, cell_w: f32) -> int {
    if cell_w <= 0 {
        return 0
    }
    return max(0, int(f32(r.w) / cell_w))
}

// Cuts the HEAD and keeps the tail, moving as little as it can: a window re-aimed every
// keystroke would slide the line sideways under a caret walking back through it. The two in
// `cells - 2` are the leading '…' and the caret past the last rune.
field_scroll :: proc(off, n, cur, cells: int) -> int {
    if cells <= 2 || n < cells {
        return 0
    }
    o := min(off, n - cells + 2) // no gap at the right edge
    o = clamp(o, cur - cells + 2, cur) // and the caret off neither end
    return max(0, o)
}

// In cells from the box's left edge; the ellipsis takes the first whenever the head is cut.
// field_index is the same sum rearranged, so a click lands on the character it points at.
field_col :: proc(off, cur: int) -> int {
    return cur - off + (off > 0 ? 1 : 0)
}

field_index :: proc(off, col, n: int) -> int {
    return clamp(col - (off > 0 ? 1 : 0) + off, 0, n)
}

// --- the pointer ---

// Which Doc, which capture, and where the box landed. Built by the pane that owns the field —
// only it knows the box — and handed to the three procs below, so they cannot disagree.
Field_Box :: struct {
    doc:    ^Doc,
    target: int, // drag.odin's target: FIELD_PATH, or the config row's index
    r:      Rect,
    off:    int,
    cw:     f32,
}

// A config field's target is its row index, which is >= 0, so the two can never be confused.
FIELD_PATH :: -1

// Rounded: a caret sits BETWEEN characters. Its twin floors, because pointing at the last `o`
// of "foo.bar" must select "foo". Both are unclamped by the box, since a drag runs past it.
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

// Capture, then place the caret, select the word, or select the whole value — the grade the run
// of presses fixed, one line deep, so the editor's triple-click IS select-all here. Begun for
// every press: a press cannot know whether it is a drag.
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

// Every frame, beside the click. No autoscroll timer: past an edge the column keeps counting,
// so the selection walks by how far past the pointer is and field_scroll follows.
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
    a.blink_base = now // the caret stays solid through the gesture
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

// The selection, or with nothing selected the whole value. The editor's "copy this line" would
// put a stray newline on the clipboard, and a field is a value, not a line of a document.
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

// doc_cut's own no-selection case is "the line", which here is the same whole value.
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

// Cut at the first newline: a second line would be text you can neither see nor delete.
field_paste :: proc(a: ^App, d: ^Doc) -> bool {
    clip := glfw.GetClipboardString(a.window)
    if i := strings.index_byte(clip, '\n'); i >= 0 {
        clip = clip[:i]
    }
    return doc_paste(d, clip)
}

// Per-cursor selection spans under the runes and carets over them. Only the window is drawn.
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
    y := i32(ty) // selection and caret share the glyph cell's top

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
    // `caret` is the gate the blink phase cannot be: a pane not being typed into stops
    // redrawing, so a caret drawn there would freeze mid-blink.
    if e.caret && caret_blink_on(a, e.now) {
        for c in e.doc.cursors {
            cx := ex + cw * f32(field_col(off, clamp(cells_col(cells, c.head.col), off, hi)))
            caret(t, Rect{i32(cx), y, i32(2 * a.scale), i32(lh)}, th.fg)
        }
    }
    // The ClayCustom contract: the painter ends with its own flush.
    flush_pane(t, clip, win_w, win_h)
}
