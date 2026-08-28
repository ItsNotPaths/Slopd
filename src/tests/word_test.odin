package tests

import "core:testing"
import "../txt"

// Word boundaries over a line's bytes. Positions in and out are BYTE columns, so the ASCII cases
// read as they did when they were rune indices; the multi-byte case at the bottom would not.

@(private = "file")
bs :: proc(s: string) -> []u8 {
    return transmute([]u8)s
}

@(test)
test_word_index :: proc(t: ^testing.T) {
    text := bs("foo.bar baz") // f o o . b a r _ b a z  (len 11)

    testing.expect_value(t, txt.word_right_index(text, 0), 3) // after foo
    testing.expect_value(t, txt.word_right_index(text, 3), 4) // after .
    testing.expect_value(t, txt.word_right_index(text, 4), 7) // after bar
    testing.expect_value(t, txt.word_right_index(text, 7), 11) // skip space, after baz

    testing.expect_value(t, txt.word_left_index(text, 11), 8) // start of baz
    testing.expect_value(t, txt.word_left_index(text, 8), 4) // skip the space, start of bar
    testing.expect_value(t, txt.word_left_index(text, 7), 4) // start of bar
}

// The run CONTAINING a column, which is what a double-click selects. Expressing it through
// word_left_index / word_right_index would be wrong at either end of a word, because those skip
// whitespace and so never name the run you stand in.
@(test)
test_word_span :: proc(t: ^testing.T) {
    text := bs("foo.bar baz") // f o o . b a r _ b a z  (len 11)

    // Every column inside a run yields the same span, its first included.
    for col in 0 ..< 3 {
        lo, hi := txt.word_span(text, col)
        testing.expect_value(t, lo, 0)
        testing.expect_value(t, hi, 3)
    }

    // A CHARACTER position, not a caret boundary: column 3 IS the '.', its own class and so its
    // own run. Which is why the pane hands this the floored glyph column.
    lo, hi := txt.word_span(text, 3)
    testing.expect_value(t, lo, 3)
    testing.expect_value(t, hi, 4)

    lo, hi = txt.word_span(text, 5) // inside "bar"
    testing.expect_value(t, lo, 4)
    testing.expect_value(t, hi, 7)

    // Whitespace is a class like any other, so a double-click in a gap selects the gap.
    lo, hi = txt.word_span(text, 7)
    testing.expect_value(t, lo, 7)
    testing.expect_value(t, hi, 8)

    // The last character of a run still belongs to it: the case that goes wrong when a caret
    // boundary is passed in by mistake.
    lo, hi = txt.word_span(text, 2)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 3)

    // Past the last rune looks LEFT: clicking off the end selects the word that ends there.
    lo, hi = txt.word_span(text, 11)
    testing.expect_value(t, lo, 8)
    testing.expect_value(t, hi, 11)

    // An empty line has no run, and must report an empty span rather than index it.
    lo, hi = txt.word_span(bs(""), 0)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 0)
}

// Every step is a whole rune, which is what lets Doc hand these byte columns straight back to a
// cursor.
//
//   f ö(2) ö(2) . b a r   ->  bytes 0 1 3 5 6 7 8, len 9
@(test)
test_word_multibyte :: proc(t: ^testing.T) {
    text := bs("föö.bar")

    testing.expect_value(t, txt.word_right_index(text, 0), 5) // past both umlauts
    testing.expect_value(t, txt.word_right_index(text, 5), 6) // past the '.'
    testing.expect_value(t, txt.word_left_index(text, 9), 6) // start of bar
    testing.expect_value(t, txt.word_left_index(text, 5), 0) // back over the umlauts

    // A span from inside the word still reports whole-rune ends.
    lo, hi := txt.word_span(text, 3) // the second ö
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 5)

    // And from past the end, looking left over a word ending in ASCII.
    lo, hi = txt.word_span(text, 9)
    testing.expect_value(t, lo, 6)
    testing.expect_value(t, hi, 9)
}
