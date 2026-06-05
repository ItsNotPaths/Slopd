package tests

import app ".."
import "core:os"
import "core:strings"
import "core:testing"

// git_find_repo backtracks from a start directory to the enclosing repo's working-tree
// root. Like filetree_test, this runs against the real working directory (the Slopd
// repo, itself a git repo); it skips the repo-dependent assertions if launched from
// somewhere that isn't a repo, so it stays deterministic without a fixture.
@(test)
test_find_repo :: proc(t: ^testing.T) {
    // The empty path never matches (guard).
    if _, ok := app.git_find_repo(""); ok {
        testing.expect(t, false, "empty start should not resolve to a repo")
    }

    cwd, err := os.get_working_directory(context.allocator)
    if err != nil {
        return
    }
    defer delete(cwd)

    root, ok := app.git_find_repo(cwd)
    if !ok {
        return // not launched from inside a repo — skip the rest
    }
    defer delete(root)

    // The result names a real repo (holds .git) and is an ancestor of (or equal to) cwd.
    testing.expect(t, os.exists(strings.concatenate({root, "/.git"}, context.temp_allocator)))
    testing.expect(t, strings.has_prefix(cwd, root))

    // Backtracking: a nested subdirectory resolves to the SAME root.
    sub := strings.concatenate({cwd, "/src/tests"}, context.temp_allocator)
    root2, ok2 := app.git_find_repo(sub)
    testing.expect(t, ok2)
    defer delete(root2)
    testing.expect_value(t, root2, root)
}

// The loaders shell out to the real `git` and parse its porcelain. Runs against the
// Slopd repo (skipped if launched outside one), exercising git_run + parsing end to end.
@(test)
test_load_state :: proc(t: ^testing.T) {
    cwd, err := os.get_working_directory(context.allocator)
    if err != nil {
        return
    }
    defer delete(cwd)
    root, ok := app.git_find_repo(cwd)
    if !ok {
        return // not inside a repo — skip
    }

    g: app.GitPane
    app.git_init(&g) // sets up the grep / commit Docs the loaders + filter rely on
    g.root = root // ownership transfers to g; git_destroy frees it (no separate delete)
    g.is_repo = true
    defer app.git_destroy(&g)

    app.git_load_branch(&g)
    app.git_load_status(&g)
    app.git_load_log(&g)

    // A repo with history yields commits, each with a non-empty hash and subject.
    testing.expect(t, len(g.commits) > 0)
    if len(g.commits) > 0 {
        testing.expect(t, len(g.commits[0].hash) > 0)
        testing.expect(t, len(g.commits[0].subject) > 0)
    }
    // Status entries (if any) carry a 2-char code; the parse never yields a short one.
    for e in g.status {
        testing.expect_value(t, len(e.code), 2)
    }

    // Loading a real commit's diff end to end (git show -> parse) yields files + hunks.
    if len(g.commits) > 0 {
        app.git_load_diff_commit(&g, g.commits[0].hash, g.commits[0].subject)
        testing.expect(t, len(g.diff_files) > 0)
        testing.expect(t, app.git_hunk_count(&g) > 0)
        testing.expect(t, len(g.diff_title) > 0)
    }
}

// The sidebar navigation primitives are pure GitPane logic — region movement clamps,
// Tab toggles the section, and selection clamps to the active list's length.
@(test)
test_git_nav :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)

    // Region: Left/Right switch between the sidebar and the right column.
    testing.expect_value(t, g.region, app.GitRegion.Sidebar)
    app.git_move_region(&g, -1)
    testing.expect_value(t, g.region, app.GitRegion.Sidebar) // already leftmost: no-op
    app.git_move_region(&g, 1)
    testing.expect_value(t, g.region, app.GitRegion.Diff) // enter the right column at the diff
    app.git_move_region(&g, 1)
    testing.expect_value(t, g.region, app.GitRegion.Diff) // already in the right column: no-op
    app.git_move_region(&g, -1)
    testing.expect_value(t, g.region, app.GitRegion.Sidebar) // back to the sidebar

    // Tab cycles the focused column's sub-mode: Status -> Log -> Branch -> Status in the
    // sidebar...
    testing.expect_value(t, g.section, app.GitSection.Status)
    app.git_tab(&g)
    testing.expect_value(t, g.section, app.GitSection.Log)
    app.git_tab(&g)
    testing.expect_value(t, g.section, app.GitSection.Branch)
    app.git_tab(&g)
    testing.expect_value(t, g.section, app.GitSection.Status)
    // ...and Grep -> Select -> Diff -> Commit -> Grep in the right column.
    g.region = .Grep
    app.git_tab(&g)
    testing.expect_value(t, g.region, app.GitRegion.Select)
    app.git_tab(&g)
    testing.expect_value(t, g.region, app.GitRegion.Diff)
    app.git_tab(&g)
    testing.expect_value(t, g.region, app.GitRegion.Commit)
    app.git_tab(&g)
    testing.expect_value(t, g.region, app.GitRegion.Grep)

    // Selection moves only in the sidebar and clamps to the active list's length.
    g.region = .Sidebar
    g.section = .Status
    app.git_move_sel(&g, 1)
    testing.expect_value(t, g.sel_status, 0) // empty list: nothing to move
    append(&g.status, app.StatusEntry{code = strings.clone("M "), path = strings.clone("a")})
    append(&g.status, app.StatusEntry{code = strings.clone("M "), path = strings.clone("b")})
    append(&g.status, app.StatusEntry{code = strings.clone("M "), path = strings.clone("c")})
    app.git_move_sel(&g, 1)
    testing.expect_value(t, g.sel_status, 1)
    app.git_move_sel(&g, 5)
    testing.expect_value(t, g.sel_status, 2) // clamped at the last row
    app.git_move_sel(&g, -10)
    testing.expect_value(t, g.sel_status, 0) // clamped at the first

    // Outside the sidebar, Up/Down don't move the sidebar selection (diff nav is covered
    // in test_diff_parse).
    g.region = .Diff
    app.git_move_sel(&g, 1)
    testing.expect_value(t, g.sel_status, 0)
}

// The diff classifier tags each line; order matters so the "--- "/"+++ " file headers
// and a deletion whose content starts with dashes don't collide.
@(test)
test_diff_classify :: proc(t: ^testing.T) {
    testing.expect_value(t, app.git_diff_classify("@@ -1,2 +1,3 @@"), app.DiffLineKind.Hunk)
    testing.expect_value(t, app.git_diff_classify("diff --git a/x b/x"), app.DiffLineKind.Header)
    testing.expect_value(t, app.git_diff_classify("index 0a1..b2c 100644"), app.DiffLineKind.Header)
    testing.expect_value(t, app.git_diff_classify("--- a/x"), app.DiffLineKind.Header)
    testing.expect_value(t, app.git_diff_classify("+++ b/x"), app.DiffLineKind.Header)
    testing.expect_value(t, app.git_diff_classify("+added"), app.DiffLineKind.Add)
    testing.expect_value(t, app.git_diff_classify("-removed"), app.DiffLineKind.Del)
    testing.expect_value(t, app.git_diff_classify(" context"), app.DiffLineKind.Context)
    testing.expect_value(t, app.git_diff_classify(""), app.DiffLineKind.Context)
    // A deleted line whose content starts with dashes must read as Del, not a header.
    testing.expect_value(t, app.git_diff_classify("---- still a deletion"), app.DiffLineKind.Del)
}

// git_is_staged decides Space's direction: a porcelain code is "staged" only when the
// index column changed and the worktree column is clean.
@(test)
test_is_staged :: proc(t: ^testing.T) {
    testing.expect(t, app.git_is_staged("M ")) // staged modification
    testing.expect(t, app.git_is_staged("A ")) // staged addition
    testing.expect(t, app.git_is_staged("D ")) // staged deletion
    testing.expect(t, !app.git_is_staged(" M")) // unstaged modification
    testing.expect(t, !app.git_is_staged("MM")) // staged + further unstaged work
    testing.expect(t, !app.git_is_staged("??")) // untracked
    testing.expect(t, !app.git_is_staged(" D")) // unstaged deletion
}

// A two-file, three-hunk unified diff (foo.txt has two hunks, bar.txt one). Context
// lines begin with a space; additions with '+'.
@(private = "file")
SAMPLE_DIFF :: "diff --git a/foo.txt b/foo.txt\n" +
    "index 111..222 100644\n--- a/foo.txt\n+++ b/foo.txt\n" +
    "@@ -1,2 +1,3 @@\n a\n+b\n c\n" +
    "@@ -10,2 +11,3 @@\n x\n+y\n z\n" +
    "diff --git a/bar.txt b/bar.txt\n" +
    "index 333..444 100644\n--- a/bar.txt\n+++ b/bar.txt\n" +
    "@@ -5,1 +5,2 @@\n m\n+n\n"

// git_set_diff -> git_parse_diff: the diff parses into files, each with a verbatim header
// block and its hunks; body lines are tagged; the first hunk is focused.
@(test)
test_diff_parse :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "two files", true)

    testing.expect_value(t, g.diff_title, "two files")
    testing.expect(t, g.diff_stageable)
    testing.expect_value(t, len(g.diff_files), 2)
    testing.expect_value(t, app.git_hunk_count(&g), 3)
    testing.expect_value(t, g.hunk_cur, 0) // focuses the first hunk

    f0 := g.diff_files[0]
    testing.expect_value(t, f0.path, "foo.txt")
    testing.expect_value(t, len(f0.header), 4) // diff --git, index, ---, +++
    testing.expect_value(t, len(f0.hunks), 2)
    testing.expect_value(t, f0.hunks[0].header, "@@ -1,2 +1,3 @@")
    testing.expect_value(t, len(f0.hunks[0].lines), 3)
    testing.expect_value(t, f0.hunks[0].lines[0].kind, app.DiffLineKind.Context)
    testing.expect_value(t, f0.hunks[0].lines[1].kind, app.DiffLineKind.Add)
    testing.expect_value(t, f0.hunks[0].lines[2].kind, app.DiffLineKind.Context)
    testing.expect_value(t, g.diff_files[1].path, "bar.txt")
    testing.expect_value(t, len(g.diff_files[1].hunks), 1)
}

// Row layout + the playhead derivation that render scrolls against. For SAMPLE_DIFF:
// foo = title + 2 hunks (3 body lines each), bar = title + 1 hunk (2 body) — with a
// header row + spacer per hunk, that's 1+5+5 + 1+4 = 16 display rows.
@(test)
test_diff_layout :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "two files", true)

    testing.expect_value(t, app.git_diff_rows(&g), 16)
    testing.expect_value(t, app.git_hunk_top_row(&g, 0), 1)
    testing.expect_value(t, app.git_hunk_top_row(&g, 1), 6)
    testing.expect_value(t, app.git_hunk_top_row(&g, 2), 12)

    // git_hunk_at_row: the last hunk whose header is at/above the given row (the one the
    // playhead sits in). Row 0 is foo's title (before any hunk) -> hunk 0 by default.
    testing.expect_value(t, app.git_hunk_at_row(&g, 0), 0)
    testing.expect_value(t, app.git_hunk_at_row(&g, 5), 0)
    testing.expect_value(t, app.git_hunk_at_row(&g, 6), 1)
    testing.expect_value(t, app.git_hunk_at_row(&g, 11), 1)
    testing.expect_value(t, app.git_hunk_at_row(&g, 12), 2)
    testing.expect_value(t, app.git_hunk_at_row(&g, 99), 2)

    // git_hunk_ptr flattens the hunk space (2 in foo, 1 in bar).
    testing.expect(t, app.git_hunk_ptr(&g, 2) == &g.diff_files[1].hunks[0])
    testing.expect(t, app.git_hunk_ptr(&g, 3) == nil)
    testing.expect(t, app.git_hunk_ptr(&g, -1) == nil)
}

// Scroll + jump against a known viewport. With diff_view_rows=10 the playhead is 5 rows
// down, so centring hunk k means scroll = hunk_top(k) - 5 (which may be negative —
// over-scroll lets the first hunk reach the centre).
@(test)
test_diff_scroll :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "two files", true)
    g.region = .Diff
    g.diff_view_rows = 10 // playhead offset = 5

    testing.expect_value(t, app.git_scroll_lo(&g), -4) // hunk_top(0) 1 - 5
    testing.expect_value(t, app.git_scroll_hi(&g), 7) //  hunk_top(2) 12 - 5

    g.hunk_cur = 0
    app.git_diff_jump_hunk(&g, 1)
    testing.expect_value(t, g.diff_scroll, 1) // centre hunk 1: 6 - 5
    g.hunk_cur = 2
    app.git_diff_jump_hunk(&g, 1)
    testing.expect_value(t, g.diff_scroll, 7) // clamps to the last hunk's centre

    // Plain Up/Down scroll clamps to the over-scroll bounds [lo, hi].
    g.diff_scroll = 0
    app.git_diff_scroll(&g, -9)
    testing.expect_value(t, g.diff_scroll, -4)
    app.git_diff_scroll(&g, 99)
    testing.expect_value(t, g.diff_scroll, 7)

    // A SHORT viewport (4 rows, offset 2): centring the last hunk (top row 12) gives 10, but
    // the diff is 16 rows, so scroll_hi extends to 16-4 = 12 so the last hunk's final line
    // clears the bottom (the commit bar) rather than staying cut off.
    g.diff_view_rows = 4
    testing.expect_value(t, app.git_scroll_hi(&g), 12)
    app.git_diff_scroll(&g, 99)
    testing.expect_value(t, g.diff_scroll, 12)
}

// The held auto-scroll's tick interval ramps from slow (at press) to fast (held a while).
@(test)
test_diff_scroll_ramp :: proc(t: ^testing.T) {
    slow := app.git_scroll_interval(0) // just pressed
    fast := app.git_scroll_interval(2.0) // held past the ramp -> clamped to full speed
    half := app.git_scroll_interval(0.15) // mid-ramp (RAMP is 0.4s)
    testing.expect(t, slow > 0.11 && slow < 0.13) // slow start (~0.12)
    testing.expect(t, fast > 0.009 && fast < 0.011) // full speed (~0.010)
    testing.expect(t, half < slow && half > fast) // monotonic in between (faster over time)
}

// Holding an arrow starts the auto-scroll (one immediate line); a same-direction REPEAT
// is ignored (our pump drives it); releasing that arrow stops it.
@(test)
test_diff_scroll_hold :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "work", true)
    g.region = .Diff
    g.diff_view_rows = 10
    g.diff_scroll = 0

    app.git_scroll_start(&g, 1, 0) // press Down
    testing.expect_value(t, g.scroll_dir, 1)
    testing.expect_value(t, g.diff_scroll, 1) // the immediate first line
    app.git_scroll_start(&g, 1, 0) // a REPEAT for the same direction is ignored
    testing.expect_value(t, g.diff_scroll, 1)
    app.git_scroll_release(&g, -1) // releasing the other arrow does nothing
    testing.expect_value(t, g.scroll_dir, 1)
    app.git_scroll_release(&g, 1) // release Down -> stop
    testing.expect_value(t, g.scroll_dir, 0)
}

// Toggling honours diff_stageable, and the built patch contains only the selected hunks'
// files + hunks (a skipped hunk's @@ line is absent).
@(test)
test_diff_stage_patch :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)

    // Not stageable: toggling is a no-op.
    app.git_set_diff(&g, SAMPLE_DIFF, "commit", false)
    g.region = .Diff
    g.hunk_cur = 0
    app.git_toggle_hunk(&g)
    testing.expect(t, !g.diff_files[0].hunks[0].selected)
    testing.expect_value(t, app.git_build_patch(&g, context.temp_allocator), "")

    // Stageable: check foo's first hunk and bar's hunk (indices 0 and 2), skip foo's
    // second (index 1).
    app.git_set_diff(&g, SAMPLE_DIFF, "work", true)
    g.hunk_cur = 0
    app.git_toggle_hunk(&g)
    testing.expect(t, g.diff_files[0].hunks[0].selected)
    g.hunk_cur = 2
    app.git_toggle_hunk(&g)
    testing.expect(t, g.diff_files[1].hunks[0].selected)

    patch := app.git_build_patch(&g, context.temp_allocator)
    testing.expect(t, strings.contains(patch, "diff --git a/foo.txt b/foo.txt"))
    testing.expect(t, strings.contains(patch, "@@ -1,2 +1,3 @@")) // foo hunk 0 (selected)
    testing.expect(t, !strings.contains(patch, "@@ -10,2 +11,3 @@")) // foo hunk 1 (skipped)
    testing.expect(t, strings.contains(patch, "diff --git a/bar.txt b/bar.txt"))
    testing.expect(t, strings.contains(patch, "@@ -5,1 +5,2 @@")) // bar hunk (selected)
    testing.expect(t, strings.contains(patch, "+b")) // foo hunk 0 body came along
    testing.expect(t, !strings.contains(patch, "+y")) // foo hunk 1 body did not

    // Untoggling foo's hunk drops its file entirely (no hunks selected there).
    g.hunk_cur = 0
    app.git_toggle_hunk(&g)
    patch2 := app.git_build_patch(&g, context.temp_allocator)
    testing.expect(t, !strings.contains(patch2, "a/foo.txt"))
    testing.expect(t, strings.contains(patch2, "a/bar.txt"))
}

// The grep filter hides hunks whose file path AND body lines miss the query; layout + nav
// then run over the visible set, and select-all acts only on what passes the filter.
@(test)
test_diff_grep_filter :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "work", true)
    testing.expect_value(t, app.git_hunk_count(&g), 3) // no filter: all visible

    // Filter by path -> only bar.txt's single hunk survives; foo.txt drops out entirely.
    app.git_set_grep(&g, "bar")
    testing.expect_value(t, app.git_hunk_count(&g), 1)
    testing.expect(t, g.diff_files[0].hidden) // foo.txt filtered out (title + hunks gone)
    testing.expect(t, !g.diff_files[1].hidden)
    testing.expect_value(t, g.hunk_cur, 0) // focus re-anchored to the first visible hunk

    // Filter by body content -> only the hunk containing "+y" (foo's second) survives.
    app.git_set_grep(&g, "+y")
    testing.expect_value(t, app.git_hunk_count(&g), 1)
    testing.expect(t, g.diff_files[0].hunks[0].hidden)
    testing.expect(t, !g.diff_files[0].hunks[1].hidden)

    // Select-all acts only on the visible hunk; the hidden ones stay unchecked.
    app.git_check_filtered(&g, true)
    testing.expect(t, g.diff_files[0].hunks[1].selected)
    testing.expect(t, !g.diff_files[0].hunks[0].selected)
    testing.expect(t, !g.diff_files[1].hunks[0].selected)

    // Clearing the filter restores every hunk; the earlier check survived.
    app.git_set_grep(&g, "")
    testing.expect_value(t, app.git_hunk_count(&g), 3)
    testing.expect(t, g.diff_files[0].hunks[1].selected)
}

// Multisearch: '+'-separated terms are OR'd — a hunk shows if it matches ANY term.
@(test)
test_diff_grep_multi :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "work", true)

    // "foo + bar" shows both files' hunks (all three); whitespace around terms is trimmed.
    app.git_set_grep(&g, "foo + bar")
    testing.expect_value(t, app.git_hunk_count(&g), 3)
    testing.expect(t, !g.diff_files[0].hidden)
    testing.expect(t, !g.diff_files[1].hidden)

    // A non-matching term OR a real body term: "zzz + n" matches only bar's hunk (its "+n"
    // body line); foo has no 'n' in its path or bodies.
    app.git_set_grep(&g, "zzz + n")
    testing.expect_value(t, app.git_hunk_count(&g), 1)
    testing.expect(t, g.diff_files[0].hidden)
    testing.expect(t, !g.diff_files[1].hidden)
}

// The Select button auto-cycles: select-all when nothing visible is checked, else clear.
@(test)
test_toggle_all :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "work", true)

    testing.expect(t, !app.git_any_checked(&g))
    app.git_toggle_all(&g) // none checked -> select all
    testing.expect(t, app.git_any_checked(&g))
    testing.expect(t, g.diff_files[0].hunks[0].selected && g.diff_files[1].hunks[0].selected)
    app.git_toggle_all(&g) // some checked -> clear all
    testing.expect(t, !app.git_any_checked(&g))
}

// The branch strip: cycling clamps, and the hover defaults to the checked-out branch.
@(test)
test_branch_nav :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    append(&g.branches, strings.clone("main"))
    append(&g.branches, strings.clone("feature"))
    append(&g.branches, strings.clone("fix"))
    g.branch = strings.clone("feature")

    app.git_sel_branch_to_current(&g)
    testing.expect_value(t, g.sel_branch, 1) // hovers the checked-out branch

    app.git_branch_cycle(&g, 1)
    testing.expect_value(t, g.sel_branch, 2)
    app.git_branch_cycle(&g, 5)
    testing.expect_value(t, g.sel_branch, 2) // clamped at the last
    app.git_branch_cycle(&g, -9)
    testing.expect_value(t, g.sel_branch, 0) // clamped at the first
}

// The slot machine moves the live diff into a snapshot, fills it with shuffled, repeated
// single-hunk REELS that spin down to a random resting row, and restores the snapshot verbatim
// on payout. SAMPLE_DIFF has 3 visible hunks, padded to >= SPIN_MIN_REELS (ceil(30/3)*3 = 30).
@(test)
test_spin :: proc(t: ^testing.T) {
    g: app.GitPane
    app.git_init(&g)
    defer app.git_destroy(&g)
    app.git_set_diff(&g, SAMPLE_DIFF, "two files", true)
    g.diff_view_rows = 10

    units := app.git_hunk_count(&g) // 3 visible hunks
    reels := ((30 + units - 1) / units) * units // padded to >= SPIN_MIN_REELS, a multiple of units
    testing.expect(t, app.git_spin_begin(&g, 1.0))
    testing.expect(t, g.spin.active)
    testing.expect_value(t, g.diff_title, "🎰 lucky dip")
    testing.expect_value(t, app.git_hunk_count(&g), reels) // 10 reps * 3 reels
    testing.expect_value(t, len(g.diff_files), reels) // each reel is its own one-hunk file
    testing.expect(t, g.spin.to > g.spin.from) // lands below the top: the reels spin downward
    testing.expect(t, !app.git_spin_begin(&g, 2.0)) // a second spin while one runs is a no-op

    app.git_spin_restore(&g) // payout: the original two-file diff comes back untouched
    testing.expect(t, !g.spin.active)
    testing.expect_value(t, len(g.diff_files), 2)
    testing.expect_value(t, app.git_hunk_count(&g), 3)
    testing.expect_value(t, g.diff_files[0].path, "foo.txt")
}

// git_cl_settle is the pane's CL feedback: a committed selection ships (clearing the message
// + checkboxes) on a real submit, and survives a back-off. A spin unwinds either way.
@(test)
test_cl_settle :: proc(t: ^testing.T) {
    a: app.App
    app.git_init(&a.git)
    defer app.git_destroy(&a.git)
    app.git_set_diff(&a.git, SAMPLE_DIFF, "two files", true)
    app.doc_set_text(&a.git.commit_msg, "wip")
    a.git.diff_files[0].hunks[0].selected = true

    // Backing off (Esc / an empty submit) leaves the message + selection intact.
    a.git.cl_wait = .Commit
    app.git_cl_settle(&a, .Commit, false)
    testing.expect_value(t, a.git.cl_wait, app.GitCLKind.None)
    testing.expect(t, app.git_any_checked(&a.git))

    // Shipping clears both — the commit bar finally empties on send.
    a.git.cl_wait = .Commit
    app.git_cl_settle(&a, .Commit, true)
    testing.expect(t, !app.git_any_checked(&a.git))
    testing.expect_value(t, app.doc_string(&a.git.commit_msg, context.temp_allocator), "")

    // A spin in flight is unwound whichever way its CL goes.
    a.git.diff_view_rows = 10
    testing.expect(t, app.git_spin_begin(&a.git, 3.0))
    a.git.cl_wait = .Spin
    app.git_cl_settle(&a, .Spin, false)
    testing.expect(t, !a.git.spin.active)
    testing.expect_value(t, len(a.git.diff_files), 2)
}

// --- merge conflict resolution (Part 1: the KB merge editor) ---

// git_is_conflict recognises the unmerged porcelain codes and nothing else.
@(test)
test_is_conflict :: proc(t: ^testing.T) {
    testing.expect(t, app.git_is_conflict("UU")) // both modified
    testing.expect(t, app.git_is_conflict("AA")) // both added
    testing.expect(t, app.git_is_conflict("DD")) // both deleted
    testing.expect(t, app.git_is_conflict("UD")) // modified / deleted
    testing.expect(t, app.git_is_conflict("AU")) // added by us
    testing.expect(t, !app.git_is_conflict("M ")) // a plain staged modification
    testing.expect(t, !app.git_is_conflict(" M"))
    testing.expect(t, !app.git_is_conflict("??"))
}

// A conflicted file with one region splits into a single conflict hunk: the clean run before
// it lands on `pre`, the two sides on `ours`/`theirs`, the clean run after on the file tail.
// The default (Unresolved) body shows both sides. Reconstruction then round-trips each choice.
@(test)
test_parse_conflicts :: proc(t: ^testing.T) {
    content := "a\nb\n<<<<<<< HEAD\nours1\nours2\n=======\ntheirs1\n>>>>>>> branch\nc\n"
    hunks, tail := app.git_parse_conflicts(content)
    files := make([dynamic]app.DiffFile)
    append(&files, app.DiffFile{hunks = hunks, tail = tail, conflict = true})
    defer {
        app.git_free_files(files)
        delete(files)
    }

    testing.expect_value(t, len(hunks), 1)
    h := &hunks[0]
    testing.expect(t, h.conflict)
    testing.expect_value(t, h.choice, app.ConflictChoice.Unresolved)
    testing.expect_value(t, len(h.pre), 2) // "a", "b"
    testing.expect_value(t, len(h.ours), 2) // "ours1", "ours2"
    testing.expect_value(t, len(h.theirs), 1) // "theirs1"
    testing.expect_value(t, len(tail), 2) // "c", "" (trailing newline)
    testing.expect_value(t, len(h.lines), 3) // Unresolved shows ours + theirs

    f := &files[0]
    f.hunks[0].choice = .Ours
    ours := app.git_resolve_content(f, context.temp_allocator)
    testing.expect_value(t, ours, "a\nb\nours1\nours2\nc\n")

    f.hunks[0].choice = .Theirs
    theirs := app.git_resolve_content(f, context.temp_allocator)
    testing.expect_value(t, theirs, "a\nb\ntheirs1\nc\n")

    f.hunks[0].choice = .Both
    both := app.git_resolve_content(f, context.temp_allocator)
    testing.expect_value(t, both, "a\nb\nours1\nours2\ntheirs1\nc\n")
}

// A diff3-style base section (||||||| .. =======) is dropped, leaving the same ours/theirs.
@(test)
test_parse_conflicts_diff3 :: proc(t: ^testing.T) {
    content := "<<<<<<< HEAD\nmine\n||||||| base\norig\n=======\nyours\n>>>>>>> b\n"
    hunks, tail := app.git_parse_conflicts(content)
    files := make([dynamic]app.DiffFile)
    append(&files, app.DiffFile{hunks = hunks, tail = tail, conflict = true})
    defer {
        app.git_free_files(files)
        delete(files)
    }
    testing.expect_value(t, len(hunks), 1)
    testing.expect_value(t, len(hunks[0].ours), 1) // "mine"
    testing.expect_value(t, len(hunks[0].theirs), 1) // "yours" (base "orig" dropped)
}

// Space cycles a conflict hunk Unresolved -> Ours -> Theirs -> Both -> Unresolved, rebuilding
// the displayed body each step.
@(test)
test_cycle_conflict :: proc(t: ^testing.T) {
    content := "<<<<<<< HEAD\nx\ny\n=======\nz\n>>>>>>> b\n"
    hunks, tail := app.git_parse_conflicts(content)
    files := make([dynamic]app.DiffFile)
    append(&files, app.DiffFile{hunks = hunks, tail = tail, conflict = true})
    defer {
        app.git_free_files(files)
        delete(files)
    }
    h := &hunks[0]

    testing.expect_value(t, h.choice, app.ConflictChoice.Unresolved)
    app.git_cycle_conflict(h)
    testing.expect_value(t, h.choice, app.ConflictChoice.Ours)
    testing.expect_value(t, len(h.lines), 2) // just ours: "x", "y"
    app.git_cycle_conflict(h)
    testing.expect_value(t, h.choice, app.ConflictChoice.Theirs)
    testing.expect_value(t, len(h.lines), 1) // just theirs: "z"
    app.git_cycle_conflict(h)
    testing.expect_value(t, h.choice, app.ConflictChoice.Both)
    testing.expect_value(t, len(h.lines), 3) // ours + theirs
    app.git_cycle_conflict(h)
    testing.expect_value(t, h.choice, app.ConflictChoice.Unresolved) // wraps
}
