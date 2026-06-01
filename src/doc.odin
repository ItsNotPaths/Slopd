package main

import "core:slice"
import "core:strings"

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
}

// Replaces all content; collapses to a single cursor at the origin (file load).
doc_set_text :: proc(d: ^Doc, text: string) {
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

// Adds a cursor offset (dline, dcol) from the primary and makes it the new
// primary, leaving the old one behind — the drop-mode trail step. Vertical steps
// keep the goal column; returns false at a document edge (nothing dropped).
doc_add_cursor :: proc(d: ^Doc, dline, dcol: int) -> bool {
    p := d.cursors[d.primary]
    np: Pos
    goal := p.goal
    if dline != 0 {
        nl := p.head.line + dline
        if nl < 0 || nl >= len(d.lines) {
            return false
        }
        np = Pos{nl, min(p.goal, line_len(&d.lines[nl]))}
    } else {
        nc := clamp(p.head.col + dcol, 0, line_len(&d.lines[p.head.line]))
        if nc == p.head.col {
            return false
        }
        np = Pos{p.head.line, nc}
        goal = nc
    }
    append(&d.cursors, Cursor{anchor = np, head = np, goal = goal})
    doc_merge_cursors(d)
    d.primary = doc_index_at(d, np)
    return true
}

// Collapses to a single cursor at the very end of the document (history recall,
// inject) — the command line's "park at end" after a text swap.
doc_cursor_to_end :: proc(d: ^Doc) {
    last := len(d.lines) - 1
    doc_reset_cursor(d, Pos{last, line_len(&d.lines[last])})
}

// --- reading ---

doc_string :: proc(d: ^Doc, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for &l, i in d.lines {
        if i > 0 {
            strings.write_byte(&b, '\n')
        }
        for r in l.text {
            strings.write_rune(&b, r)
        }
    }
    return strings.to_string(b)
}

cursor_has_selection :: proc(c: Cursor) -> bool {
    return c.anchor != c.head
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
        append(&edits, Edit{lo, hi, rs})
    }
    return doc_apply(d, edits[:])
}

doc_newline :: proc(d: ^Doc) -> bool {
    rs := make([]rune, 1, context.temp_allocator)
    rs[0] = '\n'
    return doc_insert_runes(d, rs)
}

doc_indent :: proc(d: ^Doc, indent: Indent) -> bool {
    if indent.kind == .Tab {
        return doc_insert_rune(d, '\t')
    }
    rs := make([]rune, indent.width, context.temp_allocator)
    slice.fill(rs, ' ')
    return doc_insert_runes(d, rs)
}

// Backspace: delete the selection, else the rune to the left, else join with the
// previous line (delete the newline before the caret).
doc_backspace :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{lo, hi, nil})
        } else if c.head.col > 0 {
            append(&edits, Edit{Pos{c.head.line, c.head.col - 1}, c.head, nil})
        } else if c.head.line > 0 {
            prev := c.head.line - 1
            append(&edits, Edit{Pos{prev, line_len(&d.lines[prev])}, c.head, nil})
        }
    }
    return doc_apply(d, edits[:])
}

// Delete: delete the selection, else the rune to the right, else pull the next
// line up (delete the newline after the caret).
doc_delete :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{lo, hi, nil})
        } else if c.head.col < line_len(&d.lines[c.head.line]) {
            append(&edits, Edit{c.head, Pos{c.head.line, c.head.col + 1}, nil})
        } else if c.head.line < len(d.lines) - 1 {
            append(&edits, Edit{c.head, Pos{c.head.line + 1, 0}, nil})
        }
    }
    return doc_apply(d, edits[:])
}

// Delete the word to the left, or join with the previous line at column 0.
doc_delete_word_back :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{lo, hi, nil})
        } else if c.head.col > 0 {
            to := word_left_index(d.lines[c.head.line].text[:], c.head.col)
            append(&edits, Edit{Pos{c.head.line, to}, c.head, nil})
        } else if c.head.line > 0 {
            prev := c.head.line - 1
            append(&edits, Edit{Pos{prev, line_len(&d.lines[prev])}, c.head, nil})
        }
    }
    return doc_apply(d, edits[:])
}

// Delete the word to the right, or pull the next line up at end of line.
doc_delete_word_forward :: proc(d: ^Doc) -> bool {
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            append(&edits, Edit{lo, hi, nil})
        } else if c.head.col < line_len(&d.lines[c.head.line]) {
            to := word_right_index(d.lines[c.head.line].text[:], c.head.col)
            append(&edits, Edit{c.head, Pos{c.head.line, to}, nil})
        } else if c.head.line < len(d.lines) - 1 {
            append(&edits, Edit{c.head, Pos{c.head.line + 1, 0}, nil})
        }
    }
    return doc_apply(d, edits[:])
}

// --- movement (select=true keeps each anchor to extend its selection) ---
// A plain (non-select) move with an active selection collapses to the edge it
// moves toward, the standard GUI behavior, rather than stepping from the head.

doc_move_left :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        if !select && cursor_has_selection(c) {
            lo, _ := cursor_range(c)
            cursor_place(&c, lo, false)
        } else {
            cursor_place(&c, pos_left(d, c.head), select)
        }
        c.goal = c.head.col
    }
    doc_merge_cursors(d)
}

doc_move_right :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        if !select && cursor_has_selection(c) {
            _, hi := cursor_range(c)
            cursor_place(&c, hi, false)
        } else {
            cursor_place(&c, pos_right(d, c.head), select)
        }
        c.goal = c.head.col
    }
    doc_merge_cursors(d)
}

doc_move_word_left :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        to := word_left_index(d.lines[c.head.line].text[:], c.head.col)
        cursor_place(&c, Pos{c.head.line, to}, select)
        c.goal = c.head.col
    }
    doc_merge_cursors(d)
}

doc_move_word_right :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        to := word_right_index(d.lines[c.head.line].text[:], c.head.col)
        cursor_place(&c, Pos{c.head.line, to}, select)
        c.goal = c.head.col
    }
    doc_merge_cursors(d)
}

doc_move_home :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        cursor_place(&c, Pos{c.head.line, 0}, select)
        c.goal = 0
    }
    doc_merge_cursors(d)
}

doc_move_end :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        cursor_place(&c, Pos{c.head.line, line_len(&d.lines[c.head.line])}, select)
        c.goal = c.head.col
    }
    doc_merge_cursors(d)
}

// Vertical motion keeps each cursor's goal column so passing through short lines
// doesn't lose the column.
doc_move_up :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        if c.head.line > 0 {
            line := c.head.line - 1
            cursor_place(&c, Pos{line, min(c.goal, line_len(&d.lines[line]))}, select)
        }
    }
    doc_merge_cursors(d)
}

doc_move_down :: proc(d: ^Doc, select := false) {
    for &c in d.cursors {
        if c.head.line < len(d.lines) - 1 {
            line := c.head.line + 1
            cursor_place(&c, Pos{line, min(c.goal, line_len(&d.lines[line]))}, select)
        }
    }
    doc_merge_cursors(d)
}

// --- internals ---

// One replacement: the text in [start, end) becomes runes (which may span lines).
@(private = "file")
Edit :: struct {
    start, end: Pos,
    runes:      []rune,
}

// Applies a set of non-overlapping edits (one per cursor), then rebuilds the
// cursor list collapsed onto each edit's new end. Edits are applied back-to-front
// in document order so unprocessed (earlier) edits keep valid coordinates;
// already-applied (later) results are shifted by each edit's size delta.
@(private = "file")
doc_apply :: proc(d: ^Doc, edits: []Edit) -> bool {
    if len(edits) == 0 {
        return false
    }
    slice.sort_by(edits, proc(a, b: Edit) -> bool {
        return pos_less(a.start, b.start)
    })

    changed := false
    heads := make([]Pos, len(edits), context.temp_allocator)
    for i := len(edits) - 1; i >= 0; i -= 1 {
        e := edits[i]
        if e.start != e.end || len(e.runes) > 0 {
            changed = true
        }
        new_end := doc_replace_range(d, e.start, e.end, e.runes)
        heads[i] = new_end
        for j in i + 1 ..< len(edits) {
            heads[j] = shift_pos(heads[j], e.end, new_end)
        }
    }

    clear(&d.cursors)
    for h in heads {
        append(&d.cursors, Cursor{anchor = h, head = h, goal = h.col})
    }
    d.primary = 0
    doc_merge_cursors(d)
    return changed
}

// Index of the cursor whose head is at p (after a merge), else the primary.
@(private = "file")
doc_index_at :: proc(d: ^Doc, p: Pos) -> int {
    for c, i in d.cursors {
        if c.head == p {
            return i
        }
    }
    return d.primary
}

// Replaces the text in [start, end) with runes, returning the position just past
// the inserted text. Mutates d.lines only; cursor fixup is the caller's job.
@(private = "file")
doc_replace_range :: proc(d: ^Doc, start, end: Pos, runes: []rune) -> Pos {
    // Clone the surviving fragments before the line storage is mutated.
    prefix := slice.clone(d.lines[start.line].text[:start.col], context.temp_allocator)
    suffix := slice.clone(d.lines[end.line].text[end.col:], context.temp_allocator)

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
    return new_end
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
@(private = "file")
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
