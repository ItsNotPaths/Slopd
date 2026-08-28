package gfx

import gl "vendor:OpenGL"

// The GL arm of the image verbs. RGBA8, linear-filtered, clamped: a photo scaled to a pane, not
// a tiled texture. Must run on the GL thread.
@(private)
gl_image_upload :: proc(pixels: rawptr, w, h: i32) -> (Image, bool) {
    if pixels == nil || w <= 0 || h <= 0 {
        return {}, false
    }
    tex: u32
    gl.GenTextures(1, &tex)
    if tex == 0 {
        return {}, false
    }
    gl.BindTexture(gl.TEXTURE_2D, tex)
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.BindTexture(gl.TEXTURE_2D, 0)
    return Image{handle = tex, w = w, h = h}, true
}

@(private)
gl_image_free :: proc(img: ^Image) {
    if img.handle != 0 {
        gl.DeleteTextures(1, &img.handle)
    }
    img^ = {}
}

// The window's whole framebuffer. The scissor is off so the clear reaches the gutter the panes
// leave between them.
@(private)
gl_frame_begin :: proc(win_w, win_h: i32, bg: [3]f32) {
    gl.Viewport(0, 0, win_w, win_h)
    gl.Disable(gl.SCISSOR_TEST)
    gl.ClearColor(bg.r, bg.g, bg.b, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
}

// The version the shaders in gl_draw.odin are written against. The front-end asks its window for
// a context matching this rather than picking its own number.
GL_MAJOR :: 3
GL_MINOR :: 3

// The loader is the window system's symbol lookup; GLFW's is `glfw.gl_set_proc_address`. Called
// by draw_init_gl before any other GL, so nothing above gfx needs the GL package.
@(private)
gl_load :: proc(loader: proc(p: rawptr, name: cstring)) {
    gl.load_up_to(GL_MAJOR, GL_MINOR, loader)
}
