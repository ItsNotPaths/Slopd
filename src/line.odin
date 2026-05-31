package main

import "core:strings"
import "core:unicode"

// Line — a single editable line of text. It is the shared primitive beneath the
// command line and (one per row) the editor buffer. Pure: runes + cursor, no
// rendering and no GL, so it is trivially testable.
//
// Invariant: when there is no selection, cursor == anchor. Movement with
// select=true keeps the anchor so a selection grows; every other op collapses it.
Line :: struct {
    text:   [dynamic]rune,
    cursor: int, // rune index in 0..=len(text)
    anchor: int, // selection start; anchor == cursor means no selection
}

line_destroy :: proc(l: ^Line) {
    delete(l.text)
}

// --- content ---

line_clear :: proc(l: ^Line) {
    clear(&l.text)
    l.cursor = 0
    l.anchor = 0
}

// Replaces the whole line and parks the cursor at the end (history recall, inject).
line_set :: proc(l: ^Line, s: string) {
    clear(&l.text)
    for r in s {
        append(&l.text, r)
    }
    l.cursor = len(l.text)
    l.anchor = l.cursor
}

line_string :: proc(l: ^Line, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for r in l.text {
        strings.write_rune(&b, r)
    }
    return strings.to_string(b)
}

line_selected :: proc(l: ^Line, allocator := context.allocator) -> string {
    lo, hi := line_sel_range(l)
    b := strings.builder_make(allocator)
    for r in l.text[lo:hi] {
        strings.write_rune(&b, r)
    }
    return strings.to_string(b)
}

// --- selection ---

line_has_selection :: proc(l: ^Line) -> bool {
    return l.cursor != l.anchor
}

line_sel_range :: proc(l: ^Line) -> (lo, hi: int) {
    return min(l.cursor, l.anchor), max(l.cursor, l.anchor)
}

// --- editing ---

line_insert_rune :: proc(l: ^Line, r: rune) {
    line_delete_selection(l) // typing replaces an active selection
    inject_at(&l.text, l.cursor, r)
    l.cursor += 1
    l.anchor = l.cursor
}

line_delete_back :: proc(l: ^Line) {
    if line_delete_selection(l) {
        return
    }
    if l.cursor > 0 {
        ordered_remove(&l.text, l.cursor - 1)
        l.cursor -= 1
        l.anchor = l.cursor
    }
}

line_delete_forward :: proc(l: ^Line) {
    if line_delete_selection(l) {
        return
    }
    if l.cursor < len(l.text) {
        ordered_remove(&l.text, l.cursor)
    }
}

line_delete_word_back :: proc(l: ^Line) {
    if line_delete_selection(l) {
        return
    }
    to := word_left_index(l.text[:], l.cursor)
    if to < l.cursor {
        remove_range(&l.text, to, l.cursor)
        l.cursor = to
        l.anchor = to
    }
}

line_delete_word_forward :: proc(l: ^Line) {
    if line_delete_selection(l) {
        return
    }
    to := word_right_index(l.text[:], l.cursor)
    if to > l.cursor {
        remove_range(&l.text, l.cursor, to)
    }
}

// --- movement (select=true keeps the anchor to extend a selection) ---
// A plain (non-select) move with an active selection collapses to the edge it
// moves toward, the standard GUI behavior, rather than stepping from the cursor.

line_move_left :: proc(l: ^Line, select := false) {
    if !select && line_has_selection(l) {
        lo, _ := line_sel_range(l)
        line_place(l, lo, false)
        return
    }
    line_place(l, l.cursor - 1, select)
}

line_move_right :: proc(l: ^Line, select := false) {
    if !select && line_has_selection(l) {
        _, hi := line_sel_range(l)
        line_place(l, hi, false)
        return
    }
    line_place(l, l.cursor + 1, select)
}

line_move_word_left :: proc(l: ^Line, select := false) {
    line_place(l, word_left_index(l.text[:], l.cursor), select)
}

line_move_word_right :: proc(l: ^Line, select := false) {
    line_place(l, word_right_index(l.text[:], l.cursor), select)
}

line_move_home :: proc(l: ^Line, select := false) {
    line_place(l, 0, select)
}

line_move_end :: proc(l: ^Line, select := false) {
    line_place(l, len(l.text), select)
}

// --- internals ---

@(private = "file")
line_place :: proc(l: ^Line, to: int, select: bool) {
    l.cursor = clamp(to, 0, len(l.text))
    if !select {
        l.anchor = l.cursor
    }
}

@(private = "file")
line_delete_selection :: proc(l: ^Line) -> bool {
    if !line_has_selection(l) {
        return false
    }
    lo, hi := line_sel_range(l)
    remove_range(&l.text, lo, hi)
    l.cursor = lo
    l.anchor = lo
    return true
}

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

// IDE-style word jump: skip a leading run of whitespace, then one run of a single
// class. So "foo.bar" yields three stops (foo | . | bar).
@(private = "file")
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

@(private = "file")
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
