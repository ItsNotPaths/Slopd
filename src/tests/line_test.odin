package tests

import app ".."
import "core:testing"

@(private = "file")
mk :: proc(s: string) -> app.Line {
    l: app.Line
    for r in s {
        append(&l.text, r)
    }
    return l
}

@(private = "file")
str :: proc(l: ^app.Line) -> string {
    return app.line_string(l, context.temp_allocator)
}

@(test)
test_line_edit :: proc(t: ^testing.T) {
    l := mk("helo")
    defer app.line_destroy(&l)
    app.line_insert_at(&l, 3, 'l') // "hello"
    testing.expect_value(t, str(&l), "hello")
    testing.expect_value(t, app.line_len(&l), 5)
    app.line_remove_range(&l, 1, 3) // drop "el" -> "hlo"
    testing.expect_value(t, str(&l), "hlo")
}

@(test)
test_word_index :: proc(t: ^testing.T) {
    l := mk("foo.bar baz") // f o o . b a r _ b a z  (len 11)
    defer app.line_destroy(&l)
    text := l.text[:]

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
    l := mk("foo.bar baz") // f o o . b a r _ b a z  (len 11)
    defer app.line_destroy(&l)
    text := l.text[:]

    // Every column INSIDE a run yields the same span — including its first, which is where a
    // directional motion would step out into the previous run.
    for col in 0 ..< 3 {
        lo, hi := app.word_span(text, col)
        testing.expect_value(t, lo, 0)
        testing.expect_value(t, hi, 3)
    }

    // The argument is a CHARACTER index, not a caret boundary: column 3 IS the '.', which is
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
    e := mk("")
    defer app.line_destroy(&e)
    lo, hi = app.word_span(e.text[:], 0)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 0)
}
