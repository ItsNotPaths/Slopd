package main

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Doc — the shared multi-cursor editing core beneath the command line and the
// editor buffer. A stack of pure Lines plus a list of Cursors; single-cursor is
// just N == 1, and the command line is the one-line instance (Enter submits
// instead of splitting). Pure: no rendering and no GL.
//
// Invariants, held by every op: >= 1 line, >= 1 cursor, cursors sorted by head
// ascending and non-overlapping (merged). `primary` indexes the cursor that
// drives scroll-follow and the gutter — for the drop-mode trail it tracks the
// painting end; after an edit it falls back to the topmost cursor.
Doc :: struct {
    lines:   [dynamic]Line,
    cursors: [dynamic]Cursor,
    primary: int,
    undo:    Undo, // diff/op journal (see undo.odin)
    version: u64, // bumped on every content change; lets the highlighter cache its tree
}

Pos :: struct {
    line: int,
    col:  int,
}

// A cursor is a selection: anchor..head. anchor == head means no selection; head
// is the moving caret. goal is the sticky column carried through vertical motion.
Cursor :: struct {
    anchor: Pos,
    head:   Pos,
    goal:   int,
}

// --- lifecycle ---

doc_init :: proc(d: ^Doc) {
    append(&d.lines, Line{})
    append(&d.cursors, Cursor{})
}

doc_destroy :: proc(d: ^Doc) {
    for &l in d.lines {
        line_destroy(&l)
    }
    delete(d.lines)
    delete(d.cursors)
    undo_destroy(d)
}

// Replaces all content; collapses to a single cursor at the origin (file load),
// and discards undo history (you can't undo past a fresh load).
doc_set_text :: proc(d: ^Doc, text: string) {
    undo_destroy(d)
    for &l in d.lines {
        line_destroy(&l)
    }
    clear(&d.lines)
    rest := text
    for raw in strings.split_lines_iterator(&rest) {
        l: Line
        for r in strings.trim_suffix(raw, "\r") {
            append(&l.text, r)
        }
        append(&d.lines, l)
    }
    if len(d.lines) == 0 {
        append(&d.lines, Line{})
    }
    doc_reset_cursor(d, {})
    d.version += 1 // wholesale replacement invalidates any cached highlight tree
}

// Empties the document back to one blank line with a single cursor at the origin.
doc_clear :: proc(d: ^Doc) {
    doc_set_text(d, "")
}

// Collapses to a single cursor at p.
doc_reset_cursor :: proc(d: ^Doc, p: Pos) {
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = p, head = p, goal = p.col})
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
    p := d.cursors[d.primary].head
    append(&d.cursors, Cursor{anchor = p, head = p, goal = p.col})
}

// --- pointer-placed cursors ---
// Keyboard ops are motions; a pointer names an absolute position, so these are new verbs
// mirroring the keyboard shapes. All clamp — a stale layout must never index out of bounds.

// Clamp a position onto a real line and column. The single gate every pointer-derived Pos
// passes through — the procs below take arbitrary Pos values and none of them may trust one.
doc_clamp_pos :: proc(d: ^Doc, p: Pos) -> Pos {
    line := clamp(p.line, 0, len(d.lines) - 1)
    return Pos{line, clamp(p.col, 0, line_len(&d.lines[line]))}
}

// Move the primary cursor's head to `p`. select=true keeps the anchor, growing the selection
// (shift-click); false collapses onto the new position. The same `cursor_place` a keyboard
// motion uses, reached with a destination instead of a direction.
doc_set_head :: proc(d: ^Doc, p: Pos, select: bool) {
    q := doc_clamp_pos(d, p)
    c := &d.cursors[d.primary]
    cursor_place(c, q, select)
    c.goal = q.col
}

// Add a cursor AT `p` and make it the roaming one (Alt+click) — a pointer names the
// destination, so unlike `doc_drop_anchor` the NEW cursor is the one that goes on to move.
// Deliberately no merge: a coincident drop stays a coincident pair, collapsing at the next edit.
doc_add_cursor :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    append(&d.cursors, Cursor{anchor = q, head = q, goal = q.col})
    d.primary = len(d.cursors) - 1
}

// Collapse to one cursor spanning anchor..head — the verb a DRAG needs, since a word-grade
// drag re-derives BOTH ends every frame. The order is the gesture's and deliberately not
// normalised: the head stays the end the eye is at, and `cursor_range` orders it on READ.
doc_select_span :: proc(d: ^Doc, anchor, head: Pos) {
    a := doc_clamp_pos(d, anchor)
    h := doc_clamp_pos(d, head)
    clear(&d.cursors)
    append(&d.cursors, Cursor{anchor = a, head = h, goal = h.col})
    d.primary = 0
}

// Collapse to one cursor selecting the run of one character class around `p` — the
// double-click. The head is the run's END, so a following shift-click or Shift+Right
// extends forward from where the eye is.
doc_select_word :: proc(d: ^Doc, p: Pos) {
    q := doc_clamp_pos(d, p)
    lo, hi := word_span(d.lines[q.line].text[:], q.col)
    doc_select_span(d, Pos{q.line, lo}, Pos{q.line, hi})
}

// Collapse to one cursor selecting all of `line` — the triple-click. The span is the line's
// TEXT, not the line plus its break: it is exactly what Home then Shift+End selects, so a
// copy from either path yields the same string.
doc_select_line :: proc(d: ^Doc, line: int) {
    l := clamp(line, 0, len(d.lines) - 1)
    doc_select_span(d, Pos{l, 0}, Pos{l, line_len(&d.lines[l])})
}

// The span a drag covers at its fixed GRADE — word (2) or line (3+); grade 1 is `doc_set_head`.
// `press` and `at` carry GLYPH columns, not caret boundaries: the boundary off the same pixel
// sits one past the run's end. Expanded per frame, so a double-click-drag grows by whole words.
doc_drag_span :: proc(d: ^Doc, grade: int, press, at: Pos) -> (anchor, head: Pos) {
    p := doc_clamp_pos(d, press)
    q := doc_clamp_pos(d, at)
    if grade >= 3 {
        // Line grade compares LINES, not positions: dragging left within the pressed line
        // has not reversed the gesture, it has not left the line.
        if q.line >= p.line {
            return Pos{p.line, 0}, Pos{q.line, line_len(&d.lines[q.line])}
        }
        return Pos{p.line, line_len(&d.lines[p.line])}, Pos{q.line, 0}
    }
    plo, phi := word_span(d.lines[p.line].text[:], p.col)
    qlo, qhi := word_span(d.lines[q.line].text[:], q.col)
    if !pos_less(q, p) {
        return Pos{p.line, plo}, Pos{q.line, qhi}
    }
    return Pos{p.line, phi}, Pos{q.line, qlo}
}

// Collapses to a single cursor at the very end of the document (history recall,
// inject) — the command line's "park at end" after a text swap.
doc_cursor_to_end :: proc(d: ^Doc) {
    last := len(d.lines) - 1
    doc_reset_cursor(d, Pos{last, line_len(&d.lines[last])})
}

// --- reading ---

doc_string :: proc(d: ^Doc, allocator := context.allocator) -> string {
    last := len(d.lines) - 1
    return capture_range(d, Pos{0, 0}, Pos{last, line_len(&d.lines[last])}, allocator)
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

// --- editing ---
// Every edit funnels through doc_apply: a list of non-overlapping replacements,
// one per cursor, applied back-to-front so earlier cursors keep valid coords.

doc_insert_rune :: proc(d: ^Doc, r: rune) -> bool {
    rs := make([]rune, 1, context.temp_allocator)
    rs[0] = r
    return doc_insert_runes(d, rs)
}

// Replaces each cursor's selection (or inserts at the caret) with rs. rs may
// contain '\n'. Shared by typing, indent, newline, and paste.
doc_insert_runes :: proc(d: ^Doc, rs: []rune) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        lo, hi := cursor_range(c)
        append(&edits, Edit{lo, hi, rs, 0})
    }
    return doc_commit(d, edits[:])
}

doc_newline :: proc(d: ^Doc) -> bool {
    rs := make([]rune, 1, context.temp_allocator)
    rs[0] = '\n'
    return doc_insert_runes(d, rs)
}

// --- clipboard (text gather/apply; GLFW I/O lives in input.odin) ---

// The text in [lo, hi), joined with '\n' across lines.
doc_text :: proc(d: ^Doc, lo, hi: Pos, alloc := context.allocator) -> string {
    return capture_range(d, lo, hi, alloc)
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
            content := doc_text(d, Pos{line, 0}, Pos{line, line_len(&d.lines[line])}, alloc)
            append(&out, strings.concatenate({content, "\n"}, alloc))
        }
    }
    sep := any_sel ? "\n" : ""
    return strings.join(out[:], sep, alloc), slice.clone(out[:], alloc)
}

// Inserts the same text at every cursor (replacing selections) — a plain paste.
doc_paste :: proc(d: ^Doc, text: string) -> bool {
    return doc_insert_runes(d, utf8.string_to_runes(text, context.temp_allocator))
}

// Distributes one piece per cursor in document order (multi-cursor paste of an
// equal-count multi-cursor copy). Caller guarantees len(pieces) == cursor count.
doc_paste_pieces :: proc(d: ^Doc, pieces: []string) -> bool {
    order := cursor_order(d, context.temp_allocator)
    edits := make([dynamic]Edit, 0, len(order), context.temp_allocator)
    for idx, k in order {
        lo, hi := cursor_range(d.cursors[idx])
        append(&edits, Edit{lo, hi, utf8.string_to_runes(pieces[k], context.temp_allocator), 0})
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
            hi = line < len(d.lines) - 1 ? Pos{line + 1, 0} : Pos{line, line_len(&d.lines[line])}
        }
        append(&edits, Edit{lo, hi, nil, 0})
    }
    return doc_commit(d, edits[:])
}

// Backspace: delete the selection, else the rune to the left, else join with the
// previous line (delete the newline before the caret).
doc_backspace :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{lo, hi, nil, 0})
        } else if c.head.col > 0 {
            // Backspace inside an empty auto-pair "()" removes both halves.
            line := &d.lines[c.head.line]
            prev := line.text[c.head.col - 1]
            if close, ok := pair_close(prev); ok && char_at(line, c.head.col) == close {
                append(&edits, Edit{Pos{c.head.line, c.head.col - 1}, Pos{c.head.line, c.head.col + 1}, nil, 0})
            } else {
                append(&edits, Edit{Pos{c.head.line, c.head.col - 1}, c.head, nil, 0})
            }
        } else if c.head.line > 0 {
            prev := c.head.line - 1
            append(&edits, Edit{Pos{prev, line_len(&d.lines[prev])}, c.head, nil, 0})
        }
    }
    return doc_commit(d, edits[:])
}

// The rune at col on the line, or 0 if past the end.
char_at :: proc(line: ^Line, col: int) -> rune {
    return col < line_len(line) ? line.text[col] : 0
}

// Delete: delete the selection, else the rune to the right, else pull the next
// line up (delete the newline after the caret).
doc_delete :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{lo, hi, nil, 0})
        } else if c.head.col < line_len(&d.lines[c.head.line]) {
            append(&edits, Edit{c.head, Pos{c.head.line, c.head.col + 1}, nil, 0})
        } else if c.head.line < len(d.lines) - 1 {
            append(&edits, Edit{c.head, Pos{c.head.line + 1, 0}, nil, 0})
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
            append(&edits, Edit{lo, hi, nil, 0})
        } else if c.head.col > 0 {
            to := word_left_index(d.lines[c.head.line].text[:], c.head.col)
            append(&edits, Edit{Pos{c.head.line, to}, c.head, nil, 0})
        } else if c.head.line > 0 {
            prev := c.head.line - 1
            append(&edits, Edit{Pos{prev, line_len(&d.lines[prev])}, c.head, nil, 0})
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
            append(&edits, Edit{lo, hi, nil, 0})
        } else if c.head.col < line_len(&d.lines[c.head.line]) {
            to := word_right_index(d.lines[c.head.line].text[:], c.head.col)
            append(&edits, Edit{c.head, Pos{c.head.line, to}, nil, 0})
        } else if c.head.line < len(d.lines) - 1 {
            append(&edits, Edit{c.head, Pos{c.head.line + 1, 0}, nil, 0})
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
        c.goal = c.head.col
    case .Right:
        if !select && cursor_has_selection(c^) {
            _, hi := cursor_range(c^)
            cursor_place(c, hi, false)
        } else {
            cursor_place(c, pos_right(d, c.head), select)
        }
        c.goal = c.head.col
    case .Word_Left:
        cursor_place(c, Pos{c.head.line, word_left_index(d.lines[c.head.line].text[:], c.head.col)}, select)
        c.goal = c.head.col
    case .Word_Right:
        cursor_place(c, Pos{c.head.line, word_right_index(d.lines[c.head.line].text[:], c.head.col)}, select)
        c.goal = c.head.col
    case .Home:
        cursor_place(c, Pos{c.head.line, 0}, select)
        c.goal = 0
    case .End:
        cursor_place(c, Pos{c.head.line, line_len(&d.lines[c.head.line])}, select)
        c.goal = c.head.col
    case .Up:
        if c.head.line > 0 {
            line := max(0, c.head.line - count)
            cursor_place(c, Pos{line, min(c.goal, line_len(&d.lines[line]))}, select)
        }
    case .Down:
        if c.head.line < len(d.lines) - 1 {
            line := min(len(d.lines) - 1, c.head.line + count)
            cursor_place(c, Pos{line, min(c.goal, line_len(&d.lines[line]))}, select)
        }
    }
}

// --- internals ---

// One replacement: the text in [start, end) becomes `runes` (which may span lines).
// caret_delta nudges the resulting caret left of the inserted text's end (same line only):
// 1 lands it inside a fresh pair, -1 steps one past an existing close, 0 for ordinary edits.
Edit :: struct {
    start, end:  Pos,
    runes:       []rune,
    caret_delta: int,
}

// Applies non-overlapping edits (one per cursor) back-to-front so unprocessed (earlier) edits
// keep valid coords, then rebuilds the cursors collapsed onto each new end. Non-nil `rec`
// collects reversible ops for the undo journal. `edits_in` is READ ONLY — sort/dedup a copy.
doc_apply :: proc(d: ^Doc, edits_in: []Edit, rec: ^Batch = nil) -> bool {
    if len(edits_in) == 0 {
        return false
    }
    edits := slice.clone(edits_in, context.temp_allocator)
    slice.sort_by(edits, proc(a, b: Edit) -> bool {
        return pos_less(a.start, b.start)
    })

    // Drop coincident edits: a free caret resting on a dropped cursor produces the
    // same range twice, and one position must be edited once, not N times.
    w := 0
    for r in 1 ..< len(edits) {
        if edits[r].start != edits[w].start || edits[r].end != edits[w].end {
            w += 1
            edits[w] = edits[r]
        }
    }
    edits = edits[:w + 1]

    // Apply back-to-front. heads/starts track each edit's inserted region in the
    // final document (its start/end shift as earlier edits land), so the undo
    // journal can later replace that region with the removed text.
    changed := false
    heads := make([]Pos, len(edits), context.temp_allocator)
    starts := make([]Pos, len(edits), context.temp_allocator)
    removed := make([]string, len(edits), context.temp_allocator)
    for i := len(edits) - 1; i >= 0; i -= 1 {
        e := edits[i]
        if e.start != e.end || len(e.runes) > 0 {
            changed = true
        }
        new_end, gone := doc_replace_range(d, e.start, e.end, e.runes)
        heads[i] = new_end
        starts[i] = e.start
        removed[i] = gone
        for j in i + 1 ..< len(edits) {
            heads[j] = shift_pos(heads[j], e.end, new_end)
            starts[j] = shift_pos(starts[j], e.end, new_end)
        }
    }

    if rec != nil {
        for e, i in edits {
            ins := utf8.runes_to_string(e.runes, context.temp_allocator)
            if removed[i] == "" && ins == "" {
                continue // pure no-op (e.g. backspace at the document origin)
            }
            append(
                &rec.ops,
                Op {
                    fwd_lo   = e.start,
                    fwd_hi   = e.end,
                    inv_lo   = starts[i],
                    inv_hi   = heads[i],
                    removed  = strings.clone(removed[i]),
                    inserted = strings.clone(ins),
                },
            )
        }
    }

    clear(&d.cursors)
    for h, i in heads {
        col := clamp(h.col - edits[i].caret_delta, 0, line_len(&d.lines[h.line]))
        p := Pos{h.line, col}
        append(&d.cursors, Cursor{anchor = p, head = p, goal = col})
    }
    d.primary = 0
    doc_merge_cursors(d)
    if changed {
        d.version += 1
    }
    return changed
}

// Replaces the text in [start, end) with runes, returning the position just past
// the inserted text and the (temp-allocated) text that was removed. Mutates
// d.lines only; cursor fixup is the caller's job.
@(private = "file")
doc_replace_range :: proc(d: ^Doc, start, end: Pos, runes: []rune) -> (Pos, string) {
    // Clone the surviving fragments before the line storage is mutated.
    prefix := slice.clone(d.lines[start.line].text[:start.col], context.temp_allocator)
    suffix := slice.clone(d.lines[end.line].text[end.col:], context.temp_allocator)
    removed := capture_range(d, start, end, context.temp_allocator)

    for i in start.line ..= end.line {
        line_destroy(&d.lines[i])
    }
    remove_range(&d.lines, start.line, end.line + 1)

    // Split runes on '\n' into segments; each becomes a line. The first carries
    // the prefix, the last carries the suffix (single-segment carries both).
    new_end: Pos
    seg_lo := 0
    seg := 0
    for i := 0; i <= len(runes); i += 1 {
        if i < len(runes) && runes[i] != '\n' {
            continue
        }
        l: Line
        if seg == 0 {
            append(&l.text, ..prefix)
        }
        append(&l.text, ..runes[seg_lo:i])
        if i == len(runes) { // last segment
            new_end = Pos{start.line + seg, len(l.text)}
            append(&l.text, ..suffix)
        }
        inject_at(&d.lines, start.line + seg, l)
        seg += 1
        seg_lo = i + 1
    }
    return new_end, removed
}

// The text currently in [start, end), joined with '\n' across lines. Used to
// record what an edit removed (undo) and to gather copied text.
@(private = "file")
capture_range :: proc(d: ^Doc, start, end: Pos, alloc := context.allocator) -> string {
    b := strings.builder_make(alloc)
    if start.line == end.line {
        for r in d.lines[start.line].text[start.col:end.col] {
            strings.write_rune(&b, r)
        }
    } else {
        for r in d.lines[start.line].text[start.col:] {
            strings.write_rune(&b, r)
        }
        strings.write_byte(&b, '\n')
        for li in start.line + 1 ..< end.line {
            for r in d.lines[li].text {
                strings.write_rune(&b, r)
            }
            strings.write_byte(&b, '\n')
        }
        for r in d.lines[end.line].text[:end.col] {
            strings.write_rune(&b, r)
        }
    }
    return strings.to_string(b)
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

// Shifts a position that lay at or after a replacement's end to track the edit.
@(private = "file")
shift_pos :: proc(p, old_end, new_end: Pos) -> Pos {
    q := p
    if p.line == old_end.line {
        q.col += new_end.col - old_end.col
    }
    q.line += new_end.line - old_end.line
    return q
}

@(private = "file")
cursor_place :: proc(c: ^Cursor, to: Pos, select: bool) {
    c.head = to
    if !select {
        c.anchor = to
    }
}

@(private = "file")
pos_left :: proc(d: ^Doc, p: Pos) -> Pos {
    if p.col > 0 {
        return Pos{p.line, p.col - 1}
    }
    if p.line > 0 {
        return Pos{p.line - 1, line_len(&d.lines[p.line - 1])}
    }
    return p
}

@(private = "file")
pos_right :: proc(d: ^Doc, p: Pos) -> Pos {
    if p.col < line_len(&d.lines[p.line]) {
        return Pos{p.line, p.col + 1}
    }
    if p.line < len(d.lines) - 1 {
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
            d.cursors[w] = Cursor{anchor = alo, head = bhi, goal = bhi.col}
        }
    }
    resize(&d.cursors, w + 1)
    d.primary = clamp(d.primary, 0, w)
}
