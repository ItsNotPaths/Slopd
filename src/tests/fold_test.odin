package tests

import app ".."
import "core:testing"
import "../txt"

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
    testing.expect_value(t, txt.line_indent_cols(txt.doc_line(&b.doc, 0, context.temp_allocator)), 4) // four spaces
    testing.expect_value(t, txt.line_indent_cols(txt.doc_line(&b.doc, 1, context.temp_allocator)), 1) // one tab cell
    testing.expect_value(t, txt.line_indent_cols(txt.doc_line(&b.doc, 3, context.temp_allocator)), 0)
    testing.expect(t, !txt.line_is_blank(txt.doc_line(&b.doc, 0, context.temp_allocator)))
    testing.expect(t, txt.line_is_blank(txt.doc_line(&b.doc, 2, context.temp_allocator))) // whitespace-only
}

// A blank line borrows the deeper of its non-blank neighbours, so a guide runs unbroken.
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

// The run around the cursor at least as deep as its line, blank lines included, with the rail
// one level below the cursor depth.
@(test)
test_active_scope :: proc(t: ^testing.T) {
    b := mkbuf("def f():\n    a = 1\n\n    b = 2\nx = 3")
    defer app.buffer_destroy(&b)
    all := txt.doc_line_count(&b.doc) - 1
    s := app.buffer_active_scope(&b, 1, 4, 0, all)
    testing.expect(t, s.ok)
    testing.expect_value(t, s.lo, 1)
    testing.expect_value(t, s.hi, 3)
    testing.expect_value(t, s.level, 0)

    top := app.buffer_active_scope(&b, 4, 4, 0, all) // top level: no scope
    testing.expect(t, !top.ok)

    // The walk stops at the DRAWN lines, since the rail is only painted inside the viewport.
    // Inside the bound it is still exact: the run ending first still ends the walk.
    win := app.buffer_active_scope(&b, 1, 4, 1, 2)
    testing.expect_value(t, win.lo, 1)
    testing.expect_value(t, win.hi, 2) // clipped by the window
    exact := app.buffer_active_scope(&b, 1, 4, 0, 4)
    testing.expect_value(t, exact.hi, 3) // the run really does end here

    // A caret scrolled off the top still lights the part of its run that IS on screen.
    below := app.buffer_active_scope(&b, 1, 4, 2, 3)
    testing.expect(t, below.ok)
    testing.expect_value(t, below.lo, 1) // the cursor's own line, outside the window
    testing.expect_value(t, below.hi, 3)
}

// --- the indentation fold fallback ---

@(test)
test_fold_range_indent :: proc(t: ^testing.T) {
    b := mkbuf("def f():\n    a = 1\n    b = 2\nx = 3")
    defer app.buffer_destroy(&b)

    s, e, ok := app.fold_range_indent(&b, 0)
    testing.expect(t, ok)
    testing.expect_value(t, s, 0)
    testing.expect_value(t, e, 2) // both body lines, not "x = 3"

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
    testing.expect_value(t, e, 3) // a blank line inside the block stays inside
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

    // Its forward twin, which the drag autoscroll uses. The two ends are not symmetric: line 0
    // can never be hidden, but the LAST line can, so a walk that runs out of buffer inside a
    // collapsed block has to back out.
    testing.expect_value(t, app.buffer_fwd_visible(&b, 0, 1), 3)
    testing.expect_value(t, app.buffer_fwd_visible(&b, 0, 9), 3) // past the end clamps
    testing.expect_value(t, app.buffer_fwd_visible(&b, 3, 1), 3)

    tail := mkbuf("x = 0\ndef f():\n    a = 1\n    b = 2")
    defer app.buffer_destroy(&tail)
    append(&tail.folds, app.Fold{line = 1, end = 3})
    testing.expect_value(t, app.buffer_fwd_visible(&tail, 0, 5), 1) // the header, not line 3
}

// --- the Ctrl+Enter toggle + fold-aware motion + edit invalidation ---

@(test)
test_fold_toggle_motion_and_sync :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "def f():\n    a = 1\n    b = 2\nx = 3")

    // The block opening on line 0; no grammar loaded, so the indentation fallback.
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 1)
    testing.expect(t, app.buffer_line_hidden(b, 1))

    // Down steps over the whole fold to the next visible line.
    app.buffer_motion(b, .Down)
    testing.expect_value(t, b.cursors[0].head.line, 3)
    // Up steps back onto the header, not into the hidden body.
    app.buffer_motion(b, .Up)
    testing.expect_value(t, b.cursors[0].head.line, 0)

    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 0)

    // A line-count change below a fold leaves it alone; it used to drop every fold.
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 1)
    app.buffer_motion(b, .Down) // onto the first visible line past the fold
    app.buffer_newline(b)
    app.buffer_sync_folds(b)
    testing.expect_value(t, len(b.folds), 1)
    testing.expect_value(t, b.folds[0], app.Fold{line = 0, end = 2})
}

// A fold is a range of absolute line numbers, so an edit above it MOVES it, one below does not,
// and one reaching into it drops it. The shift comes through the fold reader's own change-log
// slot, so the highlighter having looked first does not matter.
@(test)
test_fold_survives_edits :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    //             0         1         2          3          4          5
    app.buffer_set_text(b, "import x\nimport y\ndef f():\n    a = 1\n    b = 2\nx = 3")

    fold_at :: proc(a: ^app.App, b: ^app.Buffer, line: int) {
        txt.doc_reset_cursor(&b.doc, txt.Pos{line, 0})
        app.buffer_fold_toggle(a, b)
    }

    fold_at(&a, b, 2)
    testing.expect_value(t, len(b.folds), 1)
    testing.expect_value(t, b.folds[0], app.Fold{line = 2, end = 4})

    // Above: two lines at the top slide the whole fold down by two.
    txt.doc_reset_cursor(&b.doc, txt.Pos{0, 0})
    txt.doc_insert_text(&b.doc, "// one\n// two\n")
    app.buffer_sync_folds(b)
    testing.expect_value(t, len(b.folds), 1)
    testing.expect_value(t, b.folds[0], app.Fold{line = 4, end = 6})

    // Above, the other way: deleting a line slides it back up.
    txt.doc_reset_cursor(&b.doc, txt.Pos{0, 0})
    txt.doc_move(&b.doc, .Down, true)
    txt.doc_delete(&b.doc)
    app.buffer_sync_folds(b)
    testing.expect_value(t, b.folds[0], app.Fold{line = 3, end = 5})

    // BELOW: nothing moves.
    last := txt.doc_line_count(&b.doc) - 1
    txt.doc_reset_cursor(&b.doc, txt.Pos{last, 0})
    txt.doc_insert_text(&b.doc, "y = 4\n")
    app.buffer_sync_folds(b)
    testing.expect_value(t, b.folds[0], app.Fold{line = 3, end = 5})

    // An edit WITHIN a line changes no line numbers, so the fold is untouched by it either.
    txt.doc_reset_cursor(&b.doc, txt.Pos{0, 0})
    txt.doc_insert_text(&b.doc, "zz")
    app.buffer_sync_folds(b)
    testing.expect_value(t, b.folds[0], app.Fold{line = 3, end = 5})

    // INTO it: splitting the header line changes the block's shape, and a range guessed from
    // here would hide the wrong lines. Let it go rather than keep a stale one.
    txt.doc_reset_cursor(&b.doc, txt.Pos{3, 0})
    txt.doc_insert_text(&b.doc, "\n")
    app.buffer_sync_folds(b)
    testing.expect_value(t, len(b.folds), 0)
}

// The backstop: a buffer edited with nothing painting it runs the log past its cap, and a fold
// set that cannot be shifted honestly is cleared rather than left pointing at the wrong lines.
@(test)
test_fold_dropped_when_log_lost :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "def f():\n    a = 1\n    b = 2\nx = 3")
    txt.doc_reset_cursor(&b.doc, txt.Pos{0, 0})
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 1)

    // Edits with no sync in between: the log fills and drops, and every reader is behind it.
    txt.doc_reset_cursor(&b.doc, txt.Pos{3, 0})
    for _ in 0 ..< txt.DOC_CHANGE_MAX + 10 {
        txt.doc_insert_text(&b.doc, "q\n")
    }
    app.buffer_sync_folds(b)
    testing.expect_value(t, len(b.folds), 0)
}

// One stalled reader must not cost a current one its state. A buffer whose language has no
// grammar installed has a highlighter that never acks, so the log fills and drops on its own —
// and the fold reader, which HAS kept up, has to come through that untouched.
@(test)
test_change_log_drop_spares_current_readers :: proc(t: ^testing.T) {
    a: app.App
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    b := app.editor_current(&a.editor)
    app.buffer_set_text(b, "def f():\n    a = 1\n    b = 2\nx = 3")
    txt.doc_reset_cursor(&b.doc, txt.Pos{0, 0})
    app.buffer_fold_toggle(&a, b)
    testing.expect_value(t, len(b.folds), 1)

    // Edit below the fold, syncing folds each time (as a frame does) while nothing ever reads
    // the log for the highlighter. Well past the cap, so it drops more than once.
    for i in 0 ..< txt.DOC_CHANGE_MAX * 3 {
        txt.doc_reset_cursor(&b.doc, txt.Pos{txt.doc_line_count(&b.doc) - 1, 0})
        txt.doc_insert_text(&b.doc, "q\n")
        app.buffer_sync_folds(b)
    }
    testing.expect_value(t, len(b.folds), 1)
    testing.expect_value(t, b.folds[0], app.Fold{line = 0, end = 2})

    // And the log stayed small: it trims to the slowest reader, and the stalled one is behind
    // the base rather than pinning the whole list in memory.
    testing.expect(t, len(b.doc.changes) <= txt.DOC_CHANGE_MAX, "the log outgrew its cap")
}
