package main
import "../edit"

// The two fold verbs that need the document open in front of you: what Ctrl+Enter collapses,
// and the block a tree-sitter node covers. The geometry is the other half.

// Collapse the block beginning at the cursor's line, or expand it if already folded. The range
// comes from tree-sitter when a grammar is loaded, else from indentation.
buffer_fold_toggle :: proc(a: ^App, b: ^edit.Buffer) {
    edit.buffer_sync_folds(b) // an earlier same-frame edit may have invalidated the folds
    line := b.cursors[b.primary].head.line
    if i := edit.buffer_fold_index(b, line); i >= 0 {
        unordered_remove(&b.folds, i) // re-pressing the header expands it
        return
    }
    start, end, ok := fold_range(a, b, line)
    if !ok || end <= start {
        return
    }
    append(&b.folds, edit.Fold{line = start, end = end})
    edit.buffer_collapse_hidden_cursors(b)
}

// [start, end], end being the last line to hide. Tree-sitter first, falling back to an
// indentation scan when no grammar is loaded or no multi-line node opens on the line.
fold_range :: proc(a: ^App, b: ^edit.Buffer, line: int) -> (start, end: int, ok: bool) {
    if s, e, got := highlight_fold_range(a, b, line); got {
        return s, e, true
    }
    return edit.fold_range_indent(b, line)
}
