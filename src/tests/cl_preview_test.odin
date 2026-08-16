package tests

import app ".."
import "core:testing"

// The command line's live preview (cl_preview.odin): what a `:` line shows while it is typed,
// and that Esc puts the view back untouched. Driven here the way the frame loop drives it —
// set the line, call cl_preview_sync — since the version compare is the whole trigger.

@(private = "file")
mkapp :: proc(text: string) -> app.App {
    a: app.App
    app.editor_init(&a.editor)
    app.cl_init(&a.cl)
    app.buffer_set_text(app.editor_current(&a.editor), text)
    a.cl_active = true
    a.cl_preview_on = true
    return a
}

@(private = "file")
freeapp :: proc(a: ^app.App) {
    app.editor_destroy(&a.editor)
    app.cl_destroy(a)
    app.cl_preview_destroy(a)
    app.find_destroy(&a.find)
    app.grep_destroy(&a.grep)
}

// Type a line into the command line and run the frame's preview tick over it. `now` is the
// frame's clock — it only matters to `:grep`, whose search waits for a pause in the typing.
@(private = "file")
typeln :: proc(a: ^app.App, line: string, now := f64(0)) {
    app.doc_set_text(&a.cl.doc, line)
    app.cl_preview_sync(a, now)
}

// A later frame with nothing typed in it: what lets a debounced preview come due.
@(private = "file")
tick :: proc(a: ^app.App, now: f64) {
    app.cl_preview_sync(a, now)
}

@(private = "file")
caret :: proc(a: ^app.App) -> app.Pos {
    b := app.editor_current(&a.editor)
    return b.cursors[b.primary].head
}

PREVIEW_PAGE :: "l0\nl1\nl2\nl3\nl4\nl5"

// --- the shared `:j` line parse ---

// cl_jump_line answers for the bare-line form only. Both the preview and the builtin read it,
// which is what stops the two landing in different places.
@(test)
test_cl_jump_line :: proc(t: ^testing.T) {
    b: app.Buffer
    app.buffer_set_text(&b, PREVIEW_PAGE)
    defer app.buffer_destroy(&b)
    app.doc_reset_cursor(&b.doc, app.Pos{line = 2, col = 1})

    p, ok := app.cl_jump_line(&b, "4") // 1-based in, 0-based out
    testing.expect(t, ok)
    testing.expect_value(t, p, app.Pos{line = 3, col = 1}) // column kept

    p, ok = app.cl_jump_line(&b, "+2") // relative to the caret's line
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 4)

    p, ok = app.cl_jump_line(&b, "900") // past the end: clamped onto the last line
    testing.expect(t, ok)
    testing.expect_value(t, p.line, 5)

    _, ok = app.cl_jump_line(&b, "main.odin") // a file name: not this form
    testing.expect(t, !ok)
    _, ok = app.cl_jump_line(&b, "notes.md 12") // a second field says the first was a file
    testing.expect(t, !ok)
}

// --- borrow and return ---

@(test)
test_preview_jump_shows_the_target :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    typeln(&a, ":j 5")
    testing.expect_value(t, caret(&a).line, 4)
    testing.expect_value(t, a.focus, app.Focus.Editor)

    typeln(&a, ":j 2") // editing the line re-previews rather than stacking a second one
    testing.expect_value(t, caret(&a).line, 1)
}

// Esc restores the WHOLE cursor set, not one position: doc_reset_cursor collapses a
// multi-cursor trail, and a preview that could not put one back would eat it.
@(test)
test_preview_restores_the_cursor_trail :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    b := app.editor_current(&a.editor)
    app.doc_reset_cursor(&b.doc, app.Pos{line = 1, col = 0})
    app.doc_drop_anchor(&b.doc) // Alt+A + Down twice: a trail of three
    app.doc_move(&b.doc, .Down)
    app.doc_drop_anchor(&b.doc)
    before := make([]app.Cursor, len(b.cursors), context.temp_allocator)
    copy(before, b.cursors[:])
    primary := b.primary
    testing.expect(t, len(before) > 1)

    typeln(&a, ":j 6")
    testing.expect_value(t, len(b.cursors), 1) // the preview is one caret on the target

    app.cl_cancel(&a)
    testing.expect_value(t, len(b.cursors), len(before))
    for c, i in before {
        testing.expect_value(t, b.cursors[i], c)
    }
    testing.expect_value(t, b.primary, primary) // and the same one of them still drives the view
}

// Enter keeps what the preview showed. The builtin then runs over that same position, which is
// how `:f` holds the match you cycled to with no state handed between the two.
@(test)
test_preview_commit_keeps_the_landing :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    typeln(&a, ":j 4")
    app.cl_preview_commit(&a)
    testing.expect_value(t, caret(&a).line, 3)

    app.cl_cancel(&a) // nothing is owed back now, so this must not move the caret
    testing.expect_value(t, caret(&a).line, 3)
}

// A preview shows what the WHOLE line does, so a line that does more than one thing shows
// nothing: the first step of a chain is not what pressing Enter would do.
@(test)
test_preview_skips_chains_and_shell :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    typeln(&a, ":j 5 && make")
    testing.expect_value(t, caret(&a).line, 0)
    typeln(&a, "j 5") // no sigil: a shell command, and its effects are not ours to guess
    testing.expect_value(t, caret(&a).line, 0)
}

@(test)
test_preview_off_shows_nothing :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    a.cl_preview_on = false
    typeln(&a, ":j 5")
    testing.expect_value(t, caret(&a).line, 0)
}

// --- the find preview ---

@(test)
test_preview_find_marks_and_cycles :: proc(t: ^testing.T) {
    a := mkapp("l0\nhit\nl2\nhit\nl4")
    defer freeapp(&a)

    typeln(&a, ":f hit")
    testing.expect(t, a.find.show)
    testing.expect_value(t, len(a.find.matches), 2)
    testing.expect_value(t, caret(&a).line, 1) // the first hit at or after where the caret was

    testing.expect(t, app.cl_preview_step(&a, 1)) // Up/Down cycle the hits, not the history
    testing.expect_value(t, a.find.cur, 1)
    testing.expect_value(t, caret(&a).line, 3)

    // The strip reports the position within the count as they are cycled.
    testing.expect_value(t, app.cl_ghost_hint(&a, ":f hit"), "(2/2)")

    app.cl_cancel(&a)
    testing.expect(t, !a.find.show) // the marks come down with the line
    testing.expect_value(t, caret(&a).line, 0)
}

// Cycling is only for a live find preview. With none up, Up/Down are the history keys they
// have always been — cl_preview_step says so by returning false.
@(test)
test_preview_step_declines_without_a_find :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    testing.expect(t, !app.cl_preview_step(&a, 1))
    typeln(&a, ":j 3")
    testing.expect(t, !app.cl_preview_step(&a, 1))
}

@(test)
test_preview_find_reports_a_miss :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    typeln(&a, ":f nowhere")
    testing.expect_value(t, len(a.find.matches), 0)
    testing.expect_value(t, caret(&a).line, 0) // nothing to land on: the caret stays put
    testing.expect_value(t, app.cl_ghost_hint(&a, ":f nowhere"), "(no matches)")
}

// --- the grep preview ---
//
// The project root is left EMPTY, so grep_run answers nothing without spawning a process: what
// is under test is the borrow of the aux pane, not the search itself.

// The pattern half of a `:grep` line, shared with the preview so the two search alike.
@(test)
test_cl_grep_query :: proc(t: ^testing.T) {
    testing.expect_value(t, app.cl_grep_query("  foo bar  "), "foo bar") // kept whole
    testing.expect_value(t, app.cl_grep_query("-i -w thing"), "thing") // leading flags dropped
    testing.expect_value(t, app.cl_grep_query("-rn"), "") // flags alone name no pattern
}

// The Grep pane is BORROWED: what it held is moved aside and put back by the Esc, results and
// all, and the aux pane the user was on comes back with it.
@(test)
test_preview_grep_borrows_the_pane :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)
    app.grep_set(&a.grep, "older", nil) // results already in the pane, from an earlier search
    a.aux_mode = .FileTree

    typeln(&a, ":grep hello")
    tick(&a, 1) // the search waits for a pause in the typing
    testing.expect_value(t, a.aux_mode, app.AuxMode.Grep)
    testing.expect_value(t, a.focus, app.Focus.Aux)
    testing.expect_value(t, a.grep.query, "hello")
    testing.expect_value(t, app.cl_ghost_hint(&a, ":grep hello"), "(no matches)")
    testing.expect_value(t, caret(&a).line, 0) // the page is not touched at all

    app.cl_cancel(&a)
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
    testing.expect_value(t, a.focus, app.Focus.Editor)
    testing.expect_value(t, a.grep.query, "older") // the old results, not the preview's
}

// Enter keeps the pane the preview opened — the builtin then runs its own search over it.
@(test)
test_preview_grep_commit_keeps_the_pane :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)

    typeln(&a, ":grep hello")
    tick(&a, 1)
    app.cl_preview_commit(&a)
    testing.expect_value(t, a.aux_mode, app.AuxMode.Grep)
    testing.expect_value(t, a.grep.query, "hello")
    testing.expect_value(t, app.cl_ghost_hint(&a, ":grep hello"), "") // the preview is over

    app.cl_cancel(&a) // nothing is owed back now
    testing.expect_value(t, a.aux_mode, app.AuxMode.Grep)
}

// The search runs on a PAUSE, not on the keystroke: every letter of a pattern would otherwise
// be a walk of the whole project.
@(test)
test_preview_grep_waits_for_a_pause :: proc(t: ^testing.T) {
    a := mkapp(PREVIEW_PAGE)
    defer freeapp(&a)
    a.aux_mode = .FileTree

    typeln(&a, ":grep hel", 10)
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree) // still typing
    tick(&a, 10 + app.CL_GREP_DELAY / 2)
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree)
    tick(&a, 10 + app.CL_GREP_DELAY)
    testing.expect_value(t, a.aux_mode, app.AuxMode.Grep)

    // A pattern too short to mean anything is not searched for at all.
    typeln(&a, ":grep h", 20)
    tick(&a, 21)
    testing.expect_value(t, a.aux_mode, app.AuxMode.FileTree) // and the borrow was returned
}

// --- the shared line split ---

@(test)
test_cl_builtin_call :: proc(t: ^testing.T) {
    name, args, ok := app.cl_builtin_call("  :j 40  ")
    testing.expect(t, ok)
    testing.expect_value(t, name, "j")
    testing.expect_value(t, args, "40")

    name, args, ok = app.cl_builtin_call(":ls")
    testing.expect(t, ok)
    testing.expect_value(t, name, "ls")
    testing.expect_value(t, args, "")

    _, _, ok = app.cl_builtin_call("grep foo") // unsigilled: a shell command
    testing.expect(t, !ok)
    _, _, ok = app.cl_builtin_call(":") // the sigil alone names no builtin
    testing.expect(t, !ok)
}
