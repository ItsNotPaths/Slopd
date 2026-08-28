package main
import "txt"

// Folding and indentation geometry. A Buffer holds Folds, each collapsing a block to its header
// line. The same indentation helpers feed the whitespace markers and the indent guides, so "how
// deep is this line" is defined once here.
//
// Fold line numbers are absolute, so an edit above one moves it. They are shifted through the
// change log rather than dropped (buffer_sync_folds), or a fold would vanish every time you
// typed a newline above it. A fold whose OWN lines are edited is dropped: its block structure
// just changed, and a stale range is worse than none.

// The header stays visible; lines (line, end] are hidden. end >= line+1 always.
Fold :: struct {
    line: int, // header (visible)
    end:  int, // last hidden line; hidden range is [line+1, end]
}

// --- indentation geometry (shared by folds, whitespace markers, indent guides) ---

// In cells: one for tab indentation, else the space count.
indent_unit :: proc(ind: Indent) -> int {
    return ind.kind == .Tab ? 1 : max(1, ind.width)
}

// A blank line borrows the deeper of its nearest non-blank neighbours, so a guide runs unbroken
// through blank lines inside a block.
buffer_indent_levels :: proc(b: ^Buffer, line, unit: int) -> int {
    if line < 0 || line >= txt.doc_line_count(&b.doc) {
        return 0
    }
    unit := max(1, unit) // never divide by zero
    if !txt.line_is_blank(txt.doc_line(&b.doc, line)) {
        return txt.line_indent_cols(txt.doc_line(&b.doc, line)) / unit
    }
    up := 0
    for i := line - 1; i >= 0; i -= 1 {
        if !txt.line_is_blank(txt.doc_line(&b.doc, i)) {
            up = txt.line_indent_cols(txt.doc_line(&b.doc, i))
            break
        }
    }
    dn := 0
    for i := line + 1; i < txt.doc_line_count(&b.doc); i += 1 {
        if !txt.line_is_blank(txt.doc_line(&b.doc, i)) {
            dn = txt.line_indent_cols(txt.doc_line(&b.doc, i))
            break
        }
    }
    return max(up, dn) / unit
}

// The run of lines around the cursor to highlight, and which rail within it. ok=false at top
// level.
Scope :: struct {
    lo, hi: int, // contiguous span at least as deep as the cursor's line
    level: int, // the level to draw in the active colour
    ok:    bool, // false at top level
}

// The run of lines around the cursor at least as deeply indented as its line; the rail is the
// cursor depth's outer edge.
//
// Bounded to [first, last], the lines the caller will DRAW. Unbounded it is O(file) per frame:
// a caret one level deep in a 90k-line Python class spans the whole class body and cost 1.55ms
// a frame. Inside the bound the span is still exact — the walk stops on the run ending.
buffer_active_scope :: proc(b: ^Buffer, cursor_line, unit, first, last: int) -> Scope {
    depth := buffer_indent_levels(b, cursor_line, unit)
    if depth <= 0 {
        return {}
    }
    lo_bound := max(0, first)
    hi_bound := min(last, txt.doc_line_count(&b.doc) - 1)
    s := Scope{lo = cursor_line, hi = cursor_line, level = depth - 1, ok = true}
    for s.lo > lo_bound && buffer_indent_levels(b, s.lo - 1, unit) >= depth {
        s.lo -= 1
    }
    for s.hi < hi_bound && buffer_indent_levels(b, s.hi + 1, unit) >= depth {
        s.hi += 1
    }
    return s
}

scope_highlights :: proc(s: Scope, line, level: int) -> bool {
    return s.ok && level == s.level && line >= s.lo && line <= s.hi
}

// --- fold visibility ---

// The header line itself is never hidden.
buffer_line_hidden :: proc(b: ^Buffer, line: int) -> bool {
    for f in b.folds {
        if line > f.line && line <= f.end {
            return true
        }
    }
    return false
}

buffer_fold_index :: proc(b: ^Buffer, line: int) -> int {
    for f, i in b.folds {
        if f.line == line {
            return i
        }
    }
    return -1
}

// Clamped to the last line. Keeps the scroll top and a landing cursor on a real line.
buffer_next_visible :: proc(b: ^Buffer, line: int) -> int {
    i := clamp(line, 0, txt.doc_line_count(&b.doc) - 1)
    for i < txt.doc_line_count(&b.doc) - 1 && buffer_line_hidden(b, i) {
        i += 1
    }
    return i
}

buffer_prev_visible :: proc(b: ^Buffer, line: int) -> int {
    i := clamp(line, 0, txt.doc_line_count(&b.doc) - 1)
    for i > 0 && buffer_line_hidden(b, i) {
        i -= 1
    }
    return i
}

// Inclusive; lo and hi are assumed in range with lo <= hi.
buffer_visible_count :: proc(b: ^Buffer, lo, hi: int) -> int {
    n := 0
    for i in lo ..= hi {
        if !buffer_line_hidden(b, i) {
            n += 1
        }
    }
    return n
}

// Clamped to 0. Pins the scroll top so the cursor sits on the bottom row.
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

// buffer_back_visible's twin, for the drag autoscroll. It ends on buffer_prev_visible because
// the LAST line can be hidden where line 0 cannot, so a walk that runs out must back out.
buffer_fwd_visible :: proc(b: ^Buffer, line, n: int) -> int {
    i := clamp(line, 0, txt.doc_line_count(&b.doc) - 1)
    left := n
    for left > 0 && i < txt.doc_line_count(&b.doc) - 1 {
        i += 1
        if !buffer_line_hidden(b, i) {
            left -= 1
        }
    }
    return buffer_prev_visible(b, i)
}

// --- lifecycle / invalidation ---

// Bring the folds up to date with the edits since the last sync, then clamp. Called each frame
// before the folds are read, and again by anything that edits mid-frame. It reads the change
// log through its own reader slot, so call order and frequency cannot change the answer.
buffer_sync_folds :: proc(b: ^Buffer) {
    changes, lost := txt.doc_changes_since(&b.doc, .Folds)
    txt.doc_changes_ack(&b.doc, .Folds) // even with no folds, so the log can trim
    if len(b.folds) == 0 {
        return
    }
    if lost {
        clear(&b.folds) // the log cannot reach back far enough to shift them honestly
        return
    }
    for c in changes {
        fold_shift(b, c)
    }
    last := txt.doc_line_count(&b.doc) - 1
    for &f in b.folds {
        f.end = min(f.end, last)
    }
    for i := len(b.folds) - 1; i >= 0; i -= 1 {
        if b.folds[i].end <= b.folds[i].line {
            unordered_remove(&b.folds, i)
        }
    }
}

// A change spans [start, old_end] and moves the line count by `delta`: anything wholly below is
// untouched, anything wholly above slides, anything it reaches into is dropped.
@(private = "file")
fold_shift :: proc(b: ^Buffer, c: txt.Doc_Change) {
    lo := c.start_pt.line
    hi := c.old_end_pt.line
    delta := c.new_end_pt.line - c.old_end_pt.line
    if delta == 0 {
        return // an edit within its own lines moves nothing
    }
    for i := len(b.folds) - 1; i >= 0; i -= 1 {
        f := &b.folds[i]
        switch {
        case hi < f.line: // entirely above: the whole fold slides
            f.line += delta
            f.end += delta
        case lo > f.end: // entirely below
        case:
            // It reaches the header or the body: the block's shape changed, so let it go.
            unordered_remove(&b.folds, i)
        }
    }
}

// --- the Ctrl+Enter toggle ---


// Package-visible: the toggle that hides a block is the App half's, and it has to pull any
// cursor out of what it just folded away.
buffer_collapse_hidden_cursors :: proc(b: ^Buffer) {
    for &c in b.cursors {
        if buffer_line_hidden(b, c.head.line) {
            h := buffer_prev_visible(b, c.head.line)
            p := txt.doc_clamp_pos(&b.doc, txt.Pos{h, c.head.col})
            c.head, c.anchor, c.goal = p, p, txt.doc_cell_col(&b.doc, p)
        }
    }
    txt.doc_merge_cursors(&b.doc)
}


// A header is foldable when the next non-blank line is deeper. The block runs through every
// following line that is blank or deeper; trailing blank lines are not pulled in.
fold_range_indent :: proc(b: ^Buffer, line: int) -> (start, end: int, ok: bool) {
    if line < 0 || line >= txt.doc_line_count(&b.doc) {
        return 0, 0, false
    }
    base := txt.line_indent_cols(txt.doc_line(&b.doc, line))
    nxt := line + 1
    for nxt < txt.doc_line_count(&b.doc) && txt.line_is_blank(txt.doc_line(&b.doc, nxt)) {
        nxt += 1
    }
    if nxt >= txt.doc_line_count(&b.doc) || txt.line_indent_cols(txt.doc_line(&b.doc, nxt)) <= base {
        return 0, 0, false
    }
    last := line
    for i := line + 1; i < txt.doc_line_count(&b.doc); i += 1 {
        if txt.line_is_blank(txt.doc_line(&b.doc, i)) {
            continue // a blank line never ends a block
        }
        if txt.line_indent_cols(txt.doc_line(&b.doc, i)) <= base {
            break
        }
        last = i
    }
    return line, last, last > line
}
