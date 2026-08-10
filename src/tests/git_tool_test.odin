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

// Config lines carry trailing `# comment`s — the file's header promises them and every
// shipped line uses one — but the parser only ever skipped lines that STARTED with '#',
// so the comment text rode along inside the value. Invisible for years because every
// commented setting in slopd.config happens to hold the value that is already its
// default; the first one where it would bite is git_tool, whose value is free text.
@(test)
test_config_strip_comment :: proc(t: ^testing.T) {
    // The live case: a value followed by a comment keeps only the value.
    testing.expect_value(t, app.config_strip_comment("mouse: on             # on | off"), "mouse: on")
    testing.expect_value(t, app.config_strip_comment("git_tool: lazygit  # e.g. lazygit"), "git_tool: lazygit")

    // A key with NO value but a comment must come back empty after the colon, not
    // carrying the comment as its value — this is the one that would launch a process
    // named "# e.g. lazygit".
    testing.expect_value(t, app.config_strip_comment("git_tool:             # e.g. lazygit"), "git_tool:")

    // Whole-line comments and blanks collapse to "", which the loop skips.
    testing.expect_value(t, app.config_strip_comment("# a heading"), "")
    testing.expect_value(t, app.config_strip_comment("   # indented"), "")
    testing.expect_value(t, app.config_strip_comment("   "), "")

    // A line without a comment is just trimmed — the common case must not be disturbed.
    testing.expect_value(t, app.config_strip_comment("  theme: themes/default.theme  "), "theme: themes/default.theme")
}
