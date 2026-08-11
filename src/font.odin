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

// The file browser's type icons, as a SECOND FACE rather than a second atlas: Symbols Nerd Font
// Mono subset to Seti-UI + Devicons (~173KB / 388 glyphs, both MIT — download-deps.sh explains
// the choice). stb's packer takes the font bytes PER CALL, so an icon bakes into the same atlas
// as the text and lands in the same batch, the same texture and the same draw call. An icon is
// then just a rune: Clay measures it as one cell and every pane draws it with plain text.
//
// **May legitimately be EMPTY.** Without fontTools download-deps.sh vendors a zero-byte file
// rather than a 2.5MB one, so `icons_ok` is false and the browser falls back to plain tiles.
ICONS_TTF := #load("../vendor/fonts/SymbolsNerdFont-Icons.ttf")

// Glyphs are baked into the atlas LAZILY: the first time a codepoint is drawn we rasterize
// just that glyph into the shared atlas and cache its quad. A terminal only ever shows a
// small alphabet, so the atlas stays small however large the font's coverage is.
FONT_ATLAS :: 1024 // single-channel R8 atlas, 1 MB; holds far more than any one screen uses

Glyph :: struct {
    pc:      stbtt.packedchar,
    present: bool, // false: font lacks this codepoint (or it didn't fit) — draw nothing
}

Font :: struct {
    pc:     stbtt.pack_context,        // kept open for the font's life; lazy bakes pack into it
    info:   stbtt.fontinfo,            // for glyph-presence checks
    ttf:    []u8,                      // borrowed font bytes (owned by Text); needed to bake on demand
    pixels: []byte,                    // CPU mirror of the atlas; PackFontRange writes here
    cache:  map[rune]Glyph,            // codepoint -> baked quad (or absent marker)
    // Printable ASCII (32..=126), direct-indexed — valid only when `ascii_ok`, i.e. the
    // batch bake below succeeded. Nearly every glyph drawn is one of these (a terminal grid
    // is ~12k a frame), and this spares each of them the map hash.
    ascii:    [95]Glyph,
    ascii_ok: bool,
    px:     f32,                       // bake size, physical px
    dirty:  bool,                      // pixels changed since last GPU upload
    dy0, dy1:    int,                       // dirty row band [dy0, dy1) to re-upload (valid when dirty)
    ready:       bool,                      // pc/pixels/tex initialized
    tex:         u32,
    cell_w:      f32, // monospace advance, physical px
    line_height: f32, // physical px
    ascent:      f32, // baseline offset from the top, physical px

    // The icon face (ICONS_TTF above), baked into the SAME atlas as a fallback for codepoints
    // the text font lacks. `icon_px` is the bake size that makes an icon's advance match the
    // text cell, so an icon in a row occupies exactly one column rather than overhanging its
    // neighbour — the icon face has its own em, and matching the CELL is what matters here.
    icons:      []u8,
    icons_info: stbtt.fontinfo,
    icons_ok:   bool,
    icon_px:    f32,

    // Two caches for glyphs baked at a size that is NOT the cell: icons LARGE (a tile's icon is
    // inches of pixels) and text SMALL (a tile's caption is deliberately under the body size).
    // Same atlas, same texture, same batch as everything else — only the bake size differs, and
    // a glyph can only be drawn at the size it was baked. Keyed by rune, and emptied when the
    // size they were baked at changes (zoom, DPI).
    big:      map[rune]Glyph,
    big_px:   f32,
    small:    map[rune]Glyph,
    small_px: f32,
}

// The reference glyph the icon bake size is derived from — the generic file icon, which every
// subset of this face carries. Any icon would do (the face is monospace); naming one keeps the
// derivation from silently depending on whichever glyph happened to be looked up first.
ICON_REF :: rune(0xE612) // custom-default

// Picks the user's font (SLOPD_FONT) if set and readable, else bundled Iosevka Fixed.
// `owned` says which: a read file is the caller's to free, the embedded bytes are not.
choose_font :: proc() -> (ttf: []u8, owned: bool) {
    if path := os.get_env("SLOPD_FONT", context.temp_allocator); path != "" {
        if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
            return data, true
        }
    }
    return IOSEVKA_TTF, false
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

    // Warm the printable-ASCII range in one batched pack call (tighter packing than 95
    // incremental bakes, and almost always the bulk of what's on screen); the full upload
    // below covers it, so no dirty band. A false return leaves ASCII to the lazy path.
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
    // Snap the cell to a whole physical pixel. Glyphs step the pen by this fixed width, not
    // their own fractional advance, so every cell origin lands on the integer grid carets
    // and selection use — otherwise ink drifts ±1px per cell and text stops looking mono.
    f.cell_w = math.round(f32(advance) * scale)

    // The icon face, if one was vendored. Sized so an icon's advance is the text cell: bake at
    // px, measure what that gives, and scale the bake by the ratio. Done after cell_w is known,
    // and before any glyph is looked up, since font_glyph falls back to it.
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

// Returns the baked quad for r, baking it on first use. ok=false means there is nothing
// to draw (control char, a codepoint the font lacks, or the atlas is full): the caller
// still steps the pen so the cell grid is preserved.
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
        // The text font has no such glyph. Try the icon face before giving up — that fallback
        // is the whole of "icons are glyphs", and it packs into this same atlas. Still no
        // .notdef tofu: a codepoint neither face has caches absent.
        if g, ok := font_icon_bake(f, r, f.icon_px); ok {
            f.cache[r] = g
            return g.pc, true
        }
        f.cache[r] = {present = false}
        return {}, false
    }
    g: Glyph
    // PackFontRange appends this one glyph into the live atlas (the skyline packer carries
    // over between calls). A false return means the atlas is full: cache it absent — blank
    // until the next re-bake on zoom/DPI change frees the atlas — rather than retry every frame.
    g.present = bool(stbtt.PackFontRange(&f.pc, raw_data(f.ttf), 0, f.px, c.int(r), 1, &g.pc))
    if g.present {
        font_dirty_rows(f, int(g.pc.y0), int(g.pc.y1))
    }
    f.cache[r] = g
    return g.pc, g.present
}

// Bake one glyph from `ttf` at `px` into the live atlas. The packer takes the font bytes per
// call, which is the whole reason a second face and a second size cost nothing structural.
// Returns ok=false when the face lacks the codepoint or the atlas is full.
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

// A TEXT glyph baked at `px` — the browser's tile captions, which are deliberately smaller than
// the body text. The twin of font_icon_big, off the other face; a size change empties the cache
// for the same reason (one size is in force at a time, so a second key would only hold staleness).
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

// An icon baked at `px` for the browser's grid tiles, cached separately from the one-cell bake.
// A size change (font zoom, DPI) empties the cache rather than keying it by size: a tile has
// exactly one size at a time, so a second key would only ever hold stale entries.
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

// Grow the re-upload band to cover a freshly baked glyph's rows, so font_sync pushes only the
// touched strip instead of the whole 1 MB atlas.
@(private = "file")
font_dirty_rows :: proc(f: ^Font, y0, y1: int) {
    if f.dirty {
        f.dy0 = min(f.dy0, y0)
        f.dy1 = max(f.dy1, y1)
        return
    }
    f.dirty, f.dy0, f.dy1 = true, y0, y1
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
