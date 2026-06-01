package main

import "core:unicode"

// Auto-pairs — heuristic bracket/quote pairing (no tree-sitter; per Direction).
// Everything fans out to ALL cursors: each caret decides its own action from its
// local context and contributes one edit to a single commit (the funnel's
// per-edit caret_delta parks each caret inside a fresh pair or past a skipped
// close). The pair set is fixed for now; a per-language table comes with the
// language registry.

// open -> close for the pair set. Quotes are their own close. Package-visible so
// the buffer backspace can recognise an empty pair.
pair_close :: proc(open: rune) -> (close: rune, ok: bool) {
    switch open {
    case '(':
        return ')', true
    case '[':
        return ']', true
    case '{':
        return '}', true
    case '"':
        return '"', true
    case '\'':
        return '\'', true
    case '`':
        return '`', true
    }
    return 0, false
}

@(private = "file")
is_open :: proc(r: rune) -> bool {
    return r == '(' || r == '[' || r == '{'
}

@(private = "file")
is_close :: proc(r: rune) -> bool {
    return r == ')' || r == ']' || r == '}'
}

@(private = "file")
is_quote :: proc(r: rune) -> bool {
    return r == '"' || r == '\'' || r == '`'
}

@(private = "file")
is_word :: proc(r: rune) -> bool {
    return r == '_' || unicode.is_letter(r) || unicode.is_digit(r)
}

// Handles a typed pair character across every cursor; returns false (leaving the
// caller to insert it plainly) only when r isn't a pair character at all.
buffer_autopair :: proc(b: ^Buffer, r: rune) -> bool {
    if !is_open(r) && !is_close(r) && !is_quote(r) {
        return false
    }
    d := &b.doc
    close, _ := pair_close(r)
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            if is_open(r) || is_quote(r) {
                append(&edits, Edit{lo, hi, surround_runes(d, r, close, lo, hi), 0}) // surround
            } else {
                append(&edits, Edit{lo, hi, []rune{r}, 0}) // closer replaces the selection
            }
            continue
        }
        line := &d.lines[c.head.line]
        next := char_at(line, c.head.col)
        prev := c.head.col > 0 ? line.text[c.head.col - 1] : 0
        // A quote right after a word char is an apostrophe/closing quote, not a new
        // pair (foo' / don'); only auto-pair a quote away from word text.
        quote_apostrophe := is_quote(r) && is_word(prev)
        switch {
        case (is_close(r) || is_quote(r)) && next == r:
            append(&edits, Edit{c.head, c.head, nil, -1}) // step over the existing close
        case (is_open(r) || is_quote(r)) && !is_word(next) && !quote_apostrophe:
            append(&edits, Edit{c.head, c.head, []rune{r, close}, 1}) // insert pair, caret inside
        case:
            append(&edits, Edit{c.head, c.head, []rune{r}, 0}) // plain
        }
    }
    b.dirty |= doc_commit(d, edits[:])
    return true
}

// Tab: each caret inside a pair jumps just past the next close/quote on its line;
// carets in leading whitespace (or with no close ahead) indent instead. Mixed
// outcomes commit together.
buffer_tab :: proc(b: ^Buffer, indent: Indent) {
    d := &b.doc
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        line := &d.lines[c.head.line]
        if j, ok := skip_target(line, c.head.col); ok {
            // Empty edit; caret_delta jumps the caret to just past the close.
            append(&edits, Edit{c.head, c.head, nil, c.head.col - (j + 1)})
        } else {
            append(&edits, Edit{c.head, c.head, indent_runes(indent), 0})
        }
    }
    b.dirty |= doc_commit(d, edits[:])
}

// --- internals ---

// Column just past the next close/quote on the line at/after col, when the caret
// is past the leading whitespace (so Tab still indents at the line start).
@(private = "file")
skip_target :: proc(line: ^Line, col: int) -> (j: int, ok: bool) {
    first := 0
    for first < line_len(line) && (line.text[first] == ' ' || line.text[first] == '\t') {
        first += 1
    }
    if col <= first {
        return 0, false
    }
    for k in col ..< line_len(line) {
        if is_close(line.text[k]) || is_quote(line.text[k]) {
            return k, true
        }
    }
    return 0, false
}

@(private = "file")
surround_runes :: proc(d: ^Doc, open, close: rune, lo, hi: Pos) -> []rune {
    sel := doc_text(d, lo, hi, context.temp_allocator)
    out := make([dynamic]rune, 0, len(sel) + 2, context.temp_allocator)
    append(&out, open)
    for r in sel {
        append(&out, r)
    }
    append(&out, close)
    return out[:]
}

@(private = "file")
indent_runes :: proc(indent: Indent) -> []rune {
    n := indent.kind == .Tab ? 1 : indent.width
    rs := make([]rune, n, context.temp_allocator)
    for &r in rs {
        r = indent.kind == .Tab ? '\t' : ' '
    }
    return rs
}
