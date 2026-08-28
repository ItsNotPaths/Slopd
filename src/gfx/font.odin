package gfx

import "core:c"
import "core:math"
import "core:os"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// The bundled default, subset into vendor/ by download-deps.sh. Iosevka Fixed: no ligatures and
// a strictly uniform advance, so every glyph lands on the fixed cell grid. The script strips the
// CJK and rare blocks but keeps the symbol set a terminal needs — box drawing, block elements,
// braille, arrows, math — so a TUI renders its borders and spinners. SLOPD_FONT overrides it.
IOSEVKA_TTF := #load("../../vendor/fonts/IosevkaFixed-Latin.ttf")

// The browser's type icons, as a second FACE rather than a second atlas: Symbols Nerd Font Mono
// subset to Seti-UI + Devicons. stb's packer takes the font bytes per call, so an icon bakes
// into the same atlas and lands in the same batch, texture and draw call — an icon is just a
// rune. May legitimately be EMPTY: without fontTools download-deps.sh vendors a zero-byte file,
// `icons_ok` is false and the browser falls back to plain tiles.
ICONS_TTF := #load("../../vendor/fonts/SymbolsNerdFont-Icons.ttf")

// Glyphs bake lazily: the first draw of a codepoint rasterizes it into the shared atlas and
// caches the quad. A terminal shows a small alphabet, so the atlas stays small.
FONT_ATLAS :: 1024 // single-channel R8, 1 MB

Glyph :: struct {
    pc:      stbtt.packedchar,
    present: bool, // false: the font lacks it, or it did not fit — draw nothing
}

Font :: struct {
    pc:     stbtt.pack_context,        // kept open for the font's life; lazy bakes pack into it
    info:   stbtt.fontinfo,            // for glyph-presence checks
    ttf:    []u8,                      // borrowed font bytes (owned by Text), to bake on demand
    pixels: []byte,                    // CPU mirror of the atlas; PackFontRange writes here
    cache:  map[rune]Glyph,            // codepoint -> baked quad, or an absent marker
    // Printable ASCII, direct-indexed; valid only when `ascii_ok`. Nearly every glyph drawn is
    // one of these (a terminal grid is ~12k a frame), and this spares each the map hash.
    ascii:    [95]Glyph,
    ascii_ok: bool,
    px:     f32,                       // bake size, physical px
    dirty:  bool,                      // pixels changed since the last GPU upload
    dy0, dy1:    int,                       // the row band to re-upload, valid when dirty
    ready:       bool,                      // pc/pixels/tex initialized
    tex:         u32,
    cell_w:      f32, // monospace advance, physical px
    line_height: f32, // physical px
    ascent:      f32, // baseline offset from the top, physical px

    // Baked into the SAME atlas as a fallback for codepoints the text font lacks. `icon_px` is
    // the bake size that makes an icon's advance match the text cell, so an icon occupies one
    // column rather than overhanging its neighbour.
    icons:      []u8,
    icons_info: stbtt.fontinfo,
    icons_ok:   bool,
    icon_px:    f32,

    // Glyphs baked at a size that is NOT the cell: icons large (a tile's) and text small (a
    // tile's caption). Same atlas, texture and batch — only the bake size differs, and a glyph
    // can only be drawn at the size it was baked. Emptied when that size changes.
    big:      map[rune]Glyph,
    big_px:   f32,
    small:    map[rune]Glyph,
    small_px: f32,
}

// The generic file icon, which every subset of this face carries. Any would do — the face is
// monospace — but naming one stops the derivation depending on whichever was looked up first.
ICON_REF :: rune(0xE612) // custom-default

// SLOPD_FONT if set and readable, else the bundled Iosevka Fixed. `owned` says which: a read
// file is the caller's to free, the embedded bytes are not.
choose_font :: proc() -> (ttf: []u8, owned: bool) {
    if path := os.get_env("SLOPD_FONT", context.temp_allocator); path != "" {
        if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
            return data, true
        }
    }
    return IOSEVKA_TTF, false
}

// At startup and again on a font-zoom or DPI change. Tears down any prior atlas first.
font_load :: proc(f: ^Font, ttf: []u8, px: f32) -> bool {
    font_teardown(f)

    if !stbtt.InitFont(&f.info, raw_data(ttf), 0) {
        return false
    }
    // Do not commit to `f` (or set `ready`) until PackBegin succeeds, so a failure frees the
    // buffer here instead of leaking it past teardown.
    pixels := make([]byte, FONT_ATLAS * FONT_ATLAS)
    if !stbtt.PackBegin(&f.pc, raw_data(pixels), FONT_ATLAS, FONT_ATLAS, 0, 1, nil) {
        delete(pixels)
        return false
    }
    f.ttf = ttf
    f.px = px
    f.pixels = pixels
    f.cache = make(map[rune]Glyph)
    f.big = make(map[rune]Glyph)
    f.small = make(map[rune]Glyph)
    f.ready = true
    stbtt.PackSetOversampling(&f.pc, 2, 2) // smoother edges at small sizes

    // One batched pack call packs tighter than 95 incremental bakes, and is almost always the
    // bulk of what is on screen. The full upload below covers it, so no dirty band.
    ascii: [95]stbtt.packedchar
    if stbtt.PackFontRange(&f.pc, raw_data(ttf), 0, px, 32, 95, &ascii[0]) {
        for i in 0 ..< 95 {
            f.ascii[i] = {pc = ascii[i], present = true}
        }
        f.ascii_ok = true
    }

    scale := stbtt.ScaleForPixelHeight(&f.info, px)
    ascent, descent, line_gap: c.int
    stbtt.GetFontVMetrics(&f.info, &ascent, &descent, &line_gap)
    f.ascent = f32(ascent) * scale
    f.line_height = f32(ascent - descent + line_gap) * scale
    advance, lsb: c.int
    stbtt.GetCodepointHMetrics(&f.info, 'M', &advance, &lsb) // monospace: any glyph
    // Snapped to a whole physical pixel. Glyphs step the pen by this fixed width, not their own
    // fractional advance, so every cell origin lands on the integer grid carets and selection
    // use — otherwise ink drifts ±1px per cell.
    f.cell_w = math.round(f32(advance) * scale)

    // Sized so an icon's advance is the text cell: bake at px, measure, scale by the ratio.
    // After cell_w is known and before any glyph lookup, since font_glyph falls back to it.
    f.icons = ICONS_TTF
    f.icons_ok = len(f.icons) > 0 && bool(stbtt.InitFont(&f.icons_info, raw_data(f.icons), 0))
    f.icon_px = px
    if f.icons_ok {
        iscale := stbtt.ScaleForPixelHeight(&f.icons_info, px)
        iadv, ilsb: c.int
        stbtt.GetCodepointHMetrics(&f.icons_info, ICON_REF, &iadv, &ilsb)
        if w := f32(iadv) * iscale; w > 0 && f.cell_w > 0 {
            f.icon_px = px * (f.cell_w / w)
        }
    }

    gl.GenTextures(1, &f.tex)
    gl.BindTexture(gl.TEXTURE_2D, f.tex)
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1) // single-channel, tightly packed rows
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, FONT_ATLAS, FONT_ATLAS, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(f.pixels))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    f.dirty = false
    return true
}

// Texture, pack context, CPU mirror and caches, before a re-bake.
@(private = "file")
font_teardown :: proc(f: ^Font) {
    if !f.ready {
        return
    }
    if f.tex != 0 {
        gl.DeleteTextures(1, &f.tex)
        f.tex = 0
    }
    stbtt.PackEnd(&f.pc)
    delete(f.pixels)
    delete(f.cache)
    delete(f.big)
    delete(f.small)
    f.pixels = nil
    f.cache = nil
    f.big = nil
    f.small = nil
    f.big_px, f.small_px = 0, 0
    f.ascii_ok = false
    f.dirty = false
    f.ready = false
}

// Bakes on first use. ok=false means there is nothing to draw — a control char, a codepoint
// neither face has, or a full atlas — and the caller still steps the pen.
font_glyph :: proc(f: ^Font, r: rune) -> (pc: stbtt.packedchar, ok: bool) {
    if r < 32 {
        return {}, false
    }
    if f.ascii_ok && r < 127 {
        g := f.ascii[r - 32]
        return g.pc, g.present
    }
    if g, found := f.cache[r]; found {
        return g.pc, g.present
    }
    if stbtt.FindGlyphIndex(&f.info, r) == 0 {
        // Try the icon face before giving up: that fallback is the whole of "icons are
        // glyphs". No .notdef tofu — a codepoint neither face has caches absent.
        if g, ok := font_icon_bake(f, r, f.icon_px); ok {
            f.cache[r] = g
            return g.pc, true
        }
        f.cache[r] = {present = false}
        return {}, false
    }
    g: Glyph
    // PackFontRange appends into the live atlas; the skyline packer carries over between calls.
    // A false return means the atlas is full, so cache it absent rather than retry every frame.
    g.present = bool(stbtt.PackFontRange(&f.pc, raw_data(f.ttf), 0, f.px, c.int(r), 1, &g.pc))
    if g.present {
        font_dirty_rows(f, int(g.pc.y0), int(g.pc.y1))
    }
    f.cache[r] = g
    return g.pc, g.present
}

// The packer takes the font bytes per call, which is why a second face and a second size cost
// nothing structural. ok=false when the face lacks the codepoint or the atlas is full.
@(private = "file")
font_bake_at :: proc(f: ^Font, info: ^stbtt.fontinfo, ttf: []u8, r: rune, px: f32) -> (g: Glyph, ok: bool) {
    if len(ttf) == 0 || px <= 0 || stbtt.FindGlyphIndex(info, r) == 0 {
        return {}, false
    }
    g.present = bool(stbtt.PackFontRange(&f.pc, raw_data(ttf), 0, px, c.int(r), 1, &g.pc))
    if !g.present {
        return {}, false
    }
    font_dirty_rows(f, int(g.pc.y0), int(g.pc.y1))
    return g, true
}

@(private = "file")
font_icon_bake :: proc(f: ^Font, r: rune, px: f32) -> (g: Glyph, ok: bool) {
    if !f.icons_ok {
        return {}, false
    }
    return font_bake_at(f, &f.icons_info, f.icons, r, px)
}

// The browser's tile captions, deliberately smaller than the body text. font_icon_big's twin
// off the other face; a size change empties the cache, since one size is in force at a time.
font_text_small :: proc(f: ^Font, r: rune, px: f32) -> (pc: stbtt.packedchar, ok: bool) {
    if !f.ready || px <= 0 {
        return {}, false
    }
    if px != f.small_px {
        clear(&f.small)
        f.small_px = px
    }
    if g, found := f.small[r]; found {
        return g.pc, g.present
    }
    g, baked := font_bake_at(f, &f.info, f.ttf, r, px)
    f.small[r] = baked ? g : Glyph{present = false}
    return g.pc, baked
}

// For the browser's grid tiles, cached apart from the one-cell bake. A size change empties the
// cache rather than keying by size: a tile has one size at a time.
font_icon_big :: proc(f: ^Font, r: rune, px: f32) -> (pc: stbtt.packedchar, ok: bool) {
    if !f.ready || !f.icons_ok || px <= 0 {
        return {}, false
    }
    if px != f.big_px {
        clear(&f.big)
        f.big_px = px
    }
    if g, found := f.big[r]; found {
        return g.pc, g.present
    }
    g, baked := font_icon_bake(f, r, px)
    f.big[r] = baked ? g : Glyph{present = false}
    return g.pc, baked
}

// So font_sync pushes only the touched strip instead of the whole 1 MB atlas.
@(private = "file")
font_dirty_rows :: proc(f: ^Font, y0, y1: int) {
    if f.dirty {
        f.dy0 = min(f.dy0, y0)
        f.dy1 = max(f.dy1, y1)
        return
    }
    f.dirty, f.dy0, f.dy1 = true, y0, y1
}

// Just before a glyph batch is drawn, so freshly-baked glyphs are in the texture.
font_sync :: proc(f: ^Font) {
    if !f.dirty {
        return
    }
    if rows := f.dy1 - f.dy0; rows > 0 {
        gl.BindTexture(gl.TEXTURE_2D, f.tex)
        gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
        gl.TexSubImage2D(
            gl.TEXTURE_2D, 0,
            0, i32(f.dy0), FONT_ATLAS, i32(rows),
            gl.RED, gl.UNSIGNED_BYTE, raw_data(f.pixels[f.dy0 * FONT_ATLAS:]),
        )
    }
    f.dirty = false
}
