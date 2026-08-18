package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// A list of open Buffers (the ring) with one active. Each is a Doc plus file/view state, so
// every motion and edit op is the code the command line uses.

Buffer :: struct {
    using doc:     Doc, // lines + cursors
    path:            string, // owned; "" = unnamed/scratch
    scroll:          int, // first visible line, the TARGET (clamped at render)
    scroll_anim:     Anim, // visual top line tweening toward `scroll`
    scroll_detached: f64, // glfw time the wheel cut the view loose; 0 = following the caret
    // The same three for the COLUMN axis: no soft wrap, so a long line runs off the right edge
    // and this is how you reach it. Separate because Shift+wheel detaches sideways alone.
    hscroll:          int,
    hscroll_anim:     Anim,
    hscroll_detached: f64,
    dirty:           bool,
    final_newline:   bool, // did the file end in '\n'? preserved on save
    crlf:            bool, // did the file break its lines with "\r\n"? restored on save
    folds:           [dynamic]Fold, // collapsed blocks (fold.odin)
    disk_mtime:      time.Time, // mtime at our last load/save; detects external rewrites
    conflict:        bool, // the file changed on disk under unsaved edits; a decision is pending
    // The private copy a staged `sudo cp` line reads (owned; "" = none). Held so the next
    // staging can delete the last — see save_stage_sudo.
    save_tmp:        string,
    // Content came from the binary (the `:readme` / `:license` builtins), so `path` is a display
    // name, not a location: nothing may save to it or stat it.
    embedded:        bool,
}

Editor :: struct {
    buffers: [dynamic]Buffer,
    active:  int,
}

editor_init :: proc(e: ^Editor) {
    b: Buffer
    doc_init(&b.doc) // one empty line, one cursor
    b.final_newline = true
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

// editor_current behind the two questions every whole-buffer tool asks first. Nil on the image
// surface and on the bare App the tests build.
main_text_buffer :: proc(a: ^App) -> ^Buffer {
    if a.main != .Text || len(a.editor.buffers) == 0 {
        return nil
    }
    return editor_current(&a.editor)
}

// Folding turned off in config.
editor_clear_folds :: proc(e: ^Editor) {
    for &b in e.buffers {
        clear(&b.folds)
    }
}

// --- cross-part seams (called by the filetree / command line) ---

// An image routes to the media viewer; anything else is text — an existing buffer for it, or
// the scratch buffer if untouched, or a new one. Focuses the main pane either way.
open_file :: proc(a: ^App, path: string) {
    defer set_focus(a, .Editor)

    // A failed decode leaves the current surface untouched.
    if is_media_path(path) {
        if m, ok := media_load(path); ok {
            media_destroy(&a.media)
            a.media = m
            a.main = .Image
        } else {
            open_stage_sudo(a, path)
        }
        return
    }

    a.main = .Text
    e := &a.editor
    for &b, i in e.buffers {
        if b.path == path && !b.embedded { // an embedded doc's path is a name
            e.active = i
            return
        }
    }
    cur := editor_current(e)
    if cur.path == "" && !cur.dirty && doc_line_count(&cur.doc) == 1 && doc_line_len(&cur.doc, 0) == 0 {
        if !buffer_load(cur, path) {
            open_stage_sudo(a, path)
        }
        return
    }
    b: Buffer
    if buffer_load(&b, path) {
        append(&e.buffers, b)
        e.active = len(e.buffers) - 1
    } else {
        buffer_destroy(&b)
        open_stage_sudo(a, path)
    }
}

// The quit/write builtins guard on this so a stray `:q` cannot discard work.
ring_dirty_count :: proc(e: ^Editor) -> int {
    n := 0
    for &b in e.buffers {
        if b.dirty {
            n += 1
        }
    }
    return n
}

// Lights up its '*' in the filetree.
ring_contains :: proc(a: ^App, path: string) -> bool {
    return ring_dirty_buffer(a, path) != nil
}

// The unsaved buffer holding `path`, or nil. An embedded doc is skipped: its path is a display
// name, so no file pane can be pointing at it.
ring_dirty_buffer :: proc(a: ^App, path: string) -> ^Buffer {
    for &b in a.editor.buffers {
        if b.dirty && !b.embedded && b.path == path {
            return &b
        }
    }
    return nil
}

// --- buffer lifecycle ---

buffer_destroy :: proc(b: ^Buffer) {
    doc_destroy(&b.doc)
    delete(b.folds)
    delete(b.path)
    buffer_drop_save_tmp(b) // the copy must not outlive its buffer
}

buffer_set_text :: proc(b: ^Buffer, text: string) {
    doc_set_text(&b.doc, text)
    b.scroll = 0
    b.scroll_anim = {} // settled, so a reused scratch buffer does not smear from its old scroll
    b.scroll_detached = 0 // a wholesale swap re-attaches the view to the caret
    b.hscroll = 0
    b.hscroll_anim = {}
    b.hscroll_detached = 0
    clear(&b.folds) // every fold range is invalidated
}

buffer_load :: proc(b: ^Buffer, path: string) -> bool {
    src, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return false
    }
    content := string(src)
    // Everything derived from `path` BEFORE freeing the old b.path: a reload passes b.path
    // itself, so freeing first would clone and stat freed memory.
    new_path := strings.clone(path)
    mtime := file_mtime(path) or_else time.Time{}
    buffer_set_text(b, content)
    delete(b.path)
    b.path = new_path
    b.dirty = false
    b.embedded = false // a real file, whatever this buffer held before
    b.final_newline = strings.has_suffix(content, "\n")
    b.crlf = crlf_file(content)
    b.disk_mtime = mtime
    return true
}

// A load fails for many reasons; only a permission denial has a way forward (the staged
// `sudo chmod`), so it is the only one worth telling apart. Asked of the path directly, since
// the failed read gave the reason away and dropped it.
path_read_denied :: proc(path: string) -> bool {
    f, err := os.open(path, {.Read})
    if err == nil {
        os.close(f)
    }
    return err == .Permission_Denied
}

// The precondition every disk op shares. False for a scratch buffer and an embedded doc.
buffer_on_disk :: proc(b: ^Buffer) -> bool {
    return b.path != "" && !b.embedded
}

// `.Denied` is the only failure with a way forward (the staged `sudo cp`), so it is the only
// one callers act on rather than report.
Save_Result :: enum {
    Ok,
    No_Path, // unnamed scratch, or an embedded doc
    Denied, // EACCES / EPERM, on the file or on its folder
    Failed, // a full disk, a vanished folder, an I/O error
}

// Lines joined by '\n', the trailing newline back if the loaded file had one, and every break
// back to "\r\n" if that is how the file wrote them. Three callers must agree byte for byte:
// the save, the sudo line's private copy, and `:saved`.
buffer_bytes :: proc(b: ^Buffer, allocator := context.temp_allocator) -> string {
    data := doc_string(&b.doc, allocator)
    if b.final_newline {
        with_nl := strings.concatenate({data, "\n"}, allocator)
        delete(data, allocator)
        data = with_nl
    }
    if !b.crlf {
        return data
    }
    out, replaced := strings.replace_all(data, "\n", "\r\n", allocator)
    if replaced { // a one-line file with no break returns `data` itself
        delete(data, allocator)
    }
    return out
}

// A file breaks its lines the way its FIRST break does; a mixed file is saved the one way, which
// is the point of holding the flag per buffer. The load strips every '\r' (doc_normalize), so
// this is the only chance to see them.
crlf_file :: proc(text: string) -> bool {
    i := strings.index_byte(text, '\n')
    return i > 0 && text[i - 1] == '\r'
}

buffer_save :: proc(b: ^Buffer) -> Save_Result {
    if !buffer_on_disk(b) {
        return .No_Path // unnamed (no save-as yet), or embedded
    }
    res := file_write_atomic(b.path, buffer_bytes(b))
    if res == .Ok {
        buffer_mark_saved(b)
    }
    return res
}

// THE FILE IS NEVER TRUNCATED: the bytes go to a sibling temp file, reach the platter, and the
// rename swings the name over in one step. A crash, a full disk or a kill loses the save, never
// the file. Sibling because rename is only atomic inside one filesystem.
file_write_atomic :: proc(path: string, data: string) -> Save_Result {
    target := file_link_target(path) // save THROUGH a symlink; a rename would replace the link
    // The temp file is written in the folder, so the folder's rights are all the write tests.
    // A read-only FILE has to be asked about directly, or `chmod 444` would not hold.
    if f, err := os.open(target, {.Write}); err == nil {
        os.close(f)
    } else if err == .Permission_Denied {
        return .Denied
    }
    perm := os.Permissions_Read_All + {.Write_User}
    if fi, err := os.stat(target, context.temp_allocator); err == nil {
        perm = fi.mode // the file keeps its own bits, not a fresh file's defaults
    }
    // pid + a counter, in the target's folder: short, because a name built from the file's own
    // would run past NAME_MAX on a long one, and unique, so two saves cannot take each other's.
    seq := sync.atomic_add(&save_tmp_seq, 1)
    name := fmt.tprintf(".slopd-%d-%d.tmp", os.get_pid(), seq)
    tmp := filepath.join({filepath.dir(target), name}, context.temp_allocator) or_else ""
    if tmp == "" {
        return .Failed
    }
    err := file_write_synced(tmp, data, perm)
    if err == nil {
        err = os.rename(tmp, target)
    }
    if err != nil {
        os.remove(tmp) // nothing half-written is left behind
        // EACCES and EPERM both arrive as Permission_Denied. EROFS does not: a read-only mount
        // is not a door sudo can open.
        return err == .Permission_Denied ? .Denied : .Failed
    }
    return .Ok
}

@(private = "file")
save_tmp_seq: int

// Written AND flushed to stable storage, so the rename cannot publish a name whose bytes are
// still in flight.
@(private = "file")
file_write_synced :: proc(path: string, data: string, perm: os.Permissions) -> os.Error {
    f, err := os.open(path, {.Write, .Create, .Trunc}, perm)
    if err != nil {
        return err
    }
    defer os.close(f)
    n := os.write(f, transmute([]u8)data) or_return
    if n != len(data) {
        return .Short_Write
    }
    return os.sync(f)
}

// What `path` finally points at, so the save lands on the file rather than on the link. Returns
// `path` itself when it is not a link, and gives up after a few hops rather than chase a loop.
@(private = "file")
file_link_target :: proc(path: string) -> string {
    out := path
    for _ in 0 ..< 8 {
        dst, err := os.read_link(out, context.temp_allocator)
        if err != nil {
            break
        }
        if filepath.is_abs(dst) {
            out = dst
        } else {
            out = filepath.join({filepath.dir(out), dst}, context.temp_allocator) or_else out
        }
    }
    return out
}

// Clean, unconflicted, stamped with the file's current mtime so the staleness poll does not
// read our own write back as somebody else's. Shared by the save and by `:saved`.
buffer_mark_saved :: proc(b: ^Buffer) {
    b.dirty = false
    b.conflict = false // our write IS the disk now
    b.disk_mtime = file_mtime(b.path) or_else {}
    buffer_drop_save_tmp(b)
}

// What makes `:saved` safe to type anywhere: false on any other buffer, so a builtin that marks
// work clean cannot be pointed at work that is not.
buffer_matches_disk :: proc(b: ^Buffer) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    disk, err := os.read_entire_file_from_path(b.path, context.temp_allocator)
    return err == nil && string(disk) == buffer_bytes(b)
}

// On disk and from the buffer. Safe when there is none; called on restaging, `:saved` and
// close.
buffer_drop_save_tmp :: proc(b: ^Buffer) {
    if b.save_tmp == "" {
        return
    }
    os.remove(b.save_tmp)
    delete(b.save_tmp)
    b.save_tmp = ""
}

// ok=false when it cannot be stat'd. The one staleness stamp, shared with the image viewer.
file_mtime :: proc(path: string) -> (time.Time, bool) {
    fi, err := os.stat(path, context.temp_allocator)
    if err != nil {
        return {}, false
    }
    return fi.modification_time, true
}

// So a later save cannot clobber an external tool's edits. A clean buffer reloads silently; a
// dirty one is a conflict, and `prompt_on_conflict` raises it without adopting the stamp.
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
            b.conflict = true // ask, do not clobber
        } else {
            b.disk_mtime = mt // relaxed: keep my edits, accept the new stamp
        }
        return false
    }
    b.disk_mtime = mt
    return buffer_reload_keep_view(b)
}

// Holds the caret and scroll across the swap, clamped to the new length, so a background edit
// does not yank the view to the top. Shared by the silent auto-reload and `:reload y`.
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
    doc_reset_cursor(&b.doc, head) // clamped onto the reloaded content
    b.scroll = clamp(scroll, 0, max(0, doc_line_count(&b.doc) - 1))
    b.hscroll = hscroll // bounded next frame, where the pane width is known
    return true
}

// Throw the unsaved edits away and take the disk version back, so the file leaves the unsaved
// ring. The staged sudo copy goes with them — it holds the bytes being discarded. False when
// there is no file to come back from (a scratch buffer, an embedded doc).
buffer_discard :: proc(b: ^Buffer) -> bool {
    if !buffer_on_disk(b) {
        return false
    }
    b.dirty = false
    b.conflict = false // the disk is what we hold now, so there is nothing left to settle
    buffer_drop_save_tmp(b)
    return buffer_reload_keep_view(b)
}

// reload=true takes the disk version; false keeps the edits and adopts the current stamp, so
// the prompt stays down until the file changes again. Either clears the conflict.
buffer_conflict_resolve :: proc(b: ^Buffer, reload: bool) {
    b.conflict = false
    if reload {
        buffer_discard(b)
    } else {
        b.disk_mtime = file_mtime(b.path) or_else b.disk_mtime // cache "keep mine"
    }
}

// --- editing (thin wrappers over the Doc core; mark the buffer dirty) ---

buffer_insert_rune :: proc(b: ^Buffer, r: rune) {
    b.dirty |= doc_insert_rune(&b.doc, r)
}

// No auto-indent — the editor uses buffer_enter. The primitive for programmatic splits.
buffer_newline :: proc(b: ^Buffer) {
    b.dirty |= doc_newline(&b.doc)
}

// A newline copying the line's leading whitespace, plus one indent unit when the line opens a
// block at the caret. A lone caret between a bracket pair expands across three lines.
// Heuristic-first, so it works with no grammar installed.
buffer_enter :: proc(a: ^App, b: ^Buffer) {
    d := &b.doc

    if len(d.cursors) == 1 && !cursor_has_selection(d.cursors[0]) {
        c := d.cursors[0]
        prev, size := doc_rune_before(d, c.head)
        if enter_expands_pair(prev, doc_rune_at(d, c.head)) &&
           !ts_in_string_or_comment(a, b, c.head.line, c.head.col - size) {
            base := line_lead(d, c.head.line)
            inner := grow_indent(base, a.indent)
            body := strings.concatenate({"\n", inner, "\n", base}, context.temp_allocator)
            if doc_insert_text(d, body) {
                b.dirty = true
            }
            doc_reset_cursor(d, Pos{c.head.line + 1, len(inner)}) // the indented middle line
            return
        }
    }

    // Each cursor gets a newline plus its own computed indent.
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in edit_cursors(d) {
        lo, hi := cursor_range(c)
        text := strings.concatenate({"\n", enter_indent(a, b, lo)}, context.temp_allocator)
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), text, 0})
    }
    if doc_commit(d, edits[:]) {
        b.dirty = true
    }
}

// The current line's leading whitespace, plus one unit when it opens a block at the caret.
@(private = "file")
enter_indent :: proc(a: ^App, b: ^Buffer, pos: Pos) -> string {
    lead := line_lead(&b.doc, pos.line)
    if enter_opens_block(a, b, pos) {
        return grow_indent(lead, a.indent)
    }
    return lead
}

// The last non-blank char before the caret is an opener `([{` that is real code — tree-sitter
// rules out one inside a string or comment where a grammar exists.
@(private = "file")
enter_opens_block :: proc(a: ^App, b: ^Buffer, pos: Pos) -> bool {
    line := doc_line(&b.doc, pos.line)
    at := -1
    for i := min(pos.col, len(line)) - 1; i >= 0; i -= 1 {
        if line[i] != ' ' && line[i] != '\t' {
            at = i
            break
        }
    }
    if at < 0 {
        return false
    }
    switch line[at] {
    case '(', '[', '{':
        return !ts_in_string_or_comment(a, b, pos.line, at)
    }
    return false
}

// Quotes excluded: splitting a string across lines is not wanted.
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

// A sub-slice of the line's bytes, so read it before any edit.
@(private = "file")
line_lead :: proc(d: ^Doc, line: int) -> string {
    src := doc_line(d, line)
    return string(src[:line_indent_cols(src)])
}

@(private = "file")
grow_indent :: proc(lead: string, ind: Indent) -> string {
    return strings.concatenate({lead, indent_text(ind)}, context.temp_allocator)
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

// The `scroll_mode` policy, kept out of the renderer so it tests without GL. Follow moves the
// minimum once the caret would leave; Middle pins the topmost cursor. Both walk visible rows.
buffer_scroll_target :: proc(b: ^Buffer, rows: int, center: bool) -> int {
    if center {
        line := buffer_prev_visible(b, doc_top_cursor_line(&b.doc))
        return buffer_back_visible(b, line, rows / 2)
    }
    top := buffer_prev_visible(b, clamp(b.scroll, 0, doc_line_count(&b.doc) - 1))
    cur := b.cursors[b.primary].head.line
    if cur < top {
        return cur
    }
    if buffer_visible_count(b, top, cur) > rows {
        return buffer_back_visible(b, cur, rows - 1) // caret on the bottom row
    }
    return top
}

// The one place b.scroll is written per frame. While the wheel has the view detached the policy
// must not run — both modes derive the top from the caret. A keystroke re-attaches.
buffer_scroll_apply :: proc(b: ^Buffer, rows: int, center: bool, last_input_at: f64) {
    if b.scroll_detached > 0 && last_input_at > b.scroll_detached {
        b.scroll_detached = 0
    }
    if b.scroll_detached > 0 {
        // No policy, only bounds: any visible line may be the top.
        b.scroll = buffer_prev_visible(b, clamp(b.scroll, 0, max(0, doc_line_count(&b.doc) - 1)))
        return
    }
    b.scroll = buffer_scroll_target(b, rows, center)
}

// The wheel's entry point. buffer_scroll_apply snaps the result onto a visible line, so folds
// need no handling here.
buffer_scroll_by :: proc(b: ^Buffer, delta: int, now: f64) {
    b.scroll = clamp(b.scroll + delta, 0, max(0, doc_line_count(&b.doc) - 1))
    b.scroll_detached = now
}

// --- the column axis --- No soft wrap: a long line is reached by moving the window sideways.
// The three procs below mirror the vertical set — target, apply, by — so both axes detach,
// re-attach and animate alike, and only the policy differs.

// Columns of context between the caret and either edge, so you can see what you are about to
// type over rather than the caret butting against the clip.
HSCROLL_PAD :: 8

// The vertical policy's twin, with no Middle mode: pinning to the centre reads fine down a page
// but sideways it slides the whole file under every keystroke past the halfway column. So the
// column axis is always the margin policy — hold inside the padded window, then move the
// minimum. The margin halves out on a narrow pane, or two margins wider than the region between
// them would each pull the opposite way.
buffer_hscroll_target :: proc(left, col, cols: int) -> int {
    if cols <= 0 {
        return 0
    }
    pad := min(HSCROLL_PAD, (cols - 1) / 2)
    l := max(0, left)
    if col - pad < l {
        return max(0, col - pad) // the clamp also snaps a near-home caret to column 0
    }
    if col + pad > l + cols - 1 {
        return col + pad - cols + 1
    }
    return l
}

// The one place b.hscroll is written per frame. `longest` is the widest line the window is
// DRAWING, which bounds the view: blank space is not a place to be scrolled to.
//
// Call after buffer_scroll_apply, whose result it reads: the caret is only on screen while the
// vertical view follows it, so a detached page holds its column too.
buffer_hscroll_apply :: proc(b: ^Buffer, cols, longest: int, last_input_at: f64) {
    if b.hscroll_detached > 0 && last_input_at > b.hscroll_detached {
        b.hscroll_detached = 0
    }
    limit := max(0, longest + HSCROLL_PAD - cols + 1)
    if b.hscroll_detached > 0 || b.scroll_detached > 0 {
        b.hscroll = clamp(b.hscroll, 0, limit)
        return
    }
    col := doc_cell_col(&b.doc, b.cursors[b.primary].head) // the axis is CELLS
    b.hscroll = clamp(buffer_hscroll_target(b.hscroll, col, cols), 0, limit)
}

// Shift+wheel's entry point. Only the lower bound: the callback has no font and no pane rect,
// so buffer_hscroll_apply bounds the top next frame, with one notch of overshoot at most.
buffer_hscroll_by :: proc(b: ^Buffer, delta: int, now: f64) {
    b.hscroll = max(0, b.hscroll + delta)
    b.hscroll_detached = now
}

// --- movement --- select=true (Shift) grows a selection; all=true (the Alt+M prefix) moves
// every cursor rather than the free caret.

buffer_motion :: proc(b: ^Buffer, motion: Motion, select := false, all := false, count := 1) {
    buffer_sync_folds(b) // an earlier same-frame edit may have invalidated the folds
    if all {
        doc_move_all(&b.doc, motion, select, count)
    } else {
        doc_move(&b.doc, motion, select, count)
    }
    buffer_skip_hidden(b, motion)
}

// A cursor that stepped into a collapsed block snaps to the fold's visible edge in the
// direction it moved, so one keypress steps cleanly over a fold.
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
        // Vertical keeps the goal column; a horizontal wrap lands at the line edge it would
        // have reached.
        col :=
            vertical \
            ? doc_byte_col(&b.doc, target, c.goal) \
            : (forward ? 0 : doc_line_len(&b.doc, target))
        p := Pos{target, col}
        if !cursor_has_selection(c) {
            c.anchor = p
        }
        c.head = p
        if !vertical {
            c.goal = doc_cell_col(&b.doc, p)
        }
    }
    doc_merge_cursors(&b.doc)
}
