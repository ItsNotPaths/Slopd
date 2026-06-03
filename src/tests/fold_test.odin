package tests

import app ".."
import "core:testing"

@(private = "file")
mkbuf :: proc(text: string) -> app.Buffer {
    b: app.Buffer
    app.buffer_set_text(&b, text)
    return b
}

// --- indentation geometry ---

@(test)
test_indent_cols_and_blank :: proc(t: ^testing.T) {
    b := mkbuf("    x\n\thi\n   \nfoo")
    defer app.buffer_destroy(&b)
    testing.expect_value(t, app.line_indent_cols(&b.lines[0]), 4) // four spaces
    testing.expect_value(t, app.line_indent_cols(&b.lines[1]), 1) // one tab cell
    testing.expect_value(t, app.line_indent_cols(&b.lines[3]), 0)
    testing.expect(t, !app.line_is_blank(&b.lines[0]))
    testing.expect(t, app.line_is_blank(&b.lines[2])) // whitespace-only
}

// A blank line borrows the deeper of its non-blank neighbours so a guide runs
// unbroken through it.
@(test)
test_indent_levels_through_blank :: proc(t: ^testing.T) {
    b := mkbuf("def f():\n    a = 1\n\n    b = 2\nx = 3")
    defer app.buffer_destroy(&b)
    testing.expect_value(t, app.buffer_indent_levels(&b, 0, 4), 0)
    testing.expect_value(t, app.buffer_indent_levels(&b, 1, 4), 1)
    testing.expect_value(t, app.buffer_indent_levels(&b, 2, 4), 1) // blank, borrowed
    testing.expect_value(t, app.buffer_indent_levels(&b, 3, 4), 1)
    testing.expect_value(t, app.buffer_indent_levels(&b, 4, 4), 0)
}

// The active scope spans the run around the cursor at least as deep as its line,
// blank lines included, with the rail level one below the cursor depth.
@(test)
test_active_scope :: proc(t: ^testing.T) {
    b := mkbuf("def f():\n    a = 1\n\n    b = 2\nx = 3")
    defer app.buffer_destroy(&b)
    s := app.buffer_active_scope(&b, 1, 4)
    testing.expect(t, s.ok)
    testing.expect_value(t, s.lo, 1)
    testing.expect_value(t, s.hi, 3)
    testing.expect_value(t, s.level, 0)

    top := app.buffer_active_scope(&b, 4, 4) // top level -> no scope
    testing.expect(t, !top.ok)
}

// --- the indentation fold fallback ---

@(test)
test_fold_range_indent :: proc(t: ^testing.T) {
    b := mkbuf("def f():\n    a = 1\n    b = 2\nx = 3")
    defer app.buffer_destroy(&b)

    s, e, ok := app.fold_range_indent(&b, 0)
    testing.expect(t, ok)
    testing.expect_value(t, s, 0)
    testing.expect_value(t, e, 2) // hides both body lines, not "x = 3"

    _, _, ok2 := app.fold_range_indent(&b, 1) // a body line opens no block
    testing.expect(t, !ok2)
}

@(test)
test_fold_range_indent_keeps_blank :: proc(t: ^testing.T) {
    b := mkbuf("def f():\n    a = 1\n\n    b = 2\nx = 3")
    defer app.buffer_destroy(&b)
    s, e, ok := app.fold_range_indent(&b, 0)
    testing.expect(t, ok)
    testing.expect_value(t, s, 0)
    testing.expect_value(t, e, 3) // blank line inside the block stays inside it
}

// --- visibility helpers over a folded buffer ---

@(test)
test_fold_visibility_helpers :: proc(t: ^testing.T) {
    b := mkbuf("def f():\n    a = 1\n    b = 2\nx = 3")
    defer app.buffer_destroy(&b)
    append(&b.folds, app.Fold{line = 0, end = 2})

    testing.expect(t, !app.buffer_line_hidden(&b, 0))
    testing.expect(t, app.buffer_line_hidden(&b, 1))
    testing.expect(t, app.buffer_line_hidden(&b, 2))
    testing.expect(t, !app.buffer_line_hidden(&b, 3))

    testing.expect_value(t, app.buffer_next_visible(&b, 1), 3)
    testing.expect_value(t, app.buffer_prev_visible(&b, 2), 0)
    testing.expect_value(t, app.buffer_visible_count(&b, 0, 3), 2)
    testing.expect_value(t, app.buffer_back_visible(&b, 3, 1), 0)
}

// --- the Ctrl+Enter toggle + fold-aware motion + edit invalidation ---

@(test)
test_fold_toggle_motion_and_sync :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "def f():\n    a = 1\n    b = 2\nx = 3")

    // Fold the block opening on line 0 (no grammar loaded -> indentation fallback).
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 1)
    testing.expect(t, app.buffer_line_hidden(b, 1))

    // Down steps over the whole fold to the next visible line.
    app.buffer_motion(b, .Down)
    testing.expect_value(t, b.cursors[0].head.line, 3)
    // Up steps back onto the header (visible), not into the hidden body.
    app.buffer_motion(b, .Up)
    testing.expect_value(t, b.cursors[0].head.line, 0)

    // Re-pressing on the header expands it.
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 0)

    // A line-count change invalidates folds.
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 1)
    app.buffer_motion(b, .Down) // to a visible line first
    app.buffer_newline(b) // line count changes
    app.buffer_sync_folds(b)
    testing.expect_value(t, len(b.folds), 0)
}
