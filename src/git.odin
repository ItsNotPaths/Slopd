package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// GitPane — the Git aux mode's state (Sublime-Merge-lite, KB-only). The aux pane is split
// into two sub-columns: a SIDEBAR ported from Prawk's gitpane.nim (a branch strip, a
// folder-grouped working-tree Status section, and a Log) and a persistent DIFF VIEWER +
// COMMIT EDITOR. The right column always shows the full working-tree diff; the sidebar and
// the grep bar FILTER it, the hunk checkboxes are the commit selection, and Ctrl+Enter
// commits the checked set. Alt+Q reverts a browsed commit back to the live working tree.
//
// Repo state is read by shelling out to the `git` CLI (git_run), the project's chosen
// porcelain. See the "Git (aux mode)" section of plan.txt for the full design.

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
DIFF_SCROLL_SLOW :: 0.12 // first tick interval (slow start)
DIFF_SCROLL_FAST :: 0.010 // full-speed interval (higher top speed)
DIFF_SCROLL_RAMP :: 0.4 // seconds of holding to reach full speed (snappy ramp-up)

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

// Which side of a merge conflict a conflict hunk resolves to. Space cycles it
// Unresolved -> Ours -> Theirs -> Both -> Unresolved; the displayed body (DiffHunk.lines)
// is rebuilt to match (git_conflict_render), and Unresolved gates the merge from
// completing (git_merge_finish). The checkbox idiom widened from a 2-state toggle to this.
ConflictChoice :: enum {
    Unresolved, // still showing both sides (the raw conflict) — not committable
    Ours, // keep the HEAD side
    Theirs, // keep the incoming side
    Both, // ours then theirs, concatenated
}

// One @@ hunk: its header line, its body lines, and the staging checkbox. The raw text
// (header + each line.text, verbatim) is what git_build_patch reassembles for git apply.
// `hidden` is derived (git_filter_apply) from the grep query — a hidden hunk drops out of
// layout, nav, and render so the playhead only ever lands on a visible one.
//
// A CONFLICT hunk (set during a merge — see git_parse_conflicts) reuses the same block, but
// `lines` is a rebuilt VIEW of the chosen side rather than diff text: `ours`/`theirs` hold
// the two raw sides, `choice` picks between them (Space cycles it), and `pre` is the
// verbatim clean run between the previous region and this one, kept so the resolved file can
// be reconstructed exactly (git_resolve_content). `selected` is unused for conflict hunks.
DiffHunk :: struct {
    header:   string, // the "@@ -a,b +c,d @@ ctx" line (owned); "conflict" for a conflict hunk
    lines:    [dynamic]DiffLine, // body lines (owned); for a conflict hunk, the rendered chosen side
    selected: bool, // the checkbox — included in the commit selection
    hidden:   bool, // filtered out by the grep query (derived)

    conflict: bool, // a merge-conflict region: Space cycles `choice` instead of toggling `selected`
    choice:   ConflictChoice, // which side wins (conflict hunks only)
    ours:     [dynamic]string, // the HEAD side, raw lines (conflict only, owned)
    theirs:   [dynamic]string, // the incoming side, raw lines (conflict only, owned)
    pre:      [dynamic]string, // verbatim lines preceding this region (conflict only, owned) — for reconstruction
}

// One file section of a diff: its header block (diff --git / index / --- / +++ / mode
// lines, owned verbatim so a patch can be rebuilt) and its hunks. `path` is the new-side
// path, for the block title only. `hidden` (derived) drops a file whose every hunk was
// filtered out, so its title row goes with them. A CONFLICT file (`conflict`) holds conflict
// hunks instead of diff hunks; `tail` is the verbatim clean run after the last region.
DiffFile :: struct {
    header: [dynamic]string, // file-header lines in order (owned)
    path:   string, // display path (owned); "" falls back to header[0]
    hunks:  [dynamic]DiffHunk,
    hidden: bool, // no visible hunk passes the grep query (derived)

    conflict: bool, // a merge-conflicted file (its hunks are conflict regions)
    tail:     [dynamic]string, // verbatim lines after the last conflict region (owned)
}

// Which sub-region of the git pane owns the arrows. Left/Right switch between the
// sidebar and the right column; within the right column Tab cycles its three states —
// the Grep filter bar, the Diff list, and the Commit message (see git_move_region /
// git_tab). Up/Down act within the focused region. '/' jumps straight to Grep.
GitRegion :: enum {
    Sidebar,
    Grep,
    Select, // the select-all / deselect-all toggle button (beside the grep bar)
    Diff,
    Commit,
}

// The sidebar's selectable sections (Prawk's GitSection): the branch strip (where
// Left/Right swap branches), the working-tree Status (whose files filter the diff), and the
// commit Log. Tab cycles between them while the sidebar is focused; Up/Down then move the
// selection within Status/Log (Branch uses Left/Right).
GitSection :: enum {
    Status,
    Log,
    Branch,
}

// An in-progress repo operation that owns the working tree until it's resolved or aborted —
// detected from `.git` on every refresh (git_detect_op). While one is in flight the right
// column becomes a RESOLUTION view (conflict hunks + finish/abort) and the normal staging
// commit recipe is locked out (its `git reset` would wipe the unmerged index). Only Merge is
// modelled for now; the enum leaves room for cherry-pick / rebase to share the same machinery.
GitOp :: enum {
    None,
    Merge, // a `git merge` left conflicts to resolve (.git/MERGE_HEAD present)
}

// Why the git pane is waiting on the command line. Set when the pane HANDS the CL a
// command (a commit recipe, or a slot-machine payout) so it can react when that command
// ships or is dropped — the pane's one piece of CL feedback (git_cl_settle, driven by
// cl_submit / cl_cancel). None when the pane isn't waiting on anything.
GitCLKind :: enum {
    None,
    Commit, // a real commit recipe: clear the message + selection once it ships
    Spin,   // a slot-machine payout: unwind the spin whether it ships or is dropped
}

// The "lucky dip" slot-machine gag (Ctrl+Shift+Alt+S). The live diff is moved into the
// saved_* snapshot and replaced by shuffled, repeated single-hunk REELS in g.diff_files,
// which then scroll past a FIXED centre reticle and decelerate (spin_ease: gentle wind-up,
// long settle) onto a RANDOM resting row `to` — the reticle stops wherever it lands, top or
// middle or bottom of a hunk, uncontrolled. On land the hunk under it wins: a commit for it
// is injected with a lucky message, and the CL's outcome triggers git_spin_restore, which
// moves the snapshot back. The motion is driven directly from start_t (git_spin_disp), not
// the smooth-scroll anim. See git_spin_begin / git_spin_pump / git_spin_restore.
GitSpin :: struct {
    active:          bool, // a spin is on screen (decelerating, or awaiting its CL payout)
    landed:          bool, // the reels have stopped — the payout was injected
    start_t:         f64, // glfw time the spin began (drives the easing)
    from:            f32, // start scroll row (the top of the reel run)
    to:              f32, // the RANDOM resting scroll row — the winner is whatever it rests on
    saved_files:     [dynamic]DiffFile, // the pre-spin diff, moved aside (restored on payout)
    saved_preamble:  [dynamic]string,
    saved_title:     string,
    saved_scroll:    int,
    saved_stageable: bool,
}

GitPane :: struct {
    region:     GitRegion, // the focused sub-region (Left/Right move between them)
    section:    GitSection, // the active sidebar section (Tab toggles it)
    sel_status: int, // selected row in the Status list
    sel_log:    int, // selected row in the Log list
    sel_branch: int, // hovered row in the branch strip (Left/Right cycle it)
    root:       string, // the discovered repo working-tree root (owned); "" when none
    is_repo:    bool, // whether `root` names a real repo (set by git_refresh)
    branch:     string, // the checked-out branch (owned); "" when detached / none
    branches:   [dynamic]string, // all local branch names (owned), for the swap strip
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

    // The diff/commit column's two text fields (region == .Grep / .Commit). grep is a
    // single-line live filter over the always-on diff (path OR body match); commit_msg is
    // the multi-line message Ctrl+Enter commits the checked hunks under. Both persist
    // across a diff swap / refresh (you stay mid-filter / mid-message); freed in destroy.
    grep:       Doc, // the diff filter query; empty = show everything
    commit_msg: Doc, // the commit message editor
    hunk_cur:         int, // hunk under the playhead (derived in render); -1 when none
    diff_stageable:   bool, // checkboxes + Tab-stage active
    diff_scroll:      int, // target top DISPLAY row (may go negative: over-scroll to centre edge hunks)
    diff_scroll_anim: Anim, // the visual top (fractional rows) — the editor's smooth scroll
    diff_view_rows:   int, // visible diff rows, published by render so nav knows the playhead offset
    diff_recenter:    bool, // a fresh diff: render centres the first hunk on the playhead once
    scroll_dir:       int, // held auto-scroll direction (0 none / -1 up / +1 down)
    scroll_t0:        f64, // glfw time the hold began (drives the tick-rate ramp)
    scroll_next:      f64, // glfw time of the next auto-scroll tick

    cl_wait: GitCLKind, // why the pane is waiting on the command line (CL feedback)
    spin:    GitSpin, // the slot-machine gag, when one is running

    // An in-progress merge, detected from `.git` on refresh (git_detect_op). When op is
    // .Merge the diff column shows the conflicted files as conflict hunks (Space cycles each
    // region's resolution) and the commit strip becomes finish/abort instead of the staging
    // commit. merge_title is the pending merge's message (`.git/MERGE_MSG`, owned).
    op:          GitOp,
    merge_title: string, // owned; the in-progress merge's message line, for the diff title
}

git_init :: proc(g: ^GitPane) {
    g.region = .Sidebar
    doc_init(&g.grep)
    doc_init(&g.commit_msg)
}

git_destroy :: proc(g: ^GitPane) {
    git_clear(g)
    delete(g.status)
    delete(g.commits)
    delete(g.branches)
    delete(g.diff_preamble)
    delete(g.diff_files)
    doc_destroy(&g.grep)
    doc_destroy(&g.commit_msg)
}

// Drop all loaded repo state (so git_refresh is idempotent and git_destroy is clean).
// Frees every owned string and empties the lists; the backing arrays survive for reuse
// (git_destroy deletes those).
git_clear :: proc(g: ^GitPane) {
    git_spin_discard(g) // drop any in-flight gag's snapshot before its diff is freed below
    delete(g.root)
    g.root = ""
    delete(g.branch)
    g.branch = ""
    for b in g.branches {
        delete(b)
    }
    clear(&g.branches)
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
    delete(g.merge_title)
    g.merge_title = ""
    g.op = .None
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
    git_free_files(g.diff_files)
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

// Free a diff-file list's contents (header lines, path, hunks, body lines) WITHOUT
// touching the backing array — the caller clears or deletes that. Shared by git_clear_diff
// and the slot machine's snapshot teardown (git_spin_discard).
git_free_files :: proc(files: [dynamic]DiffFile) {
    for f in files {
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
            // Conflict-hunk extras (empty + harmless for a normal diff hunk).
            for s in h.ours {
                delete(s)
            }
            delete(h.ours)
            for s in h.theirs {
                delete(s)
            }
            delete(h.theirs)
            for s in h.pre {
                delete(s)
            }
            delete(h.pre)
        }
        delete(f.hunks)
        for s in f.tail {
            delete(s)
        }
        delete(f.tail)
    }
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

// Tab cycles the focused column's sub-modes: in the sidebar, Status -> Log -> Branch (the
// branch swap strip) -> Status; in the right column, Grep -> Select (the select-all toggle)
// -> Diff -> Commit -> Grep.
git_tab :: proc(g: ^GitPane) {
    switch g.region {
    case .Sidebar:
        switch g.section {
        case .Status: g.section = .Log
        case .Log:    g.section = .Branch
        case .Branch: g.section = .Status
        }
    case .Grep:
        g.region = .Select
    case .Select:
        g.region = .Diff
    case .Diff:
        g.region = .Commit
    case .Commit:
        g.region = .Grep
    }
}

// The grep query, lowercased and trimmed for case-insensitive substring matching.
git_grep_query :: proc(g: ^GitPane, allocator := context.temp_allocator) -> string {
    return strings.to_lower(strings.trim_space(doc_string(&g.grep, allocator)), allocator)
}

// Replace the grep query (Status Enter jumps the always-on diff to one file's hunks).
git_set_grep :: proc(g: ^GitPane, text: string) {
    doc_set_text(&g.grep, text)
    doc_cursor_to_end(&g.grep)
    git_filter_apply(g)
}

// Recompute per-hunk / per-file visibility against the current grep query. MULTISEARCH:
// the query splits on '+' into trimmed terms, OR'd — a hunk shows when the query is empty,
// or some term matches the file's path or one of its body lines. A file shows when any of
// its hunks shows (or, for a header-only file, when its path matches). With an empty query
// nothing is hidden, so layout/nav are unchanged. Re-aims the playhead at the first match
// (recenter) so it never sits on a hidden hunk. NOTE: '+' is purely the term separator, so a
// literal '+' can't be searched (e.g. "+foo" filters as "foo") — fine since body content is
// matched substring-wise regardless of the diff's +/- column.
git_filter_apply :: proc(g: ^GitPane) {
    terms := make([dynamic]string, 0, 4, context.temp_allocator)
    for part in strings.split(git_grep_query(g), "+", context.temp_allocator) {
        if s := strings.trim_space(part); s != "" {
            append(&terms, s)
        }
    }
    for &f in g.diff_files {
        path_lower := strings.to_lower(f.path, context.temp_allocator)
        path_hit := len(terms) == 0 || git_any_term(path_lower, terms[:])
        vis_any := false
        for &h in f.hunks {
            hit := path_hit
            if !hit {
                for l in h.lines {
                    if git_any_term(strings.to_lower(l.text, context.temp_allocator), terms[:]) {
                        hit = true
                        break
                    }
                }
            }
            h.hidden = !hit
            vis_any |= hit
        }
        f.hidden = len(f.hunks) == 0 ? !path_hit : !vis_any
    }
    g.hunk_cur = git_hunk_count(g) > 0 ? 0 : -1
    g.diff_recenter = true // render re-centres the first visible hunk on the playhead
}

// Whether `text` (already lowercased) contains any of the OR terms.
git_any_term :: proc(text: string, terms: []string) -> bool {
    for term in terms {
        if strings.contains(text, term) {
            return true
        }
    }
    return false
}

// Set every hunk that PASSES the current filter to `on`. Hidden hunks keep their checkbox —
// you only ever act on what you can see.
git_check_filtered :: proc(g: ^GitPane, on: bool) {
    for &f in g.diff_files {
        for &h in f.hunks {
            if !h.hidden {
                h.selected = on
            }
        }
    }
}

// The Select button: deselect-all if ANY visible hunk is checked, else select-all. The
// rule auto-cycles the single button between the two actions.
git_toggle_all :: proc(g: ^GitPane) {
    any := false
    outer: for &f in g.diff_files {
        for &h in f.hunks {
            if !h.hidden && h.selected {
                any = true
                break outer
            }
        }
    }
    git_check_filtered(g, !any)
}

// Whether any visible (filtered-in) hunk is currently checked — drives the Select button's
// label (select-all vs deselect-all) and its count.
git_any_checked :: proc(g: ^GitPane) -> bool {
    for f in g.diff_files {
        for h in f.hunks {
            if !h.hidden && h.selected {
                return true
            }
        }
    }
    return false
}

// Up/Down in the SIDEBAR move the active section's selection (Status / Log lists). The
// Branch strip uses Left/Right (git_branch_cycle), so Up/Down do nothing there. (The diff
// region's Up/Down is the held auto-scroll — git_scroll_*; the commit caret arrives with
// its Doc.)
git_move_sel :: proc(g: ^GitPane, dir: int) {
    if g.region != .Sidebar {
        return
    }
    switch g.section {
    case .Status:
        if n := len(g.status); n > 0 {
            g.sel_status = clamp(g.sel_status + dir, 0, n - 1)
        }
    case .Log:
        if n := len(g.commits); n > 0 {
            g.sel_log = clamp(g.sel_log + dir, 0, n - 1)
        }
    case .Branch:
    }
}

// Total VISIBLE hunks across all files — the space hunk_cur indexes (the playhead only
// lands on hunks passing the grep filter).
git_hunk_count :: proc(g: ^GitPane) -> int {
    n := 0
    for f in g.diff_files {
        for h in f.hunks {
            if !h.hidden {
                n += 1
            }
        }
    }
    return n
}

// The visible hunk at flattened index `idx` (hidden hunks skipped), or nil. The pointer is
// valid until the diff is reloaded (used immediately by the caller).
git_hunk_ptr :: proc(g: ^GitPane, idx: int) -> ^DiffHunk {
    if idx < 0 {
        return nil
    }
    i := idx
    for fi in 0 ..< len(g.diff_files) {
        for hi in 0 ..< len(g.diff_files[fi].hunks) {
            if g.diff_files[fi].hunks[hi].hidden {
                continue
            }
            if i == 0 {
                return &g.diff_files[fi].hunks[hi]
            }
            i -= 1
        }
    }
    return nil
}

// Space in the diff toggles the focused hunk's checkbox (only when stageable).
git_toggle_hunk :: proc(g: ^GitPane) {
    h := git_hunk_ptr(g, g.hunk_cur)
    if h == nil {
        return
    }
    if h.conflict {
        git_cycle_conflict(h) // a conflict region cycles its resolution instead of staging
    } else if g.diff_stageable {
        h.selected = !h.selected
    }
}

// The diff's total VISIBLE display rows. MUST match git_draw_diff's layout: the preamble
// lines, then per visible file a title row, then per visible hunk a header row + its body
// lines + a spacer row. Hidden files/hunks (filtered out) take no rows.
git_diff_rows :: proc(g: ^GitPane) -> int {
    n := len(g.diff_preamble)
    for f in g.diff_files {
        if f.hidden {
            continue
        }
        n += 1 // file title
        for h in f.hunks {
            if h.hidden {
                continue
            }
            n += 1 + len(h.lines) + 1 // header + body + spacer
        }
    }
    return n
}

// The display row of visible hunk k's header (where a jump scrolls so the hunk sits at the
// top). k indexes the visible sequence (hidden hunks skipped), matching hunk_cur.
git_hunk_top_row :: proc(g: ^GitPane, k: int) -> int {
    row := len(g.diff_preamble)
    idx := 0
    for f in g.diff_files {
        if f.hidden {
            continue
        }
        row += 1
        for h in f.hunks {
            if h.hidden {
                continue
            }
            if idx == k {
                return row
            }
            row += 1 + len(h.lines) + 1
            idx += 1
        }
    }
    return row
}

// The visible hunk "at the top" of a viewport scrolled to `row`: the last visible hunk
// whose header is at or above `row`, so its body fills the screen below. 0 when `row` is
// before the first.
git_hunk_at_row :: proc(g: ^GitPane, row: int) -> int {
    best := 0
    r := len(g.diff_preamble)
    idx := 0
    for f in g.diff_files {
        if f.hidden {
            continue
        }
        r += 1
        for h in f.hunks {
            if h.hidden {
                continue
            }
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

// Scroll bounds so the playhead sweeps from the first hunk's header to the last, with extra
// room at the bottom so a tall final hunk fully clears the commit bar. lo may be negative
// (over-scroll: blank above lets the first hunk reach the centre). Both 0 when there are none.
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
    // The last hunk's header centred on the playhead, OR — when that hunk is taller than
    // half the viewport — far enough that its LAST line clears the bottom of the band (the
    // commit bar), whichever scrolls further. Without the second term a tall final hunk
    // stays cut off below the commit box.
    centre_last := git_hunk_top_row(g, n - 1) - git_sel_offset(g)
    clear_last := git_diff_rows(g) - g.diff_view_rows
    return max(centre_last, clear_last)
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

// Space on a Status file: check (or uncheck) every hunk of that file in the always-on
// diff — file-level selection without touching the index, so the hunks stay VISIBLE (you
// see what you're committing) rather than vanishing. If all its hunks are already checked,
// the toggle clears them; otherwise it checks them all. No-op off the Status list, or on a
// file with no diff hunks (untracked / binary).
git_stage_toggle :: proc(a: ^App) {
    g := &a.git
    if !g.is_repo || g.op == .Merge || g.region != .Sidebar || g.section != .Status {
        return // checkbox staging is locked out while a merge is being resolved
    }
    if g.sel_status >= len(g.status) {
        return
    }
    path := g.status[g.sel_status].path
    all, any := true, false
    for &f in g.diff_files {
        if f.path != path {
            continue
        }
        for &h in f.hunks {
            any = true
            all &&= h.selected
        }
    }
    if !any {
        return
    }
    want := !all // every hunk already checked -> clear; otherwise check them all
    for &f in g.diff_files {
        if f.path != path {
            continue
        }
        for &h in f.hunks {
            h.selected = want
        }
    }
}

// Enter on a sidebar row, by section: Branch injects `git checkout <hovered>`; a Status
// file FILTERS the always-on diff to its path (grep set, focus moves to the diff) instead
// of loading a separate per-file view; a Log commit loads its full read-only diff. No-op
// off the sidebar or on an empty list.
git_activate :: proc(a: ^App) {
    g := &a.git
    if !g.is_repo || g.region != .Sidebar {
        return
    }
    switch g.section {
    case .Branch:
        git_checkout_inject(a)
    case .Status:
        if g.sel_status < len(g.status) {
            git_set_grep(g, g.status[g.sel_status].path)
            g.region = .Diff
        }
    case .Log:
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
    git_load_branches(g)
    git_load_status(g)
    git_load_log(g)
    git_detect_op(g) // a merge in progress flips the right column to conflict resolution
    if g.op == .Merge {
        git_load_conflicts(g) // the conflicted files, as resolvable conflict hunks
    } else {
        git_load_live(g) // default the diff to the whole working tree (the live view)
    }
    // Keep selections in range across a reload (lists may shrink). Re-finding by identity
    // is a later refinement; clamping preserves position when it still exists.
    g.sel_status = clamp(g.sel_status, 0, max(0, len(g.status) - 1))
    g.sel_log = clamp(g.sel_log, 0, max(0, len(g.commits) - 1))
    git_sel_branch_to_current(g) // hover the checked-out branch by default
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

// All local branches (the swap strip), one name per line via the plumbing format (no `*`
// decoration to strip). Order is git's own (alphabetical); the current branch is among them.
git_load_branches :: proc(g: ^GitPane) {
    out, ok := git_run(g, "branch", "--format=%(refname:short)")
    if !ok {
        return
    }
    text := out
    for line in strings.split_lines_iterator(&text) {
        name := strings.trim_space(line)
        if name != "" {
            append(&g.branches, strings.clone(name))
        }
    }
}

// Park the branch-strip hover on the checked-out branch (so it opens pointing at "you are
// here"). Falls back to 0 when the current branch isn't in the list (detached HEAD).
git_sel_branch_to_current :: proc(g: ^GitPane) {
    g.sel_branch = 0
    for b, i in g.branches {
        if b == g.branch {
            g.sel_branch = i
            return
        }
    }
}

// Left/Right on the branch strip move the hover; clamped to the list.
git_branch_cycle :: proc(g: ^GitPane, dir: int) {
    if n := len(g.branches); n > 0 {
        g.sel_branch = clamp(g.sel_branch + dir, 0, n - 1)
    }
}

// Enter on the branch strip: stage (or run, per git_checkout) `git checkout <hovered>` in
// the command line. No-op when the hover is already the checked-out branch or the list is
// empty.
git_checkout_inject :: proc(a: ^App) {
    g := &a.git
    if g.sel_branch < 0 || g.sel_branch >= len(g.branches) {
        return
    }
    target := g.branches[g.sel_branch]
    if target == g.branch {
        return // already on it
    }
    cl_dispatch(a, fmt.tprintf("git checkout %s", target), a.git_checkout_run)
}

// Space on the branch strip (when no merge is already in flight): stage (or run, per
// git_merge) `git merge <hovered>` to bring that branch's commits into the current one.
// `--no-edit` keeps git from opening $EDITOR for the merge message (which would hang the
// injected shell step). Trailing `|| true && gr` makes the pane refresh whatever the
// outcome — a CONFLICTING merge exits non-zero, and we still need to surface the conflicts.
// No-op on the current branch, an empty list, a detached HEAD, or mid-merge.
git_merge_inject :: proc(a: ^App) {
    g := &a.git
    if g.op != .None || g.sel_branch < 0 || g.sel_branch >= len(g.branches) {
        return
    }
    target := g.branches[g.sel_branch]
    if target == g.branch || target == "" {
        return
    }
    cmd := fmt.tprintf(`git -C "%s" merge --no-edit "%s" || true && gr`, g.root, target)
    cl_dispatch(a, cmd, a.git_merge_run)
}

// The grep bar's right button (region .Select): the select-all / deselect-all toggle
// normally, the merge ABORT button while a merge is being resolved.
git_select_action :: proc(a: ^App) {
    if a.git.op == .Merge {
        git_merge_abort(a)
    } else {
        git_toggle_all(&a.git)
    }
}

// The merge ABORT button (the grep bar's right slot during a merge): throw the merge away and
// return the working tree to pre-merge HEAD.
git_merge_abort :: proc(a: ^App) {
    g := &a.git
    if g.op != .Merge {
        return
    }
    cl_dispatch(a, fmt.tprintf(`git -C "%s" merge --abort || true && gr`, g.root), a.git_merge_run)
}

// FINISH a merge: write every fully-resolved conflict file (no Unresolved hunk) back to the
// working tree, then stage them; and when EVERY conflicted file is resolved, commit to
// complete the merge (--no-edit reuses git's prepared MERGE_MSG). A partial pass just writes
// + stages what's ready, so resolving can proceed file by file. No-op until at least one file
// is fully resolved. `|| true && gr` refreshes the pane regardless of the commit's outcome.
git_merge_finish :: proc(a: ^App) {
    g := &a.git
    if g.op != .Merge {
        return
    }
    paths := make([dynamic]string, 0, len(g.diff_files), context.temp_allocator)
    for &f in g.diff_files {
        if !f.conflict {
            continue
        }
        resolved := true
        for h in f.hunks {
            if h.choice == .Unresolved {
                resolved = false
                break
            }
        }
        if !resolved {
            continue
        }
        full := filepath.join({g.root, f.path}, context.temp_allocator) or_else ""
        content := git_resolve_content(&f, context.temp_allocator)
        if full == "" || os.write_entire_file(full, transmute([]byte)content) != nil {
            continue
        }
        append(&paths, f.path)
    }
    if len(paths) == 0 {
        return // nothing fully resolved yet
    }
    // Every conflicted path in the working tree (some may have no inline markers and thus no
    // diff file) — we can only commit once all of them are accounted for.
    total := 0
    for e in g.status {
        if git_is_conflict(e.code) {
            total += 1
        }
    }
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b, `git -C "%s" add --`, g.root)
    for p in paths {
        fmt.sbprintf(&b, ` "%s"`, p)
    }
    if len(paths) == total {
        fmt.sbprintf(&b, ` && git -C "%s" commit --no-edit`, g.root)
    }
    cl_dispatch(a, fmt.tprintf("%s || true && gr", strings.to_string(b)), a.git_merge_run)
}

// The working tree, from `git status --porcelain -z`. The -z form is NUL-separated and
// leaves paths LITERAL (no quoting/escaping), so they can be passed straight to
// `git diff -- <path>`. Each record is "XY <space> path"; a rename/copy (X is R/C) adds a
// following field with the original path, which we skip. A clean tree yields no records.
// Sorted by path so same-folder files cluster — the sidebar groups them under directory
// headers, and Up/Down then walks them in the order they're shown.
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
    slice.sort_by(g.status[:], proc(a, b: StatusEntry) -> bool {
        return strings.compare(a.path, b.path) < 0
    })
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

// The whole working-tree diff against HEAD — the always-on view (every uncommitted hunk,
// staged or not, so checking/unchecking never makes a row vanish), and where Alt+Q returns.
// Falls back to a plain `git diff` on an unborn HEAD (a repo with no commits yet).
git_load_live :: proc(g: ^GitPane) {
    out, ok := git_run(g, "diff", "HEAD")
    if !ok {
        out, _ = git_run(g, "diff") // unborn branch: no HEAD to diff against
    }
    git_set_diff(g, out, "working tree", true)
}

// The absolute path of the repo's git directory (`.git`, or elsewhere for a worktree /
// submodule), via rev-parse so worktrees resolve correctly. Trimmed, temp-allocated; "" on
// failure. Used to probe for in-progress-operation sentinels (MERGE_HEAD, MERGE_MSG).
git_gitdir :: proc(g: ^GitPane) -> string {
    if out, ok := git_run(g, "rev-parse", "--absolute-git-dir"); ok {
        return strings.trim_space(out)
    }
    return ""
}

// Detect an in-progress operation from `.git`. A conflicted `git merge` leaves MERGE_HEAD
// until it's committed or aborted; while present the pane resolves conflicts instead of
// staging. merge_title is read from MERGE_MSG (the pending merge's message) for the diff
// title. Called on every refresh AFTER git_clear, so a finished/aborted merge clears itself.
git_detect_op :: proc(g: ^GitPane) {
    g.op = .None
    gitdir := git_gitdir(g)
    if gitdir == "" {
        return
    }
    if !os.exists(filepath.join({gitdir, "MERGE_HEAD"}, context.temp_allocator) or_else "") {
        return
    }
    g.op = .Merge
    msg_path := filepath.join({gitdir, "MERGE_MSG"}, context.temp_allocator) or_else ""
    if data, derr := os.read_entire_file_from_path(msg_path, context.temp_allocator); derr == nil {
        text := string(data)
        if first, _ := strings.split_lines_iterator(&text); strings.trim_space(first) != "" {
            g.merge_title = strings.clone(strings.trim_space(first))
        }
    }
}

// Whether a porcelain status code marks an unmerged (conflicted) path: either side staged as
// unmerged ('U'), or the both-added / both-deleted cases git reports as AA / DD.
git_is_conflict :: proc(code: string) -> bool {
    return strings.contains(code, "U") || code == "AA" || code == "DD"
}

// Load the conflicted files as resolvable conflict hunks (the right column during a merge).
// Each conflicted working-tree file is read and split on its conflict markers
// (git_parse_conflicts); files with no inline markers (binary / add-delete) are listed in the
// sidebar status but contribute no hunks (resolve those in the editor / a terminal). Not
// stageable — the staging commit recipe is locked out while a merge is in flight.
git_load_conflicts :: proc(g: ^GitPane) {
    git_clear_diff(g)
    g.diff_title = strings.clone(g.merge_title == "" ? "resolve merge" : g.merge_title)
    g.diff_stageable = false
    for e in g.status {
        if !git_is_conflict(e.code) {
            continue
        }
        full := filepath.join({g.root, e.path}, context.temp_allocator) or_else ""
        data, derr := os.read_entire_file_from_path(full, context.temp_allocator)
        if derr != nil {
            continue
        }
        hunks, tail := git_parse_conflicts(string(data))
        if len(hunks) == 0 {
            delete(hunks)
            for s in tail {
                delete(s)
            }
            delete(tail)
            continue
        }
        append(&g.diff_files, DiffFile{path = strings.clone(e.path), hunks = hunks, conflict = true, tail = tail})
    }
    git_filter_apply(g) // initialise hidden flags (empty query -> all visible) + focus the first hunk
}

// Split a conflicted file's content into conflict hunks. Lines between `<<<<<<<` and
// `=======` are OURS (HEAD), lines after to `>>>>>>>` are THEIRS (incoming); a diff3 base
// section (`|||||||` to `=======`) is skipped. The clean run before each region is kept on
// the hunk (`pre`), and the clean run after the last region is returned as `tail`, so
// git_resolve_content can rebuild the file verbatim once a side is chosen. Each hunk starts
// Unresolved with its body rendered as the raw both-sides view (git_conflict_render). Owned
// by the caller (freed via git_free_files). Splitting on "\n" keeps every line — including a
// trailing empty one — so a join with "\n" round-trips the original bytes.
git_parse_conflicts :: proc(content: string) -> (hunks: [dynamic]DiffHunk, tail: [dynamic]string) {
    hunks = make([dynamic]DiffHunk)
    pre := make([dynamic]string) // clean run accumulating for the NEXT region (becomes its `pre`)
    h: DiffHunk
    mode := 0 // 0 clean, 1 ours, 2 base (skip), 3 theirs
    for line in strings.split(content, "\n", context.temp_allocator) {
        switch {
        case strings.has_prefix(line, "<<<<<<<"):
            h = DiffHunk{header = strings.clone("conflict"), conflict = true, pre = pre}
            h.ours = make([dynamic]string)
            h.theirs = make([dynamic]string)
            pre = make([dynamic]string)
            mode = 1
        case strings.has_prefix(line, "|||||||") && mode == 1:
            mode = 2 // entering the diff3 base section — drop it
        case strings.has_prefix(line, "=======") && (mode == 1 || mode == 2):
            mode = 3
        case strings.has_prefix(line, ">>>>>>>") && mode == 3:
            git_conflict_render(&h)
            append(&hunks, h)
            mode = 0
        case:
            switch mode {
            case 0: append(&pre, strings.clone(line))
            case 1: append(&h.ours, strings.clone(line))
            case 3: append(&h.theirs, strings.clone(line))
            // mode 2 (base) is intentionally dropped
            }
        }
    }
    // An unterminated region (malformed markers): salvage it as plain clean text in `pre`.
    if mode != 0 {
        for s in h.pre {
            append(&pre, s)
        }
        delete(h.pre)
        for s in h.ours {
            append(&pre, s)
        }
        delete(h.ours)
        for s in h.theirs {
            append(&pre, s)
        }
        delete(h.theirs)
        delete(h.header)
    }
    tail = pre
    return
}

// (Re)build a conflict hunk's displayed body from its current `choice`: Unresolved shows
// both raw sides (ours tinted as deletions, theirs as additions — the raw conflict); a
// resolved choice shows just the kept line(s) as plain context. Frees the prior body first.
git_conflict_render :: proc(h: ^DiffHunk) {
    for l in h.lines {
        delete(l.text)
    }
    clear(&h.lines)
    switch h.choice {
    case .Unresolved:
        git_conflict_emit(h, h.ours[:], .Del)
        git_conflict_emit(h, h.theirs[:], .Add)
    case .Ours:
        git_conflict_emit(h, h.ours[:], .Context)
    case .Theirs:
        git_conflict_emit(h, h.theirs[:], .Context)
    case .Both:
        git_conflict_emit(h, h.ours[:], .Context)
        git_conflict_emit(h, h.theirs[:], .Context)
    }
}

// Append cloned `src` lines to a conflict hunk's display body with the given colour kind.
git_conflict_emit :: proc(h: ^DiffHunk, src: []string, kind: DiffLineKind) {
    for s in src {
        append(&h.lines, DiffLine{kind = kind, text = strings.clone(s)})
    }
}

// Space on a conflict hunk: advance the resolution Unresolved -> Ours -> Theirs -> Both ->
// Unresolved and rebuild its body to match.
git_cycle_conflict :: proc(h: ^DiffHunk) {
    h.choice = ConflictChoice((int(h.choice) + 1) % len(ConflictChoice))
    git_conflict_render(h)
}

// Reconstruct a conflict file's resolved bytes from each hunk's chosen side: the clean run
// before each region (`pre`), then the kept side, repeated in order, then the trailing run
// (`tail`). Joined with "\n" to mirror git_parse_conflicts' split — round-tripping the
// original file save for the resolved regions. Callers gate on no hunk being Unresolved.
git_resolve_content :: proc(f: ^DiffFile, allocator := context.allocator) -> string {
    out := make([dynamic]string, 0, 64, context.temp_allocator)
    for &h in f.hunks {
        for s in h.pre {
            append(&out, s)
        }
        #partial switch h.choice {
        case .Ours:
            for s in h.ours {append(&out, s)}
        case .Theirs:
            for s in h.theirs {append(&out, s)}
        case .Both:
            for s in h.ours {append(&out, s)}
            for s in h.theirs {append(&out, s)}
        }
    }
    for s in f.tail {
        append(&out, s)
    }
    return strings.join(out[:], "\n", allocator)
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
    git_filter_apply(g) // apply the live grep query, focus the first visible hunk, recenter
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

// Enter in the commit message: assemble the commit RECIPE and inject it into the command
// line (staged for review, or run at once per git_commit). The checked hunks' patch and the
// message are written to temp files under .git (never shown in status), and the injected
// chain resets the index to HEAD, applies the patch, and commits from the message file:
//   git -C <root> reset -q && git -C <root> apply --cached --recount <patch> && git -C <root> commit -F <msg>
// `commit -F <file>` sidesteps quoting a multi-line message; the paths are quoted for spaces.
// No-op without a message or a non-empty selection. Slopd owns the index while open.
git_commit_inject :: proc(a: ^App) {
    msg := strings.trim_space(doc_string(&a.git.commit_msg, context.temp_allocator))
    git_commit_send(a, msg, .Commit, a.git_commit_run)
}

// Assemble the commit recipe for the CHECKED hunks under `msg` and hand it to the command
// line — staged for review, or run at once when `run`. `kind` tags why the pane is calling
// (a typed commit vs a slot-machine payout) so git_cl_settle can react to the CL's outcome.
// No-op without a message or a non-empty selection.
git_commit_send :: proc(a: ^App, msg: string, kind: GitCLKind, run: bool) {
    g := &a.git
    if !g.is_repo {
        return
    }
    patch := git_build_patch(g, context.temp_allocator)
    if msg == "" || patch == "" {
        return
    }
    // Temp files live in .git (or the root as a fallback) so they never appear in status;
    // reused (same names) each commit, never accumulating.
    gitdir := filepath.join({g.root, ".git"}, context.temp_allocator) or_else ""
    base := os.is_dir(gitdir) ? gitdir : g.root
    patch_path := filepath.join({base, "slopd-stage.patch"}, context.temp_allocator) or_else ""
    msg_path := filepath.join({base, "slopd-commit.msg"}, context.temp_allocator) or_else ""
    if patch_path == "" || msg_path == "" {
        return
    }
    if os.write_entire_file(patch_path, transmute([]byte)patch) != nil {
        return
    }
    if os.write_entire_file(msg_path, transmute([]byte)msg) != nil {
        return
    }
    cmd := fmt.tprintf(
        `git -C "%s" reset -q && git -C "%s" apply --cached --recount "%s" && git -C "%s" commit -F "%s"`,
        g.root,
        g.root,
        patch_path,
        g.root,
        msg_path,
    )
    cl_dispatch(a, cmd, run)
    if run {
        git_cl_settle(a, kind, true) // ran synchronously — settle as shipped now
    } else {
        g.cl_wait = kind // staged in the CL: settle on its submit / cancel
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

// --- the slot machine ("lucky dip") + the command-line feedback it leans on ---

SPIN_DUR :: 4.2 // seconds the reels spin then settle — long, so it lingers slow
SPIN_INTRO :: f32(0.22) // fraction of the spin spent winding up (ease-in); the rest decelerates
SPIN_MIN_REELS :: 30 // pad short diffs to at least this many reels (a long runway to spin down)

// The spin's easing: a gentle ease-in wind-up over the first SPIN_INTRO of the time, then a
// long ease-out (cubic) glide that decelerates the whole rest of the way to the stop. Both
// phases meet at the same peak velocity, so the reels start slow, blur only briefly, then
// take their time ticking down — no jarring full-speed start, no sudden stop. Maps the time
// fraction t in [0,1] to the distance fraction covered in [0,1].
@(private = "file")
spin_ease :: proc(t: f32) -> f32 {
    a := SPIN_INTRO
    vp := 1.0 / (a * 0.5 + (1 - a) / 3.0) // peak velocity that makes the two phases cover all of [0,1]
    if t < a {
        u := t / a
        return vp * a * u * u * 0.5 // ease-in: distance under a 0->vp velocity ramp
    }
    w := (t - a) / (1 - a)
    return vp * a * 0.5 + vp * (1 - a) * (1 - (1 - w) * (1 - w) * (1 - w)) / 3.0 // ease-out tail
}

// The eased fractional scroll position (display rows) at `now` — the reels' live offset.
git_spin_disp :: proc(s: ^GitSpin, now: f64) -> f32 {
    t := clamp(f32((now - s.start_t) / SPIN_DUR), 0, 1)
    return s.from + (s.to - s.from) * spin_ease(t)
}

// The command line reports back: a command the git pane staged has SHIPPED (Enter / a
// run-mode dispatch) or been DROPPED (Esc). Only acts when the pane was actually waiting
// (cl_wait set, cleared here). A typed commit clears the message + selection once it ships
// — the bar finally empties on send; a slot-machine spin unwinds either way. This is the
// pane's only CL feedback; cl_submit / cl_cancel call it.
git_cl_settle :: proc(a: ^App, kind: GitCLKind, shipped: bool) {
    g := &a.git
    g.cl_wait = .None
    switch kind {
    case .None:
    case .Commit:
        if shipped {
            doc_clear(&g.commit_msg) // the work went out: empty the commit bar
            for &f in g.diff_files {
                for &h in f.hunks {
                    h.selected = false // and clear the checkboxes it committed
                }
            }
        }
    case .Spin:
        git_spin_restore(g) // back to the pre-spin diff, shipped or not
    }
}

// Free a spin's saved snapshot without restoring it — teardown (git_destroy via git_clear)
// or a hard reset mid-spin. No-op when no spin is parked.
git_spin_discard :: proc(g: ^GitPane) {
    s := &g.spin
    if !s.active {
        return
    }
    git_free_files(s.saved_files)
    delete(s.saved_files)
    for str in s.saved_preamble {
        delete(str)
    }
    delete(s.saved_preamble)
    delete(s.saved_title)
    g.spin = {}
    g.cl_wait = .None
}

// One visible hunk of the (now saved) diff, paired with its file — a reel SOURCE. Pointers
// into saved_files stay valid because the snapshot isn't mutated until the restore.
@(private = "file")
Reel :: struct {
    f: ^DiffFile,
    h: ^DiffHunk,
}

// Kick off the slot machine: move the live diff into the snapshot and fill diff_files with
// shuffled, repeated single-hunk REELS, then aim the spin from the top down to a RANDOM
// resting scroll. The reels scroll past the fixed centre reticle (driven by git_spin_disp)
// and decelerate to that row — wherever it lands is the winner. Returns false (no-op) unless
// a stageable diff has at least one visible hunk. git_spin_pump pays out when it settles.
git_spin_begin :: proc(g: ^GitPane, now: f64) -> bool {
    if g.spin.active || !g.diff_stageable || git_hunk_count(g) == 0 {
        return false
    }
    rand.reset_u64(transmute(u64)now) // vary the shuffle + the lucky message each spin

    // Move the live diff aside; the reels take its place (a nil dynamic appends fresh).
    s := &g.spin
    s^ = GitSpin {
        active          = true,
        saved_files     = g.diff_files,
        saved_preamble  = g.diff_preamble,
        saved_title     = g.diff_title,
        saved_scroll    = g.diff_scroll,
        saved_stageable = g.diff_stageable,
    }
    g.diff_files = nil
    g.diff_preamble = nil
    g.diff_title = strings.clone("🎰 lucky dip")
    g.diff_recenter = false // we aim the scroll ourselves below — don't let render re-centre

    // Gather the visible hunks of the saved diff as reel sources.
    src := make([dynamic]Reel, 0, 16, context.temp_allocator)
    for &f in s.saved_files {
        if f.hidden {
            continue
        }
        for &h in f.hunks {
            if !h.hidden {
                append(&src, Reel{&f, &h})
            }
        }
    }

    // Fill diff_files with shuffled, repeated clones until there are enough reels to read as
    // a spin. Each reel is a one-hunk file (its header + the hunk) so the playhead lands on
    // a clean boundary and git_build_patch yields a valid one-hunk patch.
    reps := (SPIN_MIN_REELS + len(src) - 1) / len(src)
    for _ in 0 ..< reps {
        rand.shuffle(src[:])
        for u in src {
            reel := DiffFile{path = strings.clone(u.f.path)}
            for hl in u.f.header {
                append(&reel.header, strings.clone(hl))
            }
            append(&reel.hunks, git_clone_hunk(u.h)) // a fresh reel: unselected, visible
            append(&g.diff_files, reel)
        }
    }

    // Spin from the top of the runway down to a RANDOM resting scroll in its lower ~2/3, so
    // the reels turn a good while and the centre reticle stops on whatever row it happens to
    // — top, middle, or bottom of a reel, never snapped to a hunk boundary. The winner is
    // read off it on land (git_spin_pump). The visual is driven from start_t, not the anim.
    lo := git_scroll_lo(g)
    hi := git_scroll_hi(g)
    s.start_t = now
    s.from = f32(lo)
    s.to = f32(lo + (hi - lo) / 3 + rand.int_max(max(1, (hi - lo) * 2 / 3 + 1)))
    g.diff_scroll = int(s.to) // keep the scroll target / bounds sane; render shows the eased pos
    g.region = .Diff
    return true
}

// Deep-clone one hunk for a reel: a copy of the header + body lines, unselected and visible
// (the spin selects the winner itself). The source stays owned by the snapshot.
@(private = "file")
git_clone_hunk :: proc(h: ^DiffHunk) -> DiffHunk {
    c := DiffHunk{header = strings.clone(h.header)}
    for l in h.lines {
        append(&c.lines, DiffLine{kind = l.kind, text = strings.clone(l.text)})
    }
    return c
}

// Per-frame (main loop): once the reels have settled, stop and pay out — the winner is the
// hunk under the reticle wherever it came to rest. No-op until then, or with no spin running.
git_spin_pump :: proc(a: ^App, now: f64) {
    g := &a.git
    if !g.spin.active || g.spin.landed || now < g.spin.start_t + SPIN_DUR {
        return
    }
    s := &g.spin
    s.landed = true
    g.diff_scroll = int(s.to) // rest exactly on the random landing row
    g.diff_scroll_anim = Anim{to = f32(g.diff_scroll)} // snap; render's normal path takes over
    g.hunk_cur = git_hunk_at_row(g, g.diff_scroll + git_sel_offset(g)) // the hunk under the reticle

    // Select ONLY the winning reel, so the committed patch is just that one hunk.
    for &f in g.diff_files {
        for &h in f.hunks {
            h.selected = false
        }
    }
    if h := git_hunk_ptr(g, g.hunk_cur); h != nil {
        h.selected = true
    }
    git_commit_send(a, git_lucky_message(g), .Spin, a.risky_mode)
}

// Unwind a spin: free the reels and move the saved pre-spin diff back, restoring the scroll
// so the pane looks as it did before the gag. The grep filter's hidden flags rode along on
// the saved hunks, so no re-filter is needed.
git_spin_restore :: proc(g: ^GitPane) {
    s := &g.spin
    if !s.active {
        return
    }
    git_clear_diff(g) // free the reels' contents + reset the diff fields
    delete(g.diff_files) // and the reels' backing arrays (git_clear_diff only clears)
    delete(g.diff_preamble)
    g.diff_files = s.saved_files // move the snapshot back
    g.diff_preamble = s.saved_preamble
    g.diff_title = s.saved_title
    g.diff_stageable = s.saved_stageable
    g.diff_scroll = s.saved_scroll
    g.diff_scroll_anim = Anim{to = f32(s.saved_scroll)} // snap; no slide from the reels
    g.spin = {} // active=false; the snapshot's headers are now owned by g again
}

// A random celebratory commit message for the slot machine, in the repo author's name.
@(private = "file")
git_lucky_message :: proc(g: ^GitPane) -> string {
    name := "somebody"
    if out, ok := git_run(g, "config", "user.name"); ok {
        if n := strings.trim_space(out); n != "" {
            name = n
        }
    }
    templates := []string {
        "%s felt lucky today",
        "%s rolled the dice 🎲",
        "%s hit the jackpot 🎰",
        "lucky dip, courtesy of %s",
        "%s left this one to fate",
        "%s spun the wheel and shipped it",
    }
    return fmt.tprintf(rand.choice(templates), name)
}
