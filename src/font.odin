package main

import "core:c"
import "core:math"
import "core:os"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"

// The bundled default font, embedded at build time. Fetched + subset into vendor/ by
// download-deps.sh (Iosevka Fixed — no ligatures, strictly uniform advance, so every
// glyph lands on Slopd's fixed cell grid). The upstream TTF carries thousands of CJK/
// symbol glyphs (~9MB); we bake only printable ASCII (FONT_FIRST..), so the script
// strips it to that range (~12KB) before embedding. A user font (SLOPD_FONT) overrides
// it at runtime; this Iosevka Fixed subset is the fallback.
IOSEVKA_TTF := #load("../vendor/fonts/IosevkaFixed-Latin.ttf")

// We bake the printable ASCII range into one atlas for now. Lazy insertion of
// arbitrary Unicode glyphs can come later behind the same Font interface.
FONT_FIRST :: 32
FONT_COUNT :: 95 // 32..126 inclusive
FONT_ATLAS :: 512

Font :: struct {
    chars:       [FONT_COUNT]stbtt.packedchar,
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

// Rasterizes the ASCII range into an atlas texture and records monospace metrics.
// px is the physical pixel height (logical size * DPI scale).
font_load :: proc(f: ^Font, ttf: []u8, px: f32) -> bool {
    pixels := make([]byte, FONT_ATLAS * FONT_ATLAS)
    defer delete(pixels)

    pc: stbtt.pack_context
    if stbtt.PackBegin(&pc, raw_data(pixels), FONT_ATLAS, FONT_ATLAS, 0, 1, nil) == 0 {
        return false
    }
    stbtt.PackSetOversampling(&pc, 2, 2) // smoother edges at small sizes
    ok := stbtt.PackFontRange(&pc, raw_data(ttf), 0, px, FONT_FIRST, FONT_COUNT, &f.chars[0])
    stbtt.PackEnd(&pc)
    if ok == 0 {
        return false
    }

    info: stbtt.fontinfo
    if !stbtt.InitFont(&info, raw_data(ttf), 0) {
        return false
    }
    scale := stbtt.ScaleForPixelHeight(&info, px)
    ascent, descent, line_gap: c.int
    stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
    f.ascent = f32(ascent) * scale
    f.line_height = f32(ascent - descent + line_gap) * scale
    advance, lsb: c.int
    stbtt.GetCodepointHMetrics(&info, 'M', &advance, &lsb) // monospace: any glyph
    // Snap the cell to a whole physical pixel. Glyphs step the pen by this fixed
    // width (not their own fractional advance), so every cell origin lands on the
    // same integer grid the carets and selection use — otherwise integer-aligned
    // glyph ink drifts ±1px per cell against a fractional advance and the text
    // stops looking precisely monospace.
    f.cell_w = math.round(f32(advance) * scale)

    if f.tex != 0 { // re-bake (e.g. DPI change): replace the old atlas texture
        gl.DeleteTextures(1, &f.tex)
    }
    gl.GenTextures(1, &f.tex)
    gl.BindTexture(gl.TEXTURE_2D, f.tex)
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1) // single-channel, tightly packed rows
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, FONT_ATLAS, FONT_ATLAS, 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(pixels))
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    return true
}
