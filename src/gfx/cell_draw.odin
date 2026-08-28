package gfx

import "core:math"
import "core:strconv"
import "core:unicode/utf8"

// The cell arm of Draw: a terminal grid instead of a framebuffer. One unit is one cell, so the
// arithmetic every *_declare already does in pixels lands on columns and rows unchanged — that
// is what Face's cell_w = line_height = 1 buys, and why ascent is 0 here (a cell has no
// baseline to offset from).
//
// The GL arm's compositing order is a promise the layout relies on: within one pane, quads paint
// UNDER glyphs whatever order they were declared in, and carets paint OVER them. A grid has no
// z, so the three are batched exactly as GL batches them and composited at flush_pane. Writing
// straight into the grid would let a background declared after a label erase it.

Cell :: struct {
    r:  rune,
    fg: [3]f32,
    bg: [3]f32,
}

@(private = "file")
Cell_Rect :: struct {
    r: Rect,
    c: [3]f32,
}

// The run's text lives in Cell_Draw.scratch, which is cleared with the batches.
@(private = "file")
Cell_Run :: struct {
    x, y:  i32,
    at, n: int,
    fg:    [3]f32,
}

Cell_Draw :: struct {
    face:       Face,
    cols, rows: i32,
    cells:      []Cell,
    under:      [dynamic]Cell_Rect,
    runs:       [dynamic]Cell_Run,
    over:       [dynamic]Cell_Rect,
    scratch:    [dynamic]rune,
    out:        [dynamic]u8, // the emitted frame, rebuilt by cell_emit
    painted:    int,         // cells written this frame, for the perf log
}

// icons = false: a terminal draws whatever glyphs its own font has, and gfx cannot know which,
// so the file browser takes its plain-swatch path rather than asking for Nerd Font codepoints.
@(private)
cell_init :: proc(c: ^Cell_Draw, cols, rows: i32) -> bool {
    if cols <= 0 || rows <= 0 {
        return false
    }
    c.face = Face {
        cell_w      = 1,
        line_height = 1,
        ascent      = 0,
        px          = 1,
        icons       = false,
    }
    cell_resize(c, cols, rows)
    return true
}

@(private = "file")
cell_resize :: proc(c: ^Cell_Draw, cols, rows: i32) {
    if c.cols == cols && c.rows == rows {
        return
    }
    delete(c.cells)
    c.cols, c.rows = cols, rows
    c.cells = make([]Cell, int(cols * rows))
}

@(private)
cell_destroy :: proc(c: ^Cell_Draw) {
    delete(c.cells)
    delete(c.under)
    delete(c.runs)
    delete(c.over)
    delete(c.scratch)
    delete(c.out)
    c^ = {}
}

// The grid's ground. Resizes to the terminal first, so a SIGWINCH costs one reallocation.
@(private)
cell_frame_begin :: proc(c: ^Cell_Draw, cols, rows: i32, bg: [3]f32) {
    cell_resize(c, cols, rows)
    for &cell in c.cells {
        cell = Cell{r = ' ', fg = bg, bg = bg}
    }
    c.painted = 0
}

@(private)
cell_fill :: proc(c: ^Cell_Draw, r: Rect, col: [3]f32) {
    if r.w > 0 && r.h > 0 {
        append(&c.under, Cell_Rect{r, col})
    }
}

// A caret is a sub-cell bar in pixels; a grid's smallest mark is one cell, so it becomes the
// cell it starts in. Without the clamp a 2px caret would paint two columns wide.
@(private)
cell_caret :: proc(c: ^Cell_Draw, r: Rect, col: [3]f32) {
    if r.w > 0 && r.h > 0 {
        append(&c.over, Cell_Rect{Rect{r.x, r.y, 1, r.h}, col})
    }
}

@(private)
cell_text :: proc(c: ^Cell_Draw, runes: []rune, x, y: f32, fg: [3]f32) {
    if len(runes) == 0 {
        return
    }
    at := len(c.scratch)
    append(&c.scratch, ..runes)
    append(&c.runs, Cell_Run{i32(math.round(x)), i32(math.round(y)), at, len(runes), fg})
}

@(private)
cell_text_string :: proc(c: ^Cell_Draw, s: string, x, y: f32, fg: [3]f32) {
    at := len(c.scratch)
    for r in s {
        append(&c.scratch, r)
    }
    if n := len(c.scratch) - at; n > 0 {
        append(&c.runs, Cell_Run{i32(math.round(x)), i32(math.round(y)), at, n, fg})
    }
}

// Under-quads, glyphs, carets — the GL arm's three layers, clipped to `clip` as its scissor
// does, then the batches are emptied.
@(private)
cell_flush_pane :: proc(c: ^Cell_Draw, clip: Rect) {
    for q in c.under {
        cell_paint_bg(c, rect_isect(q.r, clip), q.c)
    }
    for run in c.runs {
        for i in 0 ..< run.n {
            cell_paint_rune(c, run.x + i32(i), run.y, c.scratch[run.at + i], run.fg, clip)
        }
    }
    for q in c.over {
        cell_paint_bg(c, rect_isect(q.r, clip), q.c)
    }
    clear(&c.under)
    clear(&c.runs)
    clear(&c.over)
    clear(&c.scratch)
}

@(private = "file")
cell_paint_bg :: proc(c: ^Cell_Draw, r: Rect, col: [3]f32) {
    for y in r.y ..< r.y + r.h {
        for x in r.x ..< r.x + r.w {
            if cell := cell_at(c, x, y); cell != nil {
                cell.bg = col
                c.painted += 1
            }
        }
    }
}

@(private = "file")
cell_paint_rune :: proc(c: ^Cell_Draw, x, y: i32, r: rune, fg: [3]f32, clip: Rect) {
    if !rect_hit(clip, x, y) {
        return
    }
    if cell := cell_at(c, x, y); cell != nil {
        cell.r = r
        cell.fg = fg
        c.painted += 1
    }
}

@(private = "file")
cell_at :: proc(c: ^Cell_Draw, x, y: i32) -> ^Cell {
    if x < 0 || y < 0 || x >= c.cols || y >= c.rows {
        return nil
    }
    return &c.cells[int(y * c.cols + x)]
}

// The grid as one write: home, then every row, emitting an SGR pair only where the colour
// changes. Truecolor throughout — a terminal without it is not one this backend targets.
@(private)
cell_emit :: proc(c: ^Cell_Draw) -> []u8 {
    clear(&c.out)
    append(&c.out, "\e[H")
    fg, bg := [3]f32{-1, -1, -1}, [3]f32{-1, -1, -1}
    for y in 0 ..< c.rows {
        if y > 0 {
            append(&c.out, "\r\n")
        }
        for x in 0 ..< c.cols {
            cell := c.cells[int(y * c.cols + x)]
            if cell.fg != fg || cell.bg != bg {
                fg, bg = cell.fg, cell.bg
                cell_sgr(&c.out, fg, bg)
            }
            b, n := utf8.encode_rune(cell.r == 0 ? ' ' : cell.r)
            append(&c.out, ..b[:n])
        }
    }
    append(&c.out, "\e[0m")
    return c.out[:]
}

@(private = "file")
cell_sgr :: proc(out: ^[dynamic]u8, fg, bg: [3]f32) {
    append(out, "\e[38;2;")
    cell_rgb(out, fg)
    append(out, ";48;2;")
    cell_rgb(out, bg)
    append(out, 'm')
}

@(private = "file")
cell_rgb :: proc(out: ^[dynamic]u8, c: [3]f32) {
    buf: [4]u8
    for v, i in c {
        if i > 0 {
            append(out, ';')
        }
        n := int(clamp(v, 0, 1) * 255 + 0.5)
        append(out, strconv.write_int(buf[:], i64(n), 10))
    }
}
