package tests

import app ".."
import "core:testing"
import "../txt"

// Line-wise editing: which lines a selection reaches (doc_cursor_lines), block indent and its
// undo (buffer_indent_block), and the one thing both rest on — the selection SURVIVING the edit,
// since Tab is pressed twice to indent twice.

@(private = "file")
SRC :: "one\n  two\n    three\nfour"

@(private = "file")
mk :: proc(src := SRC) -> app.Buffer {
    b: app.Buffer
    txt.doc_init(&b.doc)
    app.buffer_set_text(&b, src)
    return b
}

@(private = "file")
sel :: proc(b: ^app.Buffer, anchor, head: txt.Pos) {
    txt.doc_reset_cursor(&b.doc, anchor)
    txt.doc_set_head(&b.doc, head, true)
}

@(private = "file")
text :: proc(b: ^app.Buffer) -> string {
    return txt.doc_string(&b.doc, context.temp_allocator)
}

// A caret reaches its own line; a selection reaches every line it crosses. The exception is the
// one that makes a full-line sweep behave: ending at column 0 is standing on a line, not
// covering it.
@(test)
test_cursor_lines_of_a_selection :: proc(t: ^testing.T) {
    b := mk()
    defer app.buffer_destroy(&b)

    txt.doc_reset_cursor(&b.doc, txt.Pos{2, 1})
    testing.expect_value(t, len(txt.doc_cursor_lines(&b.doc)), 1)
    testing.expect_value(t, txt.doc_cursor_lines(&b.doc)[0], 2)

    sel(&b, txt.Pos{0, 1}, txt.Pos{2, 2})
    testing.expect_value(t, len(txt.doc_cursor_lines(&b.doc)), 3)

    // Line 2 is where the caret stands, not text it covers.
    sel(&b, txt.Pos{0, 0}, txt.Pos{2, 0})
    lines := txt.doc_cursor_lines(&b.doc)
    testing.expect_value(t, len(lines), 2)
    testing.expect_value(t, lines[1], 1)

    // Two carets on one line name it once.
    txt.doc_reset_cursor(&b.doc, txt.Pos{1, 0})
    txt.doc_add_cursor(&b.doc, txt.Pos{1, 3})
    testing.expect_value(t, len(txt.doc_cursor_lines(&b.doc)), 1)
}

// Tab over a selection crossing lines indents the block and KEEPS the selection, so a second
// press is a second level. A blank line is left alone rather than given trailing whitespace.
@(test)
test_block_indent_keeps_the_selection :: proc(t: ^testing.T) {
    b := mk("a\n\nb")
    defer app.buffer_destroy(&b)
    ind := app.Indent{.Spaces, 2}

    sel(&b, txt.Pos{0, 0}, txt.Pos{2, 1})
    app.buffer_tab(&b, ind)
    testing.expect_value(t, text(&b), "  a\n\n  b")
    testing.expect(t, b.dirty)

    app.buffer_tab(&b, ind) // the selection survived, so this indents again
    testing.expect_value(t, text(&b), "    a\n\n    b")

    // And it is still a selection over the same lines, its columns carried along.
    c := b.doc.cursors[b.doc.primary]
    testing.expect_value(t, c.anchor, txt.Pos{0, 4})
    testing.expect_value(t, c.head, txt.Pos{2, 5})
}

// Shift+Tab takes one level off, by the indent in force: a tab, or up to that many spaces. A line
// with nothing to give up is left alone, and the ones beside it still move.
@(test)
test_block_dedent :: proc(t: ^testing.T) {
    b := mk()
    defer app.buffer_destroy(&b)

    sel(&b, txt.Pos{0, 0}, txt.Pos{2, 5})
    app.buffer_indent_block(&b, app.Indent{.Spaces, 2}, true)
    testing.expect_value(t, text(&b), "one\ntwo\n  three\nfour")

    // Fewer spaces than a level is all of them, never a wrap onto the line above.
    b2 := mk(" x")
    defer app.buffer_destroy(&b2)
    txt.doc_reset_cursor(&b2.doc, txt.Pos{0, 0})
    app.buffer_indent_block(&b2, app.Indent{.Spaces, 4}, true)
    testing.expect_value(t, text(&b2), "x")

    b3 := mk("\t\tx")
    defer app.buffer_destroy(&b3)
    txt.doc_reset_cursor(&b3.doc, txt.Pos{0, 3})
    app.buffer_indent_block(&b3, app.Indent{.Tab, 4}, true)
    testing.expect_value(t, text(&b3), "\tx")
    testing.expect_value(t, b3.doc.cursors[0].head, txt.Pos{0, 2}) // carried with the line
}

// With no selection Shift+Tab is the caret's own line, which is how a single line is pulled back.
// A caret sitting INSIDE the whitespace it removes lands at the line start rather than before it.
@(test)
test_dedent_without_a_selection :: proc(t: ^testing.T) {
    b := mk()
    defer app.buffer_destroy(&b)

    txt.doc_reset_cursor(&b.doc, txt.Pos{1, 1})
    app.buffer_indent_block(&b, app.Indent{.Spaces, 2}, true)
    testing.expect_value(t, text(&b), "one\ntwo\n    three\nfour")
    testing.expect_value(t, b.doc.cursors[0].head, txt.Pos{1, 0})

    // Nothing to take off is not an edit at all.
    b.dirty = false
    app.buffer_indent_block(&b, app.Indent{.Spaces, 2}, true)
    testing.expect(t, !b.dirty)
}

// One undo takes the whole block back, because the batch is one commit — and it restores the
// selection that made it, not the cursors doc_apply left behind.
@(test)
test_block_indent_undoes_as_one :: proc(t: ^testing.T) {
    b := mk()
    defer app.buffer_destroy(&b)

    sel(&b, txt.Pos{0, 0}, txt.Pos{3, 4})
    app.buffer_tab(&b, app.Indent{.Spaces, 2})
    testing.expect_value(t, text(&b), "  one\n    two\n      three\n  four")

    testing.expect(t, txt.doc_undo(&b.doc))
    testing.expect_value(t, text(&b), SRC)
    testing.expect_value(t, len(b.doc.cursors), 1)
    testing.expect_value(t, b.doc.cursors[0].head, txt.Pos{3, 4})

    testing.expect(t, txt.doc_redo(&b.doc))
    testing.expect_value(t, text(&b), "  one\n    two\n      three\n  four")
    testing.expect_value(t, b.doc.cursors[0].head, txt.Pos{3, 6})
}

// A selection inside ONE line is not the block gesture: Tab stays the caret's own insert.
@(test)
test_tab_within_one_line_is_not_a_block :: proc(t: ^testing.T) {
    b := mk("hello")
    defer app.buffer_destroy(&b)

    sel(&b, txt.Pos{0, 1}, txt.Pos{0, 3})
    app.buffer_tab(&b, app.Indent{.Spaces, 2})
    testing.expect_value(t, text(&b), "hel  lo")
}
