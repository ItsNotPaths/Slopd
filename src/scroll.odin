package main

// The list panes' viewport policy — the flat-row twin of buffer_scroll_target
// (buffer.odin), so a list tracks its SELECTION the same way the editor tracks its
// caret and both answer to the one `scroll_mode` config. Lists have no folds, so this
// walks plain rows rather than visible ones; otherwise the two modes match the editor's
// exactly:
//   FOLLOW (default) — `top` holds still while `sel` is inside the viewport, then moves
//     the minimum: up to `sel` when it steps above, down to put it on the bottom row.
//     The top is kept within the list, so a shrinking list (a filter, a new directory)
//     never strands the view on blank rows.
//   MIDDLE — `sel` is pinned to the middle row, so Up/Down move the LIST under a
//     selection that never leaves the middle. Clamped at the first row (there is nothing
//     above row 0 to show); at the end it keeps centring and lets the view run past the
//     last row, exactly as the editor does.
// Pure and GL-free — the caller passes its own stored top and stores the result back.
list_scroll_target :: proc(top, sel, rows, total: int, center: bool) -> int {
    if rows <= 0 || total <= 0 {
        return 0
    }
    s := clamp(sel, 0, total - 1)
    if center {
        return max(0, s - rows / 2)
    }
    // Clamp the incoming top before comparing: the list may have shrunk since it was stored.
    t := clamp(top, 0, max(0, total - rows))
    if s < t {
        return s
    }
    if s >= t + rows {
        return s - rows + 1 // sel onto the bottom row
    }
    return t
}
