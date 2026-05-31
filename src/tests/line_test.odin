package tests

import app ".."
import "core:testing"

@(private = "file")
mk :: proc(s: string) -> app.Line {
    l: app.Line
    app.line_set(&l, s) // cursor parked at end
    return l
}

@(private = "file")
str :: proc(l: ^app.Line) -> string {
    return app.line_string(l, context.temp_allocator)
}

@(test)
test_word_motion :: proc(t: ^testing.T) {
    l := mk("foo.bar baz") // f o o . b a r _ b a z  (len 11)
    defer app.line_destroy(&l)

    app.line_move_home(&l)
    app.line_move_word_right(&l);testing.expect_value(t, l.cursor, 3) // after foo
    app.line_move_word_right(&l);testing.expect_value(t, l.cursor, 4) // after .
    app.line_move_word_right(&l);testing.expect_value(t, l.cursor, 7) // after bar
    app.line_move_word_right(&l);testing.expect_value(t, l.cursor, 11) // skip space, after baz

    app.line_move_word_left(&l);testing.expect_value(t, l.cursor, 8) // start of baz
    app.line_move_word_left(&l);testing.expect_value(t, l.cursor, 4) // start of bar
}

@(test)
test_edit_and_selection :: proc(t: ^testing.T) {
    l: app.Line
    defer app.line_destroy(&l)
    for r in "hello" {
        app.line_insert_rune(&l, r)
    }
    testing.expect_value(t, str(&l), "hello")
    testing.expect_value(t, l.cursor, 5)

    app.line_move_home(&l)
    app.line_move_right(&l, true) // select "h"
    app.line_move_right(&l, true) // select "he"
    testing.expect(t, app.line_has_selection(&l))
    testing.expect_value(t, app.line_selected(&l, context.temp_allocator), "he")

    app.line_insert_rune(&l, 'H') // typing replaces the selection
    testing.expect_value(t, str(&l), "Hllo")
    testing.expect(t, !app.line_has_selection(&l))
    testing.expect_value(t, l.cursor, 1)
}

@(test)
test_move_collapses_selection :: proc(t: ^testing.T) {
    l := mk("abcdef")
    defer app.line_destroy(&l)
    app.line_move_home(&l)
    for _ in 0 ..< 3 {
        app.line_move_right(&l, true) // select "abc": cursor 3, anchor 0
    }
    app.line_move_left(&l) // plain move collapses to the left edge
    testing.expect(t, !app.line_has_selection(&l))
    testing.expect_value(t, l.cursor, 0)
}

@(test)
test_delete_word_back :: proc(t: ^testing.T) {
    l := mk("alpha beta")
    defer app.line_destroy(&l)
    app.line_delete_word_back(&l) // removes "beta"
    testing.expect_value(t, str(&l), "alpha ")
    app.line_delete_word_back(&l) // removes " alpha" back to start
    testing.expect_value(t, str(&l), "")
}

@(test)
test_delete_back_and_forward :: proc(t: ^testing.T) {
    l := mk("abc")
    defer app.line_destroy(&l)
    app.line_delete_back(&l) // "ab"
    testing.expect_value(t, str(&l), "ab")
    app.line_move_home(&l)
    app.line_delete_forward(&l) // "b"
    testing.expect_value(t, str(&l), "b")
    testing.expect_value(t, l.cursor, 0)
}
