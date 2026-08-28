package tests

import "core:os"
import "core:testing"
import "../txt"

// The Doc change log, and the two readers that follow it (highlight.odin, fold.odin). A reader
// that keeps up must see EVERY change; one that falls behind must be told it lost them. The
// asymmetry matters because a buffer with no grammar installed — the default, since Slopd
// installs none — has a highlighter that never acks, so the log always runs to its cap.

// Folds acks every frame, so it can never fall behind, and the cap must not cost it a change.
@(test)
test_change_log_cap_keeps_the_reader_whole :: proc(t: ^testing.T) {
    d: txt.Doc
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "x")
    txt.doc_changes_ack(&d, .Folds) // the load is not a change to follow

    edits := txt.DOC_CHANGE_MAX + 8 // past the cap, so the log is dropped mid-run
    seen := 0
    for _ in 0 ..< edits {
        txt.doc_insert_rune(&d, 'a')
        changes, lost := txt.doc_changes_since(&d, .Folds)
        testing.expect(t, !lost, "a reader that acks every edit must never lose the log")
        seen += len(changes)
        txt.doc_changes_ack(&d, .Folds)
    }
    testing.expect_value(t, seen, edits)
}

// The other half of the same rule: the highlighter never acked, so it IS behind, and must be
// told rather than handed a partial list it would fold into a stale tree.
@(test)
test_change_log_cap_reports_loss_to_a_slow_reader :: proc(t: ^testing.T) {
    d: txt.Doc
    defer txt.doc_destroy(&d)
    txt.doc_set_text(&d, "x")

    for _ in 0 ..< txt.DOC_CHANGE_MAX + 8 {
        txt.doc_insert_rune(&d, 'a')
        txt.doc_changes_ack(&d, .Folds)
    }
    _, lost := txt.doc_changes_since(&d, .Highlight)
    testing.expect(t, lost)
}
