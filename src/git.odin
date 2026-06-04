package main

// GitPane — the Git aux mode's state (Sublime-Merge-lite, KB-only). The aux pane is
// split into two sub-columns: a SIDEBAR ported from Prawk's gitpane.nim (a branch
// strip, a working-tree Status section, and an expandable Log) and a DIFF VIEWER /
// COMMIT EDITOR. Selecting in the sidebar loads a diff on the right; Alt+Q reverts a
// loaded diff to the live working tree.
//
// SCAFFOLD: this holds only the cross-region focus for now. The widening of the aux
// pane (App.split_anim) and the two-column render live alongside; the git shell-out,
// the status / log model, the diff parsing, and staging are Phase 1+ (see the "Git
// (aux mode)" section of plan.txt). Each Phase 1 field hangs off this struct.

// Which sub-region of the git pane owns the arrow keys. Tab cycles through them in
// this order: the sidebar lists branches/status/log, the diff viewer scrolls hunks,
// the commit editor takes the message text.
GitRegion :: enum {
    Sidebar,
    Diff,
    Commit,
}

GitPane :: struct {
    region: GitRegion, // the focused sub-region (arrows act here; Tab cycles)
}

git_init :: proc(g: ^GitPane) {
    g.region = .Sidebar
}

git_destroy :: proc(g: ^GitPane) {
    // Nothing owned yet — the seam for Phase 1's status / log / diff / message state.
}

// Move the focus to the next sub-region, wrapping. dir is +1 forward (Tab) / -1 back
// (Shift+Tab).
git_cycle_region :: proc(g: ^GitPane, dir: int) {
    n := len(GitRegion)
    g.region = GitRegion((int(g.region) + dir + n) % n)
}
