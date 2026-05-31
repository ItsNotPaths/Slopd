package main

import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// Text renderer: draws strings as batches of textured quads sampling the font
// atlas. One shader, one reused vertex buffer. Positions are physical pixels in
// the same top-left coordinate space as Rect.

Text :: struct {
    font:       Font,
    program:    u32,
    vao, vbo:   u32,
    u_screen:   i32,
    u_color:    i32,
    verts:      [dynamic]f32, // scratch, reused every draw (4 floats/vertex: x y u v)
    ttf:        []u8, // retained so the atlas can re-bake on DPI change
    logical_px: f32, // atlas is baked at logical_px * scale physical pixels
    scale:      f32, // DPI scale the atlas is currently baked for
}

@(private = "file")
VERT_SRC := `#version 330 core
layout(location=0) in vec2 a_pos;
layout(location=1) in vec2 a_uv;
uniform vec2 u_screen;
out vec2 v_uv;
void main() {
    vec2 p = vec2(a_pos.x / u_screen.x * 2.0 - 1.0,
                  1.0 - a_pos.y / u_screen.y * 2.0);
    gl_Position = vec4(p, 0.0, 1.0);
    v_uv = a_uv;
}`

@(private = "file")
FRAG_SRC := `#version 330 core
in vec2 v_uv;
uniform sampler2D u_atlas;
uniform vec3 u_color;
out vec4 o_color;
void main() {
    o_color = vec4(u_color, texture(u_atlas, v_uv).r);
}`

text_init :: proc(t: ^Text, ttf: []u8, logical_px, scale: f32) -> bool {
    t.ttf = ttf
    t.logical_px = logical_px
    t.scale = scale
    if !font_load(&t.font, ttf, logical_px * scale) {
        return false
    }
    program, ok := gl.load_shaders_source(VERT_SRC, FRAG_SRC)
    if !ok {
        return false
    }
    t.program = program
    t.u_screen = gl.GetUniformLocation(program, "u_screen")
    t.u_color = gl.GetUniformLocation(program, "u_color")
    gl.UseProgram(program)
    gl.Uniform1i(gl.GetUniformLocation(program, "u_atlas"), 0) // sampler -> unit 0

    gl.GenVertexArrays(1, &t.vao)
    gl.GenBuffers(1, &t.vbo)
    gl.BindVertexArray(t.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.vbo)
    gl.EnableVertexAttribArray(0)
    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 16, 0)
    gl.EnableVertexAttribArray(1)
    gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 16, 8)
    gl.BindVertexArray(0)
    return true
}

// Re-bakes the atlas at a new DPI scale (e.g. the window moved to another
// monitor) so glyphs stay crisp at the new pixel density. No-op if unchanged.
text_set_scale :: proc(t: ^Text, scale: f32) {
    if scale <= 0 || scale == t.scale {
        return
    }
    t.scale = scale
    _ = font_load(&t.font, t.ttf, t.logical_px * scale)
}

// Draws s with its top-left at (x, y), clipped to clip. Unknown glyphs advance
// by one cell (monospace) and draw nothing.
text_draw :: proc(t: ^Text, s: string, x, y: f32, clip: Rect, win_w, win_h: i32, color: [3]f32) {
    clear(&t.verts)
    xpos := x
    ypos := y + t.font.ascent // stb positions glyphs relative to the baseline
    for r in s {
        text_push(t, r, &xpos, &ypos)
    }
    text_flush(t, clip, win_w, win_h, color)
}

// Same as text_draw but for an already-decoded rune slice (editable lines).
text_draw_runes :: proc(t: ^Text, runes: []rune, x, y: f32, clip: Rect, win_w, win_h: i32, color: [3]f32) {
    clear(&t.verts)
    xpos := x
    ypos := y + t.font.ascent
    for r in runes {
        text_push(t, r, &xpos, &ypos)
    }
    text_flush(t, clip, win_w, win_h, color)
}

// Appends one glyph's two triangles to the scratch buffer and advances the pen.
@(private = "file")
text_push :: proc(t: ^Text, r: rune, xpos, ypos: ^f32) {
    if r < FONT_FIRST || r >= FONT_FIRST + FONT_COUNT {
        xpos^ += t.font.cell_w
        return
    }
    idx := i32(r) - FONT_FIRST
    q: stbtt.aligned_quad
    stbtt.GetPackedQuad(&t.font.chars[0], FONT_ATLAS, FONT_ATLAS, idx, xpos, ypos, &q, true)
    append(
        &t.verts,
        q.x0, q.y0, q.s0, q.t0,  q.x1, q.y0, q.s1, q.t0,  q.x1, q.y1, q.s1, q.t1,
        q.x0, q.y0, q.s0, q.t0,  q.x1, q.y1, q.s1, q.t1,  q.x0, q.y1, q.s0, q.t1,
    )
}

// Uploads the scratch quads and draws them clipped to clip in one call.
@(private = "file")
text_flush :: proc(t: ^Text, clip: Rect, win_w, win_h: i32, color: [3]f32) {
    if len(t.verts) == 0 {
        return
    }
    gl.UseProgram(t.program)
    gl.Uniform2f(t.u_screen, f32(win_w), f32(win_h))
    gl.Uniform3f(t.u_color, color.r, color.g, color.b)
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, t.font.tex)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
    gl.Enable(gl.SCISSOR_TEST)
    gl.Scissor(clip.x, win_h - (clip.y + clip.h), clip.w, clip.h)

    gl.BindVertexArray(t.vao)
    gl.BindBuffer(gl.ARRAY_BUFFER, t.vbo)
    gl.BufferData(gl.ARRAY_BUFFER, len(t.verts) * size_of(f32), raw_data(t.verts), gl.DYNAMIC_DRAW)
    gl.DrawArrays(gl.TRIANGLES, 0, i32(len(t.verts) / 4))
    gl.BindVertexArray(0)
}
