package tests

import app ".."
import "core:testing"

// The flat-row twin of buffer_scroll_target: same two modes, same edge behaviour, no folds.
// These mirror test_scroll_follow / test_scroll_middle so the two policies stay in step.

ROWS :: 10
TOTAL :: 100

// Follow: the view holds still while the selection is inside it, then moves the minimum.
@(test)
test_list_follow :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(0, 0, ROWS, TOTAL, false), 0) // sel on row 0
    testing.expect_value(t, app.list_scroll_target(0, 5, ROWS, TOTAL, false), 0) // no move
    testing.expect_value(t, app.list_scroll_target(0, 12, ROWS, TOTAL, false), 3) // onto the bottom row
    testing.expect_value(t, app.list_scroll_target(3, 1, ROWS, TOTAL, false), 1) // above: top = sel
    testing.expect_value(t, app.list_scroll_target(3, 12, ROWS, TOTAL, false), 3) // last row: still inside
}

// Middle: the selection is pinned to the middle row, so every move scrolls the list. Clamped at
// the top; at the end it keeps centring and lets the view run past the last row.
@(test)
test_list_middle :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(0, 0, ROWS, TOTAL, true), 0) // clamped at the top
    testing.expect_value(t, app.list_scroll_target(0, 3, ROWS, TOTAL, true), 0) // still clamped
    testing.expect_value(t, app.list_scroll_target(0, 40, ROWS, TOTAL, true), 35)
    testing.expect_value(t, app.list_scroll_target(35, 41, ROWS, TOTAL, true), 36) // one row = one row
    testing.expect_value(t, app.list_scroll_target(0, 99, ROWS, TOTAL, true), 94) // past the end, centred
}

// A stored top the list has since outgrown must not strand the view on blank rows: Follow
// re-clamps the incoming top before deciding.
@(test)
test_list_follow_reclamps_stale_top :: proc(t: ^testing.T) {
    // Top 90 from a 100-row list, now 20 rows: the last full page is 10..19.
    testing.expect_value(t, app.list_scroll_target(90, 15, ROWS, 20, false), 10)
    // A selection above the re-clamped top pulls it up.
    testing.expect_value(t, app.list_scroll_target(90, 2, ROWS, 20, false), 2)
}

// Pinned to row 0 rather than a negative or out-of-range top: the panes call this every frame,
// including before their first load.
@(test)
test_list_empty_and_zero_rows :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(5, 3, ROWS, 0, false), 0) // empty list
    testing.expect_value(t, app.list_scroll_target(5, 3, ROWS, 0, true), 0)
    testing.expect_value(t, app.list_scroll_target(5, 3, 0, TOTAL, false), 0) // zero-height pane
    testing.expect_value(t, app.list_scroll_target(5, 3, 0, TOTAL, true), 0)
}

// Shorter than the viewport never scrolls in Follow, and an out-of-range selection is clamped.
@(test)
test_list_shorter_than_viewport :: proc(t: ^testing.T) {
    testing.expect_value(t, app.list_scroll_target(0, 2, ROWS, 4, false), 0)
    testing.expect_value(t, app.list_scroll_target(3, 2, ROWS, 4, false), 0) // stale top re-clamped
    testing.expect_value(t, app.list_scroll_target(0, 99, ROWS, 4, false), 0) // sel clamped to row 3
}

// The detach a wheel gesture leaves behind, and the reason a notch can mean "move the view".
@(test)
test_list_scroll_detach :: proc(t: ^testing.T) {
    scroll := 0
    detached := f64(0)

    // Attached, the policy runs: row 40 in Middle centres the view.
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, true, 0)
    testing.expect_value(t, scroll, 35)

    // A notch detaches and moves the view, after which neither policy runs — Middle re-derives
    // the top from the selection every frame and would overwrite the gesture.
    app.list_scroll_by(&scroll, &detached, 9, 100)
    testing.expect_value(t, scroll, 44)
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, true, 0)
    testing.expect_value(t, scroll, 44)
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, false, 0)
    testing.expect_value(t, scroll, 44)

    // Only input AFTER the gesture re-attaches: an older timestamp cannot be a reaction to it.
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, false, 99)
    testing.expect_value(t, scroll, 44)
    app.list_scroll_apply(&scroll, &detached, 40, ROWS, TOTAL, false, 101)
    testing.expect_value(t, scroll, 40) // row 40 is above the view, so the top goes to it
    testing.expect_value(t, detached, f64(0))
}

// The callback cannot clamp — no font, no pane rect, no row list — so the frame does, and the
// overshoot is bounded by one notch either way.
@(test)
test_list_scroll_detached_is_bounded :: proc(t: ^testing.T) {
    scroll := 0
    detached := f64(0)

    app.list_scroll_by(&scroll, &detached, -50, 100)
    app.list_scroll_apply(&scroll, &detached, 0, ROWS, TOTAL, false, 0)
    testing.expect_value(t, scroll, 0)

    // Past the end, any row may be the top, as the detached editor lets any line be. A list
    // shorter than its viewport pins at zero.
    app.list_scroll_by(&scroll, &detached, 500, 100)
    app.list_scroll_apply(&scroll, &detached, 0, ROWS, TOTAL, false, 0)
    testing.expect_value(t, scroll, TOTAL - 1)

    app.list_scroll_by(&scroll, &detached, 500, 100)
    app.list_scroll_apply(&scroll, &detached, 0, ROWS, 0, false, 0)
    testing.expect_value(t, scroll, 0)
}
