package main

// Code folding + indentation geometry for the editor. A Buffer holds a set of
// Folds; each collapses a block to its header line, hiding the lines beneath it.
// The same indentation helpers feed the whitespace markers and indent guides the
// renderer draws (see draw_editor), so "how deep is this line" is defined once here.
//
// Folds are a VIEW aid, deliberately simple in v1: their line numbers are absolute,
// so any edit that changes the line count drops them (buffer_sync_folds). Editing
// within a line keeps them. This sidesteps having to shuffle fold ranges through the
// edit funnel, at the cost of folds not surviving a newline elsewhere — fine for the
// read-a-big-file use folding is for. Fold ranges shift/stale-proof is future work.

// One collapsed block: the header line stays visible; lines (line, end] are hidden.
// end >= line+1 always (a zero-height fold is never stored).
Fold :: struct {
    line: int, // header (visible)
    end:  int, // last hidden line; hidden range is [line+1, end]
}

// --- indentation geometry (shared by folds, whitespace markers, indent guides) ---

// Leading-whitespace width in cells. Tabs advance one cell today (see Rendering),
// so each leading space or tab counts as one column.
line_indent_cols :: proc(l: ^Line) -> int {
    n := 0
    for r in l.text {
        if r != ' ' && r != '\t' {
            break
        }
        n += 1
    }
    return n
}

// A line is blank when it holds nothing but whitespace — those lines carry no indent
// of their own, so guides flow through them from the surrounding code.
line_is_blank :: proc(l: ^Line) -> bool {
    return line_indent_cols(l) == len(l.text)
}

// The indent unit in cells: one tab cell for tab indentation, else the space count.
indent_unit :: proc(ind: Indent) -> int {
    return ind.kind == .Tab ? 1 : max(1, ind.width)
}

// How many indent guide levels a display line sits at. A blank line has no indent of
// its own, so it borrows the deeper of its nearest non-blank neighbours, letting a
// guide run unbroken through blank lines inside a block.
buffer_indent_levels :: proc(b: ^Buffer, line, unit: int) -> int {
    if line < 0 || line >= len(b.lines) {
        return 0
    }
    unit := max(1, unit) // never divide by zero, whatever a caller passes
    if !line_is_blank(&b.lines[line]) {
        return line_indent_cols(&b.lines[line]) / unit
    }
    up := 0
    for i := line - 1; i >= 0; i -= 1 {
        if !line_is_blank(&b.lines[i]) {
            up = line_indent_cols(&b.lines[i])
            break
        }
    }
    dn := 0
    for i := line + 1; i < len(b.lines); i += 1 {
        if !line_is_blank(&b.lines[i]) {
            dn = line_indent_cols(&b.lines[i])
            break
        }
    }
    return max(up, dn) / unit
}

// The active indent-guide scope: the run of lines [lo, hi] around the cursor that the
// renderer should highlight, and which rail (`level`) within it. ok=false at top level.
Scope :: struct {
    lo, hi: int, // contiguous line span at least as deep as the cursor's line
    level:  int, // the indent-guide level to draw in the active colour
    ok:     bool, // false when the cursor is at top level (nothing to highlight)
}

// The scope the cursor sits in, for the active indent-guide highlight. The span is the
// run of lines around the cursor at least as deeply indented as the cursor's line; its
// rail is the cursor depth's outer edge (level = depth-1).
buffer_active_scope :: proc(b: ^Buffer, cursor_line, unit: int) -> Scope {
    depth := buffer_indent_levels(b, cursor_line, unit)
    if depth <= 0 {
        return {}
    }
    s := Scope{lo = cursor_line, hi = cursor_line, level = depth - 1, ok = true}
    for s.lo > 0 && buffer_indent_levels(b, s.lo - 1, unit) >= depth {
        s.lo -= 1
    }
    for s.hi < len(b.lines) - 1 && buffer_indent_levels(b, s.hi + 1, unit) >= depth {
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
    i := clamp(line, 0, len(b.lines) - 1)
    for i < len(b.lines) - 1 && buffer_line_hidden(b, i) {
        i += 1
    }
    return i
}

// The first visible line at or before `line` (clamped to 0).
buffer_prev_visible :: proc(b: ^Buffer, line: int) -> int {
    i := clamp(line, 0, len(b.lines) - 1)
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

// Step `n` visible lines DOWN from `line` (clamped to the last line) — the twin of
// buffer_back_visible, which C7c's drag autoscroll walks the selection past the bottom edge
// with. It ends on buffer_prev_visible because the far end is the asymmetric one: line 0 can
// never be hidden (a fold hides `line > f.line`), but the LAST line can, so a walk that runs
// out of buffer inside a collapsed block has to back out of it.
buffer_fwd_visible :: proc(b: ^Buffer, line, n: int) -> int {
    i := clamp(line, 0, len(b.lines) - 1)
    left := n
    for left > 0 && i < len(b.lines) - 1 {
        i += 1
        if !buffer_line_hidden(b, i) {
            left -= 1
        }
    }
    return buffer_prev_visible(b, i)
}

// --- lifecycle / invalidation ---

// Drops folds when the line count changed (an insert/delete moved every index below
// it — see the file header) and clamps any fold that now runs past the end. Cheap;
// called each frame before the folds are read.
buffer_sync_folds :: proc(b: ^Buffer) {
    if len(b.folds) == 0 {
        b.fold_nlines = len(b.lines)
        return
    }
    if len(b.lines) != b.fold_nlines {
        clear(&b.folds)
        b.fold_nlines = len(b.lines)
        return
    }
    // Same line count: ranges are still valid, but defensively clamp ends.
    for &f in b.folds {
        f.end = min(f.end, len(b.lines) - 1)
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
    b.fold_nlines = len(b.lines)
    // Keep every cursor on a visible line (the header), now that the body is hidden.
    buffer_collapse_hidden_cursors(b)
}

// Move any cursor that ended up inside the new fold onto its header, collapsed.
@(private = "file")
buffer_collapse_hidden_cursors :: proc(b: ^Buffer) {
    for &c in b.cursors {
        if buffer_line_hidden(b, c.head.line) {
            h := buffer_prev_visible(b, c.head.line)
            p := Pos{h, min(c.head.col, line_len(&b.lines[h]))}
            c.head, c.anchor, c.goal = p, p, p.col
        }
    }
    doc_merge_cursors(&b.doc)
}

// The line range to fold for a block opening on `line`: [start, end] with end the
// last line to hide. Tree-sitter first (accurate for braces/blocks/defs), falling
// back to an indentation scan when no grammar is loaded or no multi-line node opens
// on the line.
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
    if line < 0 || line >= len(b.lines) {
        return 0, 0, false
    }
    base := line_indent_cols(&b.lines[line])
    // The first line below must be deeper for there to be a block to fold.
    nxt := line + 1
    for nxt < len(b.lines) && line_is_blank(&b.lines[nxt]) {
        nxt += 1
    }
    if nxt >= len(b.lines) || line_indent_cols(&b.lines[nxt]) <= base {
        return 0, 0, false
    }
    last := line
    for i := line + 1; i < len(b.lines); i += 1 {
        if line_is_blank(&b.lines[i]) {
            continue // a blank line never ends a block
        }
        if line_indent_cols(&b.lines[i]) <= base {
            break
        }
        last = i
    }
    return line, last, last > line
}
