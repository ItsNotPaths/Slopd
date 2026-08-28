package gfx

// The paint target, and the only thing above gfx that names a backend — by not naming one. A
// front-end holds a Draw, calls the verbs below, and never learns whether the pixels became GL
// quads or terminal cells.
//
// The backend is a runtime choice: `draw_init_gl` opens a window's worth of GL state, a cell
// backend opens a grid instead, and both answer the same verbs afterwards. The union is what
// makes that switch total — add a variant and the compiler names every verb still missing an
// arm, because none of the switches below are #partial.
Draw :: struct {
    backend: union {
        GL_Draw,
        Cell_Draw,
    },
}

// Something a backend can paint but not describe: a GL texture name, a cell-mode nothing. The
// fields are the backend's own — read w/h, never `handle`.
Image :: struct {
    handle: u32,
    w, h:   i32,
}

image_valid :: proc(img: Image) -> bool {
    return img.handle != 0
}

// The GL backend: `loader` is the window system's symbol lookup (GLFW's is
// `glfw.gl_set_proc_address`), then an atlas baked from `ttf` at logical_px * scale. One per
// window, and the only place GL is brought up.
draw_init_gl :: proc(
    d: ^Draw,
    loader: proc(p: rawptr, name: cstring),
    ttf: []u8,
    logical_px, scale: f32,
) -> bool {
    gl_load(loader)
    g: GL_Draw
    if !gl_text_init(&g, ttf, logical_px, scale) {
        return false
    }
    d.backend = g
    return true
}

// The cell backend: a `cols` x `rows` grid. No window, no context, no font — the terminal owns
// all three, which is why this takes nothing but a size.
draw_init_cells :: proc(d: ^Draw, cols, rows: i32) -> bool {
    c: Cell_Draw
    if !cell_init(&c, cols, rows) {
        return false
    }
    d.backend = c
    return true
}

draw_destroy :: proc(d: ^Draw) {
    switch &b in d.backend {
    case GL_Draw:
    // the atlas and the VBOs go with the GL context
    case Cell_Draw:
        cell_destroy(&b)
    }
    d.backend = nil
}

// The frame as bytes to write at a terminal. Empty for a backend that presents itself.
frame_bytes :: proc(d: ^Draw) -> []u8 {
    switch &b in d.backend {
    case GL_Draw:
        return nil // SwapBuffers is the caller's
    case Cell_Draw:
        return cell_emit(&b)
    }
    return nil
}

// What layout measures itself in. Never a Font: see Face.
face :: proc(d: ^Draw) -> Face {
    switch &b in d.backend {
    case GL_Draw:
        return b.font.face
    case Cell_Draw:
        return b.face
    }
    return {}
}

// The live copy, for Clay's measure hook: a re-bake must be picked up without re-registering.
face_live :: proc(d: ^Draw) -> ^Face {
    switch &b in d.backend {
    case GL_Draw:
        return &b.font.face
    case Cell_Draw:
        return &b.face
    }
    return nil
}

// The logical size or the DPI scale changed. Reports a re-bake, since the cell advance moved and
// every cached measurement is stale.
draw_apply :: proc(d: ^Draw, logical_px, scale: f32) -> (rebaked: bool) {
    switch &b in d.backend {
    case GL_Draw:
        return gl_text_apply(&b, logical_px, scale)
    case Cell_Draw:
        return false // one size; the terminal owns it
    }
    return false
}

// Backgrounds, bars, selection.
fill :: proc(d: ^Draw, r: Rect, c: [3]f32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_fill(&b, r, c)
    case Cell_Draw:
        cell_fill(&b, r, c)
    }
}

// A rect's edge. A pixel backend draws the thin ring it always did; a grid draws box-drawing
// glyphs, because its thinnest quad is a whole cell and would read as a solid bar.
border :: proc(d: ^Draw, r: Rect, c: [3]f32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_border(&b, r, c)
    case Cell_Draw:
        cell_border(&b, r, c)
    }
}

// Above the glyphs: carets, which sit on top of the text on their column.
caret :: proc(d: ^Draw, r: Rect, c: [3]f32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_caret(&b, r, c)
    case Cell_Draw:
        cell_caret(&b, r, c)
    }
}

// Decoded RGBA pixels into whatever the backend can draw. The caller keeps the CPU copy or not
// as it likes; the backend has its own by the time this returns.
//
// The two image verbs take a nil Draw, unlike the painting ones: they are reachable from product
// code outside a frame (App borrows the backend, and that borrow is nil until main has one, or
// if bring-up failed and the deferred teardown still runs).
image_upload :: proc(d: ^Draw, pixels: rawptr, w, h: i32) -> (Image, bool) {
    if d == nil {
        return {}, false
    }
    switch &b in d.backend {
    case GL_Draw:
        return gl_image_upload(pixels, w, h)
    case Cell_Draw:
        return {}, false // no picture in a grid; the caller keeps its placeholder
    }
    return {}, false
}

image_free :: proc(d: ^Draw, img: ^Image) {
    if d == nil {
        img^ = {} // no backend ever held it; dropping the handle is the whole of the free
        return
    }
    switch &b in d.backend {
    case GL_Draw:
        gl_image_free(img)
    case Cell_Draw:
        img^ = {}
    }
}

image_push :: proc(d: ^Draw, img: Image, dst: Rect) {
    switch &b in d.backend {
    case GL_Draw:
        gl_image_push(&b, img.handle, dst)
    case Cell_Draw: // nothing was ever uploaded, so nothing to push
    }
}

// The frame's ground, before any pane paints. `bg` shows through the gutter between panes.
frame_begin :: proc(d: ^Draw, win_w, win_h: i32, bg: [3]f32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_frame_begin(win_w, win_h, bg)
    case Cell_Draw:
        cell_frame_begin(&b, win_w, win_h, bg)
    }
}

text_draw :: proc(d: ^Draw, s: string, x, y: f32, color: [3]f32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_text_draw(&b, s, x, y, color)
    case Cell_Draw:
        cell_text_string(&b, s, x, y, color)
    }
}

text_draw_runes :: proc(d: ^Draw, runes: []rune, x, y: f32, color: [3]f32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_text_draw_runes(&b, runes, x, y, color)
    case Cell_Draw:
        cell_text(&b, runes, x, y, color)
    }
}

// False when the backend cannot draw the icon; the caller falls back to a plain swatch.
icon_draw :: proc(d: ^Draw, r: rune, box: Rect, px: f32, color: [3]f32) -> bool {
    switch &b in d.backend {
    case GL_Draw:
        return gl_icon_draw(&b, r, box, px, color)
    case Cell_Draw:
        return false // no icon face; the caller falls back to a swatch
    }
    return false
}

// Text at a second size. A backend with one size draws it at that size; the caller centres from
// text_sized_cell either way.
text_draw_sized :: proc(d: ^Draw, s: string, x, y, px: f32, color: [3]f32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_text_draw_sized(&b, s, x, y, px, color)
    case Cell_Draw:
        cell_text_string(&b, s, x, y, color) // one size in a grid
    }
}

// Everything accumulated for this pane, clipped to `clip`, then the scratch is emptied.
flush_pane :: proc(d: ^Draw, clip: Rect, win_w, win_h: i32) {
    switch &b in d.backend {
    case GL_Draw:
        gl_flush_pane(&b, clip, win_w, win_h)
    case Cell_Draw:
        cell_flush_pane(&b, clip)
    }
}

// Vertices submitted this frame, for the perf log. A cell backend counts cells.
frame_verts :: proc(d: ^Draw) -> int {
    switch &b in d.backend {
    case GL_Draw:
        return b.verts
    case Cell_Draw:
        return b.painted
    }
    return 0
}

frame_verts_reset :: proc(d: ^Draw) {
    switch &b in d.backend {
    case GL_Draw:
        b.verts = 0
    case Cell_Draw:
        b.painted = 0
    }
}
