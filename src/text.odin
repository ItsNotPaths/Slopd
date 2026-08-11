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
    font:        Font,
    glyph_prog:  u32,
    glyph_vao:   u32,
    glyph_vbo:   u32,
    glyph_us:    i32, // u_screen
    quad_prog:   u32,
    quad_vao:    u32,
    quad_vbo:    u32,
    quad_us:     i32, // u_screen
    image_prog:  u32, // textured RGBA quad (the media viewer): the glyph shader is R8/alpha
    image_vao:   u32, // -only and the quad shader is untextured, so neither can blit an image
    image_vbo:   u32,
    image_us:    i32, // u_screen
    glyphs:      [dynamic]f32, // scratch, 7 floats/vertex: x y u v r g b
    under:       [dynamic]f32, // scratch, 5 floats/vertex: x y r g b
    over:        [dynamic]f32, // scratch, same layout as `under`
    images:      [dynamic]ImageQuad, // queued image blits, drawn per-pane between under-quads and glyphs
    // Bytes currently allocated in each VBO's store. Grown by doubling and never shrunk, so
    // a steady frame re-uses the same allocation (see vbo_upload).
    glyph_cap:   int,
    quad_cap:    int,
    image_cap:   int,
    ttf:         []u8, // retained so the atlas can re-bake on DPI change
    logical_px:  f32, // atlas is baked at logical_px * scale physical pixels
    scale:       f32, // DPI scale the atlas is currently baked for
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

// Textured RGBA quad: a decoded image sampled straight through (no per-vertex colour).
// Same pos->NDC transform as the other two shaders; uv maps the dst rect onto the texture.
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

// One queued image blit: a texture and the destination rect (top-left px) it fills. The
// source covers the whole texture (uv 0..1), so only the rect varies. Each carries its own
// texture, so they can't batch into one draw — but at most one image is ever on screen.
ImageQuad :: struct {
    tex: u32,
    dst: Rect,
}

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

// Re-bakes the atlas when the logical font size (font zoom) or the DPI scale (the window
// moved monitors) changes, so glyphs stay crisp; a no-op otherwise, cheap to call every
// frame. Reports a re-bake: the cell advance moved, so cached measurements must be dropped.
text_apply :: proc(t: ^Text, logical_px, scale: f32) -> (rebaked: bool) {
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

// Queues an image blit filling `dst` (top-left px) with the whole texture. Drawn in
// flush_pane between the under-quads (backdrop) and the glyphs (labels over the image).
image_push :: proc(t: ^Text, tex: u32, dst: Rect) {
    if tex != 0 && dst.w > 0 && dst.h > 0 {
        append(&t.images, ImageQuad{tex, dst})
    }
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

// Draws ONE icon glyph, baked at `px`, centred on its ink inside `box`. The browser's grid
// tiles: an icon there is inches of pixels where a row's is one cell, and a glyph can only be
// drawn at the size it was baked (there is no per-quad scale), so the tile size is baked as its
// own cache — the same atlas, the same batch, the same draw call (font_icon_big).
//
// Centred on the INK rather than on the advance box: an icon face's glyphs are not uniformly
// placed within their em, and a tile centres what you can see. Returns false when there is no
// icon face, which is the browser's cue to draw its plain tile instead.
icon_draw :: proc(t: ^Text, r: rune, box: Rect, px: f32, color: [3]f32) -> bool {
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

// The advance of one cell at bake size `px` — the body cell scaled by the size ratio. Text at a
// second bake size is still monospace, so a caller can centre a string without measuring it.
text_sized_cell :: proc(t: ^Text, px: f32) -> f32 {
    if t.font.px <= 0 {
        return t.font.cell_w
    }
    return t.font.cell_w * (px / t.font.px)
}

// Draws `s` at bake size `px` with its top-left at (x, y) — the browser's tile captions, which
// are deliberately smaller than the body text. The pen steps by the SCALED cell for the reason
// the body text steps by the whole one: a fixed advance keeps the run on a predictable grid,
// and it is what lets the caller centre the string from its rune count alone.
text_draw_sized :: proc(t: ^Text, s: string, x, y, px: f32, color: [3]f32) {
    cw := text_sized_cell(t, px)
    // The baseline scales with the bake; ascent is the body's, so take it by the same ratio.
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

// Appends one glyph's two triangles to the glyph batch and advances the pen.
@(private = "file")
glyph_push :: proc(t: ^Text, r: rune, xpos, ypos: ^f32, c: [3]f32) {
    pc, ok := font_glyph(&t.font, r) // bakes into the atlas on first use
    if !ok { // control char / codepoint the font lacks / atlas full: hold the cell, draw nothing
        xpos^ += t.font.cell_w
        return
    }
    q: stbtt.aligned_quad
    // GetPackedQuad would step the pen by the glyph's own fractional advance; we step by the
    // fixed cell instead, from an already-integral pen, so nothing drifts. align_to_integer
    // stays OFF: re-rounding each sub-pixel offset fights the 2x oversampling into jitter.
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
    image_flush(t, win_w, win_h) // images sit over the backdrop, under the text labels
    glyph_flush(t, win_w, win_h)
    quad_flush(t, &t.over, win_w, win_h)

    clear(&t.under)
    clear(&t.images)
    clear(&t.glyphs)
    clear(&t.over)
}

// Draws each queued image — one DrawArrays per image (they carry distinct textures, and
// at most one shows at a time, so no batching). The dst rect maps onto the whole texture;
// uv top-left (0,0) is the texture's first row = the image top (stb loads top-down).
@(private = "file")
image_flush :: proc(t: ^Text, win_w, win_h: i32) {
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
        t.frame_verts += 6
    }
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
    vbo_upload(&t.quad_cap, raw_data(buf^), len(buf) * size_of(f32))
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
    vbo_upload(&t.glyph_cap, raw_data(t.glyphs), len(t.glyphs) * size_of(f32))
    gl.DrawArrays(gl.TRIANGLES, 0, i32(len(t.glyphs) / 7))
    t.frame_verts += len(t.glyphs) / 7
}

// Writes `bytes` from `data` into the bound ARRAY_BUFFER. The store is grown by doubling and
// kept, so a steady frame stops reallocating it; the BufferData(nil) is the orphan hint that
// lets the driver hand back a fresh block from its pool instead of stalling on the one the
// previous draw is still reading.
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
