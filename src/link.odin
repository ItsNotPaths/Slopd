package main

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Alt+Enter follows the token under the caret, classified most- to least-specific so a bare
// identifier is the fallback:
//   [[name]]            open the nearest name.md, searched from the project root
//   http(s)/ftp/… URL   hand off to the desktop (xdg-open)
//   a colour literal    open the picker ON it, editing the token in place (color.odin)
//   an identifier       grep the project, then tree-sitter keeps only the lines that DEFINE it:
//                       one jumps straight there, several list in the GrepPane
// Only the dispatch and the URL/wiki/colour handling live here; the scan is grep.odin and the
// definition filtering highlight.odin.

link_follow :: proc(a: ^App) {
    b := editor_current(&a.editor)
    cur := b.cursors[b.primary].head
    if cur.line < 0 || cur.line >= doc_line_count(&b.doc) {
        return
    }
    // The classifiers scan one line as runes, so the byte column crosses to a rune index once,
    // here, and nothing below knows the document stores bytes.
    cells := doc_cells(&b.doc, cur.line)
    line := cells.runes
    col := cells_col(cells, cur.col)

    if name, ok := link_wikilink_at(line, col); ok {
        link_open_wiki(a, name)
    } else if url, ok := link_url_at(line, col); ok {
        desktop_open(url)
    } else if path, lno, lcol, ok := link_path_at(a, line, col); ok {
        jump_to(a, path, lno, lcol) // a file path, optionally `path:line:col`
    } else if color_open_at_caret(a) { // a colour literal: the picker opens ON it
    } else if ident, ok := link_ident_at(line, col); ok {
        link_jump_definition(a, ident)
    }
}

// --- the shared jump primitive ---

// The one "reveal a location" entry point, behind `:j`, the grep pane and every Alt+Enter
// follow. `line`/`col` are 0-based and clamped, and `col` counts CHARACTERS. Callers compute the
// absolute target: jump_to does no relative arithmetic of its own.
jump_to :: proc(a: ^App, path: string, line: int, col: int) {
    if path != "" {
        open_file(a, path)
    }
    b := editor_current(&a.editor)
    target := clamp(line, 0, doc_line_count(&b.doc) - 1)
    doc_reset_cursor(&b.doc, Pos{target, doc_byte_col(&b.doc, target, max(col, 0))})
    set_focus(a, .Editor)
}

// A bare `name.ext` is the nearest match under the project root; `/abs` and `~/` are
// system-wide; a relative path with a separator joins the root. ok=false when nothing exists,
// so the next classifier gets a try.
jump_resolve_path :: proc(a: ^App, arg: string) -> (string, bool) {
    if arg == "" {
        return "", false
    }
    switch {
    case arg[0] == '/': // system-wide
        return arg, os.is_file(arg)
    case strings.has_prefix(arg, "~/"): // home-relative, also system-wide
        home := os.get_env("HOME", context.temp_allocator)
        p := filepath.join({home, arg[2:]}, context.temp_allocator) or_else arg
        return p, os.is_file(p)
    case strings.contains(arg, "/"): // project-root-relative
        p := filepath.join({a.project_root, arg}, context.temp_allocator) or_else arg
        return p, os.is_file(p)
    case:
        // The nearest under the root, past the excluded directories: `:j app.odin` must not
        // land in `vendor/` when a search would never look there.
        return find_nearest_file(a.project_root, arg, exclude_dirs(a))
    }
}

// A bare `N` is an absolute 1-based line; a signed `+N`/`-N` is relative to `base`, which is
// 0-based. ok=false on non-numeric input.
parse_line_spec :: proc(s: string, base: int) -> (int, bool) {
    n, ok := strconv.parse_int(s, 10) // takes a leading +/-, rejects trailing junk
    if !ok {
        return 0, false
    }
    if s[0] == '+' || s[0] == '-' {
        return base + n, true
    }
    return n - 1, true
}

// --- jump to definition ---

// grep narrows to every line mentioning it, tree-sitter filters to the lines that DEFINE it.
// A single site jumps straight there; several open the grep pane.
@(private = "file")
link_jump_definition :: proc(a: ^App, ident: string) {
    hits := grep_project(a, ident, word = true, fixed = true)
    if len(hits) == 0 {
        return
    }
    defs := ts_filter_definitions(a, ident, hits)
    switch len(defs) {
    case 0:
    // Only uses, or files with no installed grammar: no definition to jump to.
    case 1:
        grep_open_hit(a, defs[0]) // one definition: straight there, no picker
    case:
        grep_set(&a.grep, ident, defs) // several: list them to pick from
        set_aux(a, .Grep)
    }
}

// --- wiki links ---

// Nearest means shallowest, searched breadth-first from the project root. An explicit extension
// is kept verbatim, otherwise `.md` is appended.
@(private = "file")
link_open_wiki :: proc(a: ^App, name: string) {
    target := strings.trim_space(name)
    if target == "" {
        return
    }
    filename := strings.contains(target, ".") ? target : strings.concatenate({target, ".md"}, context.temp_allocator)
    if path, ok := find_nearest_file(a.project_root, filename, exclude_dirs(a)); ok {
        jump_to(a, path, 0, 0) // at the top
    }
}

// So a huge tree cannot stall the UI thread on a missing link.
@(private = "file")
FIND_DIR_BUDGET :: 4096

// The shallowest match. Skips dotted directories and the configured exclusions (exclude.odin),
// and caps how many directories are visited. Temp-allocated.
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

// Through `sh -c '... &'`, so the shell backgrounds the handler: we reap the shell at once while
// a long-lived app reparents to init. The target travels as $1, never re-parsed as shell syntax.
desktop_open :: proc(target: string) {
    argv := []string{"sh", "-c", `xdg-open "$1" >/dev/null 2>&1 &`, "sh", target}
    _, _, _, _ = os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
}

// Expand over the run of URL-ish characters, trim trailing sentence punctuation, then accept
// only if it carries a known scheme.
link_url_at :: proc(line: []rune, col: int) -> (string, bool) {
    n := len(line)
    c := clamp(col, 0, n)
    if c >= n || !is_url_rune(line[c]) { // the caret may rest just past the token
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
    for hi > lo && is_trailing_punct(line[hi - 1]) { // '.' and ',' are usually prose
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

// Optionally with a `:line[:col]` suffix. Accepts only when the path resolves to an existing
// file, so a `foo.bar` field access falls through to the definition jump; a bare word with no
// '/' and no extension is skipped, avoiding a tree walk on every Alt+Enter.
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
    // The path is the first field; a trailing `:line` / `:line:col` follows.
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
        return "", 0, 0, false // a bare word: leave it to the identifier jump
    }
    if p, found := jump_resolve_path(a, arg); found {
        return p, lno, lcol, true
    }
    return "", 0, 0, false
}

// Anything but whitespace or a quoting/bracketing delimiter. ':' is included so a trailing
// `:line:col` rides along; a stray `a:b` is harmless, since the path must still resolve.
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

// Expands over [A-Za-z0-9_] both ways. Rejects a token that does not START like an identifier:
// a bare number is no symbol to jump to.
link_ident_at :: proc(line: []rune, col: int) -> (string, bool) {
    n := len(line)
    c := col
    if c >= n || !is_ident_rune(line[c]) {
        if c > 0 && is_ident_rune(line[c - 1]) {
            c -= 1 // the caret just past a token's end, a common resting spot
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

// The `[[` opener at or before the caret and the `]]` closer at or after, with no nested opener
// between. Returns the inner text.
link_wikilink_at :: proc(line: []rune, col: int) -> (string, bool) {
    n := len(line)
    c := clamp(col, 0, n)
    open := -1
    if c + 1 < n && line[c] == '[' && line[c + 1] == '[' {
        open = c // resting ON the opener: the scan below reads pairs behind the caret only
    } else {
        for i := min(c, n - 1); i >= 1; i -= 1 {
            if i < c && line[i] == ']' && line[i - 1] == ']' {
                break // a closer BEHIND us: the caret is not inside an open link. The link's
            } // own closer is not behind it, so resting on `]]` still follows the link.
            if line[i] == '[' && line[i - 1] == '[' {
                open = i - 1
                break
            }
        }
    }
    if open < 0 {
        return "", false
    }
    close := -1
    for i := open + 2; i + 1 < n; i += 1 {
        if line[i] == '[' && line[i + 1] == '[' {
            break // a new opener before any closer
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

