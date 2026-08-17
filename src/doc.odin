package main

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Doc — the shared multi-cursor editing core beneath the command line and the editor buffer. A
// Piece_Table holding the bytes plus a list of Cursors; single-cursor is just N == 1, and the
// command line is the one-line instance (Enter submits instead of splitting). Pure: no rendering
// and no GL.
//
// **A Pos is a line and a BYTE column**, matching the storage and tree-sitter's Point exactly, so
// nothing on the edit or parse path converts. The cell grid the monospace painter draws on is a
// different thing, and doc_cells / doc_cell_col are the only bridge to it. A column always lands
// on a rune boundary — doc_clamp_pos is the one gate that guarantees it, and every Pos built from
// arithmetic passes through it.
//
// Invariants, held by every op: >= 1 line, >= 1 cursor, cursors sorted by head ascending and
// non-overlapping (merged). `primary` indexes the cursor that drives scroll-follow and the gutter
// — for the drop-mode trail it tracks the painting end; after an edit it falls back to the
// topmost cursor.
Doc :: struct {
    pt:      Piece_Table,
    cursors: [dynamic]Cursor,
    primary: int,
    undo:    Undo, // patch journal (see undo.odin)
    version: u64, // bumped on every content change; lets the highlighter cache its tree
    // The change log: what happened, in the order it was applied. More than one part of the
    // editor has to follow it (see Doc_Reader), so it is NOT drained by whoever reads it first
    // — each reader keeps a sequence number and the log drops what every reader has passed.
    changes:      [dynamic]Doc_Change,
    changes_base: u64, // sequence number of changes[0]
    changes_next: u64, // one past the last recorded
    seen:         [Doc_Reader]u64, // how far each reader has got
}

// The parts that follow the change log. A fixed set rather than a registration list: there are
// two of them, they live for as long as the Doc does, and a slot each is the whole mechanism.
Doc_Reader :: enum {
    Highlight, // folds each change into the cached parse tree (highlight.odin)
    Folds,     // shifts collapsed ranges so an edit elsewhere does not drop them (fold.odin)
}

// One content change, as both byte offsets and line/column points, because tree-sitter's
// Input_Edit wants both. The offsets are in the document as it stood when this change was
// applied, so a reader must replay the list IN ORDER and never out of it.
Doc_Change :: struct {
    start, old_end, new_end:          int,
    start_pt, old_end_pt, new_end_pt: Pos,
}

// How far the log may run ahead of its slowest reader. Past it the log is dropped and everyone
// behind is told they lost it — a rebuild costs less than an unbounded list, and a document
// nobody is looking at (a buffer edited off-screen) should not grow one. Readers that keep up
// never reach this: the log trims to the slowest on every ack.
DOC_CHANGE_MAX :: 256

Pos :: struct {
    line: int,
    col:  int, // BYTES into the line
}

// A cursor is a selection: anchor..head. anchor == head means no selection; head is the moving
// caret. goal is the sticky column carried through vertical motion, in CELLS — a byte column
// would drift sideways stepping through lines that hold multi-byte runes.
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

// Replaces all content; collapses to a single cursor at the origin (file load), and discards undo
// history (you can't undo past a fresh load). CRLF collapses to LF and one trailing newline is
// dropped — Buffer remembers it as final_newline and puts it back on save.
doc_set_text :: proc(d: ^Doc, text: string) {
    undo_destroy(d)
    pt_load(&d.pt, doc_normalize(text))
    doc_reset_cursor(d, {})
    // A wholesale replacement is not an edit anything can track through, so every reader is put
    // behind the log's base and rebuilds from scratch rather than from nonsense.
    doc_changes_reset(d)
    d.version += 1
}

// Empties the document back to one blank line with a single cursor at the origin.
doc_clear :: proc(d: ^Doc) {
    doc_set_text(d, "")
}

// Collapses to a single cursor at p.
doc_reset_cursor :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = q, head = q, goal = doc_cell_col(d, q)})
    d.primary = 0
}

// Drops the rest of the cursors, keeping only the primary (Esc out of a trail).
doc_collapse_to_primary :: proc(d: ^Doc) {
    p := d.cursors[d.primary]
    clear(&d.cursors)
    append(&d.cursors, p)
    d.primary = 0
}

// Leaves a fixed cursor at the free caret's position (the Alt+A drop); the caret (primary)
// keeps roaming via the movement ops. The two sit coincident until the caret steps off, and
// a coincident pair collapses to one when an edit is applied.
doc_drop_anchor :: proc(d: ^Doc) {
    c := d.cursors[d.primary]
    append(&d.cursors, Cursor{anchor = c.head, head = c.head, goal = c.goal})
}

// --- reading ---

doc_line_count :: proc(d: ^Doc) -> int {
    return pt_line_count(&d.pt)
}

// A line's length in BYTES.
doc_line_len :: proc(d: ^Doc, line: int) -> int {
    return pt_line_len(&d.pt, line)
}

// A line's bytes, without its newline. Borrowed straight out of the piece table when the line
// sits in one piece and copied into `alloc` when an edit has split it — READ ONLY either way,
// and dead after the next edit.
doc_line :: proc(d: ^Doc, line: int, alloc := context.temp_allocator) -> []u8 {
    return pt_line(&d.pt, line, alloc)
}

// A Pos as a document byte offset, and back. The pair every edit crosses; both clamp, so neither
// can be handed an offset that indexes off the end.
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

// The line of the FIRST (topmost) cursor. The primary drives the gutter, but "the cursor" is
// a SET, so a centred viewport should hold the top of it rather than the primary. Cursors
// aren't kept globally sorted, so scan.
doc_top_cursor_line :: proc(d: ^Doc) -> int {
    line := d.cursors[0].head.line
    for c in d.cursors[1:] {
        line = min(line, c.head.line)
    }
    return line
}

// The cursor's selection as an ordered (low, high) position pair.
cursor_range :: proc(c: Cursor) -> (lo, hi: Pos) {
    if pos_less(c.head, c.anchor) {
        return c.head, c.anchor
    }
    return c.anchor, c.head
}

pos_less :: proc(a, b: Pos) -> bool {
    return a.line < b.line || (a.line == b.line && a.col < b.col)
}

// --- the cell grid ---
//
// The painter draws a monospace grid of CELLS, one per rune; the document counts BYTES. The two
// agree until a line holds a multi-byte rune, and everything below is the bridge. An ASCII line
// costs one scan and no allocation, which is the case that has to stay free.

// One line's runes with the byte offset each begins at. `offs` has one entry more than `runes`,
// the last being the line's byte length, so a cell RANGE converts to a byte range with no
// special case at the end. Temp-allocated: valid for the frame.
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

// How wide a line is in cells, WITHOUT building the table — the sizing question on its own,
// which the column bound and the highlighter's row both ask once per drawn row and neither
// needs an allocation for.
doc_cell_count :: proc(d: ^Doc, line: int) -> int {
    src := doc_line(d, line)
    n := 0
    for i := 0; i < len(src); n += 1 {
        _, sz := utf8.decode_rune(src[i:])
        i += max(sz, 1)
    }
    return n
}

// The cell a byte column sits at (rounded up onto the next rune boundary), and the byte column a
// cell starts at. Both clamp to the line. A binary search rather than a walk because the
// highlighter asks twice per capture per row, and a long line carries a lot of captures.
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

// The cell column of a Pos, and the byte column of a cell — the two conversions that do not need
// the whole table, so they walk the line instead of building one.
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

// --- pointer-placed cursors ---
// Keyboard ops are motions; a pointer names an absolute position, so these are new verbs
// mirroring the keyboard shapes. All clamp — a stale layout must never index out of bounds.

// Clamp a position onto a real line, a real column, and a RUNE BOUNDARY. The single gate every
// derived Pos passes through — the procs below take arbitrary Pos values and none may trust one,
// and a column landing mid-rune would split a character on the next edit.
doc_clamp_pos :: proc(d: ^Doc, p: Pos) -> Pos {
    line := clamp(p.line, 0, doc_line_count(d) - 1)
    src := doc_line(d, line)
    col := clamp(p.col, 0, len(src))
    for col > 0 && col < len(src) && src[col] & 0xC0 == 0x80 {
        col -= 1 // a continuation byte: back onto the start of the rune it belongs to
    }
    return Pos{line, col}
}

// Move the primary cursor's head to `p`. select=true keeps the anchor, growing the selection
// (shift-click); false collapses onto the new position. The same `cursor_place` a keyboard
// motion uses, reached with a destination instead of a direction.
doc_set_head :: proc(d: ^Doc, p: Pos, select: bool) {
    q := doc_clamp_pos(d, p)
    c := &d.cursors[d.primary]
    cursor_place(c, q, select)
    c.goal = doc_cell_col(d, q)
}

// Add a cursor AT `p` and make it the roaming one (Alt+click) — a pointer names the
// destination, so unlike `doc_drop_anchor` the NEW cursor is the one that goes on to move.
// Deliberately no merge: a coincident drop stays a coincident pair, collapsing at the next edit.
doc_add_cursor :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    append(&d.cursors, Cursor{anchor = q, head = q, goal = doc_cell_col(d, q)})
    d.primary = len(d.cursors) - 1
}

// Collapse to one cursor spanning anchor..head — the verb a DRAG needs, since a word-grade
// drag re-derives BOTH ends every frame. The order is the gesture's and deliberately not
// normalised: the head stays the end the eye is at, and `cursor_range` orders it on READ.
doc_select_span :: proc(d: ^Doc, anchor, head: Pos) {
    a := doc_clamp_pos(d, anchor)
    h := doc_clamp_pos(d, head)
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = a, head = h, goal = doc_cell_col(d, h)})
    d.primary = 0
}

// Collapse to one cursor selecting the run of one character class around `p` — the
// double-click. The head is the run's END, so a following shift-click or Shift+Right
// extends forward from where the eye is.
doc_select_word :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    lo, hi := word_span(doc_line(d, q.line), q.col)
    doc_select_span(d, Pos{q.line, lo}, Pos{q.line, hi})
}

// Collapse to one cursor selecting all of `line` — the triple-click. The span is the line's
// TEXT, not the line plus its break: it is exactly what Home then Shift+End selects, so a
// copy from either path yields the same string.
doc_select_line :: proc(d: ^Doc, line: int) {
    l := clamp(line, 0, doc_line_count(d) - 1)
    doc_select_span(d, Pos{l, 0}, Pos{l, doc_line_len(d, l)})
}

// The span a drag covers at its fixed GRADE — word (2) or line (3+); grade 1 is `doc_set_head`.
// `press` and `at` carry GLYPH positions, not caret boundaries: the boundary off the same pixel
// sits one past the run's end. Expanded per frame, so a double-click-drag grows by whole words.
doc_drag_span :: proc(d: ^Doc, grade: int, press, at: Pos) -> (anchor, head: Pos) {
    p := doc_clamp_pos(d, press)
    q := doc_clamp_pos(d, at)
    if grade >= 3 {
        // Line grade compares LINES, not positions: dragging left within the pressed line
        // has not reversed the gesture, it has not left the line.
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

// Collapses to a single cursor at the very end of the document (history recall,
// inject) — the command line's "park at end" after a text swap.
doc_cursor_to_end :: proc(d: ^Doc) {
    last := doc_line_count(d) - 1
    doc_reset_cursor(d, Pos{last, doc_line_len(d, last)})
}

// --- editing ---
// Every edit funnels through doc_apply: a list of non-overlapping replacements, one per cursor,
// applied back-to-front so the earlier ones keep valid offsets.

doc_insert_rune :: proc(d: ^Doc, r: rune) -> bool {
    return doc_insert_text(d, utf8.runes_to_string({r}, context.temp_allocator))
}

// Replaces each cursor's selection (or inserts at the caret) with `text`, which may contain
// '\n'. Shared by typing, indent, newline, and paste.
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

// --- clipboard (text gather/apply; GLFW I/O lives in input.odin) ---

// The text in [lo, hi). Newlines are stored bytes, so a span across lines carries them already.
doc_text :: proc(d: ^Doc, lo, hi: Pos, alloc := context.allocator) -> string {
    return string(pt_read(&d.pt, doc_off(d, lo), doc_off(d, hi), alloc))
}

// Gathers copy text in document order: each cursor's selection, or — nothing selected — each
// cursor's whole line plus a newline. Both results use `alloc`; `pieces` is an exact-length
// CLONE, because the caller frees it with `delete`, which sizes by len, not a dynamic's cap.
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

// Inserts the same text at every cursor (replacing selections) — a plain paste.
doc_paste :: proc(d: ^Doc, text: string) -> bool {
    return doc_insert_text(d, text)
}

// Distributes one piece per cursor in document order (multi-cursor paste of an
// equal-count multi-cursor copy). Caller guarantees len(pieces) == cursor count.
doc_paste_pieces :: proc(d: ^Doc, pieces: []string) -> bool {
    order := cursor_order(d, context.temp_allocator)
    edits := make([dynamic]Edit, 0, len(order), context.temp_allocator)
    for idx, k in order {
        lo, hi := cursor_range(d.cursors[idx])
        append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), pieces[k], 0})
    }
    return doc_commit(d, edits[:])
}

// Cut: delete each cursor's selection, or — when nothing is selected — its whole
// line. (Pair the deletion with doc_copy in the caller to fill the clipboard.)
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

// The rune at p, or 0 at end of line. Its twin reads the rune BEFORE p, with the byte size that
// steps back over it.
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

// Backspace: delete the selection, else the rune to the left, else join with the
// previous line (delete the newline before the caret).
doc_backspace :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{doc_off(d, lo), doc_off(d, hi), "", 0})
        } else if c.head.col > 0 {
            prev, size := doc_rune_before(d, c.head)
            at := Pos{c.head.line, c.head.col - size}
            // Backspace inside an empty auto-pair "()" removes both halves.
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

// Delete: delete the selection, else the rune to the right, else pull the next
// line up (delete the newline after the caret).
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

// --- movement ---
// select=true keeps the anchor to extend a selection; a plain move with a selection collapses
// to the edge it moves toward, GUI-style. Vertical motion keeps the goal column.

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

// Moves ONLY the free caret (the primary), leaving dropped cursors put — bare-arrow
// behaviour, the basis of cursor placement. `count` applies only to Up/Down (lines to jump).
doc_move :: proc(d: ^Doc, motion: Motion, select := false, count := 1) {
    move_cursor(d, &d.cursors[d.primary], motion, select, count)
}

// Moves every cursor together (the Alt+M one-shot prefix).
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

// One replacement: the bytes in [lo, hi) become `text` (which may span lines). caret_delta nudges
// the resulting caret left of the inserted text's end, in bytes and on that line only: 1 lands it
// inside a fresh ASCII pair, -1 steps one past an existing close, 0 for ordinary edits.
Edit :: struct {
    lo, hi:      int,
    text:        string,
    caret_delta: int,
}

// Applies non-overlapping edits (one per cursor) back-to-front, then rebuilds the cursors
// collapsed onto each new end. Back-to-front is what makes the offsets self-consistent: every
// edit sits after the ones still to be applied, so none of their offsets move and there is
// nothing to shift. Non-nil `rec` collects reversible patches for the undo journal. `edits_in`
// is READ ONLY — sort/dedup a copy.
doc_apply :: proc(d: ^Doc, edits_in: []Edit, rec: ^Batch = nil) -> bool {
    if len(edits_in) == 0 {
        return false
    }
    edits := slice.clone(edits_in, context.temp_allocator)
    slice.sort_by(edits, proc(a, b: Edit) -> bool {
        return a.lo < b.lo
    })

    // Drop coincident edits: a free caret resting on a dropped cursor produces the
    // same range twice, and one position must be edited once, not N times.
    w := 0
    for r in 1 ..< len(edits) {
        if edits[r].lo != edits[w].lo || edits[r].hi != edits[w].hi {
            w += 1
            edits[w] = edits[r]
        }
    }
    edits = edits[:w + 1]

    // Where each edit's text ends up ONCE THE BATCH IS DONE. An edit's own `lo` is valid while
    // it is applied — everything before it is still untouched — but the edits before it land
    // afterwards and each moves what follows, so the final home is `lo` plus their size change.
    // The cursors and the journal's inverse both read the document after all of this, and both
    // want this number rather than `lo`.
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
        // Recorded either side of the splice, because two of the three points are read from the
        // document before it and the third from the document after. Back-to-front is the order
        // these are APPLIED in, so it is the order a consumer must replay them in.
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
                continue // pure no-op (e.g. backspace at the document origin)
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
        p.col = clamp(p.col - e.caret_delta, 0, doc_line_len(d, p.line)) // same line only, by contract
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

// What `who` has not seen yet, oldest first. `lost` means the log no longer reaches back that
// far and the reader has to rebuild from the document instead of from the changes; the changes
// returned with it are still valid, they are simply not the whole story.
doc_changes_since :: proc(d: ^Doc, who: Doc_Reader) -> (changes: []Doc_Change, lost: bool) {
    if d.seen[who] < d.changes_base {
        return nil, true
    }
    return d.changes[d.seen[who] - d.changes_base:], false
}

// `who` is now in step with the document. Trims the log to the SLOWEST reader, which is what
// keeps it a handful of entries in the ordinary case where everyone keeps up.
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

// Drop the log because it outran its slowest reader. Anyone BEHIND is told they lost it; anyone
// who had caught up is untouched, and that distinction matters — a buffer whose language has no
// grammar installed has a highlighter that never acks, and it must not cost the fold set its
// ranges every DOC_CHANGE_MAX edits.
@(private = "file")
doc_changes_drop :: proc(d: ^Doc) {
    clear(&d.changes)
    d.changes_base = d.changes_next
}

// Put EVERY reader behind the log — a wholesale load, where there is no edit to track through
// and a reader that happened to be current is as out of date as one that was not.
@(private = "file")
doc_changes_reset :: proc(d: ^Doc) {
    d.changes_next += 1 // past every reader's `seen`, so none of them can still be in step
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

// The bytes a document stores for `text`: CRLF collapsed to LF, and one trailing newline
// dropped. Both are the load's business and nothing below it needs to know — a line is a run
// between newlines, and Buffer puts the trailing one back on save. Temp-allocated; returns the
// input untouched when there is nothing to strip, which is the common case.
@(private = "file")
doc_normalize :: proc(text: string) -> []u8 {
    if !strings.contains(text, "\r") {
        return transmute([]u8)(strings.has_suffix(text, "\n") ? text[:len(text) - 1] : text)
    }
    // The CR goes first and the trailing newline after it, in that order: a CRLF file ends in
    // "\r\n", and trimming the '\n' first would leave the '\r' hanging on the last line.
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

// Cursor indices in document order (cursors aren't kept globally sorted, only
// merged). Used by clipboard ops that need a stable left-to-right ordering.
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

// One rune left / right, wrapping across the line break at either end.
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

// Sorts cursors by selection start and fuses any that overlap or touch, keeping
// the multi-cursor set canonical. Single-cursor docs short-circuit.
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
        if pos_less(ahi, blo) { // disjoint: keep both
            w += 1
            d.cursors[w] = d.cursors[r]
        } else if pos_less(ahi, bhi) { // overlap: fuse into the union span
            d.cursors[w] = Cursor{anchor = alo, head = bhi, goal = doc_cell_col(d, bhi)}
        }
    }
    resize(&d.cursors, w + 1)
    d.primary = clamp(d.primary, 0, w)
}
