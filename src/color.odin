package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Colour literals, and the picker's model. Alt+Enter on a colour opens the pane on it and edits
// it IN PLACE, so reading one is only half the job — what comes out has to go back in the form
// it came from. Three forms, because none can be rewritten as another without changing the file:
//
//   #rgb #rgba #rrggbb #rrggbbaa      hex: CSS, theme files, most config
//   rgb(r, g, b)   rgba(r, g, b, a)   the CSS function; channels are 0..255
//   {r, g, b}  (r, g, b, a)  [r,g,b]  a bare tuple: an Odin [3]f32, a GLSL vec3, a Python tuple
//
// The tuple is the HEURISTIC one — three or four numbers in brackets is not a colour by itself,
// and nothing in the text says which scale they are on. The values decide: channels that all fit
// in 0..1 are read as unit floats, anything larger as 0..255 bytes. `{1, 0, 0}` is therefore
// red, which is what it means in every language that writes a colour that way, rather than the
// near-black that 1/255 would give. Numbers outside 0..255 are not a colour at all, which is
// what keeps `(1920, 1080, 60)` out of the picker.

Color_Kind :: enum {
    Hex,
    Func, // rgb() / rgba()
    Tuple, // brackets and commas
}

// How a colour was written. The picker has to put back what it took out: the same brackets, the
// same scale, the same channel count.
Color_Style :: struct {
    kind:        Color_Kind,
    has_alpha:   bool,
    open, close: rune, // Tuple: the brackets it was written in
    floats:      bool, // Tuple: channels are 0..1 rather than 0..255
    alpha_float: bool, // the alpha field is 0..1 where the channels are bytes
}

// The picker's state: the colour, the buffer range it came from, and enough of the original to
// put back on Escape. `hsva` is the editable copy — the sliders are HSV and round-tripping them
// through RGB would drift the hue every time the value passed through 0.
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
    sel:        int, // focused slider; a live drag lives in a.drag, not here
}

// --- reading ---

// The colour under rune column `col`: its value, the rune span it fills, and how it was written.
// Ordered most- to least-specific — an rgb() call is a tuple with a name in front of it, and the
// tuple's bare brackets are the loosest pattern here, so it goes last.
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

// `#rgb` / `#rgba` / `#rrggbb` / `#rrggbbaa` under the caret, span INCLUDING the '#'. A bare hex
// run is too ambiguous to be a colour, so the '#' is required.
color_hex_span :: proc(line: []rune, col: int) -> (lo, hi: int, ok: bool) {
    n := len(line)
    c := clamp(col, 0, n)
    if c < n && line[c] == '#' && c + 1 < n && color_is_hex(line[c + 1]) {
        c += 1 // the caret is on the '#': step onto the first digit
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

// An `rgb(...)` / `rgba(...)` call containing `col`: the call's span, its arguments' span, and
// the name's length — 4 is `rgba`, which is the only announcement the alpha field gets.
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

// The innermost bracket pair holding `col`, in any of the three bracket kinds. A caret ON either
// bracket counts, and so does one just past the closer — which is where the caret usually is
// after you type the thing.
color_tuple_span :: proc(line: []rune, col: int) -> (lo, hi: int, ok: bool) {
    if len(line) == 0 {
        return 0, 0, false
    }
    c := clamp(col, 0, len(line) - 1)
    // A caret just past a closing bracket belongs to the pair that bracket closes, not to
    // whatever pair happens to contain the caret now — which is the one AROUND it.
    if c > 0 && color_is_close(line[c - 1]) {
        c -= 1
    }
    return color_pair_at(line, c)
}

// The bracket pair `at` sits inside. Walking left counts depth so a pair nested in another (the
// `{...}` of `[3]f32{...}`) resolves to the inner one; a position ON a closer starts one to its
// left, or that closer's own depth would carry the walk out to the pair around it.
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
                    return 0, 0, false // crossed brackets: not a literal
                }
                return i, j + 1, true
            }
            depth -= 1
        }
    }
    return 0, 0, false
}

// The `r, g, b[, a]` inside either bracket form. `st` carries what the caller already knows —
// the kind and the brackets — and comes back with what the FIELDS decide: how many there are
// and which scale each was written on.
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
    // The scale: a CSS call is 0..255 whatever it holds; a bare tuple is floats when every
    // channel fits in 0..1. See the header for why that reading wins.
    out.floats = st.kind == .Tuple && max(v[0], v[1], v[2]) <= 1
    out.alpha_float = out.floats || dot[3]
    rgba = {0, 0, 0, 1}
    for i in 0 ..< 3 {
        rgba[i] = clampf(out.floats ? f32(v[i]) : f32(v[i]) / 255, 0, 1)
    }
    if out.has_alpha {
        rgba[3] = clampf(out.alpha_float ? f32(v[3]) : f32(v[3]) / 255, 0, 1)
    }
    return rgba, out, true
}

// One field: a plain decimal number, and whether it was written with a point — the difference
// between an alpha of `128` (a byte) and one of `0.5`.
color_field :: proc(s: string) -> (v: f64, dot, ok: bool) {
    txt := strings.trim_space(s)
    if txt == "" {
        return 0, false, false
    }
    v, ok = strconv.parse_f64(txt)
    return v, strings.contains(txt, "."), ok
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

// The function name at `i`: 4 for "rgba", 3 for "rgb", 0 otherwise. A word boundary is required
// before it, so `srgb(` is not a colour call.
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

// `rgba` in the form `st` names — the inverse of color_at, and it has to stay one: the picker
// replaces a live buffer range with this on every drag frame.
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

// A channel as it was written: a byte, or a unit float with its trailing zeros cut, so a drag
// leaves `0.5` rather than `0.500`.
@(private = "file")
color_write_chan :: proc(b: ^strings.Builder, v: f32, as_float: bool) {
    if !as_float {
        fmt.sbprintf(b, "%d", color_byte(v))
        return
    }
    s := strings.trim_right(fmt.tprintf("%.3f", clampf(v, 0, 1)), "0")
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

// The open picker, when the keys are pointed at it. The nav/activate verbs ask this the way
// every other pane's verbs ask their own target.
color_target :: proc(a: ^App) -> ^ColorPane {
    if a.aux_mode != .Color || !a.color.active || a.focus != .Aux {
        return nil
    }
    return &a.color
}

// Open on a colour with nowhere to write it back to — the `:color` command with no literal
// under the caret.
color_open :: proc(a: ^App, rgba: [4]f32) {
    color_open_full(a, rgba, {kind = .Hex}, -1, 0, 0, 0, "")
}

color_open_full :: proc(a: ^App, rgba: [4]f32, st: Color_Style, buf_idx, line, lo, hi: int, orig_text: string) {
    cp := &a.color
    if cp.orig_text != "" { // re-opening over an open picker still owns the last token
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

// Open on the colour under the caret and edit it in place. False when the caret is not on one,
// which is what lets Alt+Enter fall through to the identifier jump (link.odin).
color_open_at_caret :: proc(a: ^App) -> bool {
    b := main_text_buffer(a)
    if b == nil {
        return false
    }
    cur := b.cursors[b.primary].head
    if cur.line < 0 || cur.line >= doc_line_count(&b.doc) {
        return false
    }
    cells := doc_cells(&b.doc, cur.line)
    rgba, lo, hi, st, ok := color_at(cells.runes, cells_col(cells, cur.col))
    if !ok {
        return false
    }
    // The picker edits BYTE ranges — the document stores bytes and nothing under it knows
    // about the rune columns the classifiers scan.
    line := string(doc_line(&b.doc, cur.line, context.temp_allocator))
    b_lo, b_hi := color_byte_col(line, lo), color_byte_col(line, hi)
    color_open_full(a, rgba, st, a.editor.active, cur.line, b_lo, b_hi, line[b_lo:b_hi])
    return true
}

// Cancel puts the original token back. Commit REWINDS the preview and re-applies the final
// colour once, through the journal: the live writes are deliberately unjournalled — a drag
// would push an undo step per frame, and the colours it swept past are not states anybody
// asked to come back to — so this is where the whole session becomes one undoable edit.
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
    b.dirty = cp.orig_dirty // an untouched file must not be left starred by a cancelled edit
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

// The buffer the picker is writing into, when it still exists and still has the line.
@(private = "file")
color_live_buffer :: proc(a: ^App) -> ^Buffer {
    cp := &a.color
    if !cp.live || cp.buf_idx < 0 || cp.buf_idx >= len(a.editor.buffers) {
        return nil
    }
    b := &a.editor.buffers[cp.buf_idx]
    if cp.line < 0 || cp.line >= doc_line_count(&b.doc) {
        return nil
    }
    return b
}

// Replace the tracked range with `text` and re-point the range at what was written — every
// drag frame runs this, and the two forms differ in length. `journal` picks the funnel: the
// undo journal for the one committed edit, the bare document for the preview (color_close).
@(private = "file")
color_write :: proc(a: ^App, b: ^Buffer, text: string, journal := false) {
    cp := &a.color
    cp.hi = min(cp.hi, doc_line_len(&b.doc, cp.line))
    edits := []Edit{{doc_off(&b.doc, Pos{cp.line, cp.lo}), doc_off(&b.doc, Pos{cp.line, cp.hi}), text, 0}}
    _ = journal ? doc_commit(&b.doc, edits) : doc_apply(&b.doc, edits)
    cp.hi = cp.lo + len(text)
}

color_set_hsva :: proc(a: ^App, hsva: [4]f32) {
    cp := &a.color
    cp.hsva = {clampf(hsva[0], 0, 360), clampf(hsva[1], 0, 1), clampf(hsva[2], 0, 1), clampf(hsva[3], 0, 1)}
    cp.rgba = color_hsva_to_rgba(cp.hsva)
    color_apply_live(a)
}

color_set_rgba :: proc(a: ^App, rgba: [4]f32) {
    cp := &a.color
    cp.rgba = {clampf(rgba[0], 0, 1), clampf(rgba[1], 0, 1), clampf(rgba[2], 0, 1), clampf(rgba[3], 0, 1)}
    cp.hsva = color_rgba_to_hsva(cp.rgba)
    color_apply_live(a)
}

// The byte offset of rune column `col` in `s`, clamped to the line's end.
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
