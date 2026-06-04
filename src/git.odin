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

// Holding Up/Down auto-scrolls the diff ONE line per tick, the tick rate ramping from
// slow to full speed over DIFF_SCROLL_RAMP seconds held (intervals in seconds — we adjust
// the rate, not the step). Alt+Up/Down jump whole hunks. The selection "playhead" is a
// line at the vertical CENTRE of the diff viewport (offset = diff_view_rows/2): whichever
// hunk overlaps it is selected; edge hunks reach the centre via over-scroll.
DIFF_SCROLL_SLOW :: 0.13 // first tick interval (slow start)
DIFF_SCROLL_FAST :: 0.018 // full-speed interval
DIFF_SCROLL_RAMP :: 1.0 // seconds of holding to reach full speed

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

// A body line of a hunk, tagged for colouring. (Hunk/Header kinds are produced by the
// classifier but only Context/Add/Del occur in a hunk body; the @@ and file-header lines
// live elsewhere — see DiffHunk / DiffFile.)
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

// One @@ hunk: its header line, its body lines, and the staging checkbox. The raw text
// (header + each line.text, verbatim) is what git_build_patch reassembles for git apply.
DiffHunk :: struct {
    header:   string, // the "@@ -a,b +c,d @@ ctx" line (owned)
    lines:    [dynamic]DiffLine, // body lines (owned)
    selected: bool, // the checkbox — included when staging the selection
}

// One file section of a diff: its header block (diff --git / index / --- / +++ / mode
// lines, owned verbatim so a patch can be rebuilt) and its hunks. `path` is the new-side
// path, for the block title only.
DiffFile :: struct {
    header: [dynamic]string, // file-header lines in order (owned)
    path:   string, // display path (owned); "" falls back to header[0]
    hunks:  [dynamic]DiffHunk,
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

    // The diff shown in the right column, parsed into files -> hunks so each hunk renders
    // as a block with a checkbox. diff_preamble holds any lines before the first file (a
    // `git show` commit header). hunk_cur is the focused hunk, flattened across files
    // (Up/Down move it; render centres on it). diff_stageable gates the checkboxes +
    // Tab-staging (true for a working diff, false when browsing a commit).
    diff_preamble:  [dynamic]string, // owned
    diff_files:     [dynamic]DiffFile, // owned
    diff_title:     string, // a path, a commit, or "working tree" (owned)
    hunk_cur:         int, // hunk under the playhead (derived in render); -1 when none
    diff_stageable:   bool, // checkboxes + Tab-stage active
    diff_scroll:      int, // target top DISPLAY row (may go negative: over-scroll to centre edge hunks)
    diff_scroll_anim: Anim, // the visual top (fractional rows) — the editor's smooth scroll
    diff_view_rows:   int, // visible diff rows, published by render so nav knows the playhead offset
    diff_recenter:    bool, // a fresh diff: render centres the first hunk on the playhead once
    scroll_dir:       int, // held auto-scroll direction (0 none / -1 up / +1 down)
    scroll_t0:        f64, // glfw time the hold began (drives the tick-rate ramp)
    scroll_next:      f64, // glfw time of the next auto-scroll tick
}

git_init :: proc(g: ^GitPane) {
    g.region = .Sidebar
}

git_destroy :: proc(g: ^GitPane) {
    git_clear(g)
    delete(g.status)
    delete(g.commits)
    delete(g.diff_preamble)
    delete(g.diff_files)
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

// Free the currently shown diff (preamble + files + hunks + title). Separate from
// git_clear so a diff can be swapped (git_set_diff) without touching the rest of the
// repo state. Frees nested backing arrays too; git_destroy frees the two top-level ones.
git_clear_diff :: proc(g: ^GitPane) {
    for s in g.diff_preamble {
        delete(s)
    }
    clear(&g.diff_preamble)
    for f in g.diff_files {
        for s in f.header {
            delete(s)
        }
        delete(f.header)
        delete(f.path)
        for h in f.hunks {
            delete(h.header)
            for l in h.lines {
                delete(l.text)
            }
            delete(h.lines)
        }
        delete(f.hunks)
    }
    clear(&g.diff_files)
    delete(g.diff_title)
    g.diff_title = ""
    g.hunk_cur = -1
    g.diff_stageable = false
    g.diff_scroll = 0
    g.diff_scroll_anim = Anim{} // snap (no slide from the previous diff)
    g.diff_view_rows = 0
    g.diff_recenter = false
    g.scroll_dir = 0 // cancel any held auto-scroll
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

// Up/Down in the SIDEBAR move the active section's selection. (The diff region's Up/Down
// is the held auto-scroll — git_scroll_*; the commit editor's caret arrives with its Doc.)
git_move_sel :: proc(g: ^GitPane, dir: int) {
    if g.region != .Sidebar {
        return
    }
    if g.section == .Status {
        if n := len(g.status); n > 0 {
            g.sel_status = clamp(g.sel_status + dir, 0, n - 1)
        }
    } else {
        if n := len(g.commits); n > 0 {
            g.sel_log = clamp(g.sel_log + dir, 0, n - 1)
        }
    }
}

// Total hunks across all files (the space hunk_cur indexes).
git_hunk_count :: proc(g: ^GitPane) -> int {
    n := 0
    for f in g.diff_files {
        n += len(f.hunks)
    }
    return n
}

// The hunk at flattened index `idx`, or nil. The pointer is valid until the diff is
// reloaded (used immediately by the caller).
git_hunk_ptr :: proc(g: ^GitPane, idx: int) -> ^DiffHunk {
    if idx < 0 {
        return nil
    }
    i := idx
    for fi in 0 ..< len(g.diff_files) {
        if i < len(g.diff_files[fi].hunks) {
            return &g.diff_files[fi].hunks[i]
        }
        i -= len(g.diff_files[fi].hunks)
    }
    return nil
}

// Space in the diff toggles the focused hunk's checkbox (only when stageable).
git_toggle_hunk :: proc(g: ^GitPane) {
    if !g.diff_stageable {
        return
    }
    if h := git_hunk_ptr(g, g.hunk_cur); h != nil {
        h.selected = !h.selected
    }
}

// The diff's total display rows. MUST match git_draw_diff's layout: the preamble lines,
// then per file a title row, then per hunk a header row + its body lines + a spacer row.
git_diff_rows :: proc(g: ^GitPane) -> int {
    n := len(g.diff_preamble)
    for f in g.diff_files {
        n += 1 // file title
        for h in f.hunks {
            n += 1 + len(h.lines) + 1 // header + body + spacer
        }
    }
    return n
}

// The display row of hunk k's header (where a jump scrolls so the hunk sits at the top).
git_hunk_top_row :: proc(g: ^GitPane, k: int) -> int {
    row := len(g.diff_preamble)
    idx := 0
    for f in g.diff_files {
        row += 1
        for h in f.hunks {
            if idx == k {
                return row
            }
            row += 1 + len(h.lines) + 1
            idx += 1
        }
    }
    return row
}

// The hunk "at the top" of a viewport scrolled to `row`: the last hunk whose header is at
// or above `row`, so its body fills the screen below. 0 when `row` is before the first.
git_hunk_at_row :: proc(g: ^GitPane, row: int) -> int {
    best := 0
    r := len(g.diff_preamble)
    idx := 0
    for f in g.diff_files {
        r += 1
        for h in f.hunks {
            if r <= row {
                best = idx
            }
            r += 1 + len(h.lines) + 1
            idx += 1
        }
    }
    return best
}

// The playhead's row offset from the top of the diff viewport — its vertical centre.
git_sel_offset :: proc(g: ^GitPane) -> int {
    return g.diff_view_rows / 2
}

// Scroll bounds so the playhead sweeps from the first hunk's header to the last:
// diff_scroll in [hunk_top(0)-offset, hunk_top(last)-offset]. lo may be negative (over-
// scroll: blank above lets the first hunk reach the centre). Both 0 when there are none.
git_scroll_lo :: proc(g: ^GitPane) -> int {
    if git_hunk_count(g) == 0 {
        return 0
    }
    return git_hunk_top_row(g, 0) - git_sel_offset(g)
}
git_scroll_hi :: proc(g: ^GitPane) -> int {
    n := git_hunk_count(g)
    if n == 0 {
        return 0
    }
    return git_hunk_top_row(g, n - 1) - git_sel_offset(g)
}

// Move the diff scroll target by `dir` rows (one line per auto-scroll tick; the visual
// position tweens via the smooth-scroll anim). The selected hunk is re-derived from the
// playhead in render. `dir` may be large in tests to exercise clamping.
git_diff_scroll :: proc(g: ^GitPane, dir: int) {
    if git_hunk_count(g) == 0 {
        return
    }
    g.diff_scroll = clamp(g.diff_scroll + dir, git_scroll_lo(g), git_scroll_hi(g))
}

// Begin (or continue) the held auto-scroll. A REPEAT for the same direction is ignored —
// our own ramping tick (git_scroll_pump) drives it, not the OS key-repeat rate.
git_scroll_start :: proc(g: ^GitPane, dir: int, now: f64) {
    if g.scroll_dir == dir {
        return
    }
    g.scroll_dir = dir
    g.scroll_t0 = now
    git_diff_scroll(g, dir) // the immediate first line
    g.scroll_next = now + DIFF_SCROLL_SLOW
}

// Stop the held auto-scroll when its arrow is released.
git_scroll_release :: proc(g: ^GitPane, dir: int) {
    if g.scroll_dir == dir {
        g.scroll_dir = 0
    }
}

// The current tick interval: ramps from SLOW to FAST over DIFF_SCROLL_RAMP seconds held.
git_scroll_interval :: proc(held: f64) -> f64 {
    s := clamp(held / DIFF_SCROLL_RAMP, 0.0, 1.0)
    return DIFF_SCROLL_SLOW + (DIFF_SCROLL_FAST - DIFF_SCROLL_SLOW) * s
}

// Per-frame pump (main loop): while an arrow is held in the focused diff, advance one line
// each time the (accelerating) tick is due. Stops itself if focus / region left the diff.
git_scroll_pump :: proc(a: ^App, now: f64) {
    g := &a.git
    if g.scroll_dir == 0 {
        return
    }
    if a.aux_mode != .Git || a.focus != .Aux || g.region != .Diff {
        g.scroll_dir = 0
        return
    }
    if now >= g.scroll_next {
        git_diff_scroll(g, g.scroll_dir)
        g.scroll_next = now + git_scroll_interval(now - g.scroll_t0)
    }
}

// Alt+Up/Down: target the previous/next hunk and scroll so it lands on the playhead.
git_diff_jump_hunk :: proc(g: ^GitPane, dir: int) {
    n := git_hunk_count(g)
    if n == 0 {
        return
    }
    k := clamp(g.hunk_cur + dir, 0, n - 1)
    g.diff_scroll = git_hunk_top_row(g, k) - git_sel_offset(g) // centres hunk k on the playhead
}

// A file is "staged" (so Space will UNstage it) when its index column shows a change
// and its worktree column is clean. Untracked ('?') and worktree-dirty entries are not.
git_is_staged :: proc(code: string) -> bool {
    return len(code) == 2 && code[0] != ' ' && code[0] != '?' && code[1] == ' '
}

// Space on a Status file toggles it staged/unstaged (file-level: git add / git reset),
// then reloads. Hunk-level staging comes later. No-op off the Status list. `git add`
// also stages deletions; `git reset` unstages back to the worktree.
git_stage_toggle :: proc(a: ^App) {
    g := &a.git
    if !g.is_repo || g.region != .Sidebar || g.section != .Status {
        return
    }
    if g.sel_status >= len(g.status) {
        return
    }
    e := g.status[g.sel_status]
    path := strings.clone(e.path, context.temp_allocator) // survives the reload below
    if git_is_staged(e.code) {
        git_run(g, "reset", "--", path)
    } else {
        git_run(g, "add", "--", path)
    }
    git_refresh(a) // re-read status + the working diff (selection is clamped, kept)
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

// The whole working-tree diff — the default "live" view (stageable per hunk), and where
// Alt+Q returns.
git_load_live :: proc(g: ^GitPane) {
    out, _ := git_run(g, "diff")
    git_set_diff(g, out, "working tree", true)
}

// The working diff for one path (Status -> Enter), stageable. Empty for an untracked or
// binary file — the renderer then shows "(no changes)". (-z gave a literal path.)
git_load_diff_file :: proc(g: ^GitPane, path: string) {
    out, _ := git_run(g, "diff", "--", path)
    git_set_diff(g, out, path, true)
}

// A commit's full diff (Log -> Enter), via `git show`. Read-only: not stageable.
git_load_diff_commit :: proc(g: ^GitPane, hash, subject: string) {
    out, _ := git_run(g, "show", hash)
    git_set_diff(g, out, fmt.tprintf("%s %s", hash, subject), false)
}

// Replace the shown diff: parse `raw` into files/hunks, set the title + stageable flag,
// and focus the first hunk. `title` and every line are cloned (owned).
git_set_diff :: proc(g: ^GitPane, raw, title: string, stageable: bool) {
    git_clear_diff(g)
    g.diff_title = strings.clone(title)
    g.diff_stageable = stageable
    git_parse_diff(g, raw)
    g.hunk_cur = git_hunk_count(g) > 0 ? 0 : -1
    g.diff_recenter = true // render centres the first hunk on the playhead once
}

// Parse unified-diff text into g.diff_preamble (anything before the first file — a
// `git show` commit header) and g.diff_files (each with its verbatim header block +
// hunks). Body lines are classified for colour; the @@ line and file-header lines are
// kept raw so git_build_patch can reassemble a valid patch.
git_parse_diff :: proc(g: ^GitPane, raw: string) {
    text := raw
    for line in strings.split_lines_iterator(&text) {
        if strings.has_prefix(line, "diff --git") {
            append(&g.diff_files, DiffFile{})
            append(&g.diff_files[len(g.diff_files) - 1].header, strings.clone(line))
            continue
        }
        fi := len(g.diff_files) - 1
        if fi < 0 {
            append(&g.diff_preamble, strings.clone(line))
            continue
        }
        if strings.has_prefix(line, "@@") {
            append(&g.diff_files[fi].hunks, DiffHunk{header = strings.clone(line)})
            continue
        }
        if len(g.diff_files[fi].hunks) == 0 {
            // file-header block (index / --- / +++ / mode / binary) before the first hunk
            append(&g.diff_files[fi].header, strings.clone(line))
            if strings.has_prefix(line, "+++ b/") {
                delete(g.diff_files[fi].path) // free the tentative "--- a/" path first
                g.diff_files[fi].path = strings.clone(line[6:])
            } else if g.diff_files[fi].path == "" && strings.has_prefix(line, "--- a/") {
                g.diff_files[fi].path = strings.clone(line[6:]) // tentative (deleted files: +++ is /dev/null)
            }
            continue
        }
        hi := len(g.diff_files[fi].hunks) - 1
        append(
            &g.diff_files[fi].hunks[hi].lines,
            DiffLine{kind = git_diff_classify(line), text = strings.clone(line)},
        )
    }
}

// Build a `git apply` patch from the checked hunks: for each file with >=1 selected hunk,
// its header block then those hunks (header + body lines), verbatim. Files with nothing
// selected are omitted; "" when nothing is selected at all.
git_build_patch :: proc(g: ^GitPane, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for f in g.diff_files {
        any := false
        for h in f.hunks {
            if h.selected {
                any = true
                break
            }
        }
        if !any {
            continue
        }
        for hl in f.header {
            strings.write_string(&b, hl)
            strings.write_byte(&b, '\n')
        }
        for h in f.hunks {
            if !h.selected {
                continue
            }
            strings.write_string(&b, h.header)
            strings.write_byte(&b, '\n')
            for l in h.lines {
                strings.write_string(&b, l.text)
                strings.write_byte(&b, '\n')
            }
        }
    }
    return strings.to_string(b)
}

// Write the patch to a temp file and apply it to the index. --recount lets a SUBSET of a
// file's hunks apply even though later hunks' @@ counts assumed the skipped ones. The
// temp file lives in .git (or the root as a fallback) and is removed before the reload,
// so it never appears in status.
git_apply_cached :: proc(g: ^GitPane, patch: string) -> bool {
    gitdir := filepath.join({g.root, ".git"}, context.temp_allocator) or_else ""
    base := os.is_dir(gitdir) ? gitdir : g.root
    tmp := filepath.join({base, "slopd-stage.patch"}, context.temp_allocator) or_else ""
    if tmp == "" {
        return false
    }
    if os.write_entire_file(tmp, transmute([]byte)patch) != nil {
        return false
    }
    defer os.remove(tmp)
    _, ok := git_run(g, "apply", "--cached", "--recount", tmp)
    return ok
}

// Tab in the diff: stage every checked hunk, then move to the commit editor. With nothing
// checked it just switches (a plain Tab). After staging, the working diff reloads so the
// staged hunks drop out.
git_stage_selected :: proc(a: ^App) {
    g := &a.git
    patch := git_build_patch(g, context.temp_allocator)
    if patch != "" {
        git_apply_cached(g, patch)
        git_refresh(a)
    }
    g.region = .Commit
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
