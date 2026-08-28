package main

import "core:slice"
import "core:strings"
import "txt"

// What the workspace jump asks the App: whether it is showing, what the project root is, and
// the open-buffer ring it lists before anything you type.

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
    txt.doc_set_text(&ws.query, "")
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
// nothing is typed, the ring: an open or a save under an open prompt changes what a row says
// with no version bumped, so both counts are compared.
wsfind_sync :: proc(a: ^App) {
    ws := &a.wsfind
    if !ws.open {
        return
    }
    if ws.query.version != ws.ver || (!wsfind_typed(ws) && wsfind_ring_stale(a)) {
        wsfind_build(a)
    }
}

// The listed rows against the ring they were built from. A save keeps the total and moves one
// row across the split, so the unsaved count is the half that catches it.
@(private = "file")
wsfind_ring_stale :: proc(a: ^App) -> bool {
    total, unsaved := 0, 0
    for &b in a.editor.buffers {
        if !buffer_on_disk(&b) {
            continue
        }
        total += 1
        if b.dirty {
            unsaved += 1
        }
    }
    listed := 0
    for r in a.wsfind.rows {
        if r.dirty {
            listed += 1
        }
    }
    return total != len(a.wsfind.rows) || unsaved != listed
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

// The open ring while the line is empty, the fuzzy filter once it is not. The selection goes
// back to the top: a new list has a new best answer.
wsfind_build :: proc(a: ^App) {
    ws := &a.wsfind
    ws.ver = ws.query.version
    wsfind_rows_clear(ws)
    q := wsfind_query(ws)
    if q == "" {
        // Unsaved first, then the rest. Only buffers with a file to go back to: a scratch
        // buffer has no location.
        for want_dirty in ([?]bool{true, false}) {
            for &b in a.editor.buffers {
                if b.dirty == want_dirty && buffer_on_disk(&b) {
                    append(&ws.rows, WS_Row{strings.clone(b.path), b.dirty})
                }
            }
        }
    } else {
        wsfind_rank(a, q)
    }
    ws.selected, ws.scroll = 0, 0
    ws.scroll_detached = 0
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
        append(&ws.rows, WS_Row{strings.clone(h.path), ring_contains(&a.editor, h.path)})
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
