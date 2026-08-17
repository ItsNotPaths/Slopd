package tests

import app ".."
import "core:testing"

// Word boundaries over a line's bytes (src/word.odin). Positions in and out are BYTE columns,
// so the ASCII cases below read exactly as they did when they were rune indices — and the
// multi-byte case at the bottom is the one that would not.

@(private = "file")
bs :: proc(s: string) -> []u8 {
    return transmute([]u8)s
}

@(test)
test_word_index :: proc(t: ^testing.T) {
    text := bs("foo.bar baz") // f o o . b a r _ b a z  (len 11)

    testing.expect_value(t, app.word_right_index(text, 0), 3) // after foo
    testing.expect_value(t, app.word_right_index(text, 3), 4) // after .
    testing.expect_value(t, app.word_right_index(text, 4), 7) // after bar
    testing.expect_value(t, app.word_right_index(text, 7), 11) // skip space, after baz

    testing.expect_value(t, app.word_left_index(text, 11), 8) // start of baz
    testing.expect_value(t, app.word_left_index(text, 8), 4) // skip the space, start of bar
    testing.expect_value(t, app.word_left_index(text, 7), 4) // start of bar
}

// The symmetric question the directional word motions cannot answer: the run CONTAINING a
// column, which is what a double-click selects (C7). Expressing it in terms of
// word_left_index / word_right_index would give the wrong answer at either end of a word,
// because those two skip whitespace on the way and so never name the run you stand in.
@(test)
test_word_span :: proc(t: ^testing.T) {
    text := bs("foo.bar baz") // f o o . b a r _ b a z  (len 11)

    // Every column INSIDE a run yields the same span — including its first, which is where a
    // directional motion would step out into the previous run.
    for col in 0 ..< 3 {
        lo, hi := app.word_span(text, col)
        testing.expect_value(t, lo, 0)
        testing.expect_value(t, hi, 3)
    }

    // The argument is a CHARACTER position, not a caret boundary: column 3 IS the '.', which is
    // its own class and so its own run. (That distinction is why the pane hands this the
    // floored glyph column rather than the rounded caret column — editor_glyph_col.)
    lo, hi := app.word_span(text, 3)
    testing.expect_value(t, lo, 3)
    testing.expect_value(t, hi, 4)

    lo, hi = app.word_span(text, 5) // inside "bar"
    testing.expect_value(t, lo, 4)
    testing.expect_value(t, hi, 7)

    // Whitespace is a class like any other, so a double-click in a gap selects the gap.
    lo, hi = app.word_span(text, 7)
    testing.expect_value(t, lo, 7)
    testing.expect_value(t, hi, 8)

    // The last character of a run still belongs to it, which is the case that goes wrong
    // when a caret boundary is passed in by mistake: column 2 is the final 'o' of "foo".
    lo, hi = app.word_span(text, 2)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 3)

    // Past the last rune looks LEFT: clicking off the end of a line selects the word that
    // ends there, which is the one the caret at that column is next to.
    lo, hi = app.word_span(text, 11)
    testing.expect_value(t, lo, 8)
    testing.expect_value(t, hi, 11)

    // An empty line has no run at all, and must report an empty span rather than index it.
    lo, hi = app.word_span(bs(""), 0)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 0)
}

// Every step is a whole rune, so a boundary can never land inside one — the property that lets
// Doc hand these byte columns straight back to a cursor.
//
//   f ö(2) ö(2) . b a r   ->  bytes 0 1 3 5 6 7 8, len 9
@(test)
test_word_multibyte :: proc(t: ^testing.T) {
    text := bs("föö.bar")

    testing.expect_value(t, app.word_right_index(text, 0), 5) // past both umlauts
    testing.expect_value(t, app.word_right_index(text, 5), 6) // past the '.'
    testing.expect_value(t, app.word_left_index(text, 9), 6) // start of bar
    testing.expect_value(t, app.word_left_index(text, 5), 0) // back over the umlauts

    // A span asked from INSIDE the word still reports whole-rune ends.
    lo, hi := app.word_span(text, 3) // the second ö
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 5)

    // And from past the end, looking left over a word that ends in ASCII.
    lo, hi = app.word_span(text, 9)
    testing.expect_value(t, lo, 6)
    testing.expect_value(t, hi, 9)
}
