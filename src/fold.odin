package main

// Code folding + indentation geometry for the editor. A Buffer holds a set of
// Folds; each collapses a block to its header line, hiding the lines beneath it.
// The same indentation helpers feed the whitespace markers and indent guides the
// renderer draws (see draw_editor), so "how deep is this line" is defined once here.
//
// A fold's line numbers are absolute, so an edit ABOVE one moves it. They are shifted through
// the document's change log rather than dropped (buffer_sync_folds): folding is for reading a
// big file, and a fold that vanished every time you typed a newline three hundred lines up was
// the thing that made it not worth using. A fold whose own lines are edited IS dropped — its
// block structure just changed, and a stale range is worse than no range.

// One collapsed block: the header line stays visible; lines (line, end] are hidden.
// end >= line+1 always (a zero-height fold is never stored).
Fold :: struct {
    line: int, // header (visible)
    end:  int, // last hidden line; hidden range is [line+1, end]
}

// --- indentation geometry (shared by folds, whitespace markers, indent guides) ---

// Leading-whitespace width in cells. Space and tab are one byte each and tabs advance one cell
// today (see Rendering), so over the indent run bytes and cells are the same count.
line_indent_cols :: proc(src: []u8) -> int {
    n := 0
    for c in src {
        if c != ' ' && c != '\t' {
            break
        }
        n += 1
    }
    return n
}

// A line is blank when it holds nothing but whitespace — those lines carry no indent
// of their own, so guides flow through them from the surrounding code.
line_is_blank :: proc(src: []u8) -> bool {
    return line_indent_cols(src) == len(src)
}

// The indent unit in cells: one tab cell for tab indentation, else the space count.
indent_unit :: proc(ind: Indent) -> int {
    return ind.kind == .Tab ? 1 : max(1, ind.width)
}

// How many indent guide levels a display line sits at. A blank line has no indent of
// its own, so it borrows the deeper of its nearest non-blank neighbours, letting a
// guide run unbroken through blank lines inside a block.
buffer_indent_levels :: proc(b: ^Buffer, line, unit: int) -> int {
    if line < 0 || line >= doc_line_count(&b.doc) {
        return 0
    }
    unit := max(1, unit) // never divide by zero, whatever a caller passes
    if !line_is_blank(doc_line(&b.doc, line)) {
        return line_indent_cols(doc_line(&b.doc, line)) / unit
    }
    up := 0
    for i := line - 1; i >= 0; i -= 1 {
        if !line_is_blank(doc_line(&b.doc, i)) {
            up = line_indent_cols(doc_line(&b.doc, i))
            break
        }
    }
    dn := 0
    for i := line + 1; i < doc_line_count(&b.doc); i += 1 {
        if !line_is_blank(doc_line(&b.doc, i)) {
            dn = line_indent_cols(doc_line(&b.doc, i))
            break
        }
    }
    return max(up, dn) / unit
}

// The active indent-guide scope: the run of lines [lo, hi] around the cursor that the
// renderer should highlight, and which rail (`level`) within it. ok=false at top level.
Scope :: struct {
    lo, hi: int, // contiguous line span at least as deep as the cursor's line
    level: int, // the indent-guide level to draw in the active colour
    ok:    bool, // false when the cursor is at top level (nothing to highlight)
}

// The scope the cursor sits in, for the active indent-guide highlight. The span is the run of
// lines around the cursor at least as deeply indented as the cursor's line; its rail is the
// cursor depth's outer edge (level = depth-1).
//
// **Bounded to [first, last], the lines the caller will DRAW.** The rail is only ever painted
// inside the viewport, so a walk past it buys nothing — and unbounded it is O(file) per frame,
// idle, forever: a caret one level deep in a 90k-line Python class spans the whole class body
// and cost 1.55ms of every frame. Inside the bound the span is still exact, because the walk
// stops on the run ending, not on the bound, whenever the run ends first.
buffer_active_scope :: proc(b: ^Buffer, cursor_line, unit, first, last: int) -> Scope {
    depth := buffer_indent_levels(b, cursor_line, unit)
    if depth <= 0 {
        return {}
    }
    lo_bound := max(0, first)
    hi_bound := min(last, doc_line_count(&b.doc) - 1)
    s := Scope{lo = cursor_line, hi = cursor_line, level = depth - 1, ok = true}
    for s.lo > lo_bound && buffer_indent_levels(b, s.lo - 1, unit) >= depth {
        s.lo -= 1
    }
    for s.hi < hi_bound && buffer_indent_levels(b, s.hi + 1, unit) >= depth {
        s.hi += 1
    }
    return s
}

// Does the active scope highlight its rail on this (line, level)?
scope_highlights :: proc(s: Scope, line, level: int) -> bool {
    return s.ok && level == s.level && line >= s.lo && line <= s.hi
}

// --- fold visibility ---

// Is `line` hidden inside some fold? (The header line itself is never hidden.)
buffer_line_hidden :: proc(b: ^Buffer, line: int) -> bool {
    for f in b.folds {
        if line > f.line && line <= f.end {
            return true
        }
    }
    return false
}

// Index of the fold headed by `line`, or -1.
buffer_fold_index :: proc(b: ^Buffer, line: int) -> int {
    for f, i in b.folds {
        if f.line == line {
            return i
        }
    }
    return -1
}

// The first visible line at or after `line` (clamped to the last line). Used to keep
// the scroll top and a landing cursor on a real, on-screen line.
buffer_next_visible :: proc(b: ^Buffer, line: int) -> int {
    i := clamp(line, 0, doc_line_count(&b.doc) - 1)
    for i < doc_line_count(&b.doc) - 1 && buffer_line_hidden(b, i) {
        i += 1
    }
    return i
}

// The first visible line at or before `line` (clamped to 0).
buffer_prev_visible :: proc(b: ^Buffer, line: int) -> int {
    i := clamp(line, 0, doc_line_count(&b.doc) - 1)
    for i > 0 && buffer_line_hidden(b, i) {
        i -= 1
    }
    return i
}

// Count of visible lines in [lo, hi] inclusive (lo, hi assumed in range, lo <= hi).
buffer_visible_count :: proc(b: ^Buffer, lo, hi: int) -> int {
    n := 0
    for i in lo ..= hi {
        if !buffer_line_hidden(b, i) {
            n += 1
        }
    }
    return n
}

// Step `n` visible lines up from `line`, skipping hidden lines (clamped to 0). Used
// to pin the scroll top so the cursor sits on the bottom row of the viewport.
buffer_back_visible :: proc(b: ^Buffer, line, n: int) -> int {
    i := line
    left := n
    for left > 0 && i > 0 {
        i -= 1
        if !buffer_line_hidden(b, i) {
            left -= 1
        }
    }
    return i
}

// Step `n` visible lines DOWN from `line` (clamped to the last) — the twin of
// buffer_back_visible, used by the drag autoscroll. It ends on buffer_prev_visible because
// the LAST line CAN be hidden (line 0 cannot), so a walk that runs out must back out.
buffer_fwd_visible :: proc(b: ^Buffer, line, n: int) -> int {
    i := clamp(line, 0, doc_line_count(&b.doc) - 1)
    left := n
    for left > 0 && i < doc_line_count(&b.doc) - 1 {
        i += 1
        if !buffer_line_hidden(b, i) {
            left -= 1
        }
    }
    return buffer_prev_visible(b, i)
}

// --- lifecycle / invalidation ---

// Bring the fold set up to date with the edits since it was last synced, then clamp. Called
// each frame before the folds are read, and again by anything that edits mid-frame.
//
// It reads the change log through its own reader slot, so it does NOT matter whether the
// highlighter has already looked at the same changes — the two are independent, and neither
// call order nor how often this runs can change the answer.
buffer_sync_folds :: proc(b: ^Buffer) {
    changes, lost := doc_changes_since(&b.doc, .Folds)
    doc_changes_ack(&b.doc, .Folds) // acked even with no folds, so the log can trim
    if len(b.folds) == 0 {
        return
    }
    if lost {
        clear(&b.folds) // the log does not reach back far enough to shift them honestly
        return
    }
    for c in changes {
        fold_shift(b, c)
    }
    last := doc_line_count(&b.doc) - 1
    for &f in b.folds {
        f.end = min(f.end, last)
    }
    // A fold clamped down to its own header is no longer hiding anything.
    for i := len(b.folds) - 1; i >= 0; i -= 1 {
        if b.folds[i].end <= b.folds[i].line {
            unordered_remove(&b.folds, i)
        }
    }
}

// Move (or drop) every fold across one change. A change spans the lines [start, old_end] and
// leaves the line count `delta` different; anything wholly below it is untouched, anything
// wholly above it slides, and anything it reaches into is dropped.
@(private = "file")
fold_shift :: proc(b: ^Buffer, c: Doc_Change) {
    lo := c.start_pt.line
    hi := c.old_end_pt.line
    delta := c.new_end_pt.line - c.old_end_pt.line
    if delta == 0 {
        return // an edit within its lines moves nothing, whatever else it did
    }
    for i := len(b.folds) - 1; i >= 0; i -= 1 {
        f := &b.folds[i]
        switch {
        case hi < f.line: // entirely above: the whole fold slides
            f.line += delta
            f.end += delta
        case lo > f.end: // entirely below: nothing to do
        case:
            // It reaches the header or the hidden body. The block's shape has changed and a
            // range guessed from here would hide the wrong lines, so let it go.
            unordered_remove(&b.folds, i)
        }
    }
}

// --- the Ctrl+Enter toggle ---

// Toggle the fold headed by the cursor's line: collapse the block that begins there,
// or expand it if it is already folded. The block range comes from tree-sitter when a
// grammar is loaded, else from indentation. No-op when the line opens no block.
buffer_fold_toggle :: proc(a: ^App, b: ^Buffer) {
    buffer_sync_folds(b) // a prior same-frame edit may have invalidated the fold set
    line := b.cursors[b.primary].head.line
    if i := buffer_fold_index(b, line); i >= 0 {
        unordered_remove(&b.folds, i) // re-pressing the header expands it
        return
    }
    start, end, ok := fold_range(a, b, line)
    if !ok || end <= start {
        return
    }
    append(&b.folds, Fold{line = start, end = end})
    // Keep every cursor on a visible line (the header), now that the body is hidden.
    buffer_collapse_hidden_cursors(b)
}

// Move any cursor that ended up inside the new fold onto its header, collapsed.
@(private = "file")
buffer_collapse_hidden_cursors :: proc(b: ^Buffer) {
    for &c in b.cursors {
        if buffer_line_hidden(b, c.head.line) {
            h := buffer_prev_visible(b, c.head.line)
            p := doc_clamp_pos(&b.doc, Pos{h, c.head.col})
            c.head, c.anchor, c.goal = p, p, doc_cell_col(&b.doc, p)
        }
    }
    doc_merge_cursors(&b.doc)
}

// The line range to fold for a block opening on `line`: [start, end] with end the last line
// to hide. Tree-sitter first (accurate for braces/blocks/defs), falling back to an indentation
// scan when no grammar is loaded or no multi-line node opens on the line.
fold_range :: proc(a: ^App, b: ^Buffer, line: int) -> (start, end: int, ok: bool) {
    if s, e, got := highlight_fold_range(a, b, line); got {
        return s, e, true
    }
    return fold_range_indent(b, line)
}

// Indentation fold: a header is foldable when the next non-blank line is indented
// deeper. The block runs through every following line that is blank or more indented
// than the header; trailing blank lines are not pulled in.
fold_range_indent :: proc(b: ^Buffer, line: int) -> (start, end: int, ok: bool) {
    if line < 0 || line >= doc_line_count(&b.doc) {
        return 0, 0, false
    }
    base := line_indent_cols(doc_line(&b.doc, line))
    // The first line below must be deeper for there to be a block to fold.
    nxt := line + 1
    for nxt < doc_line_count(&b.doc) && line_is_blank(doc_line(&b.doc, nxt)) {
        nxt += 1
    }
    if nxt >= doc_line_count(&b.doc) || line_indent_cols(doc_line(&b.doc, nxt)) <= base {
        return 0, 0, false
    }
    last := line
    for i := line + 1; i < doc_line_count(&b.doc); i += 1 {
        if line_is_blank(doc_line(&b.doc, i)) {
            continue // a blank line never ends a block
        }
        if line_indent_cols(doc_line(&b.doc, i)) <= base {
            break
        }
        last = i
    }
    return line, last, last > line
}
