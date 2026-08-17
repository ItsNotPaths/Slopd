package main

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Link jumping — Alt+Enter on the token under the editor caret "follows" it, picking an action
// from what the token IS, classified most- to least-specific so a bare identifier is the fallback:
//   [[name]]            -> open the nearest name.md, searched from the project root
//   http(s)/ftp/... URL -> hand off to the desktop (xdg-open -> xdg-desktop-portal)
//   a colour literal    -> open the picker pane ON it, editing the token in place (color.odin)
//   an identifier       -> grep the project, then tree-sitter keeps only the lines that DEFINE
//                          it: one definition jumps straight there, several list in the
//                          GrepPane. No definition and no other match is a no-op.
// Only the dispatch + URL/wiki/colour handling live here; the project scan is grep.odin and the
// definition filtering is highlight.odin (where the tree-sitter machinery lives).

link_follow :: proc(a: ^App) {
    b := editor_current(&a.editor)
    cur := b.cursors[b.primary].head
    if cur.line < 0 || cur.line >= doc_line_count(&b.doc) {
        return
    }
    // The classifiers below all scan one line as runes, so the byte column crosses to a rune
    // index once, here, and nothing under this proc knows the document stores bytes.
    cells := doc_cells(&b.doc, cur.line)
    line := cells.runes
    col := cells_col(cells, cur.col)

    if name, ok := link_wikilink_at(line, col); ok {
        link_open_wiki(a, name)
    } else if url, ok := link_url_at(line, col); ok {
        desktop_open(url)
    } else if path, lno, lcol, ok := link_path_at(a, line, col); ok {
        jump_to(a, path, lno, lcol) // a file path (optionally `path:line:col`) under the caret
    } else if color_open_at_caret(a) { // a colour literal: the picker opens ON it and edits it
    } else if ident, ok := link_ident_at(line, col); ok {
        link_jump_definition(a, ident)
    }
}

// --- the shared jump primitive ---

// The ONE "reveal a location" entry point, behind the `j`/`jump` builtin, the grep pane and every
// Alt+Enter follow. `line`/`col` are 0-based and clamped, and `col` counts CHARACTERS — it comes
// from a grep hit or a typed line:col, neither of which knows about byte offsets.
// **Callers compute the absolute target** — jump_to does no relative arithmetic of its own.
jump_to :: proc(a: ^App, path: string, line: int, col: int) {
    if path != "" {
        open_file(a, path)
    }
    b := editor_current(&a.editor)
    target := clamp(line, 0, doc_line_count(&b.doc) - 1)
    doc_reset_cursor(&b.doc, Pos{target, doc_byte_col(&b.doc, target, max(col, 0))})
    set_focus(a, .Editor)
}

// Resolve a `j`/Alt+Enter file argument to an openable absolute path: a bare `name.ext` is the
// nearest match under the project root, `/abs` and `~/` are system-wide, a relative path WITH a
// separator joins the root. ok=false when nothing exists, so the next classifier gets a try.
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
        // Bare name: the nearest under the root, past the excluded directories — a `:j app.odin`
        // must not land in `vendor/` when a search for it would never look there.
        return find_nearest_file(a.project_root, arg, exclude_dirs(a))
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

// Resolve an identifier to its definition: grep narrows to every line mentioning it, tree-sitter
// filters to the lines that actually DEFINE it. Nothing found is a no-op, a single site jumps
// straight there with no picker, several open the grep pane to pick from.
@(private = "file")
link_jump_definition :: proc(a: ^App, ident: string) {
    hits := grep_project(a, ident, word = true, fixed = true)
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
// (nearest = shallowest). An explicit extension is kept verbatim, otherwise `.md` is appended.
@(private = "file")
link_open_wiki :: proc(a: ^App, name: string) {
    target := strings.trim_space(name)
    if target == "" {
        return
    }
    filename := strings.contains(target, ".") ? target : strings.concatenate({target, ".md"}, context.temp_allocator)
    if path, ok := find_nearest_file(a.project_root, filename, exclude_dirs(a)); ok {
        jump_to(a, path, 0, 0) // open at the top, via the shared jump primitive
    }
}

// Cap on directories visited so a huge tree can't stall the UI thread on a missing link.
@(private = "file")
FIND_DIR_BUDGET :: 4096

// Breadth-first search from `root` for a file whose base name equals `filename`, returning the
// shallowest match. Skips dotted directories and the configured exclusions (exclude.odin — the
// same list `:grep` and the workspace prompt read), and caps how many are visited.
// Temp-allocated.
@(private = "file")
find_nearest_file :: proc(root, filename: string, exclude: []string = nil) -> (string, bool) {
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
                dotted := len(fi.name) == 0 || fi.name[0] == '.'
                if !dotted && !exclude_hit(exclude, fi.name) {
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

// Hand a URL or FILE PATH to the desktop's default application. Spawned through `sh -c '... &'` so
// the SHELL backgrounds the handler: we reap the shell at once (no zombie) while a long-lived app
// (a video player) reparents to init. The target travels as $1, never re-parsed as shell syntax.
desktop_open :: proc(target: string) {
    argv := []string{"sh", "-c", `xdg-open "$1" >/dev/null 2>&1 &`, "sh", target}
    _, _, _, _ = os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
}

// The URL the caret sits on: expand over the run of URL-ish characters around it, trim trailing
// sentence punctuation, then accept only if it carries a known scheme.
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

// A file path under the caret, optionally with a `:line[:col]` suffix. Accepts ONLY when the path
// resolves to an existing file, so a `foo.bar` field access falls through to the definition jump;
// a bare word with no '/' and no extension is skipped, avoiding a tree walk on every Alt+Enter.
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

// Path-token characters: anything but whitespace or a quoting/bracketing delimiter. ':' IS
// included so a trailing `:line:col` rides along; a stray `a:b` is harmless since the path
// still has to resolve to a real file.
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

// The identifier the caret sits in (or just past): expand over [A-Za-z0-9_] both ways. Rejects a
// token that doesn't START like an identifier — a bare number is no symbol to jump to.
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

