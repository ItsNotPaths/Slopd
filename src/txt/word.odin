package txt

import "core:unicode"
import "core:unicode/utf8"

// Word boundaries over one line's bytes — what the word motions, the word deletes and the
// double-click all ask for. Positions in and out are BYTE columns, matching Pos, and every step
// is a whole rune, so a boundary can never land inside one. Pure and trivially testable: no
// document, no cursor, no rendering.

// IDE-style word jump: skip a leading run of whitespace, then one run of a single class. So
// "foo.bar" yields three stops (foo | . | bar).
word_right_index :: proc(text: []u8, from: int) -> int {
    i := clamp(from, 0, len(text))
    for i < len(text) {
        r, sz := utf8.decode_rune(text[i:])
        if class_of(r) != .Space {
            break
        }
        i += max(sz, 1)
    }
    if i < len(text) {
        first, _ := utf8.decode_rune(text[i:])
        c := class_of(first)
        for i < len(text) {
            r, sz := utf8.decode_rune(text[i:])
            if class_of(r) != c {
                break
            }
            i += max(sz, 1)
        }
    }
    return i
}

word_left_index :: proc(text: []u8, from: int) -> int {
    i := clamp(from, 0, len(text))
    for i > 0 {
        r, sz := utf8.decode_last_rune(text[:i])
        if class_of(r) != .Space {
            break
        }
        i -= max(sz, 1)
    }
    if i > 0 {
        last, _ := utf8.decode_last_rune(text[:i])
        c := class_of(last)
        for i > 0 {
            r, sz := utf8.decode_last_rune(text[:i])
            if class_of(r) != c {
                break
            }
            i -= max(sz, 1)
        }
    }
    return i
}

// The run of one character class CONTAINING `col`, as a half-open [lo, hi) — what a double-click
// selects. The motions above are directional and would answer this wrong at either end of a word.
// A column past the last rune looks LEFT; whitespace is a class too.
word_span :: proc(text: []u8, col: int) -> (lo, hi: int) {
    if len(text) == 0 {
        return 0, 0
    }
    i := clamp(col, 0, len(text))
    if i == len(text) {
        _, sz := utf8.decode_last_rune(text[:i])
        i -= max(sz, 1) // past the end: the run that ends here
    }
    at, size := utf8.decode_rune(text[i:])
    c := class_of(at)
    lo, hi = i, i + max(size, 1)
    for lo > 0 {
        r, sz := utf8.decode_last_rune(text[:lo])
        if class_of(r) != c {
            break
        }
        lo -= max(sz, 1)
    }
    for hi < len(text) {
        r, sz := utf8.decode_rune(text[hi:])
        if class_of(r) != c {
            break
        }
        hi += max(sz, 1)
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
