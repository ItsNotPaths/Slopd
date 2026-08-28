package tests

import "core:math/rand"
import "core:testing"
import "../txt"

// Multi-cursor editing, and what undo owes it. Every edit fans out to one replacement per
// cursor, and the two ways that goes wrong are here: carets that name the SAME range, which
// must edit it once, and carets whose ranges OVERLAP, which must not edit it twice.

@(private = "file")
mk2 :: proc(s: string, a, b: txt.Pos) -> txt.Doc {
    d: txt.Doc
    txt.doc_set_text(&d, s)
    txt.doc_reset_cursor(&d, a)
    txt.doc_add_cursor(&d, b)
    return d
}

@(private = "file")
text :: proc(d: ^txt.Doc) -> string {
    return txt.doc_string(d, context.temp_allocator)
}

// Two carets one byte apart delete one rune each. Both deletions land at the same offset in the
// document they leave behind, so undo must not read them as one.
@(test)
test_multicursor_backspace_undo :: proc(t: ^testing.T) {
    d := mk2("abcd", {0, 1}, {0, 2})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_backspace(&d))
    testing.expect_value(t, text(&d), "cd")

    testing.expect(t, txt.doc_undo(&d))
    testing.expect_value(t, text(&d), "abcd")
}

// Two carets inside one word: both word-deletes reach back to the same word start, so the word
// goes once. Applying both would eat a rune that neither caret named.
@(test)
test_multicursor_word_back_overlap :: proc(t: ^testing.T) {
    d := mk2("abcd", {0, 1}, {0, 2})
    defer txt.doc_destroy(&d)

    testing.expect(t, txt.doc_delete_word_back(&d))
    testing.expect_value(t, text(&d), "cd")

    testing.expect(t, txt.doc_undo(&d))
    testing.expect_value(t, text(&d), "abcd")
}

// Alt+A leaves a fixed cursor exactly under the free caret. That pair names one range, and a
// typed character must appear once.
@(test)
test_dropped_anchor_types_once :: proc(t: ^testing.T) {
    d: txt.Doc
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "ab")
    txt.doc_reset_cursor(&d, {0, 1})
    txt.doc_drop_anchor(&d)
    testing.expect_value(t, len(d.cursors), 2)

    testing.expect(t, txt.doc_insert_rune(&d, 'X'))
    testing.expect_value(t, text(&d), "aXb")
}

// --- the property ---

@(private = "file")
EDIT_OPS :: 40

// Undo far enough and the document is the one you started with; redo forward and it is the one
// you ended with. Nothing else is asserted, because nothing else has to be: any edit that loses
// or duplicates bytes under a caret arrangement breaks the round trip. Multi-byte runes are in
// the corpus so a caret landing mid-rune is exercised too.
@(test)
test_multicursor_undo_roundtrip :: proc(t: ^testing.T) {
    seeds := rand.create(t.seed)
    context.random_generator = rand.default_random_generator(&seeds)

    for trial in 0 ..< 200 {
        d: txt.Doc
        defer txt.doc_destroy(&d)
        start := "one two\nthree four\n\nfïve six\nseven"
        txt.doc_set_text(&d, start)

        for _ in 0 ..< EDIT_OPS {
            scatter_cursors(&d)
            random_edit(&d)
        }
        end := txt.doc_string(&d, context.temp_allocator)

        for txt.doc_undo(&d) {}
        testing.expectf(t, text(&d) == start, "trial %d: undo left %q", trial, text(&d))

        for txt.doc_redo(&d) {}
        testing.expectf(t, text(&d) == end, "trial %d: redo left %q", trial, text(&d))
    }
}

// One to four carets at random positions, each with an even chance of a selection running to
// another random position. doc_clamp_pos does the snapping, as it does for a real pointer.
@(private = "file")
scatter_cursors :: proc(d: ^txt.Doc) {
    txt.doc_reset_cursor(d, random_pos(d))
    for _ in 0 ..< rand.int_max(3) {
        txt.doc_add_cursor(d, random_pos(d))
    }
    if rand.int_max(2) == 0 {
        txt.doc_set_head(d, random_pos(d), true)
    }
    if rand.int_max(8) == 0 {
        txt.doc_drop_anchor(d) // the coincident pair
    }
}

@(private = "file")
random_pos :: proc(d: ^txt.Doc) -> txt.Pos {
    line := rand.int_max(txt.doc_line_count(d))
    return {line, rand.int_max(txt.doc_line_len(d, line) + 1)}
}

@(private = "file")
random_edit :: proc(d: ^txt.Doc) {
    switch rand.int_max(8) {
    case 0:
        txt.doc_insert_rune(d, rand.choice([]rune{'a', ' ', '(', 'é'}))
    case 1:
        txt.doc_insert_text(d, rand.choice([]string{"xy", "p\nq", "  "}))
    case 2:
        txt.doc_newline(d)
    case 3:
        txt.doc_backspace(d)
    case 4:
        txt.doc_delete(d)
    case 5:
        txt.doc_delete_word_back(d)
    case 6:
        txt.doc_delete_word_forward(d)
    case 7:
        txt.doc_cut(d)
    }
}
