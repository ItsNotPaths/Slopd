package tests

import app ".."
import "core:testing"

@(private = "file")
mkdoc :: proc(s: string) -> app.Doc {
    d: app.Doc
    app.doc_set_text(&d, s)
    return d
}

@(private = "file")
ln :: proc(d: ^app.Doc, i: int) -> string {
    return app.line_string(&d.lines[i], context.temp_allocator)
}

@(private = "file")
typ :: proc(d: ^app.Doc, s: string) {
    for r in s {
        app.doc_insert_rune(d, r)
    }
}

// Coalesced typing undoes/redoes as one step.
@(test)
test_undo_coalesce :: proc(t: ^testing.T) {
    d := mkdoc("")
    defer app.doc_destroy(&d)
    typ(&d, "abc")
    testing.expect_value(t, ln(&d, 0), "abc")

    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "") // whole run reverted at once
    testing.expect(t, !app.doc_undo(&d)) // nothing left

    testing.expect(t, app.doc_redo(&d))
    testing.expect_value(t, ln(&d, 0), "abc")
    // caret restored to the post-edit position
    c := d.cursors[0].head;testing.expect_value(t, c.col, 3)
}

// A whitespace key seals the group: "ab cd" -> two undo steps.
@(test)
test_undo_break_on_space :: proc(t: ^testing.T) {
    d := mkdoc("")
    defer app.doc_destroy(&d)
    typ(&d, "ab cd")
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "ab ") // "cd" removed
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "") // "ab " removed
}

// Bracket/quote characters are break chars too: "a(b" -> two steps.
@(test)
test_undo_break_on_bracket :: proc(t: ^testing.T) {
    d := mkdoc("")
    defer app.doc_destroy(&d)
    typ(&d, "a(b")
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "a(") // "b" removed (run reopened after the bracket)
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "")
}

// Moving the caret between runs breaks coalescing.
@(test)
test_undo_break_on_move :: proc(t: ^testing.T) {
    d := mkdoc("")
    defer app.doc_destroy(&d)
    typ(&d, "ab")
    app.doc_move(&d, .Left) // caret no longer where typing left off
    typ(&d, "c") // -> "acb"
    testing.expect_value(t, ln(&d, 0), "acb")
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "ab") // only "c" reverted
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "")
}

// Deletion is reversible (the removed text is restored).
@(test)
test_undo_delete :: proc(t: ^testing.T) {
    d := mkdoc("abc")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .End) // {0,3}
    app.doc_backspace(&d) // "ab"
    testing.expect_value(t, ln(&d, 0), "ab")
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, ln(&d, 0), "abc")
}

// A line split (newline) round-trips through undo/redo.
@(test)
test_undo_newline :: proc(t: ^testing.T) {
    d := mkdoc("ab")
    defer app.doc_destroy(&d)
    app.doc_move(&d, .Right) // {0,1}
    app.doc_newline(&d)
    testing.expect_value(t, len(d.lines), 2)
    testing.expect(t, app.doc_undo(&d))
    testing.expect_value(t, len(d.lines), 1)
    testing.expect_value(t, ln(&d, 0), "ab")
    testing.expect(t, app.doc_redo(&d))
    testing.expect_value(t, len(d.lines), 2)
    testing.expect_value(t, ln(&d, 1), "b")
}

// Typing with multiple cursors coalesces into one step (per-cursor streams in
// lockstep), so a single undo reverts the whole multi-cursor run.
@(test)
test_undo_multicursor_coalesce :: proc(t: ^testing.T) {
    d := mkdoc("foo\nbar")
    defer app.doc_destroy(&d)
    clear(&d.cursors)
    append(&d.cursors, app.Cursor{head = {0, 0}, anchor = {0, 0}})
    append(&d.cursors, app.Cursor{head = {1, 0}, anchor = {1, 0}})
    typ(&d, "ab") // both lines get "ab"
    testing.expect_value(t, ln(&d, 0), "abfoo")
    testing.expect_value(t, ln(&d, 1), "abbar")

    testing.expect(t, app.doc_undo(&d)) // one step reverts both runs
    testing.expect_value(t, ln(&d, 0), "foo")
    testing.expect_value(t, ln(&d, 1), "bar")
    testing.expect(t, !app.doc_undo(&d))
}

// Undo history survives a cursor drop: the single-cursor run and the later
// multi-cursor run are distinct steps, each undoable in turn.
@(test)
test_undo_across_multicursor :: proc(t: ^testing.T) {
    d := mkdoc("ab\ncd")
    defer app.doc_destroy(&d)
    typ(&d, "X") // "Xab" / "cd"  (single-cursor step)
    app.doc_drop_anchor(&d) // anchor at the caret {0,1}
    app.doc_move(&d, .Down) // free caret -> {1,1}, anchor stays {0,1}
    typ(&d, "Y") // "XYab" / "cYd"  (multi-cursor step)
    testing.expect_value(t, ln(&d, 0), "XYab")
    testing.expect_value(t, ln(&d, 1), "cYd")

    testing.expect(t, app.doc_undo(&d)) // revert the multi-cursor Y
    testing.expect_value(t, ln(&d, 0), "Xab")
    testing.expect_value(t, ln(&d, 1), "cd")
    testing.expect(t, app.doc_undo(&d)) // revert the single-cursor X
    testing.expect_value(t, ln(&d, 0), "ab")
    testing.expect_value(t, ln(&d, 1), "cd")
}

// A fresh edit clears the redo stack.
@(test)
test_undo_redo_cleared_on_edit :: proc(t: ^testing.T) {
    d := mkdoc("")
    defer app.doc_destroy(&d)
    typ(&d, "ab")
    app.doc_undo(&d) // ""  (redo now holds "ab")
    typ(&d, "x") // new edit -> redo discarded
    testing.expect(t, !app.doc_redo(&d))
    testing.expect_value(t, ln(&d, 0), "x")
}
