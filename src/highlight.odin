package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:text/regex"
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
// `preds` holds each query pattern's predicates, parsed (and any regexes compiled)
// once at load so the per-frame paint can filter captures without re-parsing.
Loaded_Grammar :: struct {
    lib:   dynlib.Library,
    lang:  ts.Language,
    query: ts.Query,
    preds: [][]Predicate, // indexed by pattern index; owned
    ok:    bool,
}

// A parsed query predicate, e.g. (#lua-match? @type "^[A-Z]..."), (#any-of? @x "a" "b"),
// (#not-has-parent? @t parameter call_expression). tree-sitter returns captures WITHOUT
// evaluating these, so the highlighter must — otherwise a gated capture (capitalised ->
// @type, ALL_CAPS -> @constant, context/self -> @variable.builtin) fires on every
// identifier and the real colour is lost. Filters whose op we don't model fail OPEN (the
// capture is kept), so an unsupported predicate never blanks a token.
@(private = "file")
Predicate :: struct {
    op:     Pred_Op,
    negate: bool, // a "not-" prefix
    cap:    u32, // the capture id this predicate constrains
    cap2:   i32, // a second capture id (e.g. (#eq? @a @b)); -1 when the arg is a string
    strs:   []string, // string args (owned)
    re:     regex.Regular_Expression, // compiled for Match; valid iff has_re
    has_re: bool,
}

@(private = "file")
Pred_Op :: enum {
    Unknown, // directive (#set! …) or an op we don't model -> not a filter
    Eq, // #eq?       capture text equals a string / another capture's text
    AnyOf, // #any-of?   capture text is one of the strings
    Match, // #match? / #lua-match?  capture text matches the (regex) pattern
    HasParent, // #has-parent?  capture has an ancestor of one of the named node types
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
    tree_src: string, // the exact text the tree was parsed from; node byte offsets index
    // it (predicate evaluation reads through it). Heap-owned, replaced on reparse.
    // Painted-row cache: highlight_visible repaints the same window every frame (idle
    // caret blink, a non-editor animation), redoing the query + sort + per-rune fill
    // for an identical result. Memoize the last painted rows keyed by what they depend
    // on — buffer, content version, window, and theme (colours bake in) — and reuse on a
    // match. Heap-owned so it survives the per-frame temp free_all; rebuilt on any change.
    cache_rows: []Row_Colors,
    cache_buf: rawptr,
    cache_ver: u64,
    cache_first: int,
    cache_count: int,
    cache_theme: Theme,
}

highlighter_init :: proc(h: ^Highlighter) {
    h.parser = ts.parser_new()
    h.cursor = ts.query_cursor_new()
    h.loaded = make(map[string]Loaded_Grammar)
}

highlighter_destroy :: proc(h: ^Highlighter) {
    for _, g in h.loaded {
        for preds in g.preds {
            for p in preds {
                for s in p.strs {
                    delete(s)
                }
                delete(p.strs)
                if p.has_re {
                    regex.destroy(p.re)
                }
            }
            delete(preds)
        }
        delete(g.preds)
        if g.query != nil {
            ts.query_delete(g.query)
        }
        if g.lib != nil {
            _ = dynlib.unload_library(g.lib)
        }
    }
    delete(h.loaded)
    hl_cache_free(h)
    if h.tree != nil {
        ts.tree_delete(h.tree)
        delete(h.tree_src)
    }
    ts.query_cursor_delete(h.cursor)
    ts.parser_delete(h.parser)
}

// Loads grammar `name` from an explicit `dir` and seeds it into the highlighter's
// grammar cache under `name` — the same slot highlighter_grammar fills lazily from
// the exe-relative grammars dir. Lets a caller resolve a grammar from a non-standard
// location (a test fixture, a preview) so a later highlight_visible finds it cached
// and skips the disk/registry lookup. ok mirrors the load.
highlighter_preload :: proc(h: ^Highlighter, dir, name: string) -> bool {
    g := load_grammar(dir, name)
    h.loaded[name] = g
    return g.ok
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
    // Heap-owned (not temp): kept past this frame so predicate evaluation can read node
    // text without rebuilding the whole-buffer string each cache-miss frame (a scroll).
    text := doc_string(&b.doc, context.allocator)
    tree := ts.parser_parse_string(h.parser, text)
    if tree == nil {
        delete(text)
        return nil
    }
    if h.tree != nil {
        ts.tree_delete(h.tree)
        delete(h.tree_src)
    }
    h.tree, h.tree_buf, h.tree_ver, h.tree_src = tree, rawptr(b), b.version, text
    return tree
}

// A captured node's span + the colour it paints. Hoisted to file scope so the sort
// comparator can name it.
@(private = "file")
Capture_Span :: struct {
    start, end: ts.Point, // tree-sitter points: row = line, col = BYTE offset in line
    size:       u32, // byte length, for "most specific (smallest) wins" ordering
    pattern:    u16, // query pattern index; lowest wins on an identical-span tie
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

    // Cache hit: same buffer, content version, window, and theme as the last paint — the
    // rows are identical, so skip the query + sort + fill entirely (a settled view, an
    // idle blink, or any animation that doesn't move this viewport lands here).
    if h.cache_rows != nil &&
       h.cache_buf == rawptr(b) &&
       h.cache_ver == b.version &&
       h.cache_first == first_line &&
       h.cache_count == count &&
       h.cache_theme == th^ {
        return h.cache_rows
    }

    // The whole-buffer parse is cached (tree-sitter needs the full text); we only
    // query the visible rows, so the per-frame work is bounded by the viewport and a
    // settled view (blinking caret, smooth scroll) reuses the tree without reparsing.
    tree := highlighter_tree(h, b, g.lang)
    if tree == nil {
        return nil
    }

    // The exact text the tree was parsed from (cached alongside it) — node byte offsets
    // index into it, so predicate evaluation (capture text, #lua-match?, …) reads it.
    source := h.tree_src

    last := min(first_line + count, len(b.lines))
    ts.query_cursor_set_point_range(h.cursor, {u32(first_line), 0}, {u32(last), 0})
    ts.query_cursor_exec(h.cursor, g.query, ts.tree_root_node(tree))

    // Collect the visible captures, then paint largest-span-first so a more specific
    // (smaller) capture overrides the broader one it nests inside. Captures whose
    // pattern has predicates that don't hold are dropped (tree-sitter doesn't filter
    // them); otherwise gated rules like capitalised->@type fire on every identifier.
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
        if !predicates_ok(g, u32(match.pattern_index), match, source) {
            continue
        }
        append(
            &spans,
            Capture_Span {
                start = ts.node_start_point(qc.node),
                end = ts.node_end_point(qc.node),
                size = ts.node_end_byte(qc.node) - ts.node_start_byte(qc.node),
                pattern = match.pattern_index,
                color = color,
            },
        )
    }
    // Largest span first so a smaller (more specific) capture paints over it. Ties
    // break by start position, then by query pattern index, giving a TOTAL order so
    // the painted result never depends on the (unstable) sort's input order. The
    // missing pattern tiebreak was a flicker bug: when one node is captured by two
    // patterns of different colours (same span — equal size, start row & col), the
    // pair sorted arbitrarily, and the last-painted winner flipped each frame as the
    // capture emission order shifted with the scrolling point range. highlights.scm
    // follows the later-pattern-overrides-earlier convention (general rules first,
    // specific ones last), so the HIGHEST pattern index wins — it must sort last to
    // paint last.
    slice.sort_by(spans[:], proc(x, y: Capture_Span) -> bool {
        if x.size != y.size {
            return x.size > y.size
        }
        if x.start.row != y.start.row {
            return x.start.row < y.start.row
        }
        if x.start.col != y.start.col {
            return x.start.col < y.start.col
        }
        return x.pattern < y.pattern
    })

    // A colour row per visible line, defaulting to the foreground. Heap-allocated (not
    // temp) so it can be cached across frames — freed when the cache is next replaced.
    rows := make([]Row_Colors, count)
    for k in 0 ..< count {
        line := first_line + k
        if line >= len(b.lines) {
            continue
        }
        rc := make(Row_Colors, len(b.lines[line].text))
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

    // Replace the cache with this paint so the next identical frame reuses it.
    hl_cache_free(h)
    h.cache_rows = rows
    h.cache_buf = rawptr(b)
    h.cache_ver = b.version
    h.cache_first = first_line
    h.cache_count = count
    h.cache_theme = th^
    return rows
}

// Debug: print every capture the query emits over [first_line, first_line+count),
// with its query pattern index, name, span, the theme slot it maps to, and whether
// its pattern's predicates hold. Lets a test see which patterns compete for a node and
// how precedence/filtering resolves them. Not part of the draw path.
highlight_dump_captures :: proc(a: ^App, b: ^Buffer, first_line, count: int) {
    g, ok := highlighter_grammar(a, b.path)
    if !ok || g.query == nil {
        fmt.println("no grammar/query")
        return
    }
    h := &a.hl
    tree := highlighter_tree(h, b, g.lang)
    if tree == nil {
        fmt.println("no tree")
        return
    }
    source := h.tree_src
    last := min(first_line + count, len(b.lines))
    ts.query_cursor_set_point_range(h.cursor, {u32(first_line), 0}, {u32(last), 0})
    ts.query_cursor_exec(h.cursor, g.query, ts.tree_root_node(tree))
    for {
        match, ci, more := ts.query_cursor_next_capture(h.cursor)
        if !more {
            break
        }
        qc := match.captures[ci]
        name := ts.query_capture_name_for_id(g.query, qc.index)
        sp := ts.node_start_point(qc.node)
        ep := ts.node_end_point(qc.node)
        _, mapped := capture_color(&a.theme, name)
        fmt.printfln(
            "pat=%-3d %-22s [%d:%d-%d:%d] %s pred=%v",
            match.pattern_index,
            name,
            sp.row,
            sp.col,
            ep.row,
            ep.col,
            mapped ? "MAPPED  " : "unmapped",
            predicates_ok(g, u32(match.pattern_index), match, source),
        )
    }
}

// Frees the heap-owned painted-row cache (each row slice, then the row array).
@(private = "file")
hl_cache_free :: proc(h: ^Highlighter) {
    for rc in h.cache_rows {
        delete(rc)
    }
    delete(h.cache_rows)
    h.cache_rows = nil
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

// Is the rune at (line, col) inside a string, character or comment node? Auto-indent
// (buffer.odin) consults this so an opener bracket sitting inside a string or comment —
// `x := "{"`, `// open {` — doesn't trigger an extra indent level. Returns false when no
// grammar is loaded for the buffer, so the caller falls back to the pure bracket heuristic.
ts_in_string_or_comment :: proc(a: ^App, b: ^Buffer, line, col: int) -> bool {
    g, found := highlighter_grammar(a, b.path)
    if !found {
        return false
    }
    tree := highlighter_tree(&a.hl, b, g.lang)
    if tree == nil {
        return false
    }
    bcol := rune_col_to_byte(b.lines[line].text[:], col)
    pt := ts.Point{u32(line), u32(bcol)}
    node := ts.node_descendant_for_range(ts.tree_root_node(tree), pt, pt)
    for !ts.node_is_null(node) {
        t := string(ts.node_type(node))
        if strings.contains(t, "string") || strings.contains(t, "comment") || strings.contains(t, "char") {
            return true
        }
        node = ts.node_parent(node)
    }
    return false
}

// Byte offset of rune column `col` within a line's runes (the inverse of byte_to_rune_col).
@(private = "file")
rune_col_to_byte :: proc(runes: []rune, col: int) -> int {
    b := 0
    for i in 0 ..< min(col, len(runes)) {
        b += utf8.rune_size(runes[i])
    }
    return b
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
            g.preds = build_predicates(q)
        }
    }
    return g
}

// Parses every pattern's predicates from the compiled query once, compiling Match
// patterns to regexes up front. Owned by the grammar; freed in highlighter_destroy.
@(private = "file")
build_predicates :: proc(query: ts.Query) -> [][]Predicate {
    n := ts.query_pattern_count(query)
    out := make([][]Predicate, n)
    for p in 0 ..< n {
        steps := ts.query_predicates_for_pattern(query, p)
        preds := make([dynamic]Predicate, 0, 2)
        lo := 0
        for hi in 0 ..< len(steps) {
            if steps[hi].type != .Done {
                continue
            }
            if pred, ok := parse_predicate(query, steps[lo:hi]); ok {
                append(&preds, pred)
            }
            lo = hi + 1
        }
        out[p] = preds[:]
    }
    return out
}

// Builds one Predicate from its step slice (the op name, then capture/string args).
@(private = "file")
parse_predicate :: proc(query: ts.Query, steps: []ts.Query_Predicate_Step) -> (Predicate, bool) {
    if len(steps) == 0 || steps[0].type != .String {
        return {}, false
    }
    name := ts.query_string_value_for_id(query, steps[0].value_id)
    pred := Predicate {
        cap  = max(u32),
        cap2 = -1,
    }
    // Trailing '?' marks a filter predicate; '!' (or neither) is a directive we ignore.
    // A "not-" prefix negates the test.
    if !strings.has_suffix(name, "?") {
        return {}, false
    }
    base := name[:len(name) - 1]
    if strings.has_prefix(base, "not-") {
        pred.negate = true
        base = base[4:]
    }
    switch base {
    case "eq":
        pred.op = .Eq
    case "any-of":
        pred.op = .AnyOf
    case "match", "lua-match":
        pred.op = .Match
    case "has-parent":
        pred.op = .HasParent
    case:
        pred.op = .Unknown
    }
    strs := make([dynamic]string, 0, 2)
    for s in steps[1:] {
        #partial switch s.type {
        case .Capture:
            if pred.cap == max(u32) {
                pred.cap = s.value_id
            } else {
                pred.cap2 = i32(s.value_id)
            }
        case .String:
            append(&strs, strings.clone(ts.query_string_value_for_id(query, s.value_id)))
        }
    }
    pred.strs = strs[:]
    if pred.op == .Match && len(pred.strs) > 0 {
        // Lua patterns and regex share the anchored char-class subset highlights use;
        // a pattern the engine can't compile fails open (has_re stays false).
        if re, err := regex.create(pred.strs[0]); err == nil {
            pred.re, pred.has_re = re, true
        }
    }
    return pred, true
}

// Do pattern `pi`'s predicates all pass for `match` (so its captures should paint)?
// Unmodelled ops and uncompilable regexes count as passing — we never hide a token on
// a predicate we can't evaluate.
@(private = "file")
predicates_ok :: proc(g: Loaded_Grammar, pi: u32, match: ts.Query_Match, source: string) -> bool {
    if int(pi) >= len(g.preds) {
        return true
    }
    for p in g.preds[pi] {
        node, found := capture_node(match, p.cap)
        if !found {
            continue
        }
        txt := ts.node_text(node, source)
        res: bool
        switch p.op {
        case .Unknown:
            continue
        case .Eq:
            if p.cap2 >= 0 {
                other := capture_node(match, u32(p.cap2)) or_continue
                res = txt == ts.node_text(other, source)
            } else if len(p.strs) > 0 {
                res = txt == p.strs[0]
            }
        case .AnyOf:
            res = slice.contains(p.strs, txt)
        case .Match:
            if !p.has_re {
                continue // couldn't compile -> don't filter
            }
            _, matched := regex.match(p.re, txt)
            res = matched
        case .HasParent:
            res = node_has_parent_type(node, p.strs)
        }
        if p.negate {
            res = !res
        }
        if !res {
            return false
        }
    }
    return true
}

// The node captured under id `cap` within a match, if any.
@(private = "file")
capture_node :: proc(match: ts.Query_Match, cap: u32) -> (ts.Node, bool) {
    for i in 0 ..< int(match.capture_count) {
        if match.captures[i].index == cap {
            return match.captures[i].node, true
        }
    }
    return {}, false
}

// Does `node` have an ancestor whose type is one of `types`? (#has-parent? semantics.)
@(private = "file")
node_has_parent_type :: proc(node: ts.Node, types: []string) -> bool {
    p := ts.node_parent(node)
    for !ts.node_is_null(p) {
        if slice.contains(types, string(ts.node_type(p))) {
            return true
        }
        p = ts.node_parent(p)
    }
    return false
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

// --- definition filtering (link jumping) ---
//
// Given grep hits for a symbol (grep.odin) — every line that mentions it, uses included —
// keep only the lines that DEFINE it, decided by tree-sitter. For each hit we parse its
// file (once per file; grep groups its output by file) and inspect every whole-word
// occurrence of the symbol on the hit's line: an occurrence is a definition when its
// identifier node is its construct's `name:` or `declarator:` field. That is the cross-
// grammar shape of a declaration's name (function / method / class / type / variable),
// while a call's callee sits under `function:`/`callee:` and a bare reference under no
// field — so invocations and uses fall away. Files whose language has no installed grammar
// are dropped (we can't verify a definition there).

// Node types that NAME-bearing definitions live in, matched as substrings so one list
// spans many grammars: function_definition / function_declaration / function_item,
// method_definition, class_declaration, struct_specifier, type_alias, variable_declarator,
// init_declarator, *_spec (Go), etc.
@(private = "file")
DEF_TYPE_SUBSTR :: [?]string {
    "function",
    "method",
    "constructor",
    "class",
    "struct",
    "enum",
    "union",
    "interface",
    "trait",
    "namespace",
    "module",
    "macro",
    "declaration",
    "declarator",
    "definition",
    "_item",
    "_spec",
    "binding",
}

// Filter grep `hits` for `query` down to the subset that are DEFINITIONS, with each kept
// hit's column moved onto the defining name. Temp-allocated, deduped by (path, line).
ts_filter_definitions :: proc(a: ^App, query: string, hits: []GrepHit) -> []GrepHit {
    h := &a.hl
    out := make([dynamic]GrepHit, 0, len(hits), context.temp_allocator)

    // Cache the currently-parsed file across consecutive same-file hits (grep emits its
    // results grouped by file, so this parses each candidate file at most once).
    cur_path := ""
    cur_src := ""
    cur_starts: []int
    cur_tree: ts.Tree
    defer if cur_tree != nil {ts.tree_delete(cur_tree)}

    for hit in hits {
        if hit.path != cur_path {
            if cur_tree != nil {
                ts.tree_delete(cur_tree)
                cur_tree = nil
            }
            cur_path, cur_src = hit.path, ""
            g, ok := highlighter_grammar(a, hit.path)
            if !ok {
                continue // no installed grammar for this file — can't verify a def
            }
            src, rerr := os.read_entire_file_from_path(hit.path, context.temp_allocator)
            if rerr != nil || !ts.parser_set_language(h.parser, g.lang) {
                continue
            }
            cur_src = string(src)
            cur_starts = line_byte_starts(cur_src)
            cur_tree = ts.parser_parse_string(h.parser, cur_src)
        }
        if cur_tree == nil {
            continue
        }
        if col, ok := ts_def_col_on_line(cur_tree, cur_src, cur_starts, hit.line - 1, query); ok {
            append(&out, GrepHit{path = hit.path, line = hit.line, col = col, text = hit.text})
        }
    }
    return dedup_hits(out[:])
}

// The rune column of the first DEFINING occurrence of `ident` on row `row`, or ok=false if
// none on that line defines it. Walks each whole-word occurrence, point-queries the node
// there, and tests it with ts_point_is_def.
@(private = "file")
ts_def_col_on_line :: proc(tree: ts.Tree, source: string, starts: []int, row: int, ident: string) -> (int, bool) {
    if row < 0 || row >= len(starts) {
        return 0, false
    }
    lo := starts[row]
    hi := row + 1 < len(starts) ? starts[row + 1] : len(source)
    line := source[lo:hi]
    root := ts.tree_root_node(tree)
    off := 0
    for {
        idx := strings.index(line[off:], ident)
        if idx < 0 {
            break
        }
        at := off + idx
        before_ok := at == 0 || !is_ident_byte(line[at - 1])
        after := at + len(ident)
        after_ok := after >= len(line) || !is_ident_byte(line[after])
        if before_ok && after_ok {
            pt := ts.Point{u32(row), u32(at)}
            node := ts.node_named_descendant_for_point_range(root, pt, pt)
            if ts_point_is_def(node, source, ident) {
                return utf8.rune_count_in_string(line[:at]), true
            }
        }
        off = at + len(ident)
        if off >= len(line) {
            break
        }
    }
    return 0, false
}

// Is `node` (the identifier at a match) the NAME of a definition rather than a use? True
// when its construct exposes it via `name:` or a `declarator:` chain. Checks the parent,
// then the grandparent (the name can nest one level, e.g. C's function_declarator under
// function_definition).
@(private = "file")
ts_point_is_def :: proc(node: ts.Node, source, ident: string) -> bool {
    if ts.node_is_null(node) || ts.node_text(node, source) != ident {
        return false
    }
    p := ts.node_parent(node)
    if ts.node_is_null(p) {
        return false
    }
    if ts_is_def_construct(p) && ts_field_names_node(p, node, source) {
        return true
    }
    gp := ts.node_parent(p)
    return !ts.node_is_null(gp) && ts_is_def_construct(gp) && ts_field_names_node(gp, node, source)
}

// Does construct `c` point at `node` as its definition name — directly via `name:` or down
// its `declarator:` chain (the C-family shape: function_declarator -> identifier)?
@(private = "file")
ts_field_names_node :: proc(c, node: ts.Node, source: string) -> bool {
    name := ts.node_child_by_field_name(c, "name")
    if !ts.node_is_null(name) && ts.node_eq(name, node) {
        return true
    }
    leaf := ts_declarator_leaf(ts.node_child_by_field_name(c, "declarator"))
    return !ts.node_is_null(leaf) && ts.node_eq(leaf, node)
}

// Follow a `declarator:` field down to its leaf identifier (C declares a function name as
// function_definition -> function_declarator -> identifier). Bounded so a cyclic/odd tree
// can't loop.
@(private = "file")
ts_declarator_leaf :: proc(node: ts.Node) -> ts.Node {
    cur := node
    for _ in 0 ..< 8 {
        if ts.node_is_null(cur) {
            return cur
        }
        switch string(ts.node_type(cur)) {
        case "identifier", "type_identifier", "field_identifier":
            return cur
        }
        cur = ts.node_child_by_field_name(cur, "declarator")
    }
    return ts.Node{}
}

@(private = "file")
ts_is_def_construct :: proc(node: ts.Node) -> bool {
    t := string(ts.node_type(node))
    for s in DEF_TYPE_SUBSTR {
        if strings.contains(t, s) {
            return true
        }
    }
    return false
}

// Byte offset of each line's start in `source` (so a tree-sitter point row maps to bytes).
@(private = "file")
line_byte_starts :: proc(source: string) -> []int {
    starts := make([dynamic]int, 0, 256, context.temp_allocator)
    append(&starts, 0)
    for i in 0 ..< len(source) {
        if source[i] == '\n' {
            append(&starts, i + 1)
        }
    }
    return starts[:]
}

@(private = "file")
is_ident_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// Drop hits that repeat a (path, line) — one definition can be reached by more than one
// occurrence on its line, or by both a construct and its nested declarator.
@(private = "file")
dedup_hits :: proc(hits: []GrepHit) -> []GrepHit {
    out := make([dynamic]GrepHit, 0, len(hits), context.temp_allocator)
    for h in hits {
        dup := false
        for e in out {
            if e.line == h.line && e.path == h.path {
                dup = true
                break
            }
        }
        if !dup {
            append(&out, h)
        }
    }
    return out[:]
}
