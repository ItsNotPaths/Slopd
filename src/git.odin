package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// GitPane — the Git aux mode's state (Sublime-Merge-lite, KB-only). The aux pane is
// split into two sub-columns: a SIDEBAR ported from Prawk's gitpane.nim (a branch
// strip, a working-tree Status section, and a Log) and a DIFF VIEWER / COMMIT EDITOR.
// Selecting in the sidebar loads a diff on the right; Alt+Q reverts a loaded diff to
// the live working tree.
//
// Phase 1 is being filled in incrementally; diff parsing, selection, and staging
// follow (see the "Git (aux mode)" section of plan.txt). Repo state is read by
// shelling out to the `git` CLI (git_run), the project's chosen porcelain.

// A repo search walks at most this many seconds before giving up. A parent walk is
// normally microseconds; the budget is insurance against a hung stat on a slow or
// network-mounted filesystem freezing the frame (detection runs on the main thread).
// It bounds the WALK as a whole, not a single blocking syscall — no userspace timer
// can interrupt one of those — but the walk is the only part we control.
REPO_FIND_BUDGET :: 3.0

// How many commits the Log loads. A bounded window keeps git_run cheap and the parse
// trivial; the sidebar only shows what fits anyway.
GIT_LOG_LIMIT :: 50

// One working-tree change from `git status --porcelain`: a two-char XY status code
// (index + worktree) and the path. Strings are owned by the GitPane.
StatusEntry :: struct {
    code: string, // the 2-char porcelain code ("M ", " M", "??", "A ", "D ", …)
    path: string, // the working-tree path
}

// One commit from `git log`. Strings are owned by the GitPane.
Commit :: struct {
    hash:    string, // abbreviated hash
    subject: string, // the summary line
}

// A single line of a parsed diff, tagged for colouring. Hunks (the @@ groups) aren't
// modelled as a tree yet — that grouping arrives with staging, which needs hunk
// boundaries; for viewing, a flat tagged list is all the renderer wants.
DiffLineKind :: enum {
    Context, // unchanged line (or anything unrecognised)
    Add, // +added
    Del, // -removed
    Hunk, // the @@ -a,b +c,d @@ header
    Header, // file headers (diff --git, index, ---, +++, mode/rename lines, Binary)
}

DiffLine :: struct {
    kind: DiffLineKind,
    text: string, // the raw line, owned
}

// Which sub-region of the git pane owns the arrows. Left/Right switch between the
// sidebar and the right column; within the right column Tab swaps its two states, so
// Diff and Commit are reached there (see git_move_region / git_tab). Up/Down act within
// the focused region.
GitRegion :: enum {
    Sidebar,
    Diff,
    Commit,
}

// The sidebar's two selectable sections (Prawk's GitSection): the working-tree changes
// (whose diffs load on the right) and the commit Log. Tab toggles between them while the
// sidebar is focused; Up/Down then move the selection within the active one.
GitSection :: enum {
    Status,
    Log,
}

GitPane :: struct {
    region:     GitRegion, // the focused sub-region (Left/Right move between them)
    section:    GitSection, // the active sidebar section (Tab toggles it)
    sel_status: int, // selected row in the Status list
    sel_log:    int, // selected row in the Log list
    root:       string, // the discovered repo working-tree root (owned); "" when none
    is_repo:    bool, // whether `root` names a real repo (set by git_refresh)
    branch:     string, // the checked-out branch (owned); "" when detached / none
    status:     [dynamic]StatusEntry, // working-tree changes (owned)
    commits:    [dynamic]Commit, // recent log on the current branch (owned)

    // The diff shown in the right column. Defaults to the whole working tree (the live
    // view); Enter on a Status file or a Log commit loads that instead; Alt+Q reverts to
    // live. diff_title names what's shown; diff_scroll is the top visible line.
    diff:        [dynamic]DiffLine, // parsed lines of the current diff (owned)
    diff_title:  string, // what the diff shows: a path, a commit, or "working tree" (owned)
    diff_scroll: int, // first visible diff line
}

git_init :: proc(g: ^GitPane) {
    g.region = .Sidebar
}

git_destroy :: proc(g: ^GitPane) {
    git_clear(g)
    delete(g.status)
    delete(g.commits)
    delete(g.diff)
}

// Drop all loaded repo state (so git_refresh is idempotent and git_destroy is clean).
// Frees every owned string and empties the lists; the backing arrays survive for reuse
// (git_destroy deletes those).
git_clear :: proc(g: ^GitPane) {
    delete(g.root)
    g.root = ""
    delete(g.branch)
    g.branch = ""
    for e in g.status {
        delete(e.code)
        delete(e.path)
    }
    clear(&g.status)
    for c in g.commits {
        delete(c.hash)
        delete(c.subject)
    }
    clear(&g.commits)
    git_clear_diff(g)
    g.is_repo = false
}

// Free the currently shown diff (its lines + title). Separate from git_clear so a diff
// can be swapped (git_set_diff) without touching the rest of the repo state.
git_clear_diff :: proc(g: ^GitPane) {
    for l in g.diff {
        delete(l.text)
    }
    clear(&g.diff)
    delete(g.diff_title)
    g.diff_title = ""
    g.diff_scroll = 0
}

// Left/Right switch between the two columns: the sidebar and the right (diff / commit)
// column. Entering the right column lands on the diff; Tab then swaps diff vs. commit
// message within it (git_tab). dir is +1 (Right) / -1 (Left). Alt+Left/Right still exits
// the git pane to the editor; this is in-pane only.
git_move_region :: proc(g: ^GitPane, dir: int) {
    if dir > 0 && g.region == .Sidebar {
        g.region = .Diff
    } else if dir < 0 && g.region != .Sidebar {
        g.region = .Sidebar
    }
}

// Tab swaps the focused column's two sub-modes: in the sidebar, Status <-> Log
// (Prawk-style); in the right column, diff browsing <-> the commit message editor.
git_tab :: proc(g: ^GitPane) {
    switch g.region {
    case .Sidebar:
        g.section = g.section == .Status ? .Log : .Status
    case .Diff:
        g.region = .Commit
    case .Commit:
        g.region = .Diff
    }
}

// Move the selection within the focused region with Up/Down: the active sidebar list,
// or the diff scroll. The commit editor's caret arrives with the message Doc.
git_move_sel :: proc(g: ^GitPane, dir: int) {
    switch g.region {
    case .Sidebar:
        if g.section == .Status {
            if n := len(g.status); n > 0 {
                g.sel_status = clamp(g.sel_status + dir, 0, n - 1)
            }
        } else {
            if n := len(g.commits); n > 0 {
                g.sel_log = clamp(g.sel_log + dir, 0, n - 1)
            }
        }
    case .Diff:
        if n := len(g.diff); n > 0 {
            g.diff_scroll = clamp(g.diff_scroll + dir, 0, n - 1)
        }
    case .Commit:
    // commit editor caret lands with the message Doc
    }
}

// Enter on a sidebar row loads its diff into the right column: a Status file's working
// diff, or a Log commit's full diff. No-op off the sidebar or on an empty list.
git_activate :: proc(a: ^App) {
    g := &a.git
    if !g.is_repo || g.region != .Sidebar {
        return
    }
    if g.section == .Status {
        if g.sel_status < len(g.status) {
            git_load_diff_file(g, g.status[g.sel_status].path)
        }
    } else {
        if g.sel_log < len(g.commits) {
            c := g.commits[g.sel_log]
            git_load_diff_commit(g, c.hash, c.subject)
        }
    }
}

// Re-detect the repo for the current project root and reload its state — called when
// the git pane gains focus (set_focus). Idempotent: clears prior state first, so it is
// safe to call on every focus-gain. Detection is a filesystem walk (git_find_repo);
// the branch / status / log then read through git_run.
git_refresh :: proc(a: ^App) {
    g := &a.git
    git_clear(g)
    root, ok := git_find_repo(a.project_root)
    if !ok {
        return
    }
    g.root = root
    g.is_repo = true
    git_load_branch(g)
    git_load_status(g)
    git_load_log(g)
    git_load_live(g) // default the diff to the whole working tree (the live view)
    // Keep selections in range across a reload (lists may shrink). Re-finding by identity
    // is a later refinement; clamping preserves position when it still exists.
    g.sel_status = clamp(g.sel_status, 0, max(0, len(g.status) - 1))
    g.sel_log = clamp(g.sel_log, 0, max(0, len(g.commits) - 1))
}

// Walk up from `start` until a git repo is found — a directory holding `.git` (a
// directory for a normal clone, or a FILE for a worktree/submodule, so os.exists covers
// both) — and return that directory: the working-tree root, cloned into `allocator`.
// Backtracking from the project root means a child working directory still resolves to
// its enclosing repo, which avoids "why is there no repo here?" confusion.
//
// Gives up after REPO_FIND_BUDGET seconds (see the constant). filepath.dir returns a
// slice of its input, so the walked path always aliases `start`'s storage and is never
// freed mid-walk; only the winning root is cloned.
git_find_repo :: proc(start: string, allocator := context.allocator) -> (root: string, ok: bool) {
    if start == "" {
        return "", false
    }
    begin := time.now()
    dir := start
    for {
        if time.duration_seconds(time.since(begin)) > REPO_FIND_BUDGET {
            return "", false // slow filesystem — bail rather than stall the frame
        }
        dot := filepath.join({dir, ".git"}, context.temp_allocator) or_else ""
        if os.exists(dot) {
            return strings.clone(dir, allocator), true
        }
        parent := filepath.dir(dir) // a slice of `dir`; aliases `start`, never freed here
        if parent == dir {
            return "", false // reached the filesystem root with no repo above
        }
        dir = parent
    }
}

// Run a git subcommand in the repo root, returning its stdout (temp-allocated) and
// whether it exited 0. No shell, so paths with spaces are safe and there is nothing to
// quote; os.process_exec reaps the child and frees the pipes (no fd leak). A failing
// command (e.g. `log` in a repo with no commits) just yields ok=false, which the
// loaders treat as "nothing to show".
git_run :: proc(g: ^GitPane, args: ..string) -> (out: string, ok: bool) {
    if !g.is_repo {
        return "", false
    }
    argv := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
    append(&argv, "git")
    append(&argv, ..args)
    state, sout, _, err := os.process_exec(
        os.Process_Desc{command = argv[:], working_dir = g.root},
        context.temp_allocator,
    )
    if err != nil {
        return "", false
    }
    return string(sout), state.exited && state.exit_code == 0
}

// The checked-out branch. Empty on a detached HEAD or an unborn branch — both render
// as "(detached)" rather than a name.
git_load_branch :: proc(g: ^GitPane) {
    if out, ok := git_run(g, "branch", "--show-current"); ok {
        g.branch = strings.clone(strings.trim_space(out))
    }
}

// The working tree, from `git status --porcelain -z`. The -z form is NUL-separated and
// leaves paths LITERAL (no quoting/escaping), so they can be passed straight to
// `git diff -- <path>`. Each record is "XY <space> path"; a rename/copy (X is R/C) adds a
// following field with the original path, which we skip. A clean tree yields no records.
git_load_status :: proc(g: ^GitPane) {
    out, ok := git_run(g, "status", "--porcelain", "-z")
    if !ok {
        return
    }
    fields := strings.split(out, "\x00", context.temp_allocator)
    i := 0
    for i < len(fields) {
        rec := fields[i]
        i += 1
        if len(rec) < 4 {
            continue // the trailing empty field after the final NUL
        }
        code := rec[:2]
        append(&g.status, StatusEntry{code = strings.clone(code), path = strings.clone(rec[3:])})
        if code[0] == 'R' || code[0] == 'C' {
            i += 1 // rename/copy: the next field is the original path — consume it
        }
    }
}

// The recent log on the current branch: hash + subject, tab-separated so subjects with
// spaces stay intact. Bounded to GIT_LOG_LIMIT.
git_load_log :: proc(g: ^GitPane) {
    out, ok := git_run(g, "log", "-n", fmt.tprintf("%d", GIT_LOG_LIMIT), "--pretty=format:%h\t%s")
    if !ok {
        return
    }
    text := out
    for line in strings.split_lines_iterator(&text) {
        tab := strings.index_byte(line, '\t')
        if tab < 0 {
            continue
        }
        append(&g.commits, Commit{hash = strings.clone(line[:tab]), subject = strings.clone(line[tab + 1:])})
    }
}

// The whole working-tree diff — the default "live" view, and where Alt+Q returns.
git_load_live :: proc(g: ^GitPane) {
    out, _ := git_run(g, "diff")
    git_set_diff(g, out, "working tree")
}

// The working diff for one path (Status -> Enter). Empty for an untracked or binary file
// — the renderer then shows "(no changes)". (-z gave us a literal path, safe to pass.)
git_load_diff_file :: proc(g: ^GitPane, path: string) {
    out, _ := git_run(g, "diff", "--", path)
    git_set_diff(g, out, path)
}

// A commit's full diff (Log -> Enter), via `git show`.
git_load_diff_commit :: proc(g: ^GitPane, hash, subject: string) {
    out, _ := git_run(g, "show", hash)
    git_set_diff(g, out, fmt.tprintf("%s %s", hash, subject))
}

// Replace the shown diff: parse `raw` into tagged lines and set the title. Resets the
// scroll to the top. `title` and each line are cloned (owned).
git_set_diff :: proc(g: ^GitPane, raw, title: string) {
    git_clear_diff(g)
    g.diff_title = strings.clone(title)
    text := raw
    for line in strings.split_lines_iterator(&text) {
        append(&g.diff, DiffLine{kind = git_diff_classify(line), text = strings.clone(line)})
    }
}

// Tag a diff line for colouring. Order matters: hunk headers and the file-header block
// (which includes the "--- " / "+++ " lines) are matched before the bare +/- content
// lines so those headers aren't mistaken for additions/deletions.
git_diff_classify :: proc(line: string) -> DiffLineKind {
    switch {
    case strings.has_prefix(line, "@@"):
        return .Hunk
    case strings.has_prefix(line, "diff "),
         strings.has_prefix(line, "index "),
         strings.has_prefix(line, "--- "),
         strings.has_prefix(line, "+++ "),
         strings.has_prefix(line, "new file"),
         strings.has_prefix(line, "deleted file"),
         strings.has_prefix(line, "old mode"),
         strings.has_prefix(line, "new mode"),
         strings.has_prefix(line, "similarity"),
         strings.has_prefix(line, "rename "),
         strings.has_prefix(line, "copy "),
         strings.has_prefix(line, "Binary files"):
        return .Header
    case strings.has_prefix(line, "+"):
        return .Add
    case strings.has_prefix(line, "-"):
        return .Del
    case:
        return .Context
    }
}
