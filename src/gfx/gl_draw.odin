package gfx

import "core:math"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// The GL arm of Draw. Two batches, each accumulating across a whole pane and flushed in one
// draw: solid colour
// quads and textured glyph quads sampling the font atlas. Colour is per-vertex in both, which
// is what lets a syntax-highlighted line batch into a single glyph draw. Nothing outside gfx
// calls these: draw.odin dispatches to them.
//
// A pane composites in three ordered layers under one scissor: under-quads (backgrounds,
// selection, the current-line bar), glyphs, then over-quads (carets, which must land above the
// text). Positions are physical pixels in Rect's top-left space; both shaders flip y to NDC.

GL_Draw :: struct {
    font:        Font,
    glyph_prog:  u32,
    glyph_vao:   u32,
    glyph_vbo:   u32,
    glyph_us:    i32, // u_screen
    quad_prog:   u32,
    quad_vao:    u32,
    quad_vbo:    u32,
    quad_us:     i32, // u_screen
    image_prog:  u32, // textured RGBA quad: the glyph shader is R8-only and the quad shader
    image_vao:   u32, // untextured, so neither can blit an image
    image_vbo:   u32,
    image_us:    i32, // u_screen
    glyphs:      [dynamic]f32, // scratch, 7 floats/vertex: x y u v r g b
    under:       [dynamic]f32, // scratch, 5 floats/vertex: x y r g b
    over:        [dynamic]f32, // scratch, same layout as `under`
    images:      [dynamic]ImageQuad, // drawn per-pane between the under-quads and the glyphs
    // Bytes allocated in each VBO's store. Grown by doubling and never shrunk, so a steady
    // frame re-uses the same allocation.
    glyph_cap:   int,
    quad_cap:    int,
    image_cap:   int,
    ttf:         []u8, // retained so the atlas can re-bake on DPI change
    logical_px:  f32, // atlas is baked at logical_px * scale physical pixels
    scale:       f32, // DPI scale the atlas is currently baked for
    verts:       int, // vertices submitted this frame; read by the perf log
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

// A decoded image sampled straight through, no per-vertex colour. The same pos->NDC transform
// as the other two shaders; uv maps the dst rect onto the texture.
@(private = "file")
IMAGE_VERT := `#version 330 core
layout(location=0) in vec2 a_pos;
layout(location=1) in vec2 a_uv;
uniform vec2 u_screen;
out vec2 v_uv;
void main() {
    gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0,
                       1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
    v_uv = a_uv;
}`

@(private = "file")
IMAGE_FRAG := `#version 330 core
in vec2 v_uv;
uniform sampler2D u_img;
out vec4 o_color;
void main() {
    o_color = texture(u_img, v_uv);
}`

// A texture and the dst rect it fills; the source is the whole texture, so only the rect
// varies. Each carries its own texture, so they cannot batch — but at most one is ever up.
ImageQuad :: struct {
    tex: u32,
    dst: Rect,
}

@(private)
gl_text_init :: proc(t: ^GL_Draw, ttf: []u8, logical_px, scale: f32) -> bool {
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

    ip, iok := gl.load_shaders_source(IMAGE_VERT, IMAGE_FRAG)
    if !iok {
        return false
    }
    t.image_prog = ip
    t.image_us = gl.GetUniformLocation(ip, "u_screen")
    gl.UseProgram(ip)
    gl.Uniform1i(gl.GetUniformLocation(ip, "u_img"), 0) // sampler -> unit 0

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

    // Image layout: x y u v (stride 16).
    gl.GenVertexArrays(1, &t.image_vao)
    gl.GenBuffers(1, &t.image_vbo)
    gl.BindVertexArray(t.image_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.image_vbo)
    gl.EnableVertexAttribArray(0);gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 16, 0)
    gl.EnableVertexAttribArray(1);gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 16, 8)

    gl.BindVertexArray(0)
    return true
}

// When the logical font size or the DPI scale changes, so glyphs stay crisp; a no-op otherwise.
// Reports a re-bake, since the cell advance moved and cached measurements must be dropped.
@(private)
gl_text_apply :: proc(t: ^GL_Draw, logical_px, scale: f32) -> (rebaked: bool) {
    if logical_px <= 0 || scale <= 0 {
        return false
    }
    if logical_px == t.logical_px && scale == t.scale {
        return false
    }
    t.logical_px = logical_px
    t.scale = scale
    _ = font_load(&t.font, t.ttf, logical_px * scale)
    return true
}

// Backgrounds, bars, selection.
@(private)
gl_fill :: proc(t: ^GL_Draw, r: Rect, c: [3]f32) {
    if r.w > 0 && r.h > 0 {
        push_quad(&t.under, r, c)
    }
}

// Above the glyphs: carets, which sit on top of the text on their column.
@(private)
gl_caret :: proc(t: ^GL_Draw, r: Rect, c: [3]f32) {
    if r.w > 0 && r.h > 0 {
        push_quad(&t.over, r, c)
    }
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

// Drawn in gl_flush_pane between the under-quads and the glyphs.
@(private)
gl_image_push :: proc(t: ^GL_Draw, tex: u32, dst: Rect) {
    if tex != 0 && dst.w > 0 && dst.h > 0 {
        append(&t.images, ImageQuad{tex, dst})
    }
}

// Unknown glyphs advance by one cell and draw nothing.
@(private)
gl_text_draw :: proc(t: ^GL_Draw, s: string, x, y: f32, color: [3]f32) {
    xpos := math.round(x) // start the cell grid on a whole pixel
    ypos := y + t.font.ascent // stb positions glyphs from the baseline
    for r in s {
        glyph_push(t, r, &xpos, &ypos, color)
    }
}

// gl_text_draw for an already-decoded rune slice.
@(private)
gl_text_draw_runes :: proc(t: ^GL_Draw, runes: []rune, x, y: f32, color: [3]f32) {
    xpos := math.round(x)
    ypos := y + t.font.ascent
    for r in runes {
        glyph_push(t, r, &xpos, &ypos, color)
    }
}

// One icon baked at `px`, centred on its ink inside `box`. A glyph can only be drawn at the
// size it was baked, so the tile size gets its own cache (font_icon_big) — the same atlas,
// batch and draw call. Centred on the INK rather than the advance box, since an icon face's
// glyphs are not uniformly placed within their em. False when there is no icon face.
@(private)
gl_icon_draw :: proc(t: ^GL_Draw, r: rune, box: Rect, px: f32, color: [3]f32) -> bool {
    pc, ok := font_icon_big(&t.font, r, px)
    if !ok {
        return false
    }
    q: stbtt.aligned_quad
    x, y: f32 = 0, 0
    stbtt.GetPackedQuad(&pc, FONT_ATLAS, FONT_ATLAS, 0, &x, &y, &q, false)
    dx := math.round(f32(box.x) + (f32(box.w) - (q.x1 - q.x0)) / 2 - q.x0)
    dy := math.round(f32(box.y) + (f32(box.h) - (q.y1 - q.y0)) / 2 - q.y0)
    c := color
    x0, y0, x1, y1 := q.x0 + dx, q.y0 + dy, q.x1 + dx, q.y1 + dy
    append(
        &t.glyphs,
        x0, y0, q.s0, q.t0, c.r, c.g, c.b,  x1, y0, q.s1, q.t0, c.r, c.g, c.b,
        x1, y1, q.s1, q.t1, c.r, c.g, c.b,  x0, y0, q.s0, q.t0, c.r, c.g, c.b,
        x1, y1, q.s1, q.t1, c.r, c.g, c.b,  x0, y1, q.s0, q.t1, c.r, c.g, c.b,
    )
    return true
}

// The browser's tile captions, deliberately smaller than the body text. The pen steps by the
// SCALED cell for the reason the body steps by the whole one: a fixed advance keeps the run on
// a predictable grid, and lets the caller centre from the rune count alone.
@(private)
gl_text_draw_sized :: proc(t: ^GL_Draw, s: string, x, y, px: f32, color: [3]f32) {
    cw := text_sized_cell(t.font.face, px)
    // The baseline scales with the bake; ascent is the body's, so scale by the same ratio.
    ratio := t.font.px > 0 ? px / t.font.px : 1
    xpos := math.round(x)
    ypos := y + t.font.ascent * ratio
    for r in s {
        pc, ok := font_text_small(&t.font, r, px)
        if !ok {
            xpos += cw
            continue
        }
        q: stbtt.aligned_quad
        pen := xpos
        stbtt.GetPackedQuad(&pc, FONT_ATLAS, FONT_ATLAS, 0, &pen, &ypos, &q, false)
        xpos += cw
        append(
            &t.glyphs,
            q.x0, q.y0, q.s0, q.t0, color.r, color.g, color.b,
            q.x1, q.y0, q.s1, q.t0, color.r, color.g, color.b,
            q.x1, q.y1, q.s1, q.t1, color.r, color.g, color.b,
            q.x0, q.y0, q.s0, q.t0, color.r, color.g, color.b,
            q.x1, q.y1, q.s1, q.t1, color.r, color.g, color.b,
            q.x0, q.y1, q.s0, q.t1, color.r, color.g, color.b,
        )
    }
}

// Two triangles into the glyph batch, then advance the pen.
@(private = "file")
glyph_push :: proc(t: ^GL_Draw, r: rune, xpos, ypos: ^f32, c: [3]f32) {
    pc, ok := font_glyph(&t.font, r) // bakes into the atlas on first use
    if !ok { // nothing to draw: hold the cell anyway
        xpos^ += t.font.cell_w
        return
    }
    q: stbtt.aligned_quad
    // GetPackedQuad would step the pen by the glyph's own fractional advance; stepping by the
    // fixed cell from an integral pen drifts nothing. align_to_integer stays off: re-rounding
    // each sub-pixel offset fights the 2x oversampling into jitter.
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

// Under-quads, glyphs, over-quads, clipped to `clip`, then the scratch batches are emptied.
// The scissor uses a bottom-left origin where our rects are top-left, so y flips.
@(private)
gl_flush_pane :: proc(t: ^GL_Draw, clip: Rect, win_w, win_h: i32) {
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
    gl.Enable(gl.SCISSOR_TEST)
    gl.Scissor(clip.x, win_h - (clip.y + clip.h), clip.w, clip.h)

    quad_flush(t, &t.under, win_w, win_h)
    image_flush(t, win_w, win_h) // over the backdrop, under the text labels
    glyph_flush(t, win_w, win_h)
    quad_flush(t, &t.over, win_w, win_h)

    clear(&t.under)
    clear(&t.images)
    clear(&t.glyphs)
    clear(&t.over)
}

// One DrawArrays per image: they carry distinct textures, and at most one shows at a time. The
// dst rect maps onto the whole texture, and uv (0,0) is the image top, since stb loads
// top-down.
@(private = "file")
image_flush :: proc(t: ^GL_Draw, win_w, win_h: i32) {
    if len(t.images) == 0 {
        return
    }
    gl.UseProgram(t.image_prog)
    gl.Uniform2f(t.image_us, f32(win_w), f32(win_h))
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindVertexArray(t.image_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.image_vbo)
    for im in t.images {
        x0, y0 := f32(im.dst.x), f32(im.dst.y)
        x1, y1 := f32(im.dst.x + im.dst.w), f32(im.dst.y + im.dst.h)
        verts := [?]f32 {
            x0, y0, 0, 0,  x1, y0, 1, 0,  x1, y1, 1, 1,
            x0, y0, 0, 0,  x1, y1, 1, 1,  x0, y1, 0, 1,
        }
        gl.BindTexture(gl.TEXTURE_2D, im.tex)
        vbo_upload(&t.image_cap, &verts[0], size_of(verts))
        gl.DrawArrays(gl.TRIANGLES, 0, 6)
        t.verts += 6
    }
}

@(private = "file")
quad_flush :: proc(t: ^GL_Draw, buf: ^[dynamic]f32, win_w, win_h: i32) {
    if len(buf) == 0 {
        return
    }
    gl.UseProgram(t.quad_prog)
    gl.Uniform2f(t.quad_us, f32(win_w), f32(win_h))
    gl.BindVertexArray(t.quad_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.quad_vbo)
    vbo_upload(&t.quad_cap, raw_data(buf^), len(buf) * size_of(f32))
    gl.DrawArrays(gl.TRIANGLES, 0, i32(len(buf) / 5))
    t.verts += len(buf) / 5
}

@(private = "file")
glyph_flush :: proc(t: ^GL_Draw, win_w, win_h: i32) {
    if len(t.glyphs) == 0 {
        return
    }
    font_sync(&t.font) // upload glyphs baked this pass before they are sampled
    gl.UseProgram(t.glyph_prog)
    gl.Uniform2f(t.glyph_us, f32(win_w), f32(win_h))
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, t.font.tex)
    gl.BindVertexArray(t.glyph_vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.glyph_vbo)
    vbo_upload(&t.glyph_cap, raw_data(t.glyphs), len(t.glyphs) * size_of(f32))
    gl.DrawArrays(gl.TRIANGLES, 0, i32(len(t.glyphs) / 7))
    t.verts += len(t.glyphs) / 7
}

// Into the bound ARRAY_BUFFER. The store is grown by doubling and kept, so a steady frame stops
// reallocating; the BufferData(nil) is the orphan hint that lets the driver hand back a fresh
// block instead of stalling on the one the previous draw is still reading.
@(private = "file")
vbo_upload :: proc(store: ^int, data: rawptr, bytes: int) {
    if bytes > store^ {
        n := max(store^, 4096)
        for n < bytes {
            n *= 2
        }
        store^ = n
    }
    gl.BufferData(gl.ARRAY_BUFFER, store^, nil, gl.DYNAMIC_DRAW)
    gl.BufferSubData(gl.ARRAY_BUFFER, 0, bytes, data)
}
