package tests

import app "../slopd"
import "core:testing"
import "../txt"
import "../edit"

// Auto-indent + brace expansion on Enter (buffer_enter). No grammar is loaded for these
// buffers (path is ""), so the tree-sitter string/comment gate is inert and these exercise
// the pure bracket heuristic — exactly the no-grammar fallback path.

@(private = "file")
mkbuf :: proc(s: string) -> edit.Buffer {
    b: edit.Buffer
    edit.buffer_set_text(&b, s)
    return b
}

@(private = "file")
bln :: proc(b: ^edit.Buffer, i: int) -> string {
    return string(txt.doc_line(&b.doc, i, context.temp_allocator))
}

@(private = "file")
SP4 :: txt.Indent {
    kind  = .Spaces,
    width = 4,
}

@(private = "file")
put_caret :: proc(b: ^edit.Buffer, line, col: int) {
    b.cursors[0] = txt.Cursor{head = {line, col}, anchor = {line, col}}
}

// A plain line: the newline copies the existing leading indentation.
@(test)
test_enter_keeps_indent :: proc(t: ^testing.T) {
    a: app.App
    a.indent = SP4
    b := mkbuf("    foo")
    defer edit.buffer_destroy(&b)
    put_caret(&b, 0, 7) // end of "    foo"
    app.buffer_enter(&a, &b)
    testing.expect_value(t, bln(&b, 1), "    ")
    testing.expect_value(t, b.cursors[0].head.line, 1)
    testing.expect_value(t, b.cursors[0].head.col, 4)
}

// A trailing opener adds one indent level.
@(test)
test_enter_indents_after_opener :: proc(t: ^testing.T) {
    a: app.App
    a.indent = SP4
    b := mkbuf("if x {")
    defer edit.buffer_destroy(&b)
    put_caret(&b, 0, 6) // end, just after '{'
    app.buffer_enter(&a, &b)
    testing.expect_value(t, bln(&b, 1), "    ")
}

// Existing indent + opener stacks (4 -> 8).
@(test)
test_enter_indents_nested :: proc(t: ^testing.T) {
    a: app.App
    a.indent = SP4
    b := mkbuf("    if x {")
    defer edit.buffer_destroy(&b)
    put_caret(&b, 0, 10)
    app.buffer_enter(&a, &b)
    testing.expect_value(t, bln(&b, 1), "        ")
}

// Caret between an opener and its matching closer expands across three lines.
@(test)
test_enter_expands_braces :: proc(t: ^testing.T) {
    a: app.App
    a.indent = SP4
    b := mkbuf("f() {}")
    defer edit.buffer_destroy(&b)
    put_caret(&b, 0, 5) // between '{' and '}'
    app.buffer_enter(&a, &b)
    testing.expect_value(t, bln(&b, 0), "f() {")
    testing.expect_value(t, bln(&b, 1), "    ")
    testing.expect_value(t, bln(&b, 2), "}")
    testing.expect_value(t, b.cursors[0].head.line, 1) // caret on the middle line
    testing.expect_value(t, b.cursors[0].head.col, 4)
}

// No three-line expansion when the next char isn't the matching closer — the opener still
// bumps the indent (the general path), but the close doesn't drop to its own line.
@(test)
test_enter_no_expand_unmatched :: proc(t: ^testing.T) {
    a: app.App
    a.indent = SP4
    b := mkbuf("{x")
    defer edit.buffer_destroy(&b)
    put_caret(&b, 0, 1) // between '{' and 'x'
    app.buffer_enter(&a, &b)
    testing.expect_value(t, bln(&b, 0), "{")
    testing.expect_value(t, bln(&b, 1), "    x")
}

// Tab indentation: the unit is a single tab, not spaces.
@(test)
test_enter_tab_indent :: proc(t: ^testing.T) {
    a: app.App
    a.indent = txt.Indent{kind = .Tab, width = 4}
    b := mkbuf("x {")
    defer edit.buffer_destroy(&b)
    put_caret(&b, 0, 3)
    app.buffer_enter(&a, &b)
    testing.expect_value(t, bln(&b, 1), "\t")
}
