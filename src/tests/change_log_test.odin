package tests

import app ".."
import "core:os"
import "core:testing"

// The Doc change log, and the two readers that follow it (highlight.odin, fold.odin). A reader
// that keeps up must see EVERY change; one that falls behind must be told it lost them. The
// asymmetry matters because a buffer with no grammar installed — the default, since Slopd
// installs none — has a highlighter that never acks, so the log always runs to its cap.

// Folds acks every frame, so it can never fall behind, and the cap must not cost it a change.
@(test)
test_change_log_cap_keeps_the_reader_whole :: proc(t: ^testing.T) {
    d: app.Doc
    defer app.doc_destroy(&d)
    app.doc_set_text(&d, "x")
    app.doc_changes_ack(&d, .Folds) // the load is not a change to follow

    edits := app.DOC_CHANGE_MAX + 8 // past the cap, so the log is dropped mid-run
    seen := 0
    for _ in 0 ..< edits {
        app.doc_insert_rune(&d, 'a')
        changes, lost := app.doc_changes_since(&d, .Folds)
        testing.expect(t, !lost, "a reader that acks every edit must never lose the log")
        seen += len(changes)
        app.doc_changes_ack(&d, .Folds)
    }
    testing.expect_value(t, seen, edits)
}

// The other half of the same rule: the highlighter never acked, so it IS behind, and must be
// told rather than handed a partial list it would fold into a stale tree.
@(test)
test_change_log_cap_reports_loss_to_a_slow_reader :: proc(t: ^testing.T) {
    d: app.Doc
    defer app.doc_destroy(&d)
    app.doc_set_text(&d, "x")

    for _ in 0 ..< app.DOC_CHANGE_MAX + 8 {
        app.doc_insert_rune(&d, 'a')
        app.doc_changes_ack(&d, .Folds)
    }
    _, lost := app.doc_changes_since(&d, .Highlight)
    testing.expect(t, lost)
}
