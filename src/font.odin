package main

import "core:c"
import "core:math"
import "core:os"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// The bundled default font, embedded at build time. Fetched + subset into vendor/ by
// download-deps.sh (Iosevka Fixed — no ligatures, strictly uniform advance, so every
// glyph lands on Slopd's fixed cell grid). The upstream TTF carries thousands of CJK
// glyphs (~9MB); the script strips the CJK/rare blocks but keeps the full symbol set a
// terminal needs — box drawing, block elements, braille, arrows, math, Latin — so any
// TUI (Claude Code, Helix, …) running in Slopd's terminal renders its borders, cursors
// and spinners. A user font (SLOPD_FONT) overrides it at runtime.
IOSEVKA_TTF := #load("../vendor/fonts/IosevkaFixed-Latin.ttf")

// Glyphs are baked into the atlas LAZILY: the first time a codepoint is drawn we
// rasterize just that glyph into the shared atlas and cache its quad. A terminal only
// ever shows a small alphabet of distinct glyphs, so the atlas stays small no matter
// how large the font's coverage is — and any codepoint the font has Just Works, with
// no fixed pre-baked list to maintain. (The old design pre-baked one contiguous ASCII
// range, which is why box/braille/symbols rendered blank.)
FONT_ATLAS :: 1024 // single-channel R8 atlas, 1 MB; holds far more than any one screen uses

Glyph :: struct {
    pc:      stbtt.packedchar,
    present: bool, // false: font lacks this codepoint (or it didn't fit) — draw nothing
}

Font :: struct {
    pc:          stbtt.pack_context,        // kept open for the font's life; lazy bakes pack into it
    info:        stbtt.fontinfo,            // for glyph-presence checks
    ttf:         []u8,                      // borrowed font bytes (owned by Text); needed to bake on demand
    pixels:      []byte,                    // CPU mirror of the atlas; PackFontRange writes here
    cache:       map[rune]Glyph,            // codepoint -> baked quad (or absent marker)
    px:          f32,                       // bake size, physical px
    dirty:       bool,                      // pixels changed since last GPU upload
    dy0, dy1:    int,                       // dirty row band [dy0, dy1) to re-upload (valid when dirty)
    ready:       bool,                      // pc/pixels/tex initialized
    tex:         u32,
    cell_w:      f32, // monospace advance, physical px
    line_height: f32, // physical px
    ascent:      f32, // baseline offset from the top, physical px
}

// Picks the user's font (SLOPD_FONT) if set and readable, else bundled Iosevka Fixed.
choose_font :: proc() -> []u8 {
    if path := os.get_env("SLOPD_FONT", context.temp_allocator); path != "" {
        return os.read_entire_file_from_path(path, context.allocator) or_else IOSEVKA_TTF
    }
    return IOSEVKA_TTF
}

// (Re)initializes the atlas at px physical pixels and records monospace metrics. Called
// at startup and again on font-zoom / DPI change. Tears down any prior atlas first.
font_load :: proc(f: ^Font, ttf: []u8, px: f32) -> bool {
    font_teardown(f)

    if !stbtt.InitFont(&f.info, raw_data(ttf), 0) {
        return false
    }
    // Allocate first, but don't commit to `f` (or set `ready`) until PackBegin succeeds,
    // so a PackBegin failure frees the buffer here instead of leaking it past teardown.
    pixels := make([]byte, FONT_ATLAS * FONT_ATLAS)
    if stbtt.PackBegin(&f.pc, raw_data(pixels), FONT_ATLAS, FONT_ATLAS, 0, 1, nil) == 0 {
        delete(pixels)
        return false
    }
    f.ttf = ttf
    f.px = px
    f.pixels = pixels
    f.cache = make(map[rune]Glyph)
    f.ready = true
    stbtt.PackSetOversampling(&f.pc, 2, 2) // smoother edges at small sizes

    // Warm the printable-ASCII range in one batched pack call (tighter packing than 95
    // incremental bakes, and it's almost always the bulk of what's on screen). Folded
    // into the initial full upload below, so no dirty-band bookkeeping. Everything else
    // bakes lazily on first use. A 0 return (only at extreme zoom, where the batch won't
    // fit) just leaves ASCII to the lazy path.
    ascii: [95]stbtt.packedchar
    if stbtt.PackFontRange(&f.pc, raw_data(ttf), 0, px, 32, 95, &ascii[0]) != 0 {
        for i in 0 ..< 95 {
            f.cache[rune(32 + i)] = {pc = ascii[i], present = true}
        }
    }

    scale := stbtt.ScaleForPixelHeight(&f.info, px)
    ascent, descent, line_gap: c.int
    stbtt.GetFontVMetrics(&f.info, &ascent, &descent, &line_gap)
    f.ascent = f32(ascent) * scale
    f.line_height = f32(ascent - descent + line_gap) * scale
    advance, lsb: c.int
    stbtt.GetCodepointHMetrics(&f.info, 'M', &advance, &lsb) // monospace: any glyph
    // Snap the cell to a whole physical pixel. Glyphs step the pen by this fixed
    // width (not their own fractional advance), so every cell origin lands on the
    // same integer grid the carets and selection use — otherwise integer-aligned
    // glyph ink drifts ±1px per cell against a fractional advance and the text
    // stops looking precisely monospace.
    f.cell_w = math.round(f32(advance) * scale)

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

// Frees the previous atlas (texture, pack context, CPU mirror, cache) before a re-bake.
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
    f.pixels = nil
    f.cache = nil
    f.dirty = false
    f.ready = false
}

// Returns the baked quad for r, baking it on first use. ok=false means there is nothing
// to draw (control char, a codepoint the font lacks, or the atlas is full): the caller
// still steps the pen so the cell grid is preserved.
font_glyph :: proc(f: ^Font, r: rune) -> (pc: stbtt.packedchar, ok: bool) {
    if r < 32 {
        return {}, false
    }
    if g, found := f.cache[r]; found {
        return g.pc, g.present
    }
    if stbtt.FindGlyphIndex(&f.info, r) == 0 { // font has no such glyph — don't bake .notdef tofu
        f.cache[r] = {present = false}
        return {}, false
    }
    g: Glyph
    // PackFontRange appends this one glyph into the live atlas (skyline packer carries
    // over between calls), writing its bitmap into f.pixels and quad into g.pc. A 0
    // return means the atlas is full: cache it absent (renders blank until the next
    // re-bake on zoom/DPI change frees the atlas) rather than retrying every frame.
    g.present = stbtt.PackFontRange(&f.pc, raw_data(f.ttf), 0, f.px, c.int(r), 1, &g.pc) != 0
    if g.present {
        // Grow the dirty band to cover this glyph's rows, so font_sync re-uploads only
        // the touched strip instead of the whole 1 MB atlas.
        y0, y1 := int(g.pc.y0), int(g.pc.y1)
        if f.dirty {
            f.dy0 = min(f.dy0, y0)
            f.dy1 = max(f.dy1, y1)
        } else {
            f.dirty, f.dy0, f.dy1 = true, y0, y1
        }
    }
    f.cache[r] = g
    return g.pc, g.present
}

// Uploads the rows baked since the last upload to the GPU, if any. Called just before a
// glyph batch is drawn, so freshly-baked glyphs are present in the texture.
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
