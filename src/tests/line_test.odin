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
