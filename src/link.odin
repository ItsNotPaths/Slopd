package main

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Link jumping — Alt+Enter on the token under the editor caret "follows" it, picking an
// action from what the token IS (classified most- to least-specific, so a bare identifier
// is the fallback):
//   [[name]]            -> open the nearest name.md, searched from the project root
//   http(s)/ftp/... URL -> hand off to the desktop (xdg-open -> xdg-desktop-portal)
//   #hex / rgb()/rgba() -> stash the colour for the (stubbed) colour editor pane
//   an identifier       -> grep the project for it, then tree-sitter keeps only the lines
//                          that DEFINE it (not the invocations): one definition jumps
//                          straight there, several stash in the GrepPane (grep.odin) for a
//                          future results UI. A word that's none of the above and has no
//                          definition is a no-op.
// Only the dispatch + the URL/wiki/colour handling live here; the project scan is grep.odin
// and the definition filtering is highlight.odin (where the tree-sitter machinery lives).

link_follow :: proc(a: ^App) {
    b := editor_current(&a.editor)
    cur := b.cursors[b.primary].head
    if cur.line < 0 || cur.line >= len(b.lines) {
        return
    }
    line := b.lines[cur.line].text[:]
    col := clamp(cur.col, 0, len(line))

    if name, ok := link_wikilink_at(line, col); ok {
        link_open_wiki(a, name)
    } else if url, ok := link_url_at(line, col); ok {
        link_open_url(url)
    } else if rgba, ok := link_color_at(line, col); ok {
        color_open(a, rgba)
    } else if ident, ok := link_ident_at(line, col); ok {
        link_jump_definition(a, ident)
    }
}

// --- jump to definition ---

// Resolve an identifier to its definition: grep narrows to every file/line that mentions
// it (grep_run), tree-sitter filters those to the lines that actually DEFINE it
// (ts_filter_definitions). Nothing found is a no-op, a single site jumps straight there
// (no picker), several stash in the grep pane for a future results UI to list and pick.
@(private = "file")
link_jump_definition :: proc(a: ^App, ident: string) {
    hits := grep_run(a.project_root, ident, word = true, fixed = true)
    if len(hits) == 0 {
        return
    }
    defs := ts_filter_definitions(a, ident, hits)
    switch len(defs) {
    case 0:
    // grep matched only uses/invocations (or files with no installed grammar) — no def to jump to
    case 1:
        grep_open_hit(a, defs[0]) // one definition: jump straight there, no picker
    case:
        grep_set(&a.grep, ident, defs) // several: list them in the grep pane to pick from
        set_aux(a, .Grep)
    }
}

// --- wiki links ---

// `[[name]]` -> open the nearest `name.md`, searched breadth-first from the project root
// (nearest = shallowest). `name` keeps an explicit extension verbatim (`[[notes.txt]]`),
// otherwise `.md` is appended. No-op when nothing matches.
@(private = "file")
link_open_wiki :: proc(a: ^App, name: string) {
    target := strings.trim_space(name)
    if target == "" {
        return
    }
    filename := strings.contains(target, ".") ? target : strings.concatenate({target, ".md"}, context.temp_allocator)
    if path, ok := find_nearest_file(a.project_root, filename); ok {
        open_file(a, path)
    }
}

// Cap on directories visited so a huge tree can't stall the UI thread on a missing link.
@(private = "file")
FIND_DIR_BUDGET :: 4096

// Breadth-first search from `root` for a file whose base name equals `filename`, returning
// the shallowest match (the "nearest"). Skips dotted directories (.git etc.) and caps the
// number of directories visited. The returned path is temp-allocated (open_file clones it).
@(private = "file")
find_nearest_file :: proc(root, filename: string) -> (string, bool) {
    queue := make([dynamic]string, context.temp_allocator)
    append(&queue, strings.clone(root, context.temp_allocator))
    for i := 0; i < len(queue) && i < FIND_DIR_BUDGET; i += 1 {
        dir := queue[i]
        f, oerr := os.open(dir)
        if oerr != nil {
            continue
        }
        it := os.read_directory_iterator_create(f)
        for fi in os.read_directory_iterator(&it) {
            if fi.type == .Directory {
                if len(fi.name) > 0 && fi.name[0] != '.' {
                    if sub, jerr := filepath.join({dir, fi.name}, context.temp_allocator); jerr == nil {
                        append(&queue, sub)
                    }
                }
            } else if fi.name == filename {
                path, jerr := filepath.join({dir, fi.name}, context.temp_allocator)
                os.read_directory_iterator_destroy(&it)
                os.close(f)
                return path, jerr == nil
            }
        }
        os.read_directory_iterator_destroy(&it)
        os.close(f)
    }
    return "", false
}

// --- web links ---

@(private = "file")
URL_SCHEMES :: [?]string{"https://", "http://", "ftp://", "file://", "mailto:", "www."}

// Hand a URL to the desktop. xdg-open is the freedesktop entry point: on a portal-enabled
// desktop (Flatpak / modern Wayland) it routes to org.freedesktop.portal.OpenURI, falling
// back to the user's default handler elsewhere — so we reach the portal where it exists
// without linking a dbus client. Spawned like git_run shells out to git (os.process_exec
// reaps it, no zombie); xdg-open returns at once after launching the handler, so the brief
// synchronous wait doesn't stall the UI. This proc is the single seam to swap in a direct
// OpenURI dbus call later.
@(private = "file")
link_open_url :: proc(url: string) {
    argv := []string{"xdg-open", url}
    _, _, _, _ = os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
}

// The URL the caret sits on: expand over the contiguous run of URL-ish characters around
// it (stopping at whitespace and bracketing/quoting delimiters), trim trailing sentence
// punctuation, then accept only if it carries a known scheme.
@(private = "file")
link_url_at :: proc(line: []rune, col: int) -> (string, bool) {
    n := len(line)
    c := clamp(col, 0, n)
    if c >= n || !is_url_rune(line[c]) { // caret may rest just past the token's end
        if c > 0 && is_url_rune(line[c - 1]) {
            c -= 1
        } else {
            return "", false
        }
    }
    lo := c
    for lo > 0 && is_url_rune(line[lo - 1]) {
        lo -= 1
    }
    hi := c + 1
    for hi < n && is_url_rune(line[hi]) {
        hi += 1
    }
    for hi > lo && is_trailing_punct(line[hi - 1]) { // '.', ',' etc. are usually prose, not the URL
        hi -= 1
    }
    token := utf8.runes_to_string(line[lo:hi], context.temp_allocator)
    low := strings.to_lower(token, context.temp_allocator)
    for s in URL_SCHEMES {
        if strings.has_prefix(low, s) {
            return token, true
        }
    }
    return "", false
}

@(private = "file")
is_url_rune :: proc(r: rune) -> bool {
    if unicode.is_space(r) {
        return false
    }
    switch r {
    case '<', '>', '"', '`', '{', '}', '|', '\\', '^', '(', ')', '[', ']', '\'':
        return false
    }
    return true
}

@(private = "file")
is_trailing_punct :: proc(r: rune) -> bool {
    switch r {
    case '.', ',', ';', ':', '!', '?':
        return true
    }
    return false
}

// --- identifiers ---

// The identifier the caret sits in (or just past): expand over [A-Za-z0-9_] both ways.
// Rejects a token that doesn't START like an identifier (a bare number is no symbol to
// jump to). Returns a temp-allocated string.
@(private = "file")
link_ident_at :: proc(line: []rune, col: int) -> (string, bool) {
    n := len(line)
    c := col
    if c >= n || !is_ident_rune(line[c]) {
        if c > 0 && is_ident_rune(line[c - 1]) {
            c -= 1 // caret just past a token's end (a common resting spot)
        } else {
            return "", false
        }
    }
    lo := c
    for lo > 0 && is_ident_rune(line[lo - 1]) {
        lo -= 1
    }
    hi := c + 1
    for hi < n && is_ident_rune(line[hi]) {
        hi += 1
    }
    if !is_ident_start(line[lo]) {
        return "", false
    }
    return utf8.runes_to_string(line[lo:hi], context.temp_allocator), true
}

@(private = "file")
is_ident_rune :: proc(r: rune) -> bool {
    return r == '_' || unicode.is_letter(r) || unicode.is_digit(r)
}

@(private = "file")
is_ident_start :: proc(r: rune) -> bool {
    return r == '_' || unicode.is_letter(r)
}

// --- wiki link scan ---

// `[[name]]` containing the caret: find the `[[` opener at or before it and the `]]` closer
// at or after, with no nested opener between. Returns the inner text.
@(private = "file")
link_wikilink_at :: proc(line: []rune, col: int) -> (string, bool) {
    n := len(line)
    c := clamp(col, 0, n)
    open := -1
    for i := min(c, n - 1); i >= 1; i -= 1 {
        if line[i] == ']' && line[i - 1] == ']' {
            break // a closer to our left — the caret isn't inside an open link
        }
        if line[i] == '[' && line[i - 1] == '[' {
            open = i - 1
            break
        }
    }
    if open < 0 {
        return "", false
    }
    close := -1
    for i := open + 2; i + 1 < n; i += 1 {
        if line[i] == '[' && line[i + 1] == '[' {
            break // a new opener before any closer — not a complete link around the caret
        }
        if line[i] == ']' && line[i + 1] == ']' {
            close = i
            break
        }
    }
    if close < 0 || c > close + 2 {
        return "", false
    }
    return utf8.runes_to_string(line[open + 2:close], context.temp_allocator), true
}

// --- colours ---

// ColorPane — the (stubbed) colour editor's state: just the colour the caret was on, in
// 0..1 RGBA. Opening currently only records it; the editing UI + the AuxMode that shows it
// are future work, so this is the seam, not the pane.
ColorPane :: struct {
    rgba: [4]f32,
}

color_open :: proc(a: ^App, rgba: [4]f32) {
    a.color.rgba = rgba
    // TODO(colour-editor): set_aux(a, .Color) once the pane + its AuxMode exist.
}

// A colour under the caret: a `#`-prefixed hex literal, else an `rgb()/rgba()` tuple.
@(private = "file")
link_color_at :: proc(line: []rune, col: int) -> ([4]f32, bool) {
    if rgba, ok := link_hex_at(line, col); ok {
        return rgba, true
    }
    return link_rgbfunc_at(line, col)
}

// `#rgb` / `#rgba` / `#rrggbb` / `#rrggbbaa` under the caret: expand over hex digits and
// require a leading '#' (a bare hex run is too ambiguous to treat as a colour).
@(private = "file")
link_hex_at :: proc(line: []rune, col: int) -> ([4]f32, bool) {
    n := len(line)
    c := clamp(col, 0, n)
    if c < n && line[c] == '#' && c + 1 < n && is_hex_rune(line[c + 1]) {
        c += 1 // caret on the '#': step onto the first digit
    }
    if c >= n || !is_hex_rune(line[c]) {
        if c > 0 && (is_hex_rune(line[c - 1]) || line[c - 1] == '#') {
            c -= 1
        } else {
            return {}, false
        }
    }
    lo := c
    for lo > 0 && is_hex_rune(line[lo - 1]) {
        lo -= 1
    }
    if lo == 0 || line[lo - 1] != '#' {
        return {}, false
    }
    hi := c + 1
    for hi < n && is_hex_rune(line[hi]) {
        hi += 1
    }
    return parse_hex_rgba(line[lo:hi])
}

@(private = "file")
is_hex_rune :: proc(r: rune) -> bool {
    switch r {
    case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
        return true
    }
    return false
}

// Parse a hex colour body (no '#'): 6/8 digits verbatim, 3/4 expanded to byte pairs.
@(private = "file")
parse_hex_rgba :: proc(hex: []rune) -> (rgba: [4]f32, ok: bool) {
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

// `rgb(r,g,b)` / `rgba(r,g,b,a)` containing the caret: scan the line for the function name
// + '(' ... ')' and check the caret falls within. Channels are 0..255 (-> 0..1); alpha is
// 0..1 when written with a decimal point, else 0..255.
@(private = "file")
link_rgbfunc_at :: proc(line: []rune, col: int) -> ([4]f32, bool) {
    n := len(line)
    for i := 0; i < n; i += 1 {
        name := rgb_name_len(line, i)
        if name == 0 {
            continue
        }
        p := i + name
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
        if col >= i && col <= q {
            if rgba, ok := parse_rgb_args(line[p + 1:q], name == 4); ok {
                return rgba, true
            }
        }
        i = q
    }
    return {}, false
}

// The function-name length at index i: 4 for "rgba", 3 for "rgb", 0 otherwise. Requires a
// word boundary before i so "srgb(" doesn't match.
@(private = "file")
rgb_name_len :: proc(line: []rune, i: int) -> int {
    if i > 0 && is_ident_rune(line[i - 1]) {
        return 0
    }
    if runes_match(line, i, "rgba") {
        return 4
    }
    if runes_match(line, i, "rgb") {
        return 3
    }
    return 0
}

@(private = "file")
runes_match :: proc(line: []rune, at: int, s: string) -> bool {
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
parse_rgb_args :: proc(args: []rune, has_alpha: bool) -> (rgba: [4]f32, ok: bool) {
    s := utf8.runes_to_string(args, context.temp_allocator)
    parts := strings.split(s, ",", context.temp_allocator)
    if len(parts) != (has_alpha ? 4 : 3) {
        return {}, false
    }
    rgba = {0, 0, 0, 1}
    for k in 0 ..< 3 {
        v, vok := strconv.parse_f64(strings.trim_space(parts[k]))
        if !vok {
            return {}, false
        }
        rgba[k] = clampf(f32(v) / 255, 0, 1)
    }
    if has_alpha {
        astr := strings.trim_space(parts[3])
        v, vok := strconv.parse_f64(astr)
        if !vok {
            return {}, false
        }
        // an alpha written with a '.' is 0..1 (CSS); a bare integer is 0..255 (some tools)
        rgba[3] = strings.contains(astr, ".") ? clampf(f32(v), 0, 1) : clampf(f32(v) / 255, 0, 1)
    }
    return rgba, true
}
