package main

import "core:os"
import "core:strings"
import "core:time"

// The text editor: a list of open Buffers (the ring) with one active. Each Buffer is a Doc
// (the shared multi-cursor editing core) plus file/view state, so every motion and edit op is
// the same code the command line uses. Multi-cursor native: single-cursor is just N == 1.

Buffer :: struct {
    using doc:     Doc, // lines + cursors
    path:            string, // owned; "" = unnamed/scratch
    scroll:          int, // first visible line, the scroll TARGET (clamped at render)
    scroll_anim:     Anim, // visual top line tweening toward `scroll` (smooth scroll)
    scroll_detached: f64, // glfw time the wheel cut the view loose from the caret; 0 = following it
    // The same three fields for the COLUMN axis (no soft wrap, so a long line runs off the
    // right edge and this is how you reach it). Separate from the vertical set because the
    // gestures are separate: Shift+wheel detaches sideways without touching the page.
    hscroll:          int, // first visible column, the horizontal TARGET (clamped at render)
    hscroll_anim:     Anim, // visual left column tweening toward `hscroll`
    hscroll_detached: f64, // glfw time Shift+wheel cut the column loose from the caret
    dirty:           bool,
    final_newline:   bool, // did the file end in '\n'? preserved on save (POSIX round-trip)
    folds:           [dynamic]Fold, // collapsed blocks (Ctrl+Enter); see fold.odin
    fold_nlines:     int, // line count the folds were valid at (drop them when it changes)
    disk_mtime:      time.Time, // file mtime at our last load/save; detects external rewrites (see buffer_reload_if_changed)
    conflict:        bool, // the file changed on disk under unsaved edits: a decision is pending (the prompt; see buffer_conflict_resolve)
    // The private copy a staged `sudo cp` line reads (owned; "" = none staged). Held so the
    // NEXT staging can delete the last one — see save_stage_sudo.
    save_tmp:        string,
    // Content came from the binary, not the filesystem (the `readme` / `license` builtins).
    // `path` is then a DISPLAY NAME, not a location: nothing may save to it or stat it.
    embedded:        bool,
}

Editor :: struct {
    buffers: [dynamic]Buffer,
    active:  int,
}

editor_init :: proc(e: ^Editor) {
    b: Buffer
    doc_init(&b.doc) // one empty line, one cursor
    b.final_newline = true // a fresh file gets the conventional trailing newline
    append(&e.buffers, b)
}

editor_destroy :: proc(e: ^Editor) {
    for &b in e.buffers {
        buffer_destroy(&b)
    }
    delete(e.buffers)
}

editor_current :: proc(e: ^Editor) -> ^Buffer {
    return &e.buffers[e.active]
}

// Expand every fold in every buffer (folding turned off in config).
editor_clear_folds :: proc(e: ^Editor) {
    for &b in e.buffers {
        clear(&b.folds)
        b.fold_nlines = len(b.lines)
    }
}

// --- cross-part seams (called by the filetree / command line) ---

// Loads path into the main pane: an image routes to the media viewer (Image surface);
// any other file is text — reactivates an existing buffer for it, reuses the scratch
// buffer if it's untouched, otherwise opens a new buffer. Focuses the main pane either way.
open_file :: proc(a: ^App, path: string) {
    defer set_focus(a, .Editor)

    // Image (and future media): decode into the viewer instead of the text ring, and flip
    // the main pane to .Image. A failed decode leaves the current surface untouched.
    if is_media_path(path) {
        if m, ok := media_load(path); ok {
            media_destroy(&a.media)
            a.media = m
            a.main = .Image
        }
        return
    }

    a.main = .Text // a text file flips the main pane back to the editor
    e := &a.editor
    for &b, i in e.buffers {
        if b.path == path && !b.embedded { // an embedded doc's path is a name, never a location
            e.active = i
            return
        }
    }
    cur := editor_current(e)
    if cur.path == "" && !cur.dirty && len(cur.lines) == 1 && len(cur.lines[0].text) == 0 {
        buffer_load(cur, path)
        return
    }
    b: Buffer
    if buffer_load(&b, path) {
        append(&e.buffers, b)
        e.active = len(e.buffers) - 1
    } else {
        buffer_destroy(&b)
    }
}

// How many open buffers hold unsaved changes (the ring's size). The quit/write
// builtins guard on this so a stray `q` can't discard work.
ring_dirty_count :: proc(e: ^Editor) -> int {
    n := 0
    for &b in e.buffers {
        if b.dirty {
            n += 1
        }
    }
    return n
}

// Is path open with unsaved changes? (Lights up its '*' in the filetree.)
ring_contains :: proc(a: ^App, path: string) -> bool {
    for &b in a.editor.buffers {
        if b.dirty && b.path == path {
            return true
        }
    }
    return false
}

// --- buffer lifecycle ---

buffer_destroy :: proc(b: ^Buffer) {
    doc_destroy(&b.doc)
    delete(b.folds)
    delete(b.path)
    buffer_drop_save_tmp(b) // a staged sudo line dies with its buffer; the copy must not outlive it
}

buffer_set_text :: proc(b: ^Buffer, text: string) {
    doc_set_text(&b.doc, text)
    b.scroll = 0
    b.scroll_anim = {} // settled at the top; a reused scratch buffer won't smear from its old scroll
    b.scroll_detached = 0 // a wholesale text swap re-attaches the view to the caret
    b.hscroll = 0
    b.hscroll_anim = {} // …and settled at column 0, for the same reason
    b.hscroll_detached = 0
    clear(&b.folds) // a wholesale text swap invalidates every fold range
    b.fold_nlines = len(b.lines)
}

buffer_load :: proc(b: ^Buffer, path: string) -> bool {
    src, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return false
    }
    content := string(src)
    // Capture everything derived from `path` BEFORE freeing the old b.path: a reload
    // (buffer_reload_keep_view) passes b.path itself, so freeing first would leave `path`
    // dangling and clone/stat it from freed memory.
    new_path := strings.clone(path)
    mtime := file_mtime(path) or_else time.Time{} // the stamp staleness is measured against
    buffer_set_text(b, content)
    delete(b.path)
    b.path = new_path
    b.dirty = false
    b.embedded = false // a real file, even if this buffer previously held an embedded doc
    b.final_newline = strings.has_suffix(content, "\n") // remember it for save
    b.disk_mtime = mtime
    return true
}

// Whether `path` names a real file — the precondition every disk op shares. False for a
// scratch buffer (no name yet) and for an embedded doc (a name that is not a location).
buffer_on_disk :: proc(b: ^Buffer) -> bool {
    return b.path != "" && !b.embedded
}

// Why a save did not happen. `.Denied` is the one an ordinary user hits on purpose — a file they
// may read and not write — and it is the only failure with a way forward, so it is the only one
// the callers act on rather than report (the staged `sudo cp`; see save_stage_sudo).
Save_Result :: enum {
    Ok,
    No_Path, // unnamed scratch, or an embedded doc: there is nothing to write to
    Denied, // EACCES / EPERM, on the file or on the folder it would be created in
    Failed, // anything else: a full disk, a vanished folder, an I/O error
}

// The bytes a save writes: the shared serializer (lines joined by '\n', no trailing one), plus
// the trailing newline back if the file we loaded had one. THREE callers must agree byte for
// byte — the save, the private copy the sudo line carries, and the compare in `:saved` — which
// is why the rule lives in one proc instead of being spelled out at each of them.
buffer_bytes :: proc(b: ^Buffer, allocator := context.temp_allocator) -> string {
    data := doc_string(&b.doc, allocator)
    if !b.final_newline {
        return data
    }
    out := strings.concatenate({data, "\n"}, allocator)
    delete(data, allocator)
    return out
}

buffer_save :: proc(b: ^Buffer) -> Save_Result {
    if !buffer_on_disk(b) {
        return .No_Path // unnamed (save-as not implemented yet), or an embedded doc
    }
    data := buffer_bytes(b)
    if err := os.write_entire_file(b.path, transmute([]u8)data); err != nil {
        // EACCES and EPERM both arrive as Permission_Denied, from the file OR from a folder we
        // may not create in. EROFS does not: a read-only mount is not a door sudo can open.
        return err == .Permission_Denied ? .Denied : .Failed
    }
    buffer_mark_saved(b)
    return .Ok
}

// Adopt the disk as ours: clean, unconflicted, and stamped with the file's CURRENT mtime so the
// staleness poll does not read our own write back as somebody else's. Shared by the save and by
// `:saved` — the builtin that ends a staged sudo line, where the write was root's, not ours.
buffer_mark_saved :: proc(b: ^Buffer) {
    b.dirty = false
    b.conflict = false // our write IS the disk now, so any pending conflict is resolved
    b.disk_mtime = file_mtime(b.path) or_else {}
    buffer_drop_save_tmp(b) // the staged copy has served its purpose
}

// Whether the file on disk already holds exactly what this buffer would write. The check that
// makes `:saved` safe to type anywhere: on any other buffer it is simply false, so a builtin
// that marks work clean can never be pointed at work that is not.
buffer_matches_disk :: proc(b: ^Buffer) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    disk, err := os.read_entire_file_from_path(b.path, context.temp_allocator)
    return err == nil && string(disk) == buffer_bytes(b)
}

// Remove the private copy staged for a sudo save, on disk and from the buffer. Safe to call
// when there is none; called on every restaging, on `:saved`, and on close.
buffer_drop_save_tmp :: proc(b: ^Buffer) {
    if b.save_tmp == "" {
        return
    }
    os.remove(b.save_tmp)
    delete(b.save_tmp)
    b.save_tmp = ""
}

// The file's on-disk modification time, ok=false if it can't be stat'd (gone/unreadable).
// The single source of the staleness stamp shared by the text buffer and the image viewer.
file_mtime :: proc(path: string) -> (time.Time, bool) {
    fi, err := os.stat(path, context.temp_allocator)
    if err != nil {
        return {}, false
    }
    return fi.modification_time, true
}

// Re-read the file if it changed on disk since we last loaded or saved it, so a later save
// can't clobber an external tool's edits. A CLEAN buffer reloads silently; a DIRTY one is a
// conflict — `prompt_on_conflict` raises `conflict` and deliberately does NOT adopt the stamp.
buffer_reload_if_changed :: proc(b: ^Buffer, prompt_on_conflict: bool) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    mt := file_mtime(b.path) or_else b.disk_mtime // unreadable: treat as unchanged
    if mt == b.disk_mtime {
        return false
    }
    if b.dirty {
        if prompt_on_conflict {
            b.conflict = true // disk changed under unsaved edits: ask, don't clobber
        } else {
            b.disk_mtime = mt // relaxed: keep my edits silently, accept the new disk stamp
        }
        return false
    }
    b.disk_mtime = mt
    return buffer_reload_keep_view(b)
}

// Re-read the file from disk, holding the caret line/column and scroll across the swap
// (clamped to the new length) so a background edit doesn't yank the view to the top. The
// unconditional reload core, shared by the silent auto-reload and the conflict "reload".
buffer_reload_keep_view :: proc(b: ^Buffer) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    head := b.cursors[b.primary].head
    scroll := b.scroll
    hscroll := b.hscroll
    if !buffer_load(b, b.path) {
        return false
    }
    line := clamp(head.line, 0, len(b.lines) - 1)
    col := clamp(head.col, 0, len(b.lines[line].text))
    doc_reset_cursor(&b.doc, {line = line, col = col})
    b.scroll = clamp(scroll, 0, max(0, len(b.lines) - 1))
    b.hscroll = hscroll // bounded next frame, where the pane width is known
    return true
}

// Settle a pending disk-change conflict. reload=true takes the disk version; reload=false
// KEEPS the edits and adopts the current disk stamp — the cached decision, so the prompt
// stays down until the file changes AGAIN. Either clears the conflict.
buffer_conflict_resolve :: proc(b: ^Buffer, reload: bool) {
    b.conflict = false
    if reload {
        b.dirty = false // the reload re-reads from disk, so the buffer is clean again
        buffer_reload_keep_view(b)
    } else {
        b.disk_mtime = file_mtime(b.path) or_else b.disk_mtime // cache "keep mine" against the current disk version
    }
}

// --- editing (thin wrappers over the Doc core; mark the buffer dirty) ---

buffer_insert_rune :: proc(b: ^Buffer, r: rune) {
    b.dirty |= doc_insert_rune(&b.doc, r)
}

// A plain newline at every cursor, no auto-indent (the editor uses buffer_enter; this is the
// dumb primitive for programmatic splits + tests).
buffer_newline :: proc(b: ^Buffer) {
    b.dirty |= doc_newline(&b.doc)
}

// Enter in the editor: a newline that copies the line's leading whitespace, plus one indent
// unit when the line opens a block at the caret. Special case: a lone caret between a bracket
// pair expands across three lines. Heuristic-first, so it works with no grammar installed.
buffer_enter :: proc(a: ^App, b: ^Buffer) {
    d := &b.doc

    // Brace-pair expansion: a lone caret between an opener and its matching closer.
    if len(d.cursors) == 1 && !cursor_has_selection(d.cursors[0]) {
        c := d.cursors[0]
        line := &d.lines[c.head.line]
        prev := c.head.col > 0 ? line.text[c.head.col - 1] : 0
        if enter_expands_pair(prev, char_at(line, c.head.col)) &&
           !ts_in_string_or_comment(a, b, c.head.line, c.head.col - 1) {
            base := line_lead(line)
            inner := grow_indent(base, a.indent)
            if doc_insert_runes(d, expand_runes(inner, base)) {
                b.dirty = true
            }
            doc_reset_cursor(d, Pos{c.head.line + 1, len(inner)}) // onto the indented middle line
            return
        }
    }

    // General case (incl. multi-cursor): each cursor gets a newline + its own computed indent.
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        lo, hi := cursor_range(c)
        append(&edits, Edit{lo, hi, newline_indent(enter_indent(a, b, lo)), 0})
    }
    if doc_commit(d, edits[:]) {
        b.dirty = true
    }
}

// The indentation the line after Enter should start with: the current line's leading
// whitespace, plus one unit when the line opens a block at the caret.
@(private = "file")
enter_indent :: proc(a: ^App, b: ^Buffer, pos: Pos) -> []rune {
    lead := line_lead(&b.lines[pos.line])
    if enter_opens_block(a, b, pos) {
        return grow_indent(lead, a.indent)
    }
    return lead
}

// Opens a block at the caret = its last non-blank char before the caret is an opener `([{`
// that's real code (tree-sitter rules out one inside a string/comment when a grammar exists).
@(private = "file")
enter_opens_block :: proc(a: ^App, b: ^Buffer, pos: Pos) -> bool {
    line := &b.lines[pos.line]
    at := -1
    for i := pos.col - 1; i >= 0; i -= 1 {
        if line.text[i] != ' ' && line.text[i] != '\t' {
            at = i
            break
        }
    }
    if at < 0 {
        return false
    }
    switch line.text[at] {
    case '(', '[', '{':
        return !ts_in_string_or_comment(a, b, pos.line, at)
    }
    return false
}

// True when Enter between `prev` and `next` should expand a bracket pair (quotes excluded —
// splitting a string across lines isn't wanted).
@(private = "file")
enter_expands_pair :: proc(prev, next: rune) -> bool {
    switch prev {
    case '(':
        return next == ')'
    case '[':
        return next == ']'
    case '{':
        return next == '}'
    }
    return false
}

// A line's leading whitespace, as a sub-slice of its runes (read before any edit mutates it).
@(private = "file")
line_lead :: proc(l: ^Line) -> []rune {
    return l.text[:line_indent_cols(l)]
}

// `lead` plus one indentation unit.
@(private = "file")
grow_indent :: proc(lead: []rune, ind: Indent) -> []rune {
    unit := indent_runes(ind)
    out := make([]rune, len(lead) + len(unit), context.temp_allocator)
    copy(out, lead)
    copy(out[len(lead):], unit)
    return out
}

// "\n" followed by the given indentation.
@(private = "file")
newline_indent :: proc(indent: []rune) -> []rune {
    out := make([]rune, 1 + len(indent), context.temp_allocator)
    out[0] = '\n'
    copy(out[1:], indent)
    return out
}

// "\n" + inner + "\n" + base — the three-line body for brace-pair expansion (the caret lands
// at the end of the `inner` line).
@(private = "file")
expand_runes :: proc(inner, base: []rune) -> []rune {
    out := make([]rune, 2 + len(inner) + len(base), context.temp_allocator)
    out[0] = '\n'
    copy(out[1:], inner)
    out[1 + len(inner)] = '\n'
    copy(out[2 + len(inner):], base)
    return out
}

buffer_backspace :: proc(b: ^Buffer) {
    b.dirty |= doc_backspace(&b.doc)
}

buffer_delete :: proc(b: ^Buffer) {
    b.dirty |= doc_delete(&b.doc)
}

buffer_delete_word_back :: proc(b: ^Buffer) {
    b.dirty |= doc_delete_word_back(&b.doc)
}

buffer_delete_word_forward :: proc(b: ^Buffer) {
    b.dirty |= doc_delete_word_forward(&b.doc)
}

buffer_undo :: proc(b: ^Buffer) {
    if doc_undo(&b.doc) {
        b.dirty = true
    }
}

buffer_redo :: proc(b: ^Buffer) {
    if doc_redo(&b.doc) {
        b.dirty = true
    }
}

// --- view ---

// The viewport's target top line for a `rows`-tall pane — the `scroll_mode` policy, kept out
// of the renderer so it is testable without GL. FOLLOW moves the minimum only once the caret
// would leave the view; MIDDLE pins the TOPMOST cursor to the middle. Both walk VISIBLE rows.
buffer_scroll_target :: proc(b: ^Buffer, rows: int, center: bool) -> int {
    if center {
        line := buffer_prev_visible(b, doc_top_cursor_line(&b.doc))
        return buffer_back_visible(b, line, rows / 2)
    }
    top := buffer_prev_visible(b, clamp(b.scroll, 0, len(b.lines) - 1))
    cur := b.cursors[b.primary].head.line
    if cur < top {
        return cur
    }
    if buffer_visible_count(b, top, cur) > rows {
        return buffer_back_visible(b, cur, rows - 1) // caret on the bottom row
    }
    return top
}

// Settle this frame's scroll target — the one place b.scroll is written per frame. While the
// WHEEL has the view detached the policy must NOT run (both modes derive the top from the
// caret and would yank it back); comparing timestamps re-attaches on any keystroke.
buffer_scroll_apply :: proc(b: ^Buffer, rows: int, center: bool, last_input_at: f64) {
    if b.scroll_detached > 0 && last_input_at > b.scroll_detached {
        b.scroll_detached = 0
    }
    if b.scroll_detached > 0 {
        // No policy, only bounds: any visible line may be the top, first to last.
        b.scroll = buffer_prev_visible(b, clamp(b.scroll, 0, max(0, len(b.lines) - 1)))
        return
    }
    b.scroll = buffer_scroll_target(b, rows, center)
}

// Move the detached view by `delta` visible-ish lines and stamp it as detached at `now`
// (the wheel's entry point — see mouse.odin). Clamped to the buffer; buffer_scroll_apply
// snaps the result onto a visible line, so folds need no handling here.
buffer_scroll_by :: proc(b: ^Buffer, delta: int, now: f64) {
    b.scroll = clamp(b.scroll + delta, 0, max(0, len(b.lines) - 1))
    b.scroll_detached = now
}

// --- the column axis ---
//
// There is no soft wrap: a long line runs off the right edge and is reached by moving the
// window sideways instead. The three procs below mirror the vertical set exactly — target,
// apply, and the wheel's by — so both axes detach, re-attach and animate under one set of
// rules, and only the policy in the middle differs.

// Columns of context the caret keeps between itself and either edge — "don't leave it on the
// edge". At the right margin you can then see the few characters you are about to type over,
// and at the left the start of the token you are walking back into, rather than the caret
// butting against the clip with the text appearing one column at a time.
HSCROLL_PAD :: 8

// The target first COLUMN for a `cols`-wide text region. The vertical policy's twin, with one
// deliberate difference: there is no MIDDLE mode. `scroll_mode: middle` pins what you follow to
// the centre, which reads fine down a page — the rows either side stay put — but sideways it
// slides the WHOLE file under every keystroke past the halfway column, and nothing on screen
// holds still to read against. So the column axis is always the margin policy: hold while the
// caret is inside the padded window, then move the minimum to put it back.
//
// The margin is halved out on a narrow pane. Two margins wider than the region between them
// would each pull the opposite way, and the view would never settle on either.
buffer_hscroll_target :: proc(left, col, cols: int) -> int {
    if cols <= 0 {
        return 0
    }
    pad := min(HSCROLL_PAD, (cols - 1) / 2)
    l := max(0, left)
    if col - pad < l {
        return max(0, col - pad) // the clamp is also what snaps a near-home caret back to column 0
    }
    if col + pad > l + cols - 1 {
        return col + pad - cols + 1
    }
    return l
}

// Settle this frame's column target — the one place b.hscroll is written per frame. `longest`
// is the widest line the window is DRAWING, which is what bounds the view: past its end plus
// the margin there is nothing to look at, and blank space is not a place to be scrolled to.
//
// **Call this after buffer_scroll_apply**, whose result it reads: the caret is only guaranteed
// on screen while the VERTICAL view is following it, and a column policy aimed at a line nobody
// can see would slide the visible ones sideways for nothing. So a wheel-detached page holds its
// column too, and the keystroke that re-attaches one axis re-attaches both.
buffer_hscroll_apply :: proc(b: ^Buffer, cols, longest: int, last_input_at: f64) {
    if b.hscroll_detached > 0 && last_input_at > b.hscroll_detached {
        b.hscroll_detached = 0
    }
    limit := max(0, longest + HSCROLL_PAD - cols + 1)
    if b.hscroll_detached > 0 || b.scroll_detached > 0 {
        b.hscroll = clamp(b.hscroll, 0, limit)
        return
    }
    col := b.cursors[b.primary].head.col
    b.hscroll = clamp(buffer_hscroll_target(b.hscroll, col, cols), 0, limit)
}

// Move the detached column by `delta` and stamp it — Shift+wheel's entry point. Only the
// lower bound is applied: the callback has no font and no pane rect, so it cannot know how
// wide a column is or how many fit, and buffer_hscroll_apply bounds the top next frame with
// one notch of overshoot at most (as the vertical wheel does).
buffer_hscroll_by :: proc(b: ^Buffer, delta: int, now: f64) {
    b.hscroll = max(0, b.hscroll + delta)
    b.hscroll_detached = now
}

// --- movement (no edits; the Doc ops wrap across line boundaries). select=true
// (Shift) grows a selection; all=true (the Alt+M prefix) moves every cursor rather
// than just the free caret. ---

buffer_motion :: proc(b: ^Buffer, motion: Motion, select := false, all := false, count := 1) {
    buffer_sync_folds(b) // a prior same-frame edit may have invalidated the fold set
    if all {
        doc_move_all(&b.doc, motion, select, count)
    } else {
        doc_move(&b.doc, motion, select, count)
    }
    buffer_skip_hidden(b, motion)
}

// Keeps cursors off folded (hidden) lines after a motion: a cursor that stepped into a
// collapsed block snaps to the fold's visible edge in the direction it moved (header above,
// first visible line past it), so a single Up/Down/arrow steps cleanly over a fold.
@(private = "file")
buffer_skip_hidden :: proc(b: ^Buffer, motion: Motion) {
    if len(b.folds) == 0 {
        return
    }
    forward := motion == .Right || motion == .Word_Right || motion == .Down || motion == .End
    vertical := motion == .Up || motion == .Down
    for &c in b.cursors {
        if !buffer_line_hidden(b, c.head.line) {
            continue
        }
        target := forward ? buffer_next_visible(b, c.head.line) : buffer_prev_visible(b, c.head.line)
        // Vertical motion keeps the goal column; a horizontal wrap lands at the line
        // edge it would have reached (end of the header / start of the line past it).
        col := vertical ? min(c.goal, line_len(&b.lines[target])) : (forward ? 0 : line_len(&b.lines[target]))
        p := Pos{target, col}
        if !cursor_has_selection(c) {
            c.anchor = p
        }
        c.head = p
        if !vertical {
            c.goal = col
        }
    }
    doc_merge_cursors(&b.doc)
}
