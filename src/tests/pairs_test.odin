package tests

import app ".."
import "core:testing"
import "../txt"

@(private = "file")
mkbuf :: proc(s: string) -> app.Buffer {
    b: app.Buffer
    app.buffer_set_text(&b, s)
    return b
}

@(private = "file")
bln :: proc(b: ^app.Buffer, i: int) -> string {
    return string(txt.doc_line(&b.doc, i, context.temp_allocator))
}

@(private = "file")
SPACES :: app.Indent {
    kind  = .Spaces,
    width = 4,
}

@(test)
test_pair_insert :: proc(t: ^testing.T) {
    b := mkbuf("")
    defer app.buffer_destroy(&b)
    testing.expect(t, app.buffer_autopair(&b, '('))
    testing.expect_value(t, bln(&b, 0), "()")
    testing.expect_value(t, b.cursors[0].head.col, 1) // caret parked inside
}

@(test)
test_pair_skip_closer :: proc(t: ^testing.T) {
    b := mkbuf("()")
    defer app.buffer_destroy(&b)
    b.cursors[0] = txt.Cursor{head = {0, 1}, anchor = {0, 1}} // between ( )
    app.buffer_autopair(&b, ')')
    testing.expect_value(t, bln(&b, 0), "()") // no new char
    testing.expect_value(t, b.cursors[0].head.col, 2) // stepped past )
}

// An opener right before a word stays literal (don't wrap the word, allow don't).
@(test)
test_pair_skip_before_word :: proc(t: ^testing.T) {
    b := mkbuf("foo")
    defer app.buffer_destroy(&b)
    app.buffer_autopair(&b, '(')
    testing.expect_value(t, bln(&b, 0), "(foo")
}

// A quote right after a word char stays literal (apostrophe), not a pair.
@(test)
test_quote_after_word_is_literal :: proc(t: ^testing.T) {
    b := mkbuf("don")
    defer app.buffer_destroy(&b)
    b.cursors[0] = txt.Cursor{head = {0, 3}, anchor = {0, 3}} // after "don"
    app.buffer_autopair(&b, '\'')
    testing.expect_value(t, bln(&b, 0), "don'") // single quote, no pair
    // A bracket after a word still pairs (function call), for contrast.
    app.buffer_autopair(&b, '(')
    testing.expect_value(t, bln(&b, 0), "don'()")
}

@(test)
test_pair_backspace_empty :: proc(t: ^testing.T) {
    b := mkbuf("()")
    defer app.buffer_destroy(&b)
    b.cursors[0] = txt.Cursor{head = {0, 1}, anchor = {0, 1}}
    app.buffer_backspace(&b) // inside an empty pair -> delete both
    testing.expect_value(t, bln(&b, 0), "")
}

@(test)
test_pair_surround_selection :: proc(t: ^testing.T) {
    b := mkbuf("foo")
    defer app.buffer_destroy(&b)
    b.cursors[0] = txt.Cursor{head = {0, 3}, anchor = {0, 0}} // select "foo"
    app.buffer_autopair(&b, '(')
    testing.expect_value(t, bln(&b, 0), "(foo)")
}

@(test)
test_tab_skips_out_of_pair :: proc(t: ^testing.T) {
    b := mkbuf("(stuff)")
    defer app.buffer_destroy(&b)
    b.cursors[0] = txt.Cursor{head = {0, 6}, anchor = {0, 6}} // just before )
    app.buffer_tab(&b, SPACES)
    testing.expect_value(t, bln(&b, 0), "(stuff)") // unchanged
    testing.expect_value(t, b.cursors[0].head.col, 7) // past )
}

@(test)
test_tab_indents_at_line_start :: proc(t: ^testing.T) {
    b := mkbuf("foo")
    defer app.buffer_destroy(&b)
    app.buffer_tab(&b, SPACES) // caret in leading whitespace -> indent
    testing.expect_value(t, bln(&b, 0), "    foo")
}

// The pair fans out to every cursor.
@(test)
test_pair_multicursor :: proc(t: ^testing.T) {
    b := mkbuf("x\nx")
    defer app.buffer_destroy(&b)
    clear(&b.cursors)
    append(&b.cursors, txt.Cursor{head = {0, 1}, anchor = {0, 1}}) // end of line 0
    append(&b.cursors, txt.Cursor{head = {1, 1}, anchor = {1, 1}}) // end of line 1
    app.buffer_autopair(&b, '(')
    testing.expect_value(t, bln(&b, 0), "x()")
    testing.expect_value(t, bln(&b, 1), "x()")
}
