package main


// Running a search against the project, and following a hit into the editor. The result set
// itself, and the rows it draws as, are the other half.

// The one jump, shared by the pane's Enter and link.odin's single-definition goto.
grep_open_hit :: proc(a: ^App, h: GrepHit) {
    jump_to(a, h.path, h.line - 1, h.col) // GrepHit.line is 1-based, jump_to 0-based
}

// A no-op on an empty or out-of-range list.
grep_open_selected :: proc(a: ^App) {
    g := &a.grep
    if g.selected >= 0 && g.selected < len(g.hits) {
        grep_open_hit(a, g.hits[g.selected])
    }
}

// The root and the excluded directories filled in, so no caller has to remember that a search
// skips `vendor`.
grep_project :: proc(a: ^App, query: string, word := false, fixed := false) -> []GrepHit {
    return grep_run(a.project_root, query, exclude_dirs(a), word, fixed)
}
