package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import ts "../vendor/odin-tree-sitter"

// Syntax highlighting via tree-sitter. A buffer's language is resolved from its file
// extension against the registry; the grammar's compiled parser (grammars/<lang>.so)
// is dlopen'd once and its highlights query (grammars/<lang>.scm) compiled once, both
// cached by language. On draw we reparse the buffer and colour the visible rows from
// the query's captures. v1 reparses the whole buffer each draw — simple and fast for
// normal files; incremental reparse is a later optimisation. The tree-sitter engine is
// the vendored `ts` bindings (libtree-sitter, statically linked); the per-language .so
// is the only dynamically loaded piece.

// A colour per rune for one line (length == the line's rune count). An unhighlighted
// rune keeps the default foreground.
Row_Colors :: [][3]f32

// A loaded grammar: the dlopen handle, its tree-sitter language, and the compiled
// highlights query (nil if the grammar shipped none). `ok` is false when loading or
// the ABI check failed — cached so a broken grammar isn't retried every draw.
Loaded_Grammar :: struct {
    lib:   dynlib.Library,
    lang:  ts.Language,
    query: ts.Query,
    ok:    bool,
}

Highlighter :: struct {
    parser: ts.Parser,
    cursor: ts.Query_Cursor,
    loaded: map[string]Loaded_Grammar, // by language name; load/compile once
    // The last buffer's parse tree, reused across frames until its content changes.
    // A caret blink or smooth scroll redraws without reparsing the whole file.
    tree: ts.Tree,
    tree_buf: rawptr, // the Buffer it was parsed from (identity)
    tree_ver: u64, // doc.version at parse time
}

highlighter_init :: proc(h: ^Highlighter) {
    h.parser = ts.parser_new()
    h.cursor = ts.query_cursor_new()
    h.loaded = make(map[string]Loaded_Grammar)
}

highlighter_destroy :: proc(h: ^Highlighter) {
    for _, g in h.loaded {
        if g.query != nil {
            ts.query_delete(g.query)
        }
        if g.lib != nil {
            _ = dynlib.unload_library(g.lib)
        }
    }
    delete(h.loaded)
    if h.tree != nil {
        ts.tree_delete(h.tree)
    }
    ts.query_cursor_delete(h.cursor)
    ts.parser_delete(h.parser)
}

// Parses b once and caches the tree, returning it unchanged on later frames until
// the buffer's content version moves. nil if the parse fails. The cached tree is
// owned by the highlighter (freed on reparse / destroy) — callers must not delete it.
@(private = "file")
highlighter_tree :: proc(h: ^Highlighter, b: ^Buffer, lang: ts.Language) -> ts.Tree {
    if h.tree != nil && h.tree_buf == rawptr(b) && h.tree_ver == b.version {
        return h.tree
    }
    if !ts.parser_set_language(h.parser, lang) {
        return nil
    }
    text := doc_string(&b.doc, context.temp_allocator)
    tree := ts.parser_parse_string(h.parser, text)
    if tree == nil {
        return nil
    }
    if h.tree != nil {
        ts.tree_delete(h.tree)
    }
    h.tree, h.tree_buf, h.tree_ver = tree, rawptr(b), b.version
    return tree
}

// A captured node's span + the colour it paints. Hoisted to file scope so the sort
// comparator can name it.
@(private = "file")
Capture_Span :: struct {
    start, end: ts.Point, // tree-sitter points: row = line, col = BYTE offset in line
    size:       u32, // byte length, for "most specific (smallest) wins" ordering
    color:      [3]f32,
}

// Per-visible-row rune colours for buffer b's window [first_line, first_line+count).
// Returns nil when b has no installed/loadable grammar (caller draws plain fg).
// Temp-allocated — valid for the current frame only.
highlight_visible :: proc(a: ^App, b: ^Buffer, first_line, count: int) -> []Row_Colors {
    g, ok := highlighter_grammar(a, b.path)
    if !ok || g.query == nil {
        return nil
    }
    th := &a.theme
    h := &a.hl

    // The whole-buffer parse is cached (tree-sitter needs the full text); we only
    // query the visible rows, so the per-frame work is bounded by the viewport and a
    // settled view (blinking caret, smooth scroll) reuses the tree without reparsing.
    tree := highlighter_tree(h, b, g.lang)
    if tree == nil {
        return nil
    }

    last := min(first_line + count, len(b.lines))
    ts.query_cursor_set_point_range(h.cursor, {u32(first_line), 0}, {u32(last), 0})
    ts.query_cursor_exec(h.cursor, g.query, ts.tree_root_node(tree))

    // Collect the visible captures, then paint largest-span-first so a more specific
    // (smaller) capture overrides the broader one it nests inside.
    spans := make([dynamic]Capture_Span, 0, 256, context.temp_allocator)
    for {
        match, ci, more := ts.query_cursor_next_capture(h.cursor)
        if !more {
            break
        }
        qc := match.captures[ci]
        color, mapped := capture_color(th, ts.query_capture_name_for_id(g.query, qc.index))
        if !mapped {
            continue
        }
        append(
            &spans,
            Capture_Span {
                start = ts.node_start_point(qc.node),
                end = ts.node_end_point(qc.node),
                size = ts.node_end_byte(qc.node) - ts.node_start_byte(qc.node),
                color = color,
            },
        )
    }
    // Largest span first so a smaller (more specific) capture paints over it. Ties
    // break by start position for a stable order — equal-size captures never swap
    // precedence frame to frame (which would flicker their colour).
    slice.sort_by(spans[:], proc(x, y: Capture_Span) -> bool {
        if x.size != y.size {
            return x.size > y.size
        }
        if x.start.row != y.start.row {
            return x.start.row < y.start.row
        }
        return x.start.col < y.start.col
    })

    // A colour row per visible line, defaulting to the foreground.
    rows := make([]Row_Colors, count, context.temp_allocator)
    for k in 0 ..< count {
        line := first_line + k
        if line >= len(b.lines) {
            continue
        }
        rc := make(Row_Colors, len(b.lines[line].text), context.temp_allocator)
        slice.fill(rc, th.fg)
        rows[k] = rc
    }

    // Paint each capture across the visible rows it covers, mapping byte columns to
    // runes. Clamp the row span to the window so a capture extending far above/below
    // (a long multi-line string/comment) costs only the rows we actually draw.
    for s in spans {
        lo_row := max(int(s.start.row), first_line)
        hi_row := min(int(s.end.row), first_line + count - 1)
        for row in lo_row ..= hi_row {
            k := row - first_line
            if rows[k] == nil {
                continue // line past end-of-buffer (defensive; count keeps k in range)
            }
            runes := b.lines[row].text[:]
            lo_byte := row == int(s.start.row) ? int(s.start.col) : 0
            hi_byte := row == int(s.end.row) ? int(s.end.col) : max(int)
            for c in byte_to_rune_col(runes, lo_byte) ..< byte_to_rune_col(runes, hi_byte) {
                rows[k][c] = s.color
            }
        }
    }
    return rows
}

// The fold range for a block opening on `line`, from the buffer's parse tree:
// [line, end_row] where end_row is the last line to hide. Finds the innermost
// multi-line syntax node that BEGINS on `line` (a brace block, a def/proc body, an
// array literal, …) and folds down to its last line. ok=false when there's no loaded
// grammar or no such node — the caller then falls back to an indentation scan.
highlight_fold_range :: proc(a: ^App, b: ^Buffer, line: int) -> (start, end: int, ok: bool) {
    if line < 0 || line >= len(b.lines) {
        return 0, 0, false
    }
    g, found := highlighter_grammar(a, b.path)
    if !found {
        return 0, 0, false
    }
    tree := highlighter_tree(&a.hl, b, g.lang)
    if tree == nil {
        return 0, 0, false
    }

    // Descend at the line's first real token (past the indentation), then climb to
    // the nearest ancestor that opens here and spans more than one line.
    col := u32(line_indent_cols(&b.lines[line]))
    node := ts.node_descendant_for_range(ts.tree_root_node(tree), ts.Point{u32(line), col}, ts.Point{u32(line), col})
    for !ts.node_is_null(node) {
        sp := ts.node_start_point(node)
        ep := ts.node_end_point(node)
        if int(sp.row) < line {
            break // ancestors from here up begin above this line — none opens it
        }
        if int(sp.row) == line && int(ep.row) > line {
            last := min(int(ep.row), len(b.lines) - 1)
            if ep.col == 0 && last > line {
                last -= 1 // half-open end at column 0 sits on the next line; trim it
            }
            // Keep a lone dedented closer (the `}` of a brace block) on its own line.
            // A node's end point lands on the `}` line or just past it depending on the
            // grammar, so without this equivalent blocks folded differently — the brace
            // survived at one nesting depth but not another. Trimming any trailing line
            // no deeper than the header makes the closer always visible, consistently.
            if last > line && line_indent_cols(&b.lines[last]) <= line_indent_cols(&b.lines[line]) {
                last -= 1
            }
            return line, last, last > line
        }
        node = ts.node_parent(node)
    }
    return 0, 0, false
}

// The loaded grammar for a buffer path's extension, loading on first use and caching.
// ok=false means no registry match. A not-yet-installed grammar is NOT cached (so a
// later install is picked up on a subsequent draw); a present-but-broken one IS cached
// as failed so it isn't retried every frame.
@(private = "file")
highlighter_grammar :: proc(a: ^App, path: string) -> (Loaded_Grammar, bool) {
    if path == "" {
        return {}, false
    }
    ext := strings.trim_prefix(filepath.ext(path), ".")
    name, found := grammar_for_ext(a.grammars, ext)
    if !found {
        return {}, false
    }
    if g, cached := a.hl.loaded[name]; cached {
        return g, g.ok
    }
    dir := grammars_dir(context.temp_allocator)
    if !grammar_present(dir, name) {
        return {}, false // not installed yet; don't cache so an install is seen later
    }
    g := load_grammar(dir, name)
    a.hl.loaded[name] = g
    return g, g.ok
}

// dlopen grammars/<name>.so, resolve its tree_sitter_<name> language, ABI-check it,
// and compile grammars/<name>.scm. Never panics — any failure returns ok=false.
@(private = "file")
load_grammar :: proc(dir, name: string) -> Loaded_Grammar {
    lib, loaded := dynlib.load_library(grammar_lib_path(dir, name, context.temp_allocator))
    if !loaded {
        return {}
    }
    sym, found := dynlib.symbol_address(lib, fmt.tprintf("tree_sitter_%s", name))
    if !found {
        _ = dynlib.unload_library(lib)
        return {}
    }
    lang := (cast(proc "c" () -> ts.Language)sym)()
    if abi := ts.language_abi_version(lang); abi < ts.MIN_COMPATIBLE_LANGUAGE_VERSION || abi > ts.LANGUAGE_VERSION {
        fmt.eprintfln(
            "slopd: grammar %q ABI %d unsupported (need %d..%d) — reinstall it",
            name,
            abi,
            ts.MIN_COMPATIBLE_LANGUAGE_VERSION,
            ts.LANGUAGE_VERSION,
        )
        _ = dynlib.unload_library(lib)
        return {}
    }
    g := Loaded_Grammar {
        lib  = lib,
        lang = lang,
        ok   = true,
    }
    scm := grammar_query_path(dir, name, context.temp_allocator)
    if src := os.read_entire_file_from_path(scm, context.temp_allocator) or_else nil; src != nil {
        if q, _, err := ts.query_new(lang, string(src)); err == .None {
            g.query = q
        }
    }
    return g
}

// Maps a tree-sitter capture name to a theme colour slot, leniently: only the base
// (before the first '.') matters, so @function.builtin and @function share a slot.
// ok=false for names with no slot — those are drawn in the default foreground.
@(private = "file")
capture_color :: proc(th: ^Theme, name: string) -> (color: [3]f32, ok: bool) {
    base := name
    if dot := strings.index_byte(name, '.'); dot >= 0 {
        base = name[:dot]
    }
    switch base {
    case "keyword":
        return th.code_keyword, true
    case "string", "char", "escape":
        return th.code_string, true
    case "comment":
        return th.code_comment, true
    case "number", "float":
        return th.code_number, true
    case "operator":
        return th.code_operator, true
    case "type", "constructor":
        return th.code_type, true
    case "function", "method":
        return th.code_function, true
    case "variable", "property", "parameter", "field":
        return th.code_variable, true
    case "constant", "boolean":
        return th.code_constant, true
    case "punctuation", "bracket", "delimiter":
        return th.code_punctuation, true
    }
    return {}, false // unmapped (label, tag, attribute, namespace, …) -> foreground
}

// The rune column at or after the given byte offset within a line (tree-sitter points
// are byte offsets; the editor positions glyphs by rune). Clamps past the line end.
@(private = "file")
byte_to_rune_col :: proc(runes: []rune, byte_col: int) -> int {
    b := 0
    for r, i in runes {
        if b >= byte_col {
            return i
        }
        b += utf8.rune_size(r)
    }
    return len(runes)
}
