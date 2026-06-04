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

    // Loading a real commit's diff end to end (git show -> parse) yields tagged lines.
    if len(g.commits) > 0 {
        app.git_load_diff_commit(&g, g.commits[0].hash, g.commits[0].subject)
        testing.expect(t, len(g.diff) > 0)
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

    // In the diff region, Up/Down scroll the diff (and leave the sidebar selection put).
    g.region = .Diff
    append(&g.diff, app.DiffLine{kind = .Context, text = strings.clone("a")})
    append(&g.diff, app.DiffLine{kind = .Context, text = strings.clone("b")})
    app.git_move_sel(&g, 1)
    testing.expect_value(t, g.diff_scroll, 1)
    app.git_move_sel(&g, 5)
    testing.expect_value(t, g.diff_scroll, 1) // clamped to the last line
    testing.expect_value(t, g.sel_status, 0) // sidebar selection untouched
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

// git_set_diff parses a raw diff into tagged lines and records the title.
@(test)
test_set_diff :: proc(t: ^testing.T) {
    g: app.GitPane
    defer app.git_destroy(&g)
    app.git_set_diff(&g, "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n ctx", "x")
    testing.expect_value(t, g.diff_title, "x")
    testing.expect_value(t, len(g.diff), 5)
    testing.expect_value(t, g.diff[0].kind, app.DiffLineKind.Header)
    testing.expect_value(t, g.diff[1].kind, app.DiffLineKind.Hunk)
    testing.expect_value(t, g.diff[2].kind, app.DiffLineKind.Del)
    testing.expect_value(t, g.diff[3].kind, app.DiffLineKind.Add)
    testing.expect_value(t, g.diff[4].kind, app.DiffLineKind.Context)
}
