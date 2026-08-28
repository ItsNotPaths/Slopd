package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "../txt"
import "../edit"

// Colour literals, and the picker's model. Alt+Enter on a colour edits it IN PLACE, so what
// comes out has to go back in the form it came from. Three forms, none rewritable as another:
//
//   #rgb #rgba #rrggbb #rrggbbaa      hex: CSS, theme files, most config
//   rgb(r, g, b)   rgba(r, g, b, a)   the CSS function; channels are 0..255
//   {r, g, b}  (r, g, b, a)  [r,g,b]  a bare tuple: an Odin [3]f32, a vec3, a Python tuple
//
// The tuple is the heuristic one: nothing in the text says which scale it is on, so the values
// decide — all fitting in 0..1 reads as unit floats, anything larger as bytes. `{1, 0, 0}` is
// therefore red. Numbers outside 0..255 are not a colour, which keeps `(1920, 1080, 60)` out.

Color_Kind :: enum {
    Hex,
    Func, // rgb() / rgba()
    Tuple, // brackets and commas
}

// The picker has to put back what it took: the same brackets, scale and channel count.
Color_Style :: struct {
    kind:        Color_Kind,
    has_alpha:   bool,
    open, close: rune, // Tuple: the brackets it was written in
    floats:      bool, // Tuple: channels are 0..1 rather than 0..255
    alpha_float: bool, // the alpha field is 0..1 where the channels are bytes
}

// The colour, the buffer range it came from, and enough of the original to put back on Escape.
// `hsva` is the editable copy: round-tripping the sliders through RGB would drift the hue every
// time the value passed through 0.
ColorPane :: struct {
    rgba:       [4]f32,
    hsva:       [4]f32, // h 0..360, s 0..1, v 0..1, a 0..1
    style:      Color_Style,
    active:     bool,
    live:       bool, // editing a buffer range
    buf_idx:    int, // editor.buffers index, -1 = none
    line:       int,
    lo:         int, // byte col start (inclusive)
    hi:         int, // byte col end (exclusive)
    orig_text:  string, // owned clone of the original token
    orig_rgba:  [4]f32,
    orig_dirty: bool,
    sel:        int, // focused slider; a live drag lives in a.drag
}

// --- reading ---

// Its value, the rune span it fills, and how it was written. Ordered most- to least-specific:
// an rgb() call is a tuple with a name in front, and bare brackets are the loosest pattern.
color_at :: proc(line: []rune, col: int) -> (rgba: [4]f32, lo, hi: int, st: Color_Style, ok: bool) {
    if l, h, hok := color_hex_span(line, col); hok {
        if v, vok := color_parse_hex(line[l + 1:h]); vok {
            body := h - l - 1
            return v, l, h, {kind = .Hex, has_alpha = body == 4 || body == 8}, true
        }
    }
    if l, h, a_lo, a_hi, name, fok := color_func_span(line, col); fok {
        if v, st, vok := color_parse_args(line[a_lo:a_hi], {kind = .Func}); vok && st.has_alpha == (name == 4) {
            return v, l, h, st, true
        }
    }
    if l, h, tok := color_tuple_span(line, col); tok {
        if v, st, vok := color_parse_args(line[l + 1:h - 1], {kind = .Tuple, open = line[l], close = line[h - 1]});
           vok {
            return v, l, h, st, true
        }
    }
    return {}, 0, 0, {}, false
}

// Span INCLUDING the '#', which is required: a bare hex run is too ambiguous to be a colour.
color_hex_span :: proc(line: []rune, col: int) -> (lo, hi: int, ok: bool) {
    n := len(line)
    c := clamp(col, 0, n)
    if c < n && line[c] == '#' && c + 1 < n && color_is_hex(line[c + 1]) {
        c += 1 // on the '#': step onto the first digit
    }
    if c >= n || !color_is_hex(line[c]) {
        if c > 0 && (color_is_hex(line[c - 1]) || line[c - 1] == '#') {
            c -= 1 // the caret is just past the literal
        } else {
            return 0, 0, false
        }
    }
    lo = c
    for lo > 0 && color_is_hex(line[lo - 1]) {
        lo -= 1
    }
    if lo == 0 || line[lo - 1] != '#' {
        return 0, 0, false
    }
    lo -= 1
    hi = c + 1
    for hi < n && color_is_hex(line[hi]) {
        hi += 1
    }
    switch hi - lo - 1 {
    case 3, 4, 6, 8:
        return lo, hi, true
    }
    return 0, 0, false
}

// The call's span, its arguments' span, and the name's length — 4 is `rgba`, the only
// announcement the alpha field gets.
color_func_span :: proc(line: []rune, col: int) -> (lo, hi, a_lo, a_hi, name: int, ok: bool) {
    n := len(line)
    for i := 0; i < n; i += 1 {
        nm := color_func_name(line, i)
        if nm == 0 {
            continue
        }
        p := i + nm
        for p < n && line[p] == ' ' {
            p += 1
        }
        if p >= n || line[p] != '(' {
            continue
        }
        q := p + 1
        for q < n && line[q] != ')' {
            q += 1
        }
        if q >= n { // unterminated call
            continue
        }
        if col >= i && col <= q + 1 { // q + 1: the caret one past the ')' is still on the call
            return i, q + 1, p + 1, q, nm, true
        }
        i = q
    }
    return 0, 0, 0, 0, 0, false
}

// In any of the three bracket kinds. A caret ON either bracket counts, and so does one just
// past the closer, where the caret usually is after you type the thing.
color_tuple_span :: proc(line: []rune, col: int) -> (lo, hi: int, ok: bool) {
    if len(line) == 0 {
        return 0, 0, false
    }
    c := clamp(col, 0, len(line) - 1)
    // A caret just past a closer belongs to the pair that bracket closes, not the one around.
    if c > 0 && color_is_close(line[c - 1]) {
        c -= 1
    }
    return color_pair_at(line, c)
}

// Walking left counts depth, so a nested pair resolves to the inner one. A position ON a closer
// starts one to its left, or that closer's own depth would carry the walk outward.
@(private = "file")
color_pair_at :: proc(line: []rune, at: int) -> (lo, hi: int, ok: bool) {
    i := color_is_close(line[at]) ? at - 1 : at
    depth := 0
    for ; i >= 0; i -= 1 {
        if color_is_close(line[i]) {
            depth += 1
        } else if color_close_of(line[i]) != 0 {
            if depth == 0 {
                break
            }
            depth -= 1
        }
    }
    if i < 0 {
        return 0, 0, false
    }
    want := color_close_of(line[i])
    depth = 0
    for j := i + 1; j < len(line); j += 1 {
        if color_close_of(line[j]) != 0 {
            depth += 1
        } else if color_is_close(line[j]) {
            if depth == 0 {
                if line[j] != want {
                    return 0, 0, false // crossed brackets
                }
                return i, j + 1, true
            }
            depth -= 1
        }
    }
    return 0, 0, false
}

// `st` carries what the caller knows — the kind and the brackets — and comes back with what the
// FIELDS decide: how many there are, and which scale.
color_parse_args :: proc(args: []rune, st: Color_Style) -> (rgba: [4]f32, out: Color_Style, ok: bool) {
    out = st
    s := utf8.runes_to_string(args, context.temp_allocator)
    parts := strings.split(s, ",", context.temp_allocator)
    if len(parts) != 3 && len(parts) != 4 {
        return {}, st, false
    }
    v: [4]f64
    dot: [4]bool
    for p, i in parts {
        n, d, nok := color_field(p)
        if !nok || n < 0 || n > 255 { // outside every scale a colour is written on
            return {}, st, false
        }
        v[i], dot[i] = n, d
    }
    out.has_alpha = len(parts) == 4
    // A CSS call is 0..255 whatever it holds; a bare tuple is floats when every channel fits
    // in 0..1. See the header.
    out.floats = st.kind == .Tuple && max(v[0], v[1], v[2]) <= 1
    out.alpha_float = out.floats || dot[3]
    rgba = {0, 0, 0, 1}
    for i in 0 ..< 3 {
        rgba[i] = clamp(out.floats ? f32(v[i]) : f32(v[i]) / 255, 0, 1)
    }
    if out.has_alpha {
        rgba[3] = clamp(out.alpha_float ? f32(v[3]) : f32(v[3]) / 255, 0, 1)
    }
    return rgba, out, true
}

// A decimal number, and whether it was written with a point — `128` against `0.5`.
color_field :: proc(s: string) -> (v: f64, dot, ok: bool) {
    body := strings.trim_space(s)
    if body == "" {
        return 0, false, false
    }
    v, ok = strconv.parse_f64(body)
    return v, strings.contains(body, "."), ok
}

// A hex body with no '#': 6/8 digits verbatim, 3/4 expanded to byte pairs.
color_parse_hex :: proc(hex: []rune) -> (rgba: [4]f32, ok: bool) {
    s := utf8.runes_to_string(hex, context.temp_allocator)
    full: string
    switch len(s) {
    case 6, 8:
        full = s
    case 3, 4:
        b := strings.builder_make(context.temp_allocator)
        for r in s {
            strings.write_rune(&b, r)
            strings.write_rune(&b, r)
        }
        full = strings.to_string(b)
    case:
        return {}, false
    }
    v, pok := strconv.parse_u64(full, 16)
    if !pok {
        return {}, false
    }
    if len(full) == 8 {
        return {
                f32((v >> 24) & 0xff) / 255,
                f32((v >> 16) & 0xff) / 255,
                f32((v >> 8) & 0xff) / 255,
                f32(v & 0xff) / 255,
            },
            true
    }
    return {f32((v >> 16) & 0xff) / 255, f32((v >> 8) & 0xff) / 255, f32(v & 0xff) / 255, 1}, true
}

// 4 for "rgba", 3 for "rgb", 0 otherwise. A word boundary is required, so `srgb(` is not one.
color_func_name :: proc(line: []rune, i: int) -> int {
    if i > 0 && color_is_word(line[i - 1]) {
        return 0
    }
    if color_runes_are(line, i, "rgba") {
        return 4
    }
    if color_runes_are(line, i, "rgb") {
        return 3
    }
    return 0
}

@(private = "file")
color_runes_are :: proc(line: []rune, at: int, s: string) -> bool {
    i := at
    for r in s {
        if i >= len(line) || line[i] != r {
            return false
        }
        i += 1
    }
    return true
}

@(private = "file")
color_is_hex :: proc(r: rune) -> bool {
    switch r {
    case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
        return true
    }
    return false
}

@(private = "file")
color_is_word :: proc(r: rune) -> bool {
    switch r {
    case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '_':
        return true
    }
    return false
}

// The closer that matches an opening bracket, or 0 for anything else.
@(private = "file")
color_close_of :: proc(r: rune) -> rune {
    switch r {
    case '(':
        return ')'
    case '[':
        return ']'
    case '{':
        return '}'
    }
    return 0
}

@(private = "file")
color_is_close :: proc(r: rune) -> bool {
    switch r {
    case ')', ']', '}':
        return true
    }
    return false
}

// --- writing ---

// The inverse of color_at, and it has to stay one: the picker replaces a live buffer range with
// this on every drag frame.
color_format :: proc(rgba: [4]f32, st: Color_Style, alloc := context.allocator) -> string {
    b := strings.builder_make(alloc)
    switch st.kind {
    case .Hex:
        fmt.sbprintf(&b, "#%02x%02x%02x", color_byte(rgba[0]), color_byte(rgba[1]), color_byte(rgba[2]))
        if st.has_alpha {
            fmt.sbprintf(&b, "%02x", color_byte(rgba[3]))
        }
    case .Func, .Tuple:
        if st.kind == .Func {
            strings.write_string(&b, st.has_alpha ? "rgba(" : "rgb(")
        } else {
            strings.write_rune(&b, st.open)
        }
        for i in 0 ..< (st.has_alpha ? 4 : 3) {
            if i > 0 {
                strings.write_string(&b, ", ")
            }
            color_write_chan(&b, rgba[i], i == 3 ? st.alpha_float : st.floats)
        }
        strings.write_rune(&b, st.kind == .Func ? ')' : st.close)
    }
    return strings.to_string(b)
}

color_byte :: proc(v: f32) -> int {
    return clamp(int(math.round(v * 255)), 0, 255)
}

// A byte, or a unit float with its trailing zeros cut, so a drag leaves `0.5` not `0.500`.
@(private = "file")
color_write_chan :: proc(b: ^strings.Builder, v: f32, as_float: bool) {
    if !as_float {
        fmt.sbprintf(b, "%d", color_byte(v))
        return
    }
    s := strings.trim_right(fmt.tprintf("%.3f", clamp(v, 0, 1)), "0")
    strings.write_string(b, strings.has_suffix(s, ".") ? s[:len(s) - 1] : s)
}

// --- HSV ---

color_rgba_to_hsva :: proc(rgba: [4]f32) -> [4]f32 {
    r, g, b, a := rgba[0], rgba[1], rgba[2], rgba[3]
    maxc := max(r, g, b)
    minc := min(r, g, b)
    delta := maxc - minc
    h, s: f32
    if maxc > 0 {
        s = delta / maxc
    }
    if delta > 0.0001 {
        switch maxc {
        case r:
            h = 60 * math.mod((g - b) / delta, 6)
        case g:
            h = 60 * ((b - r) / delta + 2)
        case b:
            h = 60 * ((r - g) / delta + 4)
        }
        if h < 0 {
            h += 360
        }
    }
    return {h, s, maxc, a}
}

color_hsva_to_rgba :: proc(hsva: [4]f32) -> [4]f32 {
    h, s, v, a := hsva[0], hsva[1], hsva[2], hsva[3]
    if s <= 0 {
        return {v, v, v, a}
    }
    hh := math.mod(h, 360) / 60
    i := int(math.floor(hh))
    f := hh - f32(i)
    p := v * (1 - s)
    q := v * (1 - s * f)
    t := v * (1 - s * (1 - f))
    r, g, b: f32
    switch i {
    case 0:
        r, g, b = v, t, p
    case 1:
        r, g, b = q, v, p
    case 2:
        r, g, b = p, v, t
    case 3:
        r, g, b = p, q, v
    case 4:
        r, g, b = t, p, v
    case:
        r, g, b = v, p, q
    }
    return {r, g, b, a}
}

// --- the picker ---

// The open picker, when the keys point at it, as every other pane's verbs ask their target.
color_target :: proc(a: ^App) -> ^ColorPane {
    if a.aux_mode != .Color || !a.color.active || a.focus != .Aux {
        return nil
    }
    return &a.color
}

// With nowhere to write it back to: `:color` with no literal under the caret.
color_open :: proc(a: ^App, rgba: [4]f32) {
    color_open_full(a, rgba, {kind = .Hex}, -1, 0, 0, 0, "")
}

color_open_full :: proc(a: ^App, rgba: [4]f32, st: Color_Style, buf_idx, line, lo, hi: int, orig_text: string) {
    cp := &a.color
    if cp.orig_text != "" { // re-opening still owns the last token
        delete(cp.orig_text)
    }
    cp^ = ColorPane {
        rgba       = rgba,
        hsva       = color_rgba_to_hsva(rgba),
        style      = st,
        active     = true,
        live       = buf_idx >= 0 && buf_idx < len(a.editor.buffers),
        buf_idx    = buf_idx,
        line       = line,
        lo         = lo,
        hi         = hi,
        orig_text  = strings.clone(orig_text),
        orig_rgba  = rgba,
        orig_dirty = buf_idx >= 0 && buf_idx < len(a.editor.buffers) ? a.editor.buffers[buf_idx].dirty : false,
    }
    set_aux(a, .Color)
}

// False when the caret is not on one, which lets Alt+Enter fall through to the identifier jump.
color_open_at_caret :: proc(a: ^App) -> bool {
    b := main_text_buffer(a)
    if b == nil {
        return false
    }
    cur := b.cursors[b.primary].head
    if cur.line < 0 || cur.line >= txt.doc_line_count(&b.doc) {
        return false
    }
    cells := txt.doc_cells(&b.doc, cur.line)
    rgba, lo, hi, st, ok := color_at(cells.runes, txt.cells_col(cells, cur.col))
    if !ok {
        return false
    }
    // Byte ranges: the document stores bytes, not the rune columns the classifiers scan.
    line := string(txt.doc_line(&b.doc, cur.line, context.temp_allocator))
    b_lo, b_hi := color_byte_col(line, lo), color_byte_col(line, hi)
    color_open_full(a, rgba, st, a.editor.active, cur.line, b_lo, b_hi, line[b_lo:b_hi])
    return true
}

// Cancel puts the original token back. Commit rewinds the preview and re-applies the final
// colour once through the journal: the live writes are unjournalled, since a drag would push an
// undo step per frame, so this is where the session becomes one undoable edit.
color_close :: proc(a: ^App, commit: bool) {
    cp := &a.color
    if !cp.active {
        return
    }
    final := color_format(cp.rgba, cp.style, context.temp_allocator)
    color_restore(a)
    if b := color_live_buffer(a); commit && b != nil && final != cp.orig_text {
        color_write(a, b, final, journal = true)
        b.dirty = true
    }
    if cp.orig_text != "" {
        delete(cp.orig_text)
        cp.orig_text = ""
    }
    cp.active = false
    cp.live = false
    cp.buf_idx = -1
}

color_restore :: proc(a: ^App) {
    cp := &a.color
    b := color_live_buffer(a)
    if b == nil || cp.orig_text == "" {
        return
    }
    color_write(a, b, cp.orig_text)
    b.dirty = cp.orig_dirty // a cancelled edit must not leave the file starred
    cp.rgba = cp.orig_rgba
    cp.hsva = color_rgba_to_hsva(cp.orig_rgba)
}

color_apply_live :: proc(a: ^App) {
    b := color_live_buffer(a)
    if b == nil {
        return
    }
    color_write(a, b, color_format(a.color.rgba, a.color.style, context.temp_allocator))
    b.dirty = true
}

// When it still exists and still has the line.
@(private = "file")
color_live_buffer :: proc(a: ^App) -> ^edit.Buffer {
    cp := &a.color
    if !cp.live || cp.buf_idx < 0 || cp.buf_idx >= len(a.editor.buffers) {
        return nil
    }
    b := &a.editor.buffers[cp.buf_idx]
    if cp.line < 0 || cp.line >= txt.doc_line_count(&b.doc) {
        return nil
    }
    return b
}

// Re-points the range at what was written, since the two forms differ in length. `journal`
// picks the funnel: the undo journal for the committed edit, the bare document for the preview.
@(private = "file")
color_write :: proc(a: ^App, b: ^edit.Buffer, text: string, journal := false) {
    cp := &a.color
    cp.hi = min(cp.hi, txt.doc_line_len(&b.doc, cp.line))
    edits := []txt.Edit{{txt.doc_off(&b.doc, txt.Pos{cp.line, cp.lo}), txt.doc_off(&b.doc, txt.Pos{cp.line, cp.hi}), text, 0}}
    _ = journal ? txt.doc_commit(&b.doc, edits) : txt.doc_apply(&b.doc, edits)
    cp.hi = cp.lo + len(text)
}

color_set_hsva :: proc(a: ^App, hsva: [4]f32) {
    cp := &a.color
    cp.hsva = {clamp(hsva[0], 0, 360), clamp(hsva[1], 0, 1), clamp(hsva[2], 0, 1), clamp(hsva[3], 0, 1)}
    cp.rgba = color_hsva_to_rgba(cp.hsva)
    color_apply_live(a)
}

color_set_rgba :: proc(a: ^App, rgba: [4]f32) {
    cp := &a.color
    cp.rgba = {clamp(rgba[0], 0, 1), clamp(rgba[1], 0, 1), clamp(rgba[2], 0, 1), clamp(rgba[3], 0, 1)}
    cp.hsva = color_rgba_to_hsva(cp.rgba)
    color_apply_live(a)
}

// Clamped to the line's end.
color_byte_col :: proc(s: string, col: int) -> int {
    n := 0
    for i := 0; i < len(s); n += 1 {
        if n == col {
            return i
        }
        _, sz := utf8.decode_rune_in_string(s[i:])
        i += max(sz, 1)
    }
    return len(s)
}
