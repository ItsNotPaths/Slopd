package main

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The workspace jump list. Alt+P turns the file pane's top bar into a `WORKSPACE/` prompt: with
// nothing typed the list under it is the unsaved ring, and the first keystroke replaces that
// with a fuzzy filter over every file under the project root.
//
// The listing it covers is untouched — no navigation, no selection moved, no directory read —
// which is what makes this a prompt rather than a mode. One model, drawn by both faces of the
// pane. Host-independent as filetree.odin is, bar two seams: the ring lives in the editor, and
// opening a row is the editor's open_file.

// In cells, not pixels: the field starts after it under both faces.
WS_PROMPT :: "WORKSPACE/"

// Directories it may open, files it may remember, and the longest list a filter shows. A tree
// big enough to hit these is one where the answer arrives after you have typed the whole name.
WS_DIR_BUDGET :: 4096
WS_FILE_MAX :: 20000
WS_ROWS_MAX :: 200

// Where it goes, and whether it is open with unsaved changes.
WS_Row :: struct {
    path:  string, // absolute (owned)
    dirty: bool,
}

WS_Find :: struct {
    open:  bool,
    query: Doc,
    off:   int, // the typed line's window, the shared field's

    // The rows follow the typed line on a version compare (cl_preview.odin's trick): one test a
    // frame catches every kind of edit, so no edit path has to remember to rebuild.
    ver:   u64,

    // Every file under `root`, absolute and owned. `root` is what the scan WALKED, not
    // a.project_root: reading the live root would relabel a list it no longer describes.
    root:  string,
    files: [dynamic]string,

    rows:  [dynamic]WS_Row, // what is listed right now (owned paths)

    selected:        int,
    scroll:          int,
    hover:           int, // the row under the pointer, or -1; transient frame state
    scroll_detached: f64,
    scroll_anim:     Anim,
}

// The path bar is -1 and a config row is its own index, so a capture cannot be mistaken.
FIELD_WSFIND :: -2

wsfind_init :: proc(ws: ^WS_Find) {
    ws.hover = -1
    doc_init(&ws.query)
}

wsfind_destroy :: proc(ws: ^WS_Find) {
    doc_destroy(&ws.query)
    wsfind_files_clear(ws)
    delete(ws.files)
    wsfind_rows_clear(ws)
    delete(ws.rows)
    delete(ws.root)
}

@(private = "file")
wsfind_files_clear :: proc(ws: ^WS_Find) {
    for p in ws.files {
        delete(p)
    }
    clear(&ws.files)
}

@(private = "file")
wsfind_rows_clear :: proc(ws: ^WS_Find) {
    for r in ws.rows {
        delete(r.path)
    }
    clear(&ws.rows)
}

// It belongs to the file pane, so another aux mode hides it and leaves it open.
wsfind_shown :: proc(a: ^App) -> bool {
    return a.wsfind.open && a.aux_mode == .FileTree
}

// …and whether it owns the keyboard. filebrowser_path_live's twin.
wsfind_live :: proc(a: ^App) -> bool {
    return wsfind_shown(a) && a.focus == .Aux
}

// The tree is re-scanned here rather than cached across opens: a project changes under you, and
// this is an explicit gesture.
wsfind_open :: proc(a: ^App) {
    set_aux(a, .FileTree) // focuses the aux pane
    filebrowser_path_cancel(a) // one line at a time in that bar
    ws := &a.wsfind
    ws.open = true
    doc_set_text(&ws.query, "")
    ws.off = 0
    wsfind_scan(ws, a.project_root, exclude_dirs(a))
    wsfind_build(a)
}

// Esc, and every path that opens a row. The rows go with it: they are clones, and nothing will
// read them again.
wsfind_close :: proc(a: ^App) {
    ws := &a.wsfind
    ws.open = false
    wsfind_rows_clear(ws)
    ws.selected, ws.scroll, ws.hover = 0, 0, -1
    ws.scroll_detached = 0
}

// Called by whichever face is up, before it declares. The rows follow the typed line and, while
// nothing is typed, the ring: a save under an open prompt drops a row with no version bumped to
// say so. A count is enough, since those rows ARE the dirty buffers.
wsfind_sync :: proc(a: ^App) {
    ws := &a.wsfind
    if !ws.open {
        return
    }
    if ws.query.version != ws.ver || (!wsfind_typed(ws) && len(ws.rows) != wsfind_ring_count(a)) {
        wsfind_build(a)
    }
}

// Unsaved, and with a file to go back to.
@(private = "file")
wsfind_ring_count :: proc(a: ^App) -> (n: int) {
    for &b in a.editor.buffers {
        if b.dirty && buffer_on_disk(&b) {
            n += 1
        }
    }
    return
}

wsfind_move :: proc(ws: ^WS_Find, delta: int) {
    if n := len(ws.rows); n > 0 {
        ws.selected = clamp(ws.selected + delta, 0, n - 1)
    }
}

wsfind_selected :: proc(ws: ^WS_Find) -> (WS_Row, bool) {
    if ws.selected < 0 || ws.selected >= len(ws.rows) {
        return {}, false
    }
    return ws.rows[ws.selected], true
}

// The path is copied out first: closing frees the row it came from.
wsfind_activate :: proc(a: ^App) {
    row, ok := wsfind_selected(&a.wsfind)
    if !ok {
        return
    }
    path := strings.clone(row.path, context.temp_allocator)
    wsfind_close(a)
    open_file(a, path) // focuses the editor, as every other open does
}

// --- the rows ---

// Trimmed. Which of the two lists the prompt is showing, asked in one place.
wsfind_query :: proc(ws: ^WS_Find) -> string {
    return strings.trim_space(doc_string(&ws.query, context.temp_allocator))
}

wsfind_typed :: proc(ws: ^WS_Find) -> bool {
    return wsfind_query(ws) != ""
}

// The unsaved ring while the line is empty, the fuzzy filter once it is not. The selection goes
// back to the top: a new list has a new best answer.
wsfind_build :: proc(a: ^App) {
    ws := &a.wsfind
    ws.ver = ws.query.version
    wsfind_rows_clear(ws)
    q := wsfind_query(ws)
    if q == "" {
        // Only buffers with a file to go back to: a dirty scratch buffer has no location.
        for &b in a.editor.buffers {
            if b.dirty && buffer_on_disk(&b) {
                append(&ws.rows, WS_Row{strings.clone(b.path), true})
            }
        }
    } else {
        wsfind_rank(a, q)
    }
    ws.selected, ws.scroll = 0, 0
    ws.scroll_detached = 0
}

@(private = "file")
WS_Hit :: struct {
    path:  string, // borrowed from ws.files
    score: int,
}

// Keeps the best WS_ROWS_MAX. The match runs over the RELATIVE path: the root's own directories
// are in every candidate, so scoring them would rank on the part they all share.
@(private = "file")
wsfind_rank :: proc(a: ^App, q: string) {
    ws := &a.wsfind
    hits := make([dynamic]WS_Hit, 0, 64, context.temp_allocator)
    for p in ws.files {
        if s, ok := wsfind_score(wsfind_rel(ws.root, p), q); ok {
            append(&hits, WS_Hit{p, s})
        }
    }
    slice.sort_by(hits[:], wsfind_better)
    for h in hits[:min(len(hits), WS_ROWS_MAX)] {
        append(&ws.rows, WS_Row{strings.clone(h.path), ring_contains(a, h.path)})
    }
}

// Higher score, then shorter path, then alphabetical so the order never wobbles.
@(private = "file")
wsfind_better :: proc(x, y: WS_Hit) -> bool {
    if x.score != y.score {
        return x.score > y.score
    }
    if len(x.path) != len(y.path) {
        return len(x.path) < len(y.path)
    }
    return x.path < y.path
}

// Relative to the root when under it, absolute when not — a dirty buffer from elsewhere is
// still in the ring. A slice of `path`, never a copy.
wsfind_rel :: proc(root, path: string) -> string {
    if root == "" || !strings.has_prefix(path, root) {
        return path
    }
    return strings.trim_prefix(path[len(root):], "/")
}

// As a subsequence, case-folded, scored on the two things that separate a match you meant from
// one you did not: a RUN of query characters landing together, and a character landing at the
// start of a path segment or a word. Spaces in the query are ignored, so "ed ui" reads as one
// pattern with a gap. Byte-wise on purpose: a UTF-8 continuation byte can never equal an ASCII
// one, so folding A-Z alone is exact, where a per-candidate rune decode would not be free.
wsfind_score :: proc(text, query: string) -> (score: int, ok: bool) {
    base := strings.last_index_byte(text, '/') + 1 // where the base name starts
    at := 0
    last := -2
    for i in 0 ..< len(query) {
        q := ws_fold(query[i])
        if q == ' ' {
            continue
        }
        for at < len(text) && ws_fold(text[at]) != q {
            at += 1
        }
        if at >= len(text) {
            return 0, false
        }
        if at == last + 1 {
            score += 8
        }
        if at == 0 || ws_is_break(text[at - 1]) {
            score += 6
        }
        if at >= base {
            score += 4
        }
        last = at
        at += 1
    }
    return score - len(text) / 8, true // a shorter path wins a tie
}

@(private = "file")
ws_fold :: proc(b: u8) -> u8 {
    return b >= 'A' && b <= 'Z' ? b + 32 : b
}

@(private = "file")
ws_is_break :: proc(b: u8) -> bool {
    switch b {
    case '/', '_', '-', '.', ' ':
        return true
    }
    return false
}

// --- the scan ---

// Breadth-first, leaving out dotted directories, the configured exclusions (exclude.odin) and
// anything past the caps. Dotted FILES are kept: `.gitignore` is a file you edit.
wsfind_scan :: proc(ws: ^WS_Find, root: string, exclude: []string = nil) {
    wsfind_files_clear(ws)
    delete(ws.root)
    ws.root = strings.clone(root)
    if root == "" {
        return
    }
    queue := make([dynamic]string, 0, 64, context.temp_allocator)
    append(&queue, strings.clone(root, context.temp_allocator))
    for i := 0; i < len(queue) && i < WS_DIR_BUDGET && len(ws.files) < WS_FILE_MAX; i += 1 {
        dir := queue[i]
        f, oerr := os.open(dir)
        if oerr != nil {
            continue
        }
        it := os.read_directory_iterator_create(f)
        for fi in os.read_directory_iterator(&it) {
            if fi.type == .Directory {
                dotted := len(fi.name) > 0 && fi.name[0] == '.'
                if dotted || exclude_hit(exclude, fi.name) {
                    continue
                }
                if sub, err := filepath.join({dir, fi.name}, context.temp_allocator); err == nil {
                    append(&queue, sub)
                }
                continue
            }
            if len(ws.files) >= WS_FILE_MAX {
                break
            }
            if path, err := filepath.join({dir, fi.name}); err == nil {
                append(&ws.files, path)
            }
        }
        os.read_directory_iterator_destroy(&it)
        os.close(f)
    }
}
