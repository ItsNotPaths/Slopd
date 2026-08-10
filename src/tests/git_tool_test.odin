package tests

import app ".."
import "core:testing"

// The one piece of the git-tool launcher that is worth pinning headlessly: which terminal
// session a launch lands in. Everything else in git_tool.odin either forks a process or
// writes to a PTY, neither of which belongs in a test — but the clamping rule is pure
// arithmetic with three edges, and it is the part a user actually notices getting wrong.

// A number names a session; a number past the end means "the next one". The interesting
// case is the third: asking for session 8 with three open must open the FOURTH, not fail
// and not silently land on the third. One past the end, however far past you aimed.
@(test)
test_git_term_slot :: proc(t: ^testing.T) {
    // Within range: the number is taken at face value.
    testing.expect_value(t, app.git_term_slot(3, 1), 1)
    testing.expect_value(t, app.git_term_slot(3, 2), 2)
    testing.expect_value(t, app.git_term_slot(3, 3), 3)

    // Past the end: exactly one new session, no matter the overshoot. This is the rule
    // the config's comment promises, so it is the one a mutation should break.
    testing.expect_value(t, app.git_term_slot(3, 4), 4)
    testing.expect_value(t, app.git_term_slot(3, 8), 4)
    testing.expect_value(t, app.git_term_slot(3, 9999), 4)

    // No sessions yet: the first launch opens session 1 rather than session 0, which is
    // not a session — term_focus is 1-based.
    testing.expect_value(t, app.git_term_slot(0, 1), 1)
    testing.expect_value(t, app.git_term_slot(0, 7), 1)

    // Zero and below never escape as a slot. git_tool_open routes those to the detached
    // path before asking, so this is a guard rather than a live case — but a slot of 0
    // would clamp to the LAST session inside term_focus, which is a silent wrong answer.
    testing.expect_value(t, app.git_term_slot(3, 0), 1)
    testing.expect_value(t, app.git_term_slot(3, -1), 1)

    // The session cap holds: you cannot ask your way past TERM_MAX.
    testing.expect_value(t, app.git_term_slot(app.TERM_MAX, app.TERM_MAX + 5), app.TERM_MAX)
}
