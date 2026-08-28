package main

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "txt"

// Heuristic bracket/quote pairing, no tree-sitter. Everything fans out to all cursors: each
// caret decides its own action from local context and contributes one edit to a single commit,
// with caret_delta parking it inside a fresh pair or past a skipped close. The pair set is fixed
// for now; a per-language table comes with the language registry.

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

// false — leaving the caller to insert it plainly — only when r is not a pair character.
buffer_autopair :: proc(b: ^Buffer, r: rune) -> bool {
    if !is_open(r) && !is_close(r) && !is_quote(r) {
        return false
    }
    d := &b.doc
    close, _ := txt.pair_close(r)
    self := text(r)
    edits := make([dynamic]txt.Edit, 0, len(d.cursors), context.temp_allocator)
    for c in txt.edit_cursors(d) {
        if txt.cursor_has_selection(c) {
            lo, hi := txt.cursor_range(c)
            at, to := txt.doc_off(d, lo), txt.doc_off(d, hi)
            if is_open(r) || is_quote(r) {
                append(&edits, txt.Edit{at, to, surround(d, r, close, lo, hi), 0}) // surround
            } else {
                append(&edits, txt.Edit{at, to, self, 0}) // the closer replaces the selection
            }
            continue
        }
        at := txt.doc_off(d, c.head)
        next := txt.doc_rune_at(d, c.head)
        prev, _ := txt.doc_rune_before(d, c.head)
        // A quote right after a word character is an apostrophe, not a new pair.
        quote_apostrophe := is_quote(r) && is_word(prev)
        switch {
        case (is_close(r) || is_quote(r)) && next == r:
            append(&edits, txt.Edit{at, at, "", -1}) // step over the existing close
        case (is_open(r) || is_quote(r)) && !is_word(next) && !quote_apostrophe:
            append(&edits, txt.Edit{at, at, text(r, close), 1}) // pair, caret inside
        case:
            append(&edits, txt.Edit{at, at, self, 0}) // plain
        }
    }
    b.dirty |= txt.doc_commit(d, edits[:])
    return true
}

// A caret inside a pair jumps just past the next close on its line; one in leading whitespace,
// or with no close ahead, indents instead. Mixed outcomes commit together.
buffer_tab :: proc(b: ^Buffer, indent: Indent) {
    d := &b.doc
    // A selection crossing lines is the BLOCK gesture, not a character to type over.
    for c in d.cursors {
        if lo, hi := txt.cursor_range(c); lo.line != hi.line {
            _ = buffer_indent_block(b, indent, false)
            return
        }
    }
    edits := make([dynamic]txt.Edit, 0, len(d.cursors), context.temp_allocator)
    for c in txt.edit_cursors(d) {
        at := txt.doc_off(d, c.head)
        if j, ok := skip_target(txt.doc_line(d, c.head.line), c.head.col); ok {
            // An empty edit; caret_delta jumps the caret past the close.
            append(&edits, txt.Edit{at, at, "", c.head.col - (j + 1)})
        } else {
            append(&edits, txt.Edit{at, at, indent_text(indent), 0})
        }
    }
    b.dirty |= txt.doc_commit(d, edits[:])
}

// Tab and Shift+Tab over whole lines; `out` takes a level off instead of adding one. A blank line
// is left alone, since indenting it would only leave trailing whitespace behind.
buffer_indent_block :: proc(b: ^Buffer, indent: Indent, out: bool) -> bool {
    d := &b.doc
    lines := txt.doc_cursor_lines(d)
    edits := make([dynamic]txt.Edit, 0, len(lines), context.temp_allocator)
    deltas := make([]int, len(lines), context.temp_allocator)
    unit := indent_text(indent)
    for line, i in lines {
        anchor, _ := txt.line_span(d, line)
        start := txt.doc_off(d, anchor)
        src := txt.doc_line(d, line)
        if out {
            n := dedent_width(src, indent)
            if n == 0 {
                continue
            }
            append(&edits, txt.Edit{start, start + n, "", 0})
            deltas[i] = -n
        } else if len(src) > 0 {
            append(&edits, txt.Edit{start, start, unit, 0})
            deltas[i] = len(unit)
        }
    }
    changed := txt.doc_line_commit(d, edits[:], lines, deltas)
    b.dirty |= changed
    return changed
}

// What one Shift+Tab takes off the front: a tab, or up to a level's worth of spaces.
dedent_width :: proc(src: []u8, indent: Indent) -> int {
    if len(src) > 0 && src[0] == '\t' {
        return 1
    }
    n := 0
    for n < len(src) && n < max(indent.width, 1) && src[n] == ' ' {
        n += 1
    }
    return n
}

// --- internals ---

// Per call rather than shared: a compound literal's storage is hoisted to the enclosing frame,
// so a value built in the per-cursor loop would alias one buffer across every cursor.
@(private = "file")
text :: proc(rs: ..rune) -> string {
    return utf8.runes_to_string(rs, context.temp_allocator)
}

// Only when the caret is past the leading whitespace, so Tab still indents at the line start.
// Every pair character is ASCII, so the scan is over bytes.
@(private = "file")
skip_target :: proc(src: []u8, col: int) -> (j: int, ok: bool) {
    first := 0
    for first < len(src) && (src[first] == ' ' || src[first] == '\t') {
        first += 1
    }
    if col <= first {
        return 0, false
    }
    for k in min(col, len(src)) ..< len(src) {
        if is_close(rune(src[k])) || is_quote(rune(src[k])) {
            return k, true
        }
    }
    return 0, false
}

@(private = "file")
surround :: proc(d: ^txt.Doc, open, close: rune, lo, hi: txt.Pos) -> string {
    sel := txt.doc_text(d, lo, hi, context.temp_allocator)
    return strings.concatenate({text(open), sel, text(close)}, context.temp_allocator)
}

// A tab, or N spaces. Temp-allocated.
indent_text :: proc(indent: Indent) -> string {
    n := indent.kind == .Tab ? 1 : indent.width
    return strings.repeat(indent.kind == .Tab ? "\t" : " ", n, context.temp_allocator)
}
