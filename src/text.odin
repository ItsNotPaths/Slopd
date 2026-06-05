package main

import "core:math"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// The renderer. Two batches, both accumulating across a whole pane and flushed in
// one draw each: solid colour quads (fills, selection bars, current-line bars,
// carets, panel rings) and textured glyph quads sampling the font atlas. Colour is
// PER-VERTEX in both — that is what lets a syntax-highlighted line, with a colour
// per run, batch into a single glyph draw instead of one per run.
//
// A pane composites in three ordered layers (flush_pane draws them in this order
// under one scissor): under-quads -> glyphs -> over-quads. Under holds backgrounds,
// selection and the current-line bar; glyphs sit on top; over holds carets so they
// land above the text. Positions are physical pixels in Rect's top-left space; both
// shaders flip y to NDC.

Text :: struct {
    font:       Font,
    glyph_prog: u32,
    glyph_vao:  u32,
    glyph_vbo:  u32,
    glyph_us:   i32, // u_screen
    quad_prog:  u32,
    quad_vao:   u32,
    quad_vbo:   u32,
    quad_us:    i32, // u_screen
    glyphs:     [dynamic]f32, // scratch, 7 floats/vertex: x y u v r g b
    under:      [dynamic]f32, // scratch, 5 floats/vertex: x y r g b
    over:       [dynamic]f32, // scratch, same layout as `under`
    ttf:        []u8, // retained so the atlas can re-bake on DPI change
    logical_px: f32, // atlas is baked at logical_px * scale physical pixels
    scale:      f32, // DPI scale the atlas is currently baked for
    frame_verts: int, // vertices submitted this frame (reset in render; read by the perf log)
}

@(private = "file")
GLYPH_VERT := `#version 330 core
layout(location=0) in vec2 a_pos;
layout(location=1) in vec2 a_uv;
layout(location=2) in vec3 a_color;
uniform vec2 u_screen;
out vec2 v_uv;
out vec3 v_color;
void main() {
    gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0,
                       1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
    v_uv = a_uv;
    v_color = a_color;
}`

@(private = "file")
GLYPH_FRAG := `#version 330 core
in vec2 v_uv;
in vec3 v_color;
uniform sampler2D u_atlas;
out vec4 o_color;
void main() {
    o_color = vec4(v_color, texture(u_atlas, v_uv).r);
}`

@(private = "file")
QUAD_VERT := `#version 330 core
layout(location=0) in vec2 a_pos;
layout(location=1) in vec3 a_color;
uniform vec2 u_screen;
out vec3 v_color;
void main() {
    gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0,
                       1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
    v_color = a_color;
}`

@(private = "file")
QUAD_FRAG := `#version 330 core
in vec3 v_color;
out vec4 o_color;
void main() {
    o_color = vec4(v_color, 1.0);
}`

text_init :: proc(t: ^Text, ttf: []u8, logical_px, scale: f32) -> bool {
    t.ttf = ttf
    t.logical_px = logical_px
    t.scale = scale
    if !font_load(&t.font, ttf, logical_px * scale) {
        return false
    }

    gp, gok := gl.load_shaders_source(GLYPH_VERT, GLYPH_FRAG)
    if !gok {
        return false
    }
    t.glyph_prog = gp
    t.glyph_us = gl.GetUniformLocation(gp, "u_screen")
    gl.UseProgram(gp)
    gl.Uniform1i(gl.GetUniformLocation(gp, "u_atlas"), 0) // sampler -> unit 0

    qp, qok := gl.load_shaders_source(QUAD_VERT, QUAD_FRAG)
    if !qok {
        return false
    }
    t.quad_prog = qp
    t.quad_us = gl.GetUniformLocation(qp, "u_screen")

    // Glyph layout: x y u v r g b (stride 28).
    gl.GenVertexArrays(1, &t.glyph_vao)
    gl.GenBuffers(1, &t.glyph_vbo)
    gl.BindVertexArray(t.glyph_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.glyph_vbo)
    gl.EnableVertexAttribArray(0);gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 28, 0)
    gl.EnableVertexAttribArray(1);gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 28, 8)
    gl.EnableVertexAttribArray(2);gl.VertexAttribPointer(2, 3, gl.FLOAT, false, 28, 16)

    // Quad layout: x y r g b (stride 20).
    gl.GenVertexArrays(1, &t.quad_vao)
    gl.GenBuffers(1, &t.quad_vbo)
    gl.BindVertexArray(t.quad_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.quad_vbo)
    gl.EnableVertexAttribArray(0);gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 20, 0)
    gl.EnableVertexAttribArray(1);gl.VertexAttribPointer(1, 3, gl.FLOAT, false, 20, 8)

    gl.BindVertexArray(0)
    return true
}

// Re-bakes the atlas when the logical font size (font zoom) or the DPI scale (the
// window moved to another monitor) changes, so glyphs stay crisp at the new pixel
// density and size. No-op when both are unchanged — cheap to call every frame.
text_apply :: proc(t: ^Text, logical_px, scale: f32) {
    if logical_px <= 0 || scale <= 0 {
        return
    }
    if logical_px == t.logical_px && scale == t.scale {
        return
    }
    t.logical_px = logical_px
    t.scale = scale
    _ = font_load(&t.font, t.ttf, logical_px * scale)
}

// Queues a solid rect into the under-quad layer (backgrounds, bars, selection).
fill :: proc(t: ^Text, r: Rect, c: [3]f32) {
    if r.w > 0 && r.h > 0 {
        push_quad(&t.under, r, c)
    }
}

// Queues a solid rect into the over-quad layer, so it lands above the glyphs
// (carets, which must sit on top of the text on their column).
caret :: proc(t: ^Text, r: Rect, c: [3]f32) {
    if r.w > 0 && r.h > 0 {
        push_quad(&t.over, r, c)
    }
}

// Queues an arbitrary 4-corner quad (p0->p1->p2->p3, e.g. a slanted parallelogram) into
// the under-quad layer. Points are physical px in top-left space — used for diagonal
// hatching, which axis-aligned fill() can't express.
fill_quad :: proc(t: ^Text, p0, p1, p2, p3: [2]f32, c: [3]f32) {
    append(
        &t.under,
        p0.x, p0.y, c.r, c.g, c.b,  p1.x, p1.y, c.r, c.g, c.b,  p2.x, p2.y, c.r, c.g, c.b,
        p0.x, p0.y, c.r, c.g, c.b,  p2.x, p2.y, c.r, c.g, c.b,  p3.x, p3.y, c.r, c.g, c.b,
    )
}

@(private = "file")
push_quad :: proc(buf: ^[dynamic]f32, r: Rect, c: [3]f32) {
    x0, y0 := f32(r.x), f32(r.y)
    x1, y1 := f32(r.x + r.w), f32(r.y + r.h)
    append(
        buf,
        x0, y0, c.r, c.g, c.b,  x1, y0, c.r, c.g, c.b,  x1, y1, c.r, c.g, c.b,
        x0, y0, c.r, c.g, c.b,  x1, y1, c.r, c.g, c.b,  x0, y1, c.r, c.g, c.b,
    )
}

// Queues s with its top-left at (x, y) in the given colour. Unknown glyphs advance
// by one cell (monospace) and draw nothing.
text_draw :: proc(t: ^Text, s: string, x, y: f32, color: [3]f32) {
    xpos := math.round(x) // start the cell grid on a whole pixel so glyphs align
    ypos := y + t.font.ascent // stb positions glyphs relative to the baseline
    for r in s {
        glyph_push(t, r, &xpos, &ypos, color)
    }
}

// Same as text_draw but for an already-decoded rune slice (editable lines).
text_draw_runes :: proc(t: ^Text, runes: []rune, x, y: f32, color: [3]f32) {
    xpos := math.round(x)
    ypos := y + t.font.ascent
    for r in runes {
        glyph_push(t, r, &xpos, &ypos, color)
    }
}

// Appends one glyph's two triangles to the glyph batch and advances the pen.
@(private = "file")
glyph_push :: proc(t: ^Text, r: rune, xpos, ypos: ^f32, c: [3]f32) {
    pc, ok := font_glyph(&t.font, r) // bakes into the atlas on first use
    if !ok { // control char / codepoint the font lacks / atlas full: hold the cell, draw nothing
        xpos^ += t.font.cell_w
        return
    }
    q: stbtt.aligned_quad
    // GetPackedQuad would step the pen by the glyph's own (fractional) advance; we ignore
    // that and step by the fixed cell below so the grid stays exactly monospace. The pen
    // we feed in is already integral, so there is no accumulator to drift — and with the
    // cell origin pinned, align_to_integer is left OFF: it would re-round each glyph's
    // sub-pixel offset (fighting the 2x atlas oversampling) and make spacing look jittery,
    // worst at small sizes. Off, the oversampled ink lands at its true offset in the cell.
    pen := xpos^
    stbtt.GetPackedQuad(&pc, FONT_ATLAS, FONT_ATLAS, 0, &pen, ypos, &q, false)
    xpos^ += t.font.cell_w
    append(
        &t.glyphs,
        q.x0, q.y0, q.s0, q.t0, c.r, c.g, c.b,  q.x1, q.y0, q.s1, q.t0, c.r, c.g, c.b,
        q.x1, q.y1, q.s1, q.t1, c.r, c.g, c.b,  q.x0, q.y0, q.s0, q.t0, c.r, c.g, c.b,
        q.x1, q.y1, q.s1, q.t1, c.r, c.g, c.b,  q.x0, q.y1, q.s0, q.t1, c.r, c.g, c.b,
    )
}

// Draws everything queued for one pane — under-quads, then glyphs, then over-quads
// — clipped to `clip`, then empties the scratch batches for the next pane. Scissor
// uses a bottom-left origin; our rects are top-left, so flip y.
flush_pane :: proc(t: ^Text, clip: Rect, win_w, win_h: i32) {
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
    gl.Enable(gl.SCISSOR_TEST)
    gl.Scissor(clip.x, win_h - (clip.y + clip.h), clip.w, clip.h)

    quad_flush(t, &t.under, win_w, win_h)
    glyph_flush(t, win_w, win_h)
    quad_flush(t, &t.over, win_w, win_h)

    clear(&t.under)
    clear(&t.glyphs)
    clear(&t.over)
}

@(private = "file")
quad_flush :: proc(t: ^Text, buf: ^[dynamic]f32, win_w, win_h: i32) {
    if len(buf) == 0 {
        return
    }
    gl.UseProgram(t.quad_prog)
    gl.Uniform2f(t.quad_us, f32(win_w), f32(win_h))
    gl.BindVertexArray(t.quad_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.quad_vbo)
    gl.BufferData(gl.ARRAY_BUFFER, len(buf) * size_of(f32), raw_data(buf^), gl.DYNAMIC_DRAW)
    gl.DrawArrays(gl.TRIANGLES, 0, i32(len(buf) / 5))
    t.frame_verts += len(buf) / 5
}

@(private = "file")
glyph_flush :: proc(t: ^Text, win_w, win_h: i32) {
    if len(t.glyphs) == 0 {
        return
    }
    font_sync(&t.font) // upload any glyphs baked on demand this pass before they're sampled
    gl.UseProgram(t.glyph_prog)
    gl.Uniform2f(t.glyph_us, f32(win_w), f32(win_h))
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, t.font.tex)
    gl.BindVertexArray(t.glyph_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.glyph_vbo)
    gl.BufferData(gl.ARRAY_BUFFER, len(t.glyphs) * size_of(f32), raw_data(t.glyphs), gl.DYNAMIC_DRAW)
    gl.DrawArrays(gl.TRIANGLES, 0, i32(len(t.glyphs) / 7))
    t.frame_verts += len(t.glyphs) / 7
}
