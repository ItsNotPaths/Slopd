package main

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// WS_Find — the workspace jump list. Alt+P shows the file pane and turns its top bar into a
// `WORKSPACE/` prompt: with nothing typed the list under it is the UNSAVED RING (red, starred,
// as the listing marks those files anyway), and the first keystroke replaces that with a fuzzy
// filter over every file under the project root.
//
// **The listing it covers is untouched.** No navigation, no selection moved, no directory read —
// Esc puts the bar and the rows back exactly as they were, which is what makes this a prompt
// rather than a mode. One model, drawn by BOTH faces of the pane (wsfind_ui.odin): the browser's
// path bar and the `ls` header are two boxes for the same prompt, and the rows are the same rows.
//
// Host-independent in the same way filetree.odin is, bar the two seams it cannot avoid: the ring
// lives in the editor and opening a row is the editor's own open_file.

// The prompt's label. Cells, not pixels: the field starts after it under both faces.
WS_PROMPT :: "WORKSPACE/"

// The scan's bounds — directories it may open, files it may remember — and the longest list a
// filter will show. A jump list is a convenience: a tree big enough to hit these is one where
// the answer would arrive after you had typed the whole name anyway (find_nearest_file walks the
// same way for the same reason).
WS_DIR_BUDGET :: 4096
WS_FILE_MAX :: 20000
WS_ROWS_MAX :: 200

// A listed row: where it goes, and whether it is open with unsaved changes.
WS_Row :: struct {
    path:  string, // absolute (owned)
    dirty: bool,
}

WS_Find :: struct {
    open:  bool,
    query: Doc,
    off:   int, // the typed line's window — the shared field's (field_ui.odin)

    // The rows follow the typed line on a VERSION COMPARE (cl_preview.odin's trick): one test a
    // frame catches a keystroke, a paste, a delete and a multi-cursor edit alike, so no edit
    // path has to remember to rebuild.
    ver:   u64,

    // The scanned tree: every file under `root`, absolute and owned. `root` is what the scan
    // walked, NOT a.project_root — the rows are shown relative to it, and reading the live root
    // would relabel a list it no longer describes.
    root:  string,
    files: [dynamic]string,

    rows:  [dynamic]WS_Row, // what is listed right now (owned paths)

    selected:        int,
    scroll:          int,
    hover:           int, // the row under the pointer, or -1 — transient frame state
    scroll_detached: f64,
    scroll_anim:     Anim,
}

// drag.odin's target for the prompt's line. The path bar is -1 and a config row is its own
// index, so a capture can never be mistaken for either.
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

// Whether the prompt is DRAWN: it belongs to the file pane, so another aux mode hides it (and
// leaves it open for when you come back).
wsfind_shown :: proc(a: ^App) -> bool {
    return a.wsfind.open && a.aux_mode == .FileTree
}

// …and whether it owns the keyboard. One predicate, so the char callback, the key routing and
// the blink cannot disagree about who is being typed into (filebrowser_path_live's twin).
wsfind_live :: proc(a: ^App) -> bool {
    return wsfind_shown(a) && a.focus == .Aux
}

// Alt+P: show the file pane, then open the prompt on it, empty. The tree is re-scanned here
// rather than cached across opens — a project changes under you, and this is an explicit
// gesture, not a keystroke.
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

// Esc, and every path that opens a row. The rows go with it: they are clones of paths the ring
// and the scan own, and nothing is going to read them again.
wsfind_close :: proc(a: ^App) {
    ws := &a.wsfind
    ws.open = false
    wsfind_rows_clear(ws)
    ws.selected, ws.scroll, ws.hover = 0, 0, -1
    ws.scroll_detached = 0
}

// The per-frame tick, called by whichever face is up before it declares. The rows follow the
// typed line, and — while nothing is typed — the RING as well: a save made under an open prompt
// drops a row, and no version bumped to say so. A count is enough, since those rows ARE the
// dirty buffers.
wsfind_sync :: proc(a: ^App) {
    ws := &a.wsfind
    if !ws.open {
        return
    }
    if ws.query.version != ws.ver || (!wsfind_typed(ws) && len(ws.rows) != wsfind_ring_count(a)) {
        wsfind_build(a)
    }
}

// How many buffers the ring listing holds: unsaved, and with a file to go back to.
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

// Enter (and a double click): open the row and close the prompt. The path is copied out first —
// closing frees the row it came from.
wsfind_activate :: proc(a: ^App) {
    row, ok := wsfind_selected(&a.wsfind)
    if !ok {
        return
    }
    path := strings.clone(row.path, context.temp_allocator)
    wsfind_close(a)
    open_file(a, path) // focuses the editor, as every other way of opening a file does
}

// --- the rows ---

// The typed line, trimmed — which of the two lists the prompt is showing, asked in one place.
wsfind_query :: proc(ws: ^WS_Find) -> string {
    return strings.trim_space(doc_string(&ws.query, context.temp_allocator))
}

wsfind_typed :: proc(ws: ^WS_Find) -> bool {
    return wsfind_query(ws) != ""
}

// Rebuild the list from the typed line: the unsaved ring while it is empty, the fuzzy filter
// once it is not. The selection goes back to the top — a new list has a new best answer.
wsfind_build :: proc(a: ^App) {
    ws := &a.wsfind
    ws.ver = ws.query.version
    wsfind_rows_clear(ws)
    q := wsfind_query(ws)
    if q == "" {
        // Only buffers with a file to go back to: a dirty scratch buffer is unsaved work with
        // no location, and there is nothing for a jump to land on.
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

// Score every scanned file against `q` and keep the best WS_ROWS_MAX of them. The match runs
// over the RELATIVE path — the root's own directories are in every candidate, so scoring them
// would rank on the part they all share.
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

// Best first: the higher score, then the shorter path (a match in a name is worth more than the
// same match buried in a longer one), then alphabetical so the order never wobbles.
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

// `path` as it is LISTED: relative to the root when it is under it, absolute when it is not (a
// dirty buffer from elsewhere is still in the ring). A slice of `path`, never a copy.
wsfind_rel :: proc(root, path: string) -> string {
    if root == "" || !strings.has_prefix(path, root) {
        return path
    }
    return strings.trim_prefix(path[len(root):], "/")
}

// Does `query` appear in `text` as a subsequence, and how well? Case-folded, and scored on the
// two things that separate a match you meant from one you did not: a RUN of query characters
// landing together, and a character landing at the start of a path segment or a word. Spaces in
// the query are ignored, so "ed ui" reads as one pattern with a gap you did not have to spell.
//
// Byte-wise on purpose: a UTF-8 continuation byte can never equal an ASCII one, so folding only
// A-Z is exact for every path, and a per-candidate rune decode over a whole project is not.
wsfind_score :: proc(text, query: string) -> (score: int, ok: bool) {
    base := strings.last_index_byte(text, '/') + 1 // the base name starts here
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
    return score - len(text) / 8, true // a shorter path wins a tie it would otherwise share
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

// Every file under `root`, breadth-first, with three things left out: dotted directories (a
// `.git` is not somewhere you jump), the configured exclusions (exclude.odin — the same list
// `:grep` is handed), and anything past the caps (see WS_DIR_BUDGET). Dotted FILES are kept:
// `.gitignore` is a file you edit.
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
