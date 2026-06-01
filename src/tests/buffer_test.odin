package tests

import app ".."
import "core:strings"
import "core:testing"

@(private = "file")
mkbuf :: proc(text: string) -> app.Buffer {
    b: app.Buffer
    app.buffer_set_text(&b, text)
    return b
}

@(private = "file")
lstr :: proc(b: ^app.Buffer, i: int) -> string {
    return app.line_string(&b.lines[i], context.temp_allocator)
}

@(test)
test_buffer_newline :: proc(t: ^testing.T) {
    b := mkbuf("hello")
    defer app.buffer_destroy(&b)
    app.buffer_right(&b)
    app.buffer_right(&b) // column 2
    app.buffer_newline(&b)
    testing.expect_value(t, len(b.lines), 2)
    testing.expect_value(t, lstr(&b, 0), "he")
    testing.expect_value(t, lstr(&b, 1), "llo")
    testing.expect_value(t, b.cursors[0].head.line, 1)
    testing.expect_value(t, b.cursors[0].head.col, 0)
}

@(test)
test_buffer_join :: proc(t: ^testing.T) {
    b := mkbuf("ab\ncd")
    defer app.buffer_destroy(&b)
    app.buffer_down(&b) // line 1, column 0
    app.buffer_backspace(&b) // joins into the previous line
    testing.expect_value(t, len(b.lines), 1)
    testing.expect_value(t, lstr(&b, 0), "abcd")
    testing.expect_value(t, b.cursors[0].head.line, 0)
    testing.expect_value(t, b.cursors[0].head.col, 2)
}

@(test)
test_buffer_vertical_goal :: proc(t: ^testing.T) {
    b := mkbuf("hello\nhi\nworld")
    defer app.buffer_destroy(&b)
    app.buffer_end(&b) // column 5 on "hello"; goal = 5
    app.buffer_down(&b) // "hi" is short -> clamps to 2
    testing.expect_value(t, b.cursors[0].head.line, 1)
    testing.expect_value(t, b.cursors[0].head.col, 2)
    app.buffer_down(&b) // "world" -> goal 5 restored
    testing.expect_value(t, b.cursors[0].head.col, 5)
}

@(test)
test_ring_contains :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    b.path = strings.clone("/x/y.txt") // freed by editor_destroy

    testing.expect(t, !app.ring_contains(&a, "/x/y.txt")) // clean
    b.dirty = true
    testing.expect(t, app.ring_contains(&a, "/x/y.txt"))
    testing.expect(t, !app.ring_contains(&a, "/x/other.txt"))
}
