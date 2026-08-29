package search

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Project search and its results model. grep_run is the one entry point: grep with a forced,
// info-rich flag set, parsed into GrepHits. grep_project is how the app reaches it, since a
// search also carries the project root and the excluded directories. Both consumers go through
// it, so the parse and shape are defined once:
//   - Alt+Enter jump-to-definition: grep narrows to every line mentioning the symbol, then
//     tree-sitter keeps only the lines that DEFINE it.
//   - `:grep`: the user's flags are discarded, ours forced, the hits dropped into the pane.
// Forcing the flags gives a single parse path, always with filename and line.

GrepHit :: struct {
    path:      string,   // absolute (owned)
    line:      int,      // 1-based, matching the editor gutter and `:j`
    col:       int,      // 0-based rune column of the match; the caret lands here
    text:      string,   // the matched line, trimmed (owned): the single-line fallback
    ctx:       []string, // untrimmed lines around the match, the pane's block (owned)
    ctx_first: int,      // 1-based line of ctx[0], so the match is ctx[line - ctx_first]
}

// Above and below each match, `grep -C`-style, with the match line in the middle.
GREP_CONTEXT :: 2

// What the Grep aux mode renders and navigates. Two producers stash into it: Alt+Enter's
// multi-result definition lookup, and `:grep`.
GrepPane :: struct {
    query:    string,           // the symbol or pattern searched (owned)
    hits:     [dynamic]GrepHit, // in scan order

    // `:rep`: the text taking the query's place, already written into the rows this draws. The
    // flag and not an empty string, because deleting every hit is `:rep "x" ""`.
    replace:   string, // owned
    replacing: bool,

    selected: int,
    scroll:   int,              // first visible DISPLAY row: the viewport top
    hover:    int,              // the block under the pointer, or -1; transient

    // Wheel-detached at this glfw time; 0 = following the selection. See list_scroll_apply.
    scroll_detached: f64,
}

// Clamped, no wrap. The editor only follows on Enter, so this is pure selection movement.
grep_move :: proc(g: ^GrepPane, dir: int) {
    if n := len(g.hits); n > 0 {
        g.selected = clamp(g.selected + dir, 0, n - 1)
    }
}




// `-H` matters: a single-file result then parses the same as a tree. `word` adds -w, `fixed`
// adds -F. Execs grep directly, so pattern and paths need no quoting and `--` guards a
// leading '-'.
grep_run :: proc(root, query: string, exclude: []string = nil, word := false, fixed := false) -> []GrepHit {
    if root == "" || query == "" {
        return nil
    }
    argv := grep_argv(root, query, exclude, word, fixed)
    _, sout, _, err := os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
    if err != nil {
        return nil
    }
    hits := make([dynamic]GrepHit, 0, 32, context.temp_allocator)
    out := string(sout)
    for line in strings.split_lines_iterator(&out) {
        if h, ok := grep_parse(line, query); ok {
            append(&hits, h)
        }
    }
    return hits[:]
}

// Built rather than inlined, so the flags can be asserted without a grep on the machine. One
// `--exclude-dir` per configured pattern: grep's own syntax is the config line's syntax.
grep_argv :: proc(root, query: string, exclude: []string, word, fixed: bool, alloc := context.temp_allocator) -> []string {
    argv := make([dynamic]string, 0, 8 + len(exclude), alloc)
    append(&argv, "grep", "-rnIH")
    for p in exclude {
        append(&argv, fmt.tprintf("--exclude-dir=%s", p))
    }
    if word {
        append(&argv, "-w")
    }
    if fixed {
        append(&argv, "-F")
    }
    append(&argv, "--", query, root)
    return argv[:]
}

// Splitting on the first two colons only: a POSIX path has none, the content may have many. The
// column is the query's first occurrence as a rune offset, best effort. Temp-allocated.
@(private = "file")
grep_parse :: proc(raw, query: string) -> (GrepHit, bool) {
    c1 := strings.index_byte(raw, ':')
    if c1 < 0 {
        return {}, false
    }
    rest := raw[c1 + 1:]
    c2 := strings.index_byte(rest, ':')
    if c2 < 0 {
        return {}, false
    }
    lineno, ok := strconv.parse_int(rest[:c2], 10)
    if !ok {
        return {}, false
    }
    content := rest[c2 + 1:]
    col := 0
    if idx := strings.index(content, query); idx >= 0 {
        col = utf8.rune_count_in_string(content[:idx])
    }
    return GrepHit {
        path = strings.clone(raw[:c1], context.temp_allocator),
        line = lineno,
        col  = col,
        text = strings.clone(strings.trim_space(content), context.temp_allocator),
    }, true
}

// Deep-clones `hits`, since callers pass temp-allocated scans, and frees the previous set.
grep_set :: proc(g: ^GrepPane, query: string, hits: []GrepHit, replace := "", replacing := false) {
    grep_clear(g)
    g.query = strings.clone(query)
    g.replace = strings.clone(replace)
    g.replacing = replacing
    owned := grep_hits_clone(hits)
    append(&g.hits, ..owned)
    delete(owned)
    g.selected = 0
    g.scroll = 0
    g.hover = -1
}

// A deep copy, with the context block read from disk for any hit arriving without one — at most
// one file read per run of same-file hits. The worker clones this way on its own thread, so what
// reaches grep_set is whole and this second pass only copies.
grep_hits_clone :: proc(hits: []GrepHit, alloc := context.allocator) -> []GrepHit {
    out := make([]GrepHit, len(hits), alloc)
    cur_path := ""
    cur_lines: []string // the current file split into lines, reused across its hits
    for h, i in hits {
        ctx, first := h.ctx, h.ctx_first
        if len(ctx) == 0 {
            if h.path != cur_path {
                cur_path = h.path
                cur_lines = grep_file_lines(h.path)
            }
            ctx, first = grep_read_context(cur_lines, h.line)
        }
        out[i] = GrepHit {
            path      = strings.clone(h.path, alloc),
            line      = h.line,
            col       = h.col,
            text      = strings.clone(h.text, alloc),
            ctx       = grep_clone_lines(ctx, alloc),
            ctx_first = first,
        }
    }
    return out
}

// For a set the pane never took: the worker's answer, once it has been copied in or dropped.
grep_hits_destroy :: proc(hits: []GrepHit, alloc := context.allocator) {
    for h in hits {
        grep_hit_destroy(h, alloc)
    }
    delete(hits, alloc)
}

@(private = "file")
grep_hit_destroy :: proc(h: GrepHit, alloc := context.allocator) {
    delete(h.path, alloc)
    delete(h.text, alloc)
    for c in h.ctx {
        delete(c, alloc)
    }
    delete(h.ctx, alloc)
}

@(private = "file")
grep_clone_lines :: proc(lines: []string, alloc: runtime.Allocator) -> []string {
    if len(lines) == 0 {
        return nil
    }
    out := make([]string, len(lines), alloc)
    for l, i in lines {
        out[i] = strings.clone(l, alloc)
    }
    return out
}

grep_clear :: proc(g: ^GrepPane) {
    delete(g.query)
    g.query = ""
    delete(g.replace)
    g.replace = ""
    g.replacing = false
    for h in g.hits {
        grep_hit_destroy(h)
    }
    clear(&g.hits)
    g.selected = 0
    g.scroll = 0
    g.hover = -1
}

// Temp-allocated; the slices alias the file buffer. Unreadable yields nil, so a hit on a
// vanished file shows its trimmed text.
@(private = "file")
grep_file_lines :: proc(path: string) -> []string {
    data, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return nil
    }
    return strings.split(string(data), "\n", context.temp_allocator)
}

// GREP_CONTEXT lines either side of 1-based `line`, clamped to the file, with the 1-based
// number of the first. Borrows `lines`; the caller clones. Empty when the file could not be
// read, and the pane falls back.
@(private = "file")
grep_read_context :: proc(lines: []string, line: int) -> (ctx: []string, first: int) {
    if len(lines) == 0 {
        return nil, 0
    }
    lo := max(1, line - GREP_CONTEXT)
    hi := min(len(lines), line + GREP_CONTEXT)
    if hi < lo {
        return nil, 0
    }
    return lines[lo - 1:hi], lo
}

grep_destroy :: proc(g: ^GrepPane) {
    grep_clear(g)
    delete(g.hits)
}

// --- display rows --- Each hit renders as a context block, so one hit is several display rows
// and the viewport, policy and hit test all count rows. No colour or selected flag: colour is
// derived, and selectedness changes mid-frame on a click.

GrepRow :: struct {
    hit:    int, // index into g.hits; -1 for the blank spacer
    gutter: string, // the context line's number; "" for a header or spacer
    text:   string,
    match:  bool, // the matched line; an accent rail when its block is selected
    header: bool, // the block's "path:line" title, drawn flush-left
}

// Title, context block (or the trimmed match text when the file could not be re-read), blank
// spacer. Strings borrow the pane's storage, bar the titles and line numbers, formatted into
// `alloc`.
grep_rows :: proc(g: ^GrepPane, root: string, alloc := context.allocator) -> []GrepRow {
    rows := make([dynamic]GrepRow, 0, len(g.hits) * (2 * GREP_CONTEXT + 3), alloc)
    for h, hi in g.hits {
        loc := fmt.aprintf("%s:%d", grep_relpath(h.path, root), h.line, allocator = alloc)
        append(&rows, GrepRow{hit = hi, text = loc, header = true})
        if len(h.ctx) == 0 {
            append(&rows, GrepRow{hit = hi, text = grep_row_text(g, h.text, alloc), match = true})
        } else {
            for c, k in h.ctx {
                ln := h.ctx_first + k
                append(
                    &rows,
                    GrepRow {
                        hit    = hi,
                        gutter = fmt.aprintf("%d", ln, allocator = alloc),
                        text   = grep_row_text(g, c, alloc),
                        match  = ln == h.line,
                    },
                )
            }
        }
        append(&rows, GrepRow{hit = -1}) // blank spacer
    }
    return rows[:]
}

// Under `:rep`, what the line WILL say. Every row and not only the matched one: a context line
// can hold the query too, and the same line must not read two ways in two blocks. Borrows the
// pane's storage when nothing changes.
@(private = "file")
grep_row_text :: proc(g: ^GrepPane, src: string, alloc: runtime.Allocator) -> string {
    if !g.replacing || g.query == "" {
        return src
    }
    out, _ := strings.replace_all(src, g.query, g.replace, alloc)
    return out
}

// The pane's title. A `:rep` names both halves, since the rows below already show the new one.
grep_head :: proc(g: ^GrepPane, alloc := context.temp_allocator) -> string {
    if g.query == "" {
        return "grep"
    }
    if g.replacing {
        return fmt.aprintf("rep: %s → %s   (%d)", g.query, g.replace, len(g.hits), allocator = alloc)
    }
    return fmt.aprintf("grep: %s   (%d)", g.query, len(g.hits), allocator = alloc)
}

// How many distinct files the hits fall in. They arrive grouped by file, so one pass counting
// the changes of path is exact.
grep_file_count :: proc(g: ^GrepPane) -> (n: int) {
    prev := ""
    for h, i in g.hits {
        if i == 0 || h.path != prev {
            n += 1
        }
        prev = h.path
    }
    return
}

// Its title. The policy frames this as the editor frames its caret line, so a block scrolls in
// by its top rather than by whichever row is nearest.
grep_anchor :: proc(rows: []GrepRow, sel: int) -> int {
    for r, i in rows {
        if r.header && r.hit == sel {
            return i
        }
    }
    return 0
}

// Measured from the rows that will actually be drawn, where estimating from
// `max(h.line) + GREP_CONTEXT` over-reserves for a match near end-of-file.
grep_gutter_w :: proc(rows: []GrepRow) -> int {
    w := 1
    for r in rows {
        w = max(w, len(r.gutter))
    }
    return w
}

// "/root/proj/src/x.odin" -> "src/x.odin", falling back to the full path when it is not under
// the root. Borrows `path`'s storage.
grep_relpath :: proc(path, root: string) -> string {
    if root != "" && strings.has_prefix(path, root) {
        rel := path[len(root):]
        return strings.has_prefix(rel, "/") ? rel[1:] : rel
    }
    return path
}
