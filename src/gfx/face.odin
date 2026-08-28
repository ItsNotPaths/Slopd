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
    return i32(math.round(f32(n) * line_height / 16))
}

// The thinnest thing worth drawing: a focus ring, a pane gutter, a divider.
hairline :: proc(line_height: f32) -> i32 {
    return pad(line_height, 2)
}

// A gap that SEPARATES TEXT, as opposed to one that decorates. Padding is free to round away to
// nothing in a grid; this is not, because two labels with no gap between them read as one word.
// One cell is the least a grid can put there.
gap :: proc(size: f32) -> i32 {
    return max(1, i32(size))
}
