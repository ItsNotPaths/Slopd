package tests

import app ".."
import "core:testing"
import "../txt"

// The in-buffer literal search behind `:f` and its live preview (find.odin). All of it is pure
// — a Buffer in, a match list out — so none of this needs a window.

@(private = "file")
mkbuf :: proc(text: string) -> app.Buffer {
    b: app.Buffer
    app.buffer_set_text(&b, text)
    return b
}

@(private = "file")
scan :: proc(f: ^app.Find, b: ^app.Buffer, query: string) {
    app.find_set(f, b, query, txt.Pos{})
}

@(test)
test_find_scans_in_line_order :: proc(t: ^testing.T) {
    b := mkbuf("one two\nthree\ntwo two")
    defer app.buffer_destroy(&b)
    f: app.Find
    defer app.find_destroy(&f)

    scan(&f, &b, "two")
    testing.expect_value(t, len(f.matches), 3)
    testing.expect_value(t, f.matches[0], app.Find_Match{line = 0, col = 4, n = 3})
    testing.expect_value(t, f.matches[1], app.Find_Match{line = 2, col = 0, n = 3})
    testing.expect_value(t, f.matches[2], app.Find_Match{line = 2, col = 4, n = 3})
}

// Hits do not overlap: the scan resumes past the one it took, so `aa` in `aaa` is one match.
@(test)
test_find_hits_do_not_overlap :: proc(t: ^testing.T) {
    b := mkbuf("aaa")
    defer app.buffer_destroy(&b)
    f: app.Find
    defer app.find_destroy(&f)

    scan(&f, &b, "aa")
    testing.expect_value(t, len(f.matches), 1)
    testing.expect_value(t, f.matches[0].col, 0)
}

// Smart case: an all-lowercase query matches either case, a capital in it matches exactly.
@(test)
test_find_smart_case :: proc(t: ^testing.T) {
    b := mkbuf("Buffer buffer BUFFER")
    defer app.buffer_destroy(&b)
    f: app.Find
    defer app.find_destroy(&f)

    scan(&f, &b, "buffer")
    testing.expect_value(t, len(f.matches), 3)

    scan(&f, &b, "Buffer")
    testing.expect_value(t, len(f.matches), 1)
    testing.expect_value(t, f.matches[0].col, 0)
}

@(test)
test_find_empty_query_clears :: proc(t: ^testing.T) {
    b := mkbuf("aaa")
    defer app.buffer_destroy(&b)
    f: app.Find
    defer app.find_destroy(&f)

    scan(&f, &b, "a")
    testing.expect_value(t, len(f.matches), 3)
    scan(&f, &b, "")
    testing.expect_value(t, len(f.matches), 0)
}

// The landing is the first hit at or after the anchor, wrapping to the first when every hit
// is behind it. The anchor is a parameter so the preview can re-scan on every keystroke
// without the caret walking down the file as the query grows.
@(test)
test_find_lands_at_or_after_anchor :: proc(t: ^testing.T) {
    b := mkbuf("x\nx\nx")
    defer app.buffer_destroy(&b)
    f: app.Find
    defer app.find_destroy(&f)

    app.find_set(&f, &b, "x", txt.Pos{line = 1, col = 0})
    testing.expect_value(t, f.cur, 1)

    app.find_set(&f, &b, "x", txt.Pos{line = 9, col = 0}) // past every hit: wraps to the first
    testing.expect_value(t, f.cur, 0)
}

@(test)
test_find_step_wraps_both_ways :: proc(t: ^testing.T) {
    b := mkbuf("x\nx\nx")
    defer app.buffer_destroy(&b)
    f: app.Find
    defer app.find_destroy(&f)

    scan(&f, &b, "x")
    app.find_step(&f, -1) // back off the first: round to the last
    testing.expect_value(t, f.cur, 2)
    app.find_step(&f, 1) // and forward off the last: round to the first
    testing.expect_value(t, f.cur, 0)

    scan(&f, &b, "zz") // nothing found: stepping is a no-op, not an index off the end
    app.find_step(&f, 1)
    testing.expect_value(t, f.cur, 0)
}

// The paint's row lookup: the first match ON a line, or one past the end when the line and
// everything after it is clear.
@(test)
test_find_first_on_line :: proc(t: ^testing.T) {
    ms := []app.Find_Match {
        {line = 1, col = 0, n = 1},
        {line = 3, col = 2, n = 1},
        {line = 3, col = 9, n = 1},
    }
    testing.expect_value(t, app.find_first_on_line(ms, 0), 0) // before the first: its index
    testing.expect_value(t, app.find_first_on_line(ms, 1), 0)
    testing.expect_value(t, app.find_first_on_line(ms, 2), 1) // a clear line: the next line's
    testing.expect_value(t, app.find_first_on_line(ms, 3), 1) // the FIRST of the two on line 3
    testing.expect_value(t, app.find_first_on_line(ms, 4), 3) // past every match
    testing.expect_value(t, app.find_first_on_line(nil, 0), 0)
}

// `:f` submitted: the caret lands on a match and the marks come DOWN — Enter is an answer,
// and what it leaves behind is a caret on the word, not a lit-up page.
@(test)
test_cl_find_lands_and_clears_marks :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    defer app.find_destroy(&a.find)

    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "one\ntwo\nthree")
    a.find.show = true

    app.cl_find(&a, "three")
    testing.expect_value(t, b.cursors[0].head, txt.Pos{line = 2, col = 0})
    testing.expect(t, !a.find.show)
}
