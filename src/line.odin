package main

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Line — one line of text: just a run of runes. Pure storage with position-
// parameterized ops; it has no cursor and no rendering. Cursors live in Doc
// (multiple can share a line), so Line knows nothing about selection or carets.
// GL-free and trivially testable.
Line :: struct {
    text: [dynamic]rune,
}

line_destroy :: proc(l: ^Line) {
    delete(l.text)
}

line_len :: proc(l: ^Line) -> int {
    return len(l.text)
}

// Inserts r at col (0..=len). col is assumed in range; callers clamp.
line_insert_at :: proc(l: ^Line, col: int, r: rune) {
    inject_at(&l.text, col, r)
}

// Removes the runes in [lo, hi). The range is assumed valid.
line_remove_range :: proc(l: ^Line, lo, hi: int) {
    remove_range(&l.text, lo, hi)
}

line_string :: proc(l: ^Line, allocator := context.allocator) -> string {
    b := strings.builder_make_len_cap(0, runes_byte_len(l.text[:]), allocator)
    for r in l.text {
        strings.write_rune(&b, r)
    }
    return strings.to_string(b)
}

// The UTF-8 byte length of a rune span — the exact capacity for a builder that will hold
// it. One cheap read-only pass buys a single right-sized allocation instead of a regrow
// chain, which matters on the whole-buffer capture the highlighter does per reparse.
runes_byte_len :: proc(runes: []rune) -> int {
    n := 0
    for r in runes {
        n += utf8.rune_size(r)
    }
    return n
}

// --- word boundaries (used by Doc for word motions/deletes) ---

// IDE-style word jump: skip a leading run of whitespace, then one run of a single
// class. So "foo.bar" yields three stops (foo | . | bar).
word_right_index :: proc(text: []rune, from: int) -> int {
    n := len(text)
    i := from
    for i < n && class_of(text[i]) == .Space {
        i += 1
    }
    if i < n {
        c := class_of(text[i])
        for i < n && class_of(text[i]) == c {
            i += 1
        }
    }
    return i
}

word_left_index :: proc(text: []rune, from: int) -> int {
    i := from
    for i > 0 && class_of(text[i - 1]) == .Space {
        i -= 1
    }
    if i > 0 {
        c := class_of(text[i - 1])
        for i > 0 && class_of(text[i - 1]) == c {
            i -= 1
        }
    }
    return i
}

// The run of one character class CONTAINING `col`, as a half-open [lo, hi) — what a
// double-click selects. The motions above are directional and would answer this wrong at
// either end of a word. A column past the last rune looks LEFT; whitespace is a class too.
word_span :: proc(text: []rune, col: int) -> (lo, hi: int) {
    n := len(text)
    if n == 0 {
        return 0, 0
    }
    i := clamp(col, 0, n)
    if i == n {
        i -= 1 // past the end: the run that ends here
    }
    c := class_of(text[i])
    lo, hi = i, i + 1
    for lo > 0 && class_of(text[lo - 1]) == c {
        lo -= 1
    }
    for hi < n && class_of(text[hi]) == c {
        hi += 1
    }
    return
}

// --- internals ---

@(private = "file")
Char_Class :: enum {
    Space,
    Word,
    Punct,
}

@(private = "file")
class_of :: proc(r: rune) -> Char_Class {
    switch {
    case unicode.is_space(r):
        return .Space
    case r == '_' || unicode.is_letter(r) || unicode.is_digit(r):
        return .Word
    case:
        return .Punct
    }
}
