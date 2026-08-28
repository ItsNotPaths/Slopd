package main

import "core:c"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"
import gl "vendor:OpenGL"
import "vendor:glfw"
import stbi "vendor:stb/image"
import "../gfx"
import "../edit"

// The main pane showing an image instead of a text buffer. MainSurface says which kind; Text
// and Image are peers, both distinct from the aux pane.
//
// The pure geometry (media_fit_rect) and the extension table are GL-free and unit-tested; only
// media_load / media_destroy touch GL. One image is held at a time, on App.media.

Media :: struct {
    path: string, // owned; "" = nothing loaded
    tex:  u32, // GL RGBA texture (0 = none)
    w, h: i32, // image pixel dimensions
    zoom:  f32, // 1 = fit-to-pane; >1 zooms in
    pan:   [2]f32, // view offset in physical pixels, applied after centring
    mtime: time.Time, // mtime when decoded; a change re-decodes
}

// Lowercase; is_media_path matches case-insensitively. An animated GIF shows its first frame,
// since stb decodes only one.
@(rodata)
MEDIA_EXTS := []string{"png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "hdr", "ppm", "pgm", "pic"}

// The extension decides the surface, as grammar_for_ext does for the highlighter. GL-free and
// allocation-free.
is_media_path :: proc(path: string) -> bool {
    ext := strings.trim_prefix(filepath.ext(path), ".")
    if ext == "" {
        return false
    }
    for e in MEDIA_EXTS {
        if strings.equal_fold(e, ext) {
            return true
        }
    }
    return false
}

// A contain letterbox at zoom 1 — the largest size that fits whole, centred — then scaled by
// zoom and shifted by pan. Pure: no GL, no App.
media_fit_rect :: proc(pane: gfx.Rect, iw, ih: i32, zoom: f32, pan: [2]f32) -> gfx.Rect {
    if iw <= 0 || ih <= 0 || pane.w <= 0 || pane.h <= 0 || zoom <= 0 {
        return gfx.Rect{pane.x, pane.y, 0, 0}
    }
    base := min(f32(pane.w) / f32(iw), f32(pane.h) / f32(ih)) // contain at zoom 1
    s := base * zoom
    dw := i32(math.round(f32(iw) * s))
    dh := i32(math.round(f32(ih) * s))
    dx := pane.x + (pane.w - dw) / 2 + i32(math.round(pan.x))
    dy := pane.y + (pane.h - dh) / 2 + i32(math.round(pan.y))
    return gfx.Rect{dx, dy, dw, dh}
}

// So a stray key cannot shrink the image to a dot or blow it up forever.
MEDIA_ZOOM_MIN :: f32(0.05)
MEDIA_ZOOM_MAX :: f32(32)

// Shared by the =/- keys and a wheel notch, so the two cannot drift.
MEDIA_ZOOM_STEP :: f32(1.25)

media_zoom :: proc(m: ^Media, factor: f32) {
    m.zoom = clamp(m.zoom * factor, MEDIA_ZOOM_MIN, MEDIA_ZOOM_MAX)
}

// The pixel under (mx, my) stays there; media_zoom fixes the centre, since a key has no point.
// Fitted size scales exactly with zoom, so pinning means shifting pan by (r-1) times the
// pointer-to-centre vector. `r` is the LANDED zoom, so a clamped step cannot drift.
media_zoom_at :: proc(m: ^Media, factor: f32, pane: gfx.Rect, mx, my: i32) {
    before := m.zoom
    media_zoom(m, factor)
    if m.zoom == before {
        return
    }
    fit := media_fit_rect(pane, m.w, m.h, before, m.pan)
    if fit.w <= 0 || fit.h <= 0 {
        return // nothing on screen to keep under the pointer
    }
    r := m.zoom / before
    m.pan.x += (f32(fit.x) + f32(fit.w) / 2 - f32(mx)) * (r - 1)
    m.pan.y += (f32(fit.y) + f32(fit.h) / 2 - f32(my)) * (r - 1)
}

media_pan :: proc(m: ^Media, dx, dy: f32) {
    m.pan.x += dx
    m.pan.y += dy
}

// The open state, and the `0` / `f` key.
media_fit :: proc(m: ^Media) {
    m.zoom = 1
    m.pan = {0, 0}
}

// stb_image, forced RGBA, uploaded to a GL texture; the CPU pixels are freed once uploaded.
// Must run on the GL thread. ok=false on a decode failure, and the caller leaves the surface
// unchanged.
media_load :: proc(path: string) -> (Media, bool) {
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    w, h, comp: c.int
    pixels := stbi.load(cpath, &w, &h, &comp, 4) // 4 = force RGBA
    if pixels == nil {
        return {}, false
    }
    defer stbi.image_free(pixels)

    tex: u32
    gl.GenTextures(1, &tex)
    gl.BindTexture(gl.TEXTURE_2D, tex)
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, rawptr(pixels))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.BindTexture(gl.TEXTURE_2D, 0)

    mtime := edit.file_mtime(path) or_else time.Time{}
    return Media{path = strings.clone(path), tex = tex, w = i32(w), h = i32(h), zoom = 1, mtime = mtime}, true
}

// Keeps the current zoom and pan, so a background change does not reset the view. A no-op when
// nothing is loaded or the file is unchanged.
media_reload_if_changed :: proc(m: ^Media) -> bool {
    if m.path == "" {
        return false
    }
    mt := edit.file_mtime(m.path) or_else m.mtime // unreadable: treat as unchanged
    if mt == m.mtime {
        return false
    }
    nm, ok := media_load(m.path) // carries the new mtime
    if !ok {
        m.mtime = mt // mid-write or corrupt: adopt the stamp, or we re-decode every tick
        return false
    }
    nm.zoom, nm.pan = m.zoom, m.pan // keep the viewer where the user left it
    media_destroy(m)
    m^ = nm
    return true
}

// Safe on an empty Media.
media_destroy :: proc(m: ^Media) {
    if m.tex != 0 {
        gl.DeleteTextures(1, &m.tex)
    }
    delete(m.path)
    m^ = {}
}

