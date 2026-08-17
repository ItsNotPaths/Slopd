package main

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Heuristic bracket/quote pairing, no tree-sitter. Everything fans out to all cursors: each
// caret decides its own action from local context and contributes one edit to a single commit,
// with caret_delta parking it inside a fresh pair or past a skipped close. The pair set is fixed
// for now; a per-language table comes with the language registry.

// Quotes are their own close. Package-visible, so the buffer backspace can recognise an empty
// pair.
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

// false — leaving the caller to insert it plainly — only when r is not a pair character.
buffer_autopair :: proc(b: ^Buffer, r: rune) -> bool {
    if !is_open(r) && !is_close(r) && !is_quote(r) {
        return false
    }
    d := &b.doc
    close, _ := pair_close(r)
    self := text(r)
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        if cursor_has_selection(c) {
            lo, hi := cursor_range(c)
            at, to := doc_off(d, lo), doc_off(d, hi)
            if is_open(r) || is_quote(r) {
                append(&edits, Edit{at, to, surround(d, r, close, lo, hi), 0}) // surround
            } else {
                append(&edits, Edit{at, to, self, 0}) // the closer replaces the selection
            }
            continue
        }
        at := doc_off(d, c.head)
        next := doc_rune_at(d, c.head)
        prev, _ := doc_rune_before(d, c.head)
        // A quote right after a word character is an apostrophe, not a new pair.
        quote_apostrophe := is_quote(r) && is_word(prev)
        switch {
        case (is_close(r) || is_quote(r)) && next == r:
            append(&edits, Edit{at, at, "", -1}) // step over the existing close
        case (is_open(r) || is_quote(r)) && !is_word(next) && !quote_apostrophe:
            append(&edits, Edit{at, at, text(r, close), 1}) // pair, caret inside
        case:
            append(&edits, Edit{at, at, self, 0}) // plain
        }
    }
    b.dirty |= doc_commit(d, edits[:])
    return true
}

// A caret inside a pair jumps just past the next close on its line; one in leading whitespace,
// or with no close ahead, indents instead. Mixed outcomes commit together.
buffer_tab :: proc(b: ^Buffer, indent: Indent) {
    d := &b.doc
    edits := make([dynamic]Edit, 0, len(d.cursors), context.temp_allocator)
    for c in d.cursors {
        at := doc_off(d, c.head)
        if j, ok := skip_target(doc_line(d, c.head.line), c.head.col); ok {
            // An empty edit; caret_delta jumps the caret past the close.
            append(&edits, Edit{at, at, "", c.head.col - (j + 1)})
        } else {
            append(&edits, Edit{at, at, indent_text(indent), 0})
        }
    }
    b.dirty |= doc_commit(d, edits[:])
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
surround :: proc(d: ^Doc, open, close: rune, lo, hi: Pos) -> string {
    sel := doc_text(d, lo, hi, context.temp_allocator)
    return strings.concatenate({text(open), sel, text(close)}, context.temp_allocator)
}

// A tab, or N spaces. Temp-allocated.
indent_text :: proc(indent: Indent) -> string {
    n := indent.kind == .Tab ? 1 : indent.width
    return strings.repeat(indent.kind == .Tab ? "\t" : " ", n, context.temp_allocator)
}
