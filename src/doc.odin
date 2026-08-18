package main

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// The shared multi-cursor editing core under the command line and the editor buffer: a
// Piece_Table plus a list of Cursors. Single-cursor is N == 1. Pure — no rendering, no GL.
//
// A Pos is a line and a BYTE column, matching the storage and tree-sitter's Point, so nothing on
// the edit or parse path converts. The painter's cell grid is a different thing, and doc_cells /
// doc_cell_col are the only bridge. doc_clamp_pos is the one gate guaranteeing a column lands on
// a rune boundary, and every Pos built from arithmetic passes through it.
//
// Invariants: >= 1 line, >= 1 cursor, cursors sorted by head and non-overlapping. `primary` is
// the cursor driving scroll-follow and the gutter; after an edit it falls back to the topmost.
Doc :: struct {
    pt:      Piece_Table,
    cursors: [dynamic]Cursor,
    primary: int,
    undo:    Undo, // patch journal (undo.odin)
    version: u64, // bumped on every content change; lets the highlighter cache its tree
    // The change log, in apply order. Several readers follow it (Doc_Reader), so it is not
    // drained by the first: each keeps a sequence number and the log drops what all have passed.
    changes:      [dynamic]Doc_Change,
    changes_base: u64, // sequence number of changes[0]
    changes_next: u64, // one past the last recorded
    seen:         [Doc_Reader]u64, // how far each reader has got
}

// Fixed rather than a registration list: two of them, both living as long as the Doc.
Doc_Reader :: enum {
    Highlight, // folds each change into the cached parse tree (highlight.odin)
    Folds,     // shifts collapsed ranges so an edit elsewhere does not drop them (fold.odin)
}

// Both byte offsets and points, because tree-sitter's Input_Edit wants both. Offsets are in the
// document as it stood when the change was applied, so a reader must replay the list in order.
Doc_Change :: struct {
    start, old_end, new_end:          int,
    start_pt, old_end_pt, new_end_pt: Pos,
}

// How far the log may run ahead of its slowest reader. Past it the log is dropped and everyone
// behind is told they lost it — a rebuild costs less than an unbounded list.
DOC_CHANGE_MAX :: 256

Pos :: struct {
    line: int,
    col:  int, // BYTES into the line
}

// anchor == head means no selection; head is the moving caret. goal is the sticky column for
// vertical motion, in CELLS — a byte column would drift through multi-byte lines.
Cursor :: struct {
    anchor: Pos,
    head:   Pos,
    goal:   int,
}

// --- lifecycle ---

doc_init :: proc(d: ^Doc) {
    pt_init(&d.pt)
    append(&d.cursors, Cursor{})
}

doc_destroy :: proc(d: ^Doc) {
    pt_destroy(&d.pt)
    delete(d.cursors)
    delete(d.changes)
    undo_destroy(d)
}

// Replaces all content, collapses to one cursor at the origin, and discards undo history. CRLF
// collapses to LF and one trailing newline is dropped — Buffer puts it back on save.
doc_set_text :: proc(d: ^Doc, text: string) {
    undo_destroy(d)
    pt_load(&d.pt, doc_normalize(text))
    doc_reset_cursor(d, {})
    // Nothing can track a wholesale replacement, so every reader rebuilds from scratch.
    doc_changes_reset(d)
    d.version += 1
}

doc_clear :: proc(d: ^Doc) {
    doc_set_text(d, "")
}

doc_reset_cursor :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = q, head = q, goal = doc_cell_col(d, q)})
    d.primary = 0
}

// Esc out of a trail: keep only the primary.
doc_collapse_to_primary :: proc(d: ^Doc) {
    p := d.cursors[d.primary]
    clear(&d.cursors)
    append(&d.cursors, p)
    d.primary = 0
}

// Alt+A: leave a fixed cursor where the free caret is, which keeps roaming. The coincident pair
// collapses to one at the next edit.
doc_drop_anchor :: proc(d: ^Doc) {
    c := d.cursors[d.primary]
    append(&d.cursors, Cursor{anchor = c.head, head = c.head, goal = c.goal})
}

// --- reading ---

doc_line_count :: proc(d: ^Doc) -> int {
    return pt_line_count(&d.pt)
}

doc_line_len :: proc(d: ^Doc, line: int) -> int {
    return pt_line_len(&d.pt, line)
}

// Without the newline. Borrowed from the piece table when the line is one piece, copied into
// `alloc` when an edit split it. Read only, and dead after the next edit.
doc_line :: proc(d: ^Doc, line: int, alloc := context.temp_allocator) -> []u8 {
    return pt_line(&d.pt, line, alloc)
}

// The pair every edit crosses. Both clamp.
doc_off :: proc(d: ^Doc, p: Pos) -> int {
    q := doc_clamp_pos(d, p)
    return d.pt.lines[q.line] + q.col
}

doc_pos :: proc(d: ^Doc, off: int) -> Pos {
    o := clamp(off, 0, d.pt.size)
    line := pt_line_at_off(&d.pt, o)
    return Pos{line, o - d.pt.lines[line]}
}

doc_string :: proc(d: ^Doc, allocator := context.allocator) -> string {
    return string(pt_read(&d.pt, 0, d.pt.size, allocator))
}

cursor_has_selection :: proc(c: Cursor) -> bool {
    return c.anchor != c.head
}

// The primary drives the gutter, but a centred viewport should hold the top of the SET. Cursors
// are not kept globally sorted, so scan.
doc_top_cursor_line :: proc(d: ^Doc) -> int {
    line := d.cursors[0].head.line
    for c in d.cursors[1:] {
        line = min(line, c.head.line)
    }
    return line
}

cursor_range :: proc(c: Cursor) -> (lo, hi: Pos) {
    if pos_less(c.head, c.anchor) {
        return c.head, c.anchor
    }
    return c.anchor, c.head
}

pos_less :: proc(a, b: Pos) -> bool {
    return a.line < b.line || (a.line == b.line && a.col < b.col)
}

// --- the cell grid --- The painter draws CELLS, one per rune; the document counts BYTES. The
// two agree until a line holds a multi-byte rune, and this is the bridge. An ASCII line costs
// one scan and no allocation.

// `offs` has one entry more than `runes`, the last being the line's byte length, so a cell range
// converts with no special case at the end. Temp-allocated: valid for the frame.
Cells :: struct {
    runes: []rune,
    offs:  []int,
}

doc_cells :: proc(d: ^Doc, line: int, alloc := context.temp_allocator) -> Cells {
    src := doc_line(d, line, alloc)
    rs := make([dynamic]rune, 0, len(src), alloc)
    offs := make([dynamic]int, 0, len(src) + 1, alloc)
    for i := 0; i < len(src); {
        r, sz := utf8.decode_rune(src[i:])
        append(&rs, r)
        append(&offs, i)
        i += max(sz, 1)
    }
    append(&offs, len(src))
    return Cells{rs[:], offs[:]}
}

cells_count :: proc(c: Cells) -> int {
    return len(c.runes)
}

// Without building the table: the column bound and the highlighter's row ask once per drawn row
// and need no allocation for it.
doc_cell_count :: proc(d: ^Doc, line: int) -> int {
    src := doc_line(d, line)
    n := 0
    for i := 0; i < len(src); n += 1 {
        _, sz := utf8.decode_rune(src[i:])
        i += max(sz, 1)
    }
    return n
}

// The cell a byte column sits at (rounded up onto a rune boundary), and the byte column a cell
// starts at. A binary search because the highlighter asks twice per capture per row.
cells_col :: proc(c: Cells, byte_col: int) -> int {
    lo, hi := 0, len(c.offs)
    for lo < hi {
        mid := (lo + hi) / 2
        if c.offs[mid] < byte_col {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return min(lo, len(c.runes))
}

cells_off :: proc(c: Cells, cell: int) -> int {
    return c.offs[clamp(cell, 0, len(c.runes))]
}

// The two conversions that do not need the whole table, so they walk instead of building one.
doc_cell_col :: proc(d: ^Doc, p: Pos) -> int {
    src := doc_line(d, p.line)
    n := 0
    for i := 0; i < min(p.col, len(src)); n += 1 {
        _, sz := utf8.decode_rune(src[i:])
        i += max(sz, 1)
    }
    return n
}

doc_byte_col :: proc(d: ^Doc, line, cell: int) -> int {
    src := doc_line(d, line)
    i, n := 0, 0
    for i < len(src) && n < cell {
        _, sz := utf8.decode_rune(src[i:])
        i += max(sz, 1)
        n += 1
    }
    return i
}

// --- pointer-placed cursors --- Keyboard ops are motions; a pointer names an absolute
// position. All clamp — a stale layout must never index out of bounds.

// Onto a real line, a real column, and a rune boundary. The one gate every derived Pos passes
// through: a column landing mid-rune would split a character on the next edit.
doc_clamp_pos :: proc(d: ^Doc, p: Pos) -> Pos {
    line := clamp(p.line, 0, doc_line_count(d) - 1)
    src := doc_line(d, line)
    col := clamp(p.col, 0, len(src))
    for col > 0 && col < len(src) && src[col] & 0xC0 == 0x80 {
        col -= 1 // continuation byte: back to the rune's start
    }
    return Pos{line, col}
}

// select=true keeps the anchor (shift-click); false collapses onto the new position. The same
// `cursor_place` a keyboard motion uses, with a destination instead of a direction.
doc_set_head :: proc(d: ^Doc, p: Pos, select: bool) {
    q := doc_clamp_pos(d, p)
    c := &d.cursors[d.primary]
    cursor_place(c, q, select)
    c.goal = doc_cell_col(d, q)
}

// Alt+click. Unlike doc_drop_anchor the NEW cursor is the one that goes on to move. No merge: a
// coincident drop stays a pair, collapsing at the next edit.
doc_add_cursor :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    append(&d.cursors, Cursor{anchor = q, head = q, goal = doc_cell_col(d, q)})
    d.primary = len(d.cursors) - 1
}

// What a drag needs, since a word-grade drag re-derives both ends every frame. The order is the
// gesture's and not normalised: the head stays where the eye is, and cursor_range orders on read.
doc_select_span :: proc(d: ^Doc, anchor, head: Pos) {
    a := doc_clamp_pos(d, anchor)
    h := doc_clamp_pos(d, head)
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = a, head = h, goal = doc_cell_col(d, h)})
    d.primary = 0
}

// The double-click. The head is the run's END, so a following Shift+Right extends forward.
doc_select_word :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    lo, hi := word_span(doc_line(d, q.line), q.col)
    doc_select_span(d, Pos{q.line, lo}, Pos{q.line, hi})
}

// The triple-click. The span is the line's TEXT, not the line plus its break — exactly what
// Home then Shift+End selects.
doc_select_line :: proc(d: ^Doc, line: int) {
    anchor, head := line_span(d, line)
    doc_select_span(d, anchor, head)
}

// Ctrl+L, which is the triple-click at every cursor: the trail is kept, since collapsing it
// would undo an Alt+A this verb has nothing to do with. Two cursors on one line fuse.
doc_select_lines :: proc(d: ^Doc) {
    for &c in d.cursors {
        c.anchor, c.head = line_span(d, c.head.line)
        c.goal = doc_cell_col(d, c.head)
    }
    doc_merge_cursors(d)
}

// Ctrl+A. One selection over everything, the head at the end so a following Shift+motion grows
// from where the eye is.
doc_select_all :: proc(d: ^Doc) {
    last := doc_line_count(d) - 1
    doc_select_span(d, Pos{0, 0}, Pos{last, doc_line_len(d, last)})
}

@(private = "file")
line_span :: proc(d: ^Doc, line: int) -> (anchor, head: Pos) {
    l := clamp(line, 0, doc_line_count(d) - 1)
    return Pos{l, 0}, Pos{l, doc_line_len(d, l)}
}

// Word (2) or line (3+); grade 1 is doc_set_head. `press` and `at` carry glyph positions, not
// caret boundaries. Expanded per frame, so a double-click-drag grows by whole words.
doc_drag_span :: proc(d: ^Doc, grade: int, press, at: Pos) -> (anchor, head: Pos) {
    p := doc_clamp_pos(d, press)
    q := doc_clamp_pos(d, at)
    if grade >= 3 {
        // Compare LINES, not positions: dragging left within the pressed line has not
        // reversed the gesture.
        if q.line >= p.line {
            return Pos{p.line, 0}, Pos{q.line, doc_line_len(d, q.line)}
        }
        return Pos{p.line, doc_line_len(d, p.line)}, Pos{q.line, 0}
    }
    plo, phi := word_span(doc_line(d, p.line), p.col)
    qlo, qhi := word_span(doc_line(d, q.line), q.col)
    if !pos_less(q, p) {
        return Pos{p.line, plo}, Pos{q.line, qhi}
    }
    return Pos{p.line, phi}, Pos{q.line, qlo}
}

// The command line's "park at end" after a text swap.
doc_cursor_to_end :: proc(d: ^Doc) {
    last := doc_line_count(d) - 1
    doc_reset_cursor(d, Pos{last, doc_line_len(d, last)})
}

// --- editing --- Every edit funnels through doc_apply: non-overlapping replacements, one per
// cursor, applied back-to-front so the earlier ones keep valid offsets.

doc_insert_rune :: proc(d: ^Doc, r: rune) -> bool {
    return doc_insert_text(d, utf8.runes_to_string({r}, context.temp_allocator))
}

// `text` may contain '\n'. Shared by typing, indent, newline and paste.
doc_insert_text :: proc(d: ^Doc, text: string) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        lo, hi := cursor_range(c)
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), text, 0})
    }
    return doc_commit(d, edits[:])
}

doc_newline :: proc(d: ^Doc) -> bool {
    return doc_insert_text(d, "\n")
}

// --- clipboard (GLFW I/O lives in input.odin) ---

// Newlines are stored bytes, so a span across lines carries them already.
doc_text :: proc(d: ^Doc, lo, hi: Pos, alloc := context.allocator) -> string {
    return string(pt_read(&d.pt, doc_off(d, lo), doc_off(d, hi), alloc))
}

// Each cursor's selection, or with nothing selected each cursor's whole line plus a newline.
// `pieces` is an exact-length clone, because the caller frees it with `delete`.
doc_copy :: proc(d: ^Doc, alloc := context.allocator) -> (joined: string, pieces: []string) {
    order := cursor_order(d, context.temp_allocator)
    any_sel := false
    for c in d.cursors {
        if cursor_has_selection(c) {
            any_sel = true
            break
        }
    }
    out := make([dynamic]string, 0, len(order), context.temp_allocator)
    for idx in order {
        c := d.cursors[idx]
        if any_sel {
            if !cursor_has_selection(c) {
                continue
            }
            lo, hi := cursor_range(c)
            append(&out, doc_text(d, lo, hi, alloc))
        } else {
            line := c.head.line
            content := doc_text(d, Pos{line, 0}, Pos{line, doc_line_len(d, line)}, alloc)
            append(&out, strings.concatenate({content, "\n"}, alloc))
        }
    }
    sep := any_sel ? "\n" : ""
    return strings.join(out[:], sep, alloc), slice.clone(out[:], alloc)
}

// A plain paste: the same text at every cursor, replacing selections.
doc_paste :: proc(d: ^Doc, text: string) -> bool {
    return doc_insert_text(d, text)
}

// One piece per cursor in document order. Caller guarantees len(pieces) == cursor count.
doc_paste_pieces :: proc(d: ^Doc, pieces: []string) -> bool {
    order := cursor_order(d, context.temp_allocator)
    edits := make([dynamic]Edit, 0, len(order), context.temp_allocator)
    for idx, k in order {
        lo, hi := cursor_range(d.cursors[idx])
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), pieces[k], 0})
    }
    return doc_commit(d, edits[:])
}

// Each cursor's selection, or its whole line when nothing is selected. Pair with doc_copy.
doc_cut :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        lo, hi := cursor_range(c)
        if !cursor_has_selection(c) {
            line := c.head.line
            lo = Pos{line, 0}
            hi = line < doc_line_count(d) - 1 ? Pos{line + 1, 0} : Pos{line, doc_line_len(d, line)}
        }
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0})
    }
    return doc_commit(d, edits[:])
}

// 0 at end of line. The twin below reads the rune BEFORE p, with the size to step back over it.
doc_rune_at :: proc(d: ^Doc, p: Pos) -> rune {
    src := doc_line(d, p.line)
    if p.col >= len(src) {
        return 0
    }
    r, _ := utf8.decode_rune(src[p.col:])
    return r
}

doc_rune_before :: proc(d: ^Doc, p: Pos) -> (r: rune, size: int) {
    src := doc_line(d, p.line)
    if p.col <= 0 {
        return 0, 0
    }
    r, size = utf8.decode_last_rune(src[:min(p.col, len(src))])
    return r, max(size, 1)
}

// The selection, else the rune to the left, else join with the previous line.
doc_backspace :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0})
        } else if c.head.col > 0 {
            prev, size := doc_rune_before(d, c.head)
            at := Pos{c.head.line, c.head.col - size}
            // Inside an empty auto-pair "()" both halves go.
            if close, ok := pair_close(prev); ok && doc_rune_at(d, c.head) == close {
                _, csz := utf8.encode_rune(close)
                append(&edits, Edit{doc_off(d, at), doc_off(d, c.head) + csz, "", 0})
            } else {
                append(&edits, Edit{doc_off(d, at), doc_off(d, c.head), "", 0})
            }
        } else if c.head.line > 0 {
            prev := c.head.line - 1
            append(&edits, Edit{doc_off(d, Pos{prev, doc_line_len(d, prev)}), doc_off(d, c.head), "", 0})
        }
    }
    return doc_commit(d, edits[:])
}

// The selection, else the rune to the right, else pull the next line up.
doc_delete :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0})
        } else if c.head.col < doc_line_len(d, c.head.line) {
            _, size := utf8.decode_rune(doc_line(d, c.head.line)[c.head.col:])
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, c.head) + max(size, 1), "", 0})
        } else if c.head.line < doc_line_count(d) - 1 {
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, Pos{c.head.line + 1, 0}), "", 0})
        }
    }
    return doc_commit(d, edits[:])
}

// Delete the word to the left, or join with the previous line at column 0.
doc_delete_word_back :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0})
        } else if c.head.col > 0 {
            to := word_left_index(doc_line(d, c.head.line), c.head.col)
            append(&edits, Edit{doc_off(d, Pos{c.head.line, to}), doc_off(d, c.head), "", 0})
        } else if c.head.line > 0 {
            prev := c.head.line - 1
            append(&edits, Edit{doc_off(d, Pos{prev, doc_line_len(d, prev)}), doc_off(d, c.head), "", 0})
        }
    }
    return doc_commit(d, edits[:])
}

// Delete the word to the right, or pull the next line up at end of line.
doc_delete_word_forward :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0})
        } else if c.head.col < doc_line_len(d, c.head.line) {
            to := word_right_index(doc_line(d, c.head.line), c.head.col)
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, Pos{c.head.line, to}), "", 0})
        } else if c.head.line < doc_line_count(d) - 1 {
            append(&edits, Edit{doc_off(d, c.head), doc_off(d, Pos{c.head.line + 1, 0}), "", 0})
        }
    }
    return doc_commit(d, edits[:])
}

// --- movement --- select=true extends; a plain move with a selection collapses to the edge it
// moves toward, GUI-style. Vertical motion keeps the goal column.

Motion :: enum {
    Left,
    Right,
    Word_Left,
    Word_Right,
    Home,
    End,
    Up,
    Down,
}

// Bare-arrow behaviour: only the primary moves. `count` applies to Up/Down only.
doc_move :: proc(d: ^Doc, motion: Motion, select := false, count := 1) {
    move_cursor(d, &d.cursors[d.primary], motion, select, count)
}

// The Alt+M one-shot prefix: every cursor together.
doc_move_all :: proc(d: ^Doc, motion: Motion, select := false, count := 1) {
    for &c in d.cursors {
        move_cursor(d, &c, motion, select, count)
    }
    doc_merge_cursors(d)
}

@(private = "file")
move_cursor :: proc(d: ^Doc, c: ^Cursor, motion: Motion, select: bool, count := 1) {
    switch motion {
    case .Left:
        if !select && cursor_has_selection(c^) {
            lo, _ := cursor_range(c^)
            cursor_place(c, lo, false)
        } else {
            cursor_place(c, pos_left(d, c.head), select)
        }
        c.goal = doc_cell_col(d, c.head)
    case .Right:
        if !select && cursor_has_selection(c^) {
            _, hi := cursor_range(c^)
            cursor_place(c, hi, false)
        } else {
            cursor_place(c, pos_right(d, c.head), select)
        }
        c.goal = doc_cell_col(d, c.head)
    case .Word_Left:
        cursor_place(c, Pos{c.head.line, word_left_index(doc_line(d, c.head.line), c.head.col)}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Word_Right:
        cursor_place(c, Pos{c.head.line, word_right_index(doc_line(d, c.head.line), c.head.col)}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Home:
        cursor_place(c, Pos{c.head.line, 0}, select)
        c.goal = 0
    case .End:
        cursor_place(c, Pos{c.head.line, doc_line_len(d, c.head.line)}, select)
        c.goal = doc_cell_col(d, c.head)
    case .Up:
        if c.head.line > 0 {
            line := max(0, c.head.line - count)
            cursor_place(c, Pos{line, doc_byte_col(d, line, c.goal)}, select)
        }
    case .Down:
        if c.head.line < doc_line_count(d) - 1 {
            line := min(doc_line_count(d) - 1, c.head.line + count)
            cursor_place(c, Pos{line, doc_byte_col(d, line, c.goal)}, select)
        }
    }
}

// --- internals ---

// The bytes in [lo, hi) become `text`. caret_delta nudges the resulting caret left of the
// inserted text's end, in bytes and on that line only: 1 lands inside a fresh ASCII pair, -1
// steps one past an existing close, 0 for ordinary edits.
Edit :: struct {
    lo, hi:      int,
    text:        string,
    caret_delta: int,
}

// Back-to-front, then the cursors are rebuilt collapsed onto each new end. Back-to-front keeps
// the offsets self-consistent: every edit sits after the ones still to be applied. Non-nil `rec`
// collects reversible patches for the undo journal. `edits_in` is read only.
doc_apply :: proc(d: ^Doc, edits_in: []Edit, rec: ^Batch = nil) -> bool {
    if len(edits_in) == 0 {
        return false
    }
    edits := slice.clone(edits_in, context.temp_allocator)
    slice.sort_by(edits, proc(a, b: Edit) -> bool {
        return a.lo < b.lo
    })

    // A free caret resting on a dropped cursor produces the same range twice.
    w := 0
    for r in 1 ..< len(edits) {
        if edits[r].lo != edits[w].lo || edits[r].hi != edits[w].hi {
            w += 1
            edits[w] = edits[r]
        }
    }
    edits = edits[:w + 1]

    // Where each edit's text ends up once the batch is done: `lo` is valid while it is applied,
    // but the edits before it land afterwards and move what follows. The cursors and the
    // journal's inverse both read the finished document, so both want this rather than `lo`.
    landed := make([]int, len(edits), context.temp_allocator)
    cum := 0
    for e, i in edits {
        landed[i] = e.lo + cum
        cum += len(e.text) - (e.hi - e.lo)
    }

    changed := false
    removed := make([]string, len(edits), context.temp_allocator)
    for i := len(edits) - 1; i >= 0; i -= 1 {
        e := edits[i]
        if e.lo != e.hi || len(e.text) > 0 {
            changed = true
        }
        removed[i] = string(pt_read(&d.pt, e.lo, e.hi, context.temp_allocator))
        // Either side of the splice: two of the three points read the document before it, the
        // third after. Back-to-front is the apply order, so it is the replay order too.
        ch := Doc_Change {
            start      = e.lo,
            old_end    = e.hi,
            new_end    = e.lo + len(e.text),
            start_pt   = doc_pos(d, e.lo),
            old_end_pt = doc_pos(d, e.hi),
        }
        pt_splice(&d.pt, e.lo, e.hi, transmute([]u8)e.text)
        if e.lo != e.hi || len(e.text) > 0 {
            ch.new_end_pt = doc_pos(d, ch.new_end)
            doc_record_change(d, ch)
        }
    }

    if rec != nil {
        for e, i in edits {
            if removed[i] == "" && e.text == "" {
                continue // no-op, e.g. backspace at the document origin
            }
            append(
                &rec.ops,
                Op {
                    at = e.lo,
                    inv_at = landed[i],
                    removed = strings.clone(removed[i]),
                    inserted = strings.clone(e.text),
                },
            )
        }
    }

    clear(&d.cursors)
    for e, i in edits {
        p := doc_pos(d, landed[i] + len(e.text))
        p.col = clamp(p.col - e.caret_delta, 0, doc_line_len(d, p.line)) // same line, by contract
        q := doc_clamp_pos(d, p)
        append(&d.cursors, Cursor{anchor = q, head = q, goal = doc_cell_col(d, q)})
    }
    d.primary = 0
    doc_merge_cursors(d)
    if changed {
        d.version += 1
    }
    return changed
}

// Oldest first. `lost` means the log no longer reaches back that far, so the reader rebuilds
// from the document; the changes returned with it are valid but not the whole story.
doc_changes_since :: proc(d: ^Doc, who: Doc_Reader) -> (changes: []Doc_Change, lost: bool) {
    if d.seen[who] < d.changes_base {
        return nil, true
    }
    return d.changes[d.seen[who] - d.changes_base:], false
}

// Trims the log to the slowest reader, which keeps it short while everyone keeps up.
doc_changes_ack :: proc(d: ^Doc, who: Doc_Reader) {
    d.seen[who] = d.changes_next
    slowest := d.changes_next
    for s in d.seen {
        slowest = min(slowest, s)
    }
    if slowest > d.changes_base {
        remove_range(&d.changes, 0, int(slowest - d.changes_base))
        d.changes_base = slowest
    }
}

// Anyone behind is told they lost it; anyone caught up is untouched. That matters: a buffer with
// no grammar has a highlighter that never acks, and the fold set must not lose its ranges for it.
@(private = "file")
doc_changes_drop :: proc(d: ^Doc) {
    clear(&d.changes)
    d.changes_base = d.changes_next
}

// A wholesale load: no edit to track through, so a current reader is as out of date as any.
@(private = "file")
doc_changes_reset :: proc(d: ^Doc) {
    d.changes_next += 1 // past every reader's `seen`
    doc_changes_drop(d)
}

@(private = "file")
doc_record_change :: proc(d: ^Doc, c: Doc_Change) {
    if len(d.changes) >= DOC_CHANGE_MAX {
        doc_changes_drop(d)
        return
    }
    append(&d.changes, c)
    d.changes_next += 1
}

// CRLF collapsed to LF and one trailing newline dropped — both the load's business; Buffer puts
// the newline back on save. Temp-allocated, and returns the input untouched when there is
// nothing to strip.
@(private = "file")
doc_normalize :: proc(text: string) -> []u8 {
    if !strings.contains(text, "\r") {
        return transmute([]u8)(strings.has_suffix(text, "\n") ? text[:len(text) - 1] : text)
    }
    // CR first, then the trailing newline: a CRLF file ends "\r\n", and trimming the '\n' first
    // would leave the '\r' on the last line.
    out := make([dynamic]u8, 0, len(text), context.temp_allocator)
    for i in 0 ..< len(text) {
        if text[i] == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
            continue
        }
        append(&out, text[i])
    }
    if len(out) > 0 && out[len(out) - 1] == '\n' {
        pop(&out)
    }
    return out[:]
}

// Cursor indices in document order, for clipboard ops that need a stable left-to-right one.
@(private = "file")
Keyed_Cursor :: struct {
    lo:  Pos,
    idx: int,
}

@(private = "file")
cursor_order :: proc(d: ^Doc, alloc := context.allocator) -> []int {
    keyed := make([]Keyed_Cursor, len(d.cursors), context.temp_allocator)
    for c, i in d.cursors {
        lo, _ := cursor_range(c)
        keyed[i] = {lo, i}
    }
    slice.sort_by(keyed, proc(a, b: Keyed_Cursor) -> bool {
        return pos_less(a.lo, b.lo)
    })
    out := make([]int, len(keyed), alloc)
    for k, i in keyed {
        out[i] = k.idx
    }
    return out
}

@(private = "file")
cursor_place :: proc(c: ^Cursor, to: Pos, select: bool) {
    c.head = to
    if !select {
        c.anchor = to
    }
}

// One rune left / right, wrapping across the line break.
@(private = "file")
pos_left :: proc(d: ^Doc, p: Pos) -> Pos {
    if p.col > 0 {
        _, size := doc_rune_before(d, p)
        return Pos{p.line, p.col - size}
    }
    if p.line > 0 {
        return Pos{p.line - 1, doc_line_len(d, p.line - 1)}
    }
    return p
}

@(private = "file")
pos_right :: proc(d: ^Doc, p: Pos) -> Pos {
    src := doc_line(d, p.line)
    if p.col < len(src) {
        _, size := utf8.decode_rune(src[p.col:])
        return Pos{p.line, p.col + max(size, 1)}
    }
    if p.line < doc_line_count(d) - 1 {
        return Pos{p.line + 1, 0}
    }
    return p
}

// Sort by selection start and fuse any that overlap or touch.
@(private)
doc_merge_cursors :: proc(d: ^Doc) {
    if len(d.cursors) <= 1 {
        return
    }
    slice.sort_by(d.cursors[:], proc(a, b: Cursor) -> bool {
        alo, _ := cursor_range(a)
        blo, _ := cursor_range(b)
        return pos_less(alo, blo)
    })
    w := 0
    for r in 1 ..< len(d.cursors) {
        alo, ahi := cursor_range(d.cursors[w])
        blo, bhi := cursor_range(d.cursors[r])
        if pos_less(ahi, blo) { // disjoint
            w += 1
            d.cursors[w] = d.cursors[r]
        } else if pos_less(ahi, bhi) { // overlap: fuse into the union
            d.cursors[w] = Cursor{anchor = alo, head = bhi, goal = doc_cell_col(d, bhi)}
        }
    }
    resize(&d.cursors, w + 1)
    d.primary = clamp(d.primary, 0, w)
}
