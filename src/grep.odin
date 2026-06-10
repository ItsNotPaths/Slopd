package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Project search + its results model. grep_run is the ONE canonical entry point: run grep
// with a forced, info-rich flag set and parse the output into structured GrepHits. Both
// consumers go through it, so the parse + shape is defined once:
//   - the Alt+Enter "jump to definition" (link.odin): grep_run narrows to every line that
//     mentions the symbol, then tree-sitter (ts_filter_definitions) keeps only the lines
//     that actually DEFINE it — not the invocations.
//   - a FUTURE Prawk-style CL `grep` interception: capture the user's `grep ...`, DISCARD
//     their flags, force ours (so the output is always uniform + maximally informative),
//     route the query through grep_run, and drop the hits straight into the GrepPane.
// Forcing the flags (rather than honouring the user's) is deliberate: a single parse path,
// always with filename + line, is what makes the output reusable downstream.

GrepHit :: struct {
    path:      string,   // absolute file path (owned)
    line:      int,      // 1-based line, matching the editor gutter / the `j` builtin
    col:       int,      // 0-based rune column of the match on that line (caret lands here)
    text:      string,   // the matched line, trimmed (owned) — the single-line fallback preview
    ctx:       []string, // raw (untrimmed) lines around the match, the pane's context block (owned)
    ctx_first: int,      // 1-based line number of ctx[0], so the match line is ctx[line - ctx_first]
}

// Lines of context shown above AND below each match in the results pane (a `grep -C`
// window). The match line itself sits in the middle of the block.
GREP_CONTEXT :: 2

// GrepPane — the results model the Grep aux mode renders + navigates (draw_grep,
// grep_key). Two producers stash into it: Alt+Enter's multi-result definition lookup
// (link.odin) and the CL `grep` interception (cl_grep). The pane lists query/hits, Up/Down
// move `selected`, and Enter opens that hit (grep_open_hit) in the editor.
GrepPane :: struct {
    query:    string,           // the symbol / pattern searched (owned)
    hits:     [dynamic]GrepHit, // results, in scan order
    selected: int,              // the highlighted row (Up/Down move it; Enter jumps)
}

// Up/Down: move the highlighted row, clamped to the results (no wrap). The editor only
// follows on Enter (grep_open_hit), so this is pure selection movement.
grep_move :: proc(g: ^GrepPane, dir: int) {
    if n := len(g.hits); n > 0 {
        g.selected = clamp(g.selected + dir, 0, n - 1)
    }
}

// Open a hit's file and place the caret on the match (reusing open_file + doc_reset_cursor,
// the `j` builtin's cursor reset). open_file focuses the editor. The single canonical jump,
// shared by the pane's Enter (grep_open_selected) and link.odin's single-definition goto.
grep_open_hit :: proc(a: ^App, h: GrepHit) {
    open_file(a, h.path)
    b := editor_current(&a.editor)
    target := clamp(h.line - 1, 0, len(b.lines) - 1)
    col := clamp(h.col, 0, line_len(&b.lines[target]))
    doc_reset_cursor(&b.doc, Pos{target, col})
}

// Enter in the pane: jump to the selected hit (no-op on an empty / out-of-range list).
grep_open_selected :: proc(a: ^App) {
    g := &a.grep
    if g.selected >= 0 && g.selected < len(g.hits) {
        grep_open_hit(a, g.hits[g.selected])
    }
}

// Run grep with FORCED flags and parse stdout into hits. -r recursive, -n line numbers,
// -H always-with-filename (so a single-file result parses the same as a tree), -I skip
// binaries, --exclude-dir=.git. `word` adds -w (whole-word — symbol lookup); `fixed` adds
// -F (literal pattern, not a regex). GNU grep emits no column, so we recover it on parse
// (first occurrence of the query on the line). Shelling out mirrors git_run: no shell, so
// the pattern + paths need no quoting, and `--` guards a pattern that begins with '-'.
// Returns temp-allocated hits ([] on no match or spawn error).
grep_run :: proc(root, query: string, word := false, fixed := false) -> []GrepHit {
    if root == "" || query == "" {
        return nil
    }
    argv := make([dynamic]string, 0, 8, context.temp_allocator)
    append(&argv, "grep", "-rnIH", "--exclude-dir=.git")
    if word {
        append(&argv, "-w")
    }
    if fixed {
        append(&argv, "-F")
    }
    append(&argv, "--", query, root)

    _, sout, _, err := os.process_exec(os.Process_Desc{command = argv[:]}, context.temp_allocator)
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

// Parse one `path:line:content` grep line. Splits on the first two colons only (a POSIX
// path has none; the content may have many). The column is the first occurrence of the
// query on the line, as a rune offset (best effort: 0 when it can't be located, e.g. a
// regex query). Temp-allocated strings.
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
        col = col,
        text = strings.clone(strings.trim_space(content), context.temp_allocator),
    }, true
}

// Replace the pane's contents, deep-cloning `hits` into the pane's own storage (callers
// pass temp-allocated scans). The previous set is freed first. Each hit's context block is
// read from disk here (grep_read_context), so the pane owns it independent of the scan; the
// file is re-read at most once per run of same-file hits (grep groups its output by file).
grep_set :: proc(g: ^GrepPane, query: string, hits: []GrepHit) {
    grep_clear(g)
    g.query = strings.clone(query)
    cur_path := ""
    cur_lines: []string // the current file split into lines (temp); reused across its hits
    for h in hits {
        if h.path != cur_path {
            cur_path = h.path
            cur_lines = grep_file_lines(h.path)
        }
        ctx, first := grep_read_context(cur_lines, h.line)
        append(
            &g.hits,
            GrepHit {
                path = strings.clone(h.path),
                line = h.line,
                col = h.col,
                text = strings.clone(h.text),
                ctx = ctx,
                ctx_first = first,
            },
        )
    }
    g.selected = 0
}

grep_clear :: proc(g: ^GrepPane) {
    delete(g.query)
    g.query = ""
    for h in g.hits {
        delete(h.path)
        delete(h.text)
        for c in h.ctx {
            delete(c)
        }
        delete(h.ctx)
    }
    clear(&g.hits)
    g.selected = 0
}

// Read a file and split it into lines (temp-allocated; the slices alias the file buffer).
// "" / unreadable yields nil, so a hit on a vanished file just shows its trimmed text.
@(private = "file")
grep_file_lines :: proc(path: string) -> []string {
    data, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return nil
    }
    return strings.split(string(data), "\n", context.temp_allocator)
}

// The owned context block around 1-based `line`: GREP_CONTEXT lines either side, clamped to
// the file, each cloned. Returns the block and the 1-based number of its first line. Empty
// (and ctx_first 0) when the file couldn't be read — the pane falls back to the match text.
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
    ctx = make([]string, hi - lo + 1)
    for i in lo ..= hi {
        ctx[i - lo] = strings.clone(lines[i - 1])
    }
    return ctx, lo
}

grep_destroy :: proc(g: ^GrepPane) {
    grep_clear(g)
    delete(g.hits)
}
