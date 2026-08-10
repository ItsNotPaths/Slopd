package tests

import app ".."
import "core:testing"

// list_scroll_target is the flat-row twin of buffer_scroll_target: same two modes, same
// edge behaviour, no folds. These mirror test_scroll_follow / test_scroll_middle so the
// two policies stay in step — a list should frame its selection exactly as the editor
// frames its caret.

ROWS :: 10
TOTAL :: 100

// FOLLOW (the default): the view holds still while the selection is inside it, then moves
// the minimum — up to the selection when it steps above, down to put it on the bottom row.
@(test)
test_list_follow :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(0, 0, ROWS, TOTAL, false), 0) // sel on row 0
    testing.expect_value(t, app.list_scroll_target(0, 5, ROWS, TOTAL, false), 0) // on screen: no move
    testing.expect_value(t, app.list_scroll_target(0, 12, ROWS, TOTAL, false), 3) // onto the bottom row
    testing.expect_value(t, app.list_scroll_target(3, 1, ROWS, TOTAL, false), 1) // stepped above: top = sel
    testing.expect_value(t, app.list_scroll_target(3, 12, ROWS, TOTAL, false), 3) // last row: still inside
}

// MIDDLE: the selection is pinned to the middle row, so every move scrolls the list.
// Clamped at the top (nothing above row 0); at the end it keeps centring and lets the view
// run past the last row — matching the editor rather than the old clamp-at-both-ends.
@(test)
test_list_middle :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(0, 0, ROWS, TOTAL, true), 0) // clamped at the top
    testing.expect_value(t, app.list_scroll_target(0, 3, ROWS, TOTAL, true), 0) // still clamped
    testing.expect_value(t, app.list_scroll_target(0, 40, ROWS, TOTAL, true), 35)
    testing.expect_value(t, app.list_scroll_target(35, 41, ROWS, TOTAL, true), 36) // one row = one row
    testing.expect_value(t, app.list_scroll_target(0, 99, ROWS, TOTAL, true), 94) // past the end, centred
}

// A stored top that the list has since outgrown (a filter narrowed it, a new directory
// loaded) must not strand the view on blank rows: Follow re-clamps the incoming top into
// the list before deciding.
@(test)
test_list_follow_reclamps_stale_top :: proc(t: ^testing.T) {
    // Top 90 from a 100-row list, now only 20 rows: the last full page is 10..19.
    testing.expect_value(t, app.list_scroll_target(90, 15, ROWS, 20, false), 10)
    // Selection above the re-clamped top pulls it up to the selection.
    testing.expect_value(t, app.list_scroll_target(90, 2, ROWS, 20, false), 2)
}

// Degenerate viewports and empty lists pin to row 0 rather than producing a negative or
// out-of-range top — the panes call this every frame, including before their first load.
@(test)
test_list_empty_and_zero_rows :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(5, 3, ROWS, 0, false), 0) // empty list
    testing.expect_value(t, app.list_scroll_target(5, 3, ROWS, 0, true), 0)
    testing.expect_value(t, app.list_scroll_target(5, 3, 0, TOTAL, false), 0) // zero-height pane
    testing.expect_value(t, app.list_scroll_target(5, 3, 0, TOTAL, true), 0)
}

// A list shorter than the viewport never scrolls in Follow (everything already fits), and
// an out-of-range selection is clamped rather than read past the end.
@(test)
test_list_shorter_than_viewport :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(0, 2, ROWS, 4, false), 0)
    testing.expect_value(t, app.list_scroll_target(3, 2, ROWS, 4, false), 0) // stale top re-clamped to 0
    testing.expect_value(t, app.list_scroll_target(0, 99, ROWS, 4, false), 0) // sel clamped to row 3
}

// The detach a wheel gesture leaves behind — the list twin of the editor's, and the reason
// a notch can mean "move the view" at all. The three states, in order.
@(test)
test_list_scroll_detach :: proc(t: ^testing.T) {
    scroll := 0
    detached := f64(0)

    // Attached, the policy runs: the selection at row 40 in MIDDLE centres the view.
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, true, 0)
    testing.expect_value(t, scroll, 35)

    // A notch detaches and moves the view. NEITHER policy runs after that — this is the
    // assertion that matters, because MIDDLE re-derives the top from the selection every
    // frame and would otherwise overwrite the gesture before it was ever seen.
    app.list_scroll_by(&scroll, &detached, 9, 100)
    testing.expect_value(t, scroll, 44)
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, true, 0)
    testing.expect_value(t, scroll, 44)
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, false, 0)
    testing.expect_value(t, scroll, 44)

    // Only INPUT AFTER the gesture re-attaches. An older timestamp is a keystroke that
    // happened before the scroll, which cannot have been a reaction to it.
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, false, 99)
    testing.expect_value(t, scroll, 44)
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, false, 101)
    testing.expect_value(t, scroll, 40) // row 40 is now ABOVE the view, so the top goes to it
    testing.expect_value(t, detached, f64(0))
}

// The wheel callback cannot clamp — it has no font, no pane rect and no flattened row list —
// so the frame does it, and the overshoot is bounded by one notch either way.
@(test)
test_list_scroll_detached_is_bounded :: proc(t: ^testing.T) {
    scroll := 0
    detached := f64(0)

    app.list_scroll_by(&scroll, &detached, -50, 100)
    app.list_scroll_apply(&scroll, &detached, 0, ROWS, TOTAL, false, 0)
    testing.expect_value(t, scroll, 0)

    // Past the end, any row may be the top — first to last, exactly as the detached editor
    // lets any line be the top. A list shorter than its viewport pins at zero.
    app.list_scroll_by(&scroll, &detached, 500, 100)
    app.list_scroll_apply(&scroll, &detached, 0, ROWS, TOTAL, false, 0)
    testing.expect_value(t, scroll, TOTAL - 1)

    app.list_scroll_by(&scroll, &detached, 500, 100)
    app.list_scroll_apply(&scroll, &detached, 0, ROWS, 0, false, 0)
    testing.expect_value(t, scroll, 0)
}
