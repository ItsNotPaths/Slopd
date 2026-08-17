package tests

import app ".."
import "core:testing"

// The one piece of the launcher worth pinning headlessly: which session a launch lands in.
// Everything else in git_tool.odin forks a process or writes to a PTY.

// A number names a session; one past the end means "the next". Asking for session 8 with three
// open must open the FOURTH, not fail and not land on the third.
@(test)
test_term_slot :: proc(t: ^testing.T) {
    testing.expect_value(t, app.term_slot(3, 1), 1)
    testing.expect_value(t, app.term_slot(3, 2), 2)
    testing.expect_value(t, app.term_slot(3, 3), 3)

    // Past the end: exactly one new session, whatever the overshoot.
    testing.expect_value(t, app.term_slot(3, 4), 4)
    testing.expect_value(t, app.term_slot(3, 8), 4)
    testing.expect_value(t, app.term_slot(3, 9999), 4)

    // No sessions yet: the first launch opens session 1, since term_focus is 1-based.
    testing.expect_value(t, app.term_slot(0, 1), 1)
    testing.expect_value(t, app.term_slot(0, 7), 1)

    // Zero and below never escape as a slot. git_tool_open routes those to the detached path
    // first, but a slot of 0 would clamp to the LAST session inside term_focus.
    testing.expect_value(t, app.term_slot(3, 0), 1)
    testing.expect_value(t, app.term_slot(3, -1), 1)

    // You cannot ask your way past TERM_MAX.
    testing.expect_value(t, app.term_slot(app.TERM_MAX, app.TERM_MAX + 5), app.TERM_MAX)
}
