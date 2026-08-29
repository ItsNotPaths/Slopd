package gfx

import "core:math"
import "core:unicode/utf8"

// The drawing face as everything above gfx sees it: how big a cell is, and what the backend can
// draw. Layout, hit testing and every *_declare read this; none of them may name a Font, an
// atlas or a texture.
//
// A cell backend sets cell_w and line_height to 1 and ascent to 0: the same arithmetic then
// lays out in cells instead of pixels.
Face :: struct {
    cell_w:      f32, // monospace advance
    line_height: f32,
    ascent:      f32, // baseline offset from the top of the line
    px:          f32, // the size these were measured at; the ratio base for a second bake size
    icons:       bool, // icon glyphs are drawable; else callers fall back to a plain swatch
}

// Monospace, so the RUNE count: `len` counts bytes, which right-aligns a label carrying
// anything non-ASCII one cell short per byte.
text_w :: proc(s: string, cell_w: f32) -> f32 {
    return f32(utf8.rune_count_in_string(s)) * cell_w
}

// The body cell scaled by the size ratio. Text at a second bake size is still monospace, so a
// caller can centre a string without measuring it. A cell backend has one size, so px == face.px
// and the ratio is 1.
text_sized_cell :: proc(face: Face, px: f32) -> f32 {
    if face.px <= 0 {
        return face.cell_w
    }
    return face.cell_w * (px / face.px)
}

// `n` layout units, where one unit is a sixteenth of a line box: 1px at a desktop font size,
// and nothing at all in a cell grid, where the smallest mark a backend can make is a whole cell.
// Every measurement in the layout below the size of a text row is counted in these, so the same
// constant is the pixel gap it always was under GL and collapses in a terminal, and no layout
// code has to know which backend is up.
//
// Scaled THEN rounded, not the other way about: a 15px font has a 15.89px line box, and rounding
// the unit first floors it to zero and takes every gap in the program with it.
pad :: proc(line_height: f32, n: i32) -> i32 {
    if line_height <= 1 {
        return 0 // a grid: there is no space smaller than a cell for padding to live in
    }
    return i32(math.round(f32(n) * line_height / 16))
}

// The thinnest thing worth drawing: a focus ring, a pane gutter, a divider.
hairline :: proc(line_height: f32) -> i32 {
    return pad(line_height, 2)
}

// A hairline that has to stay VISIBLE: a pane's own edge. Padding may round away to nothing, but
// an edge that does leaves two panes touching with no way to tell which one you are in. One cell
// is the least a grid can draw.
edge :: proc(line_height: f32) -> i32 {
    return max(1, hairline(line_height))
}

// A gap that SEPARATES TEXT, as opposed to one that decorates. Padding is free to round away to
// nothing in a grid; this is not, because two labels with no gap between them read as one word.
// One cell is the least a grid can put there.
gap :: proc(size: f32) -> i32 {
    return max(1, i32(size))
}

// One text row: the line box, whole. Every stacked row in the graphical mode is this tall, so a
// row here is a row in the terminal pane and a row in the strip.
row :: proc(line_height: f32) -> i32 {
    return max(1, i32(line_height))
}

// `n` whole cells. The horizontal twin of `row`, for a margin or a fixed column that has to land
// on the grid rather than near it.
cells :: proc(cell_w: f32, n: i32) -> i32 {
    return max(0, i32(cell_w) * n)
}

// The column the grid is in phase with. Every pane's content starts inside its ring, so that is
// where the columns start: at phase 0 the ring would push every pane's first column a whole cell
// in, and the band it left behind would show under anything pinned to that edge.
grid_phase :: proc(line_height: f32) -> i32 {
    return edge(line_height)
}

// How far past the last grid column `x` sits, counting from `from` — a point already on the grid,
// usually the content area's own left edge. Subtract it to walk a box the solver centred (or
// pinned to a right edge) back onto a column.
grid_off :: proc(x, from, cell_w: f32) -> f32 {
    if cell_w <= 0 {
        return 0
    }
    d := x - from
    return d - math.floor(d / cell_w) * cell_w
}

// A box that keeps its size but starts on a column — a popup placed at the pointer, which lands
// wherever the pointer was. Back to the column below it, so a box the caller already fitted on
// screen stays on it.
grid_place :: proc(r: Rect, cell_w, line_h: f32) -> Rect {
    ph := grid_phase(line_h)
    if cw := i32(cell_w); cw > 0 && r.x > ph {
        return Rect{ph + (r.x - ph) / cw * cw, r.y, r.w, r.h}
    }
    return r
}

// Whole cells that fit in a pixel width — the count, where `cells` gives the width.
cells_fit :: proc(w: i32, cell_w: f32) -> i32 {
    cw := i32(cell_w)
    return cw > 0 ? max(0, w / cw) : 0
}

// A pane's content, put in phase with the window's COLUMNS: the origin moves IN to the next cell
// boundary. So column 40 of the editor is column 40 of the command line, whatever the split
// between them lands on.
//
// Rows want no such thing. Every pane's content starts at the top of the same content area and
// every row is one line box, so a row in one pane is already level with a row in the next.
//
// The far edges stay where they are: trimmed back to a whole cell, a pane would keep a band of
// background under whatever is pinned to that edge — which is a gap, not alignment.
grid_snap :: proc(r: Rect, cell_w, line_h: f32) -> Rect {
    cw, ph := i32(cell_w), grid_phase(line_h)
    if cw <= 0 || r.w <= 0 || r.h <= 0 {
        return r
    }
    x := ph + ((max(0, r.x - ph) + cw - 1) / cw) * cw
    return Rect{x, r.y, max(0, r.x + r.w - x), r.h}
}
