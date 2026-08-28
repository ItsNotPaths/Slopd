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

// Light triple-dash. Unicode has no dashed corners, so the joins are the solid light ones.
@(private = "file")
BORDER_H :: '┄'
@(private = "file")
BORDER_V :: '┆'

// A rect's edge as glyphs, which is what a grid has instead of a thin quad: a filled border cell
// would be a solid block a whole cell wide, far heavier than the 2px line it stands in for.
@(private)
cell_border :: proc(c: ^Cell_Draw, r: Rect, col: [3]f32) {
    if r.w < 2 || r.h < 2 {
        return
    }
    x1, y1 := r.x + r.w - 1, r.y + r.h - 1
    cell_repeat(c, BORDER_H, int(r.w - 2), r.x + 1, r.y, col)
    cell_repeat(c, BORDER_H, int(r.w - 2), r.x + 1, y1, col)
    for y in r.y + 1 ..< y1 {
        cell_repeat(c, BORDER_V, 1, r.x, y, col)
        cell_repeat(c, BORDER_V, 1, x1, y, col)
    }
    cell_repeat(c, '┌', 1, r.x, r.y, col)
    cell_repeat(c, '┐', 1, x1, r.y, col)
    cell_repeat(c, '└', 1, r.x, y1, col)
    cell_repeat(c, '┘', 1, x1, y1, col)
}

@(private = "file")
cell_repeat :: proc(c: ^Cell_Draw, r: rune, n: int, x, y: i32, fg: [3]f32) {
    if n <= 0 {
        return
    }
    at := len(c.scratch)
    for _ in 0 ..< n {
        append(&c.scratch, r)
    }
    append(&c.runs, Cell_Run{x, y, at, n, fg})
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
        cell_paint_fill(c, rect_isect(q.r, clip), q.c)
    }
    for run in c.runs {
        for i in 0 ..< run.n {
            cell_paint_rune(c, run.x + i32(i), run.y, c.scratch[run.at + i], run.fg, clip)
        }
    }
    for q in c.over {
        cell_paint_over(c, rect_isect(q.r, clip), q.c)
    }
    clear(&c.under)
    clear(&c.runs)
    clear(&c.over)
    clear(&c.scratch)
}

// A fill COVERS what is under it, so it clears the runes as well as setting the colour. Without
// that, a badge drawn over a terminal keeps the terminal's characters and reads as "C3" where it
// should read " 3 " — the pane below bleeds through its own overlay.
//
// Safe against the layer order this backend promises: every fill in a flush composites before
// every glyph run, so a pane's own text is written after its own background whichever order the
// two were declared in.
@(private = "file")
cell_paint_fill :: proc(c: ^Cell_Draw, r: Rect, col: [3]f32) {
    for y in r.y ..< r.y + r.h {
        for x in r.x ..< r.x + r.w {
            if cell := cell_at(c, x, y); cell != nil {
                cell^ = Cell{r = ' ', fg = col, bg = col}
                c.painted += 1
            }
        }
    }
}

// A caret MARKS a cell rather than covering it: the character under a block cursor is still the
// character you are on, so only the colour changes.
@(private = "file")
cell_paint_over :: proc(c: ^Cell_Draw, r: Rect, col: [3]f32) {
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

// The grid as one write, emitting an SGR pair only where the colour changes. Truecolor
// throughout — a terminal without it is not one this backend targets.
//
// Every row is placed with an explicit cursor move rather than a newline. A row that fills the
// last column leaves the cursor in the auto-wrap pending state, and the newline after it then
// counts twice: the whole screen walks downward a row per frame and the bottom of it falls off.
@(private)
cell_emit :: proc(c: ^Cell_Draw) -> []u8 {
    clear(&c.out)
    fg, bg := [3]f32{-1, -1, -1}, [3]f32{-1, -1, -1}
    for y in 0 ..< c.rows {
        cell_cup(&c.out, y + 1)
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

// CUP: place the cursor at the start of row `row`, counting from 1.
@(private = "file")
cell_cup :: proc(out: ^[dynamic]u8, row: i32) {
    buf: [8]u8
    append(out, "\e[")
    append(out, strconv.write_int(buf[:], i64(row), 10))
    append(out, ";1H")
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
