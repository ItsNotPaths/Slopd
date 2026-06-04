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

    // Tab swaps the focused column's sub-mode: Status/Log in the sidebar...
    testing.expect_value(t, g.section, app.GitSection.Status)
    app.git_tab(&g)
    testing.expect_value(t, g.section, app.GitSection.Log)
    app.git_tab(&g)
    testing.expect_value(t, g.section, app.GitSection.Status)
    // ...and diff <-> commit message in the right column.
    g.region = .Diff
    app.git_tab(&g)
    testing.expect_value(t, g.region, app.GitRegion.Commit)
    app.git_tab(&g)
    testing.expect_value(t, g.region, app.GitRegion.Diff)

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
}

// The held auto-scroll's tick interval ramps from slow (at press) to fast (held a while).
@(test)
test_diff_scroll_ramp :: proc(t: ^testing.T) {
    slow := app.git_scroll_interval(0) // just pressed
    fast := app.git_scroll_interval(2.0) // held past the ramp -> clamped to full speed
    half := app.git_scroll_interval(0.5)
    testing.expect(t, slow > 0.12 && slow < 0.14) // slow start (~0.13)
    testing.expect(t, fast > 0.017 && fast < 0.019) // full speed (~0.018)
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
