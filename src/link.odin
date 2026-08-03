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
        desktop_open(url)
    } else if path, lno, lcol, ok := link_path_at(a, line, col); ok {
        jump_to(a, path, lno, lcol) // a file path (optionally `path:line:col`) under the caret
    } else if rgba, ok := link_color_at(line, col); ok {
        color_open(a, rgba)
    } else if ident, ok := link_ident_at(line, col); ok {
        link_jump_definition(a, ident)
    }
}

// --- the shared jump primitive ---

// jump_to is the ONE "reveal a location" entry point behind the `j`/`jump` builtin, the grep
// pane, and every Alt+Enter follow. A non-empty `path` is opened first (open_file reuses an
// already-open buffer + focuses the editor); then the caret lands on `line` (0-based, clamped
// to the file) at `col` (0-based, clamped to the line). Callers compute the absolute target —
// jump_to does no relative arithmetic of its own.
jump_to :: proc(a: ^App, path: string, line: int, col: int) {
    if path != "" {
        open_file(a, path)
    }
    b := editor_current(&a.editor)
    target := clamp(line, 0, len(b.lines) - 1)
    c := clamp(col, 0, line_len(&b.lines[target]))
    doc_reset_cursor(&b.doc, Pos{target, c})
    set_focus(a, .Editor)
}

// Resolve a `j`/Alt+Enter file argument to an openable absolute path. Per the user's rule:
// a bare `name.ext` (no separator) is looked up project-first — nearest match under the
// project root (find_nearest_file); a `/abs/path` or `~/path` is taken system-wide; a
// relative path WITH a separator joins onto the project root. ok=false when nothing exists,
// so a non-path token falls through to the next Alt+Enter classifier. Temp-allocated.
jump_resolve_path :: proc(a: ^App, arg: string) -> (string, bool) {
    if arg == "" {
        return "", false
    }
    switch {
    case arg[0] == '/': // system-wide absolute path
        return arg, os.is_file(arg)
    case strings.has_prefix(arg, "~/"): // home-relative, also system-wide
        home := os.get_env("HOME", context.temp_allocator)
        p := filepath.join({home, arg[2:]}, context.temp_allocator) or_else arg
        return p, os.is_file(p)
    case strings.contains(arg, "/"): // project-root-relative path
        p := filepath.join({a.project_root, arg}, context.temp_allocator) or_else arg
        return p, os.is_file(p)
    case:
        return find_nearest_file(a.project_root, arg) // bare name: nearest under the root
    }
}

// Parse a `j` line field: a bare `N` is an absolute 1-based line (-> 0-based); a signed
// `+N`/`-N` is relative to `base` (a 0-based line). ok=false on non-numeric input.
parse_line_spec :: proc(s: string, base: int) -> (int, bool) {
    n, ok := strconv.parse_int(s, 10) // parses a leading +/-, rejects trailing junk
    if !ok {
        return 0, false
    }
    if s[0] == '+' || s[0] == '-' {
        return base + n, true
    }
    return n - 1, true
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
        jump_to(a, path, 0, 0) // open at the top, via the shared jump primitive
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

// Hand a URL or a FILE PATH to the desktop, which opens it in its default application —
// a browser for a link, an image viewer / vlc / Sublime for a file (the filetree's
// Shift+Enter, see filetree_open_selected). xdg-open is the freedesktop entry point: on a
// portal-enabled desktop (Flatpak / modern Wayland) it routes to org.freedesktop.portal.
// OpenURI, falling back to the user's default handler elsewhere — so we reach the portal
// where it exists without linking a dbus client. This proc is the single seam to swap in a
// direct OpenURI dbus call later.
//
// Spawned through `sh -c '... &'` so the SHELL backgrounds the handler: we exec and reap the
// shell, which exits immediately (no zombie), while the app it launched — which may live for
// hours, e.g. a video player — is reparented to init and never blocks our loop. The target
// travels as $1, so nothing in it is ever re-parsed as shell syntax.
desktop_open :: proc(target: string) {
    argv := []string{"sh", "-c", `xdg-open "$1" >/dev/null 2>&1 &`, "sh", target}
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

// --- file paths ---

// A file path under the caret, optionally with a `:line` or `:line:col` suffix (the grep /
// compiler convention, e.g. `src/main.odin:42`). Expands over the run of path-ish characters,
// splits off any trailing line/col, then accepts ONLY when the path actually resolves to an
// existing file (jump_resolve_path) — so a plain identifier or `foo.bar` field access that
// isn't a real file falls through to the definition jump. A bare word with neither a '/' nor a
// file extension is skipped outright (it's an identifier, not a path — and skipping avoids a
// project-tree walk on every Alt+Enter). Returns 0-based line/col for jump_to.
@(private = "file")
link_path_at :: proc(a: ^App, line: []rune, col: int) -> (path: string, lno, lcol: int, ok: bool) {
    n := len(line)
    c := clamp(col, 0, n)
    if c >= n || !is_path_rune(line[c]) {
        if c > 0 && is_path_rune(line[c - 1]) {
            c -= 1
        } else {
            return
        }
    }
    lo := c
    for lo > 0 && is_path_rune(line[lo - 1]) {
        lo -= 1
    }
    hi := c + 1
    for hi < n && is_path_rune(line[hi]) {
        hi += 1
    }
    token := utf8.runes_to_string(line[lo:hi], context.temp_allocator)
    // Split off a trailing `:line` / `:line:col`. The path itself is the first field.
    parts := strings.split(token, ":", context.temp_allocator)
    arg := parts[0]
    if len(parts) >= 2 {
        if v, vok := strconv.parse_int(parts[1], 10); vok {
            lno = max(0, v - 1)
        }
    }
    if len(parts) >= 3 {
        if v, vok := strconv.parse_int(parts[2], 10); vok {
            lcol = max(0, v - 1)
        }
    }
    if !strings.contains(arg, "/") && filepath.ext(arg) == "" {
        return "", 0, 0, false // a bare word, not a path — leave it to the identifier jump
    }
    if p, found := jump_resolve_path(a, arg); found {
        return p, lno, lcol, true
    }
    return "", 0, 0, false
}

// Path-token characters: anything that isn't whitespace or a quoting/bracketing delimiter.
// ':' IS included so the trailing `:line:col` suffix rides along in the token (split off
// afterwards); a stray `a:b` is harmless since the path still has to resolve to a real file.
@(private = "file")
is_path_rune :: proc(r: rune) -> bool {
    if unicode.is_space(r) {
        return false
    }
    switch r {
    case '"', '\'', '`', '<', '>', '|', '(', ')', '[', ']', '{', '}', ',', ';':
        return false
    }
    return true
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
