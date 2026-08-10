package tests

import app ".."
import "core:testing"

// C7c's drag capture machine. Everything here is headless: the machine holds no window, no
// Clay context and no geometry of its own — it holds what a press RESOLVED to, and the
// clients bring the pixels. That is exactly why it is testable, and why it was worth being
// a checkpoint rather than a field on the editor.
//
// The layout used for the autoscroll questions is mouse_test.odin's, for the same reason it
// is used there: a 1000x600 window split down the middle. drag_autoscrolling asks `a.lay`,
// so the test writes one rather than running a frame.

@(private = "file")
LAY :: app.Layout {
    editor = {0, 0, 499, 560},
    aux    = {502, 0, 498, 560},
    strip  = {0, 560, 1000, 40},
    gutter = 2,
    vis    = {editor = true, aux = true},
}

// An App with the pointer held down at (x, y) and the last frame's layout in hand.
@(private = "file")
dragging_app :: proc(x, y: i32) -> app.App {
    a := app.App{mouse_on = true, lay = LAY}
    a.mouse.known = true
    a.mouse.down = true
    a.mouse.x, a.mouse.y = x, y
    return a
}

// A press captures, and a press that is already OVER does not. Both halves matter: the
// second is what keeps a click completed inside one inter-frame gap from leaving a drag
// behind that nothing will ever release.
@(test)
test_drag_begin_needs_a_held_button :: proc(t: ^testing.T) {
    a := dragging_app(120, 90)

    app.drag_begin(&a, .Editor_Text, 2, 3, app.Pos{7, 4}, 3)
    testing.expect_value(t, a.drag.kind, app.Drag_Kind.Editor_Text)
    testing.expect_value(t, a.drag.target, 2)
    testing.expect_value(t, a.drag.grade, 3)
    testing.expect_value(t, a.drag.anchor, app.Pos{7, 4})
    testing.expect_value(t, a.drag.anchor_glyph, 3)
    testing.expect_value(t, a.drag.origin_x, 120)
    testing.expect_value(t, a.drag.origin_y, 90)

    b := dragging_app(120, 90)
    b.mouse.down = false
    app.drag_begin(&b, .Editor_Text, 0, 1, app.Pos{1, 1}, 1)
    testing.expect_value(t, b.drag.kind, app.Drag_Kind.None)
}

// Capture is kind AND target. A buffer switched with the button still down must leave the
// drag inert rather than pointing it at another file's text — the whole reason the target is
// stored instead of the client just asking "am I dragging".
@(test)
test_drag_live_is_kind_and_target :: proc(t: ^testing.T) {
    a := dragging_app(120, 90)
    app.drag_begin(&a, .Editor_Text, 1, 1, app.Pos{0, 0}, 0)

    testing.expect(t, app.drag_live(&a, .Editor_Text, 1), "the drag it began")
    testing.expect(t, !app.drag_live(&a, .Editor_Text, 0), "another buffer must not be written")
    testing.expect(t, !app.drag_live(&a, .Terminal_Sel, 1), "another kind of drag entirely")
}

// The release is PARKED, not acted on. WaitEvents drains a motion and the release that
// follows it in one batch, so a machine that cleared on release would throw away the last
// stretch of the gesture — the part the user was aiming with. The drag therefore survives
// the release, gets one more frame, and dies in the sweep at the end of it.
//
// The mutation this pins: making drag_release clear the drag outright fails the first
// expect, and making drag_sweep bury a drag that has not ended fails the third.
@(test)
test_drag_release_parks_then_sweeps :: proc(t: ^testing.T) {
    a := dragging_app(120, 90)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{2, 2}, 2)

    // A sweep before the button comes up changes nothing: the gesture is still running.
    app.drag_sweep(&a)
    testing.expect(t, app.drag_live(&a, .Editor_Text, 0), "a live drag must survive its own frames")

    a.mouse.down = false
    app.drag_release(&a)
    testing.expect(t, a.drag.ending, "the release must be recorded")
    testing.expect(t, app.drag_live(&a, .Editor_Text, 0), "the owed frame: still live after the release")

    app.drag_sweep(&a)
    testing.expect_value(t, a.drag.kind, app.Drag_Kind.None)
    testing.expect(t, !a.drag.ending, "the sweep clears the whole thing, not just the kind")
}

// `mouse: off` mid-gesture buries the capture. Otherwise a drag begun before the toggle goes
// on extending after the pointer was supposed to have stopped existing.
@(test)
test_drag_sweep_buries_on_mouse_off :: proc(t: ^testing.T) {
    a := dragging_app(120, 90)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)

    a.mouse_on = false
    app.drag_sweep(&a)
    testing.expect_value(t, a.drag.kind, app.Drag_Kind.None)
}

// Whether the drag is pulling the view past an edge — the question both the client and the
// scheduler ask, which is what keeps the autoscroll wake off a render→state backchannel.
//
// It is a VERTICAL test. A pointer dragged out the side of the pane is still pointing at a
// visible row, so there is nothing to scroll toward and no reason to wake for it.
@(test)
test_drag_autoscrolling_edges :: proc(t: ^testing.T) {
    a := dragging_app(120, 300)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)
    testing.expect(t, !app.drag_autoscrolling(&a), "inside the pane")

    a.mouse.y = -20
    testing.expect(t, app.drag_autoscrolling(&a), "above the pane")

    a.mouse.y = 560 // the first row of the status strip: the editor is y[0, 560)
    testing.expect(t, app.drag_autoscrolling(&a), "below the pane")

    a.mouse.y, a.mouse.x = 300, 900 // over the aux pane, but level with the text
    testing.expect(t, !app.drag_autoscrolling(&a), "out the side is not out the bottom")

    // The terminal's drag (C7d) reads the AUX rect, which is the same band vertically —
    // pinned so a later kind added to the switch cannot silently inherit the editor's rect.
    a.drag.kind = .Terminal_Sel
    a.mouse.y = 570
    testing.expect(t, app.drag_autoscrolling(&a), "the aux pane has the same bottom edge")

    // The divider (C8) drags by pixel delta and has no view to run off the end of.
    a.drag.kind = .Split
    testing.expect(t, !app.drag_autoscrolling(&a), "a divider does not autoscroll")

    // Before the first frame a.lay is all zeroes, and a zero-height rect must not read as
    // "the pointer is past the bottom of it" — which `y >= r.y + r.h` says for every y at
    // all, including 0. The layout is cleared rather than the pointer moved, because the
    // pointer is not the thing under test.
    b := dragging_app(0, 0)
    b.lay = {}
    app.drag_begin(&b, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)
    testing.expect(t, !app.drag_autoscrolling(&b), "no layout yet is not an edge")
}

// One line at the boundary, one more per row height beyond it, capped. The cap is the point:
// the overshoot is unbounded (a 200px pane on a 4K screen) and a drag that teleports to the
// end of the file is not a drag.
@(test)
test_drag_scroll_step :: proc(t: ^testing.T) {
    testing.expect_value(t, app.drag_scroll_step(0, 18), 1)
    testing.expect_value(t, app.drag_scroll_step(17, 18), 1)
    testing.expect_value(t, app.drag_scroll_step(18, 18), 2)
    testing.expect_value(t, app.drag_scroll_step(54, 18), 4)
    testing.expect_value(t, app.drag_scroll_step(100000, 18), app.DRAG_SCROLL_MAX)
    testing.expect_value(t, app.drag_scroll_step(50, 0), 1) // a degenerate pane still steps
}

// The tick paces the autoscroll, and its zero value is in the PAST on purpose: leaving the
// pane acts on the very next frame rather than up to DRAG_SCROLL_S later.
@(test)
test_drag_tick_paces_and_starts_immediately :: proc(t: ^testing.T) {
    a := dragging_app(120, 900)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)

    testing.expect(t, app.drag_tick(&a, 100), "the first tick is due at once")
    testing.expect(t, !app.drag_tick(&a, 100), "and is spent: no second step in the same frame")
    testing.expect(t, !app.drag_tick(&a, 100 + app.DRAG_SCROLL_S/2), "nor half an interval later")
    testing.expect(t, app.drag_tick(&a, 100 + app.DRAG_SCROLL_S), "the next interval steps again")
}

// The pump. A click and a wheel notch each ARRIVE as an event, so the loop is already awake
// for them; a drag held still past the bottom edge produces no events at all and would sit
// frozen without a wake of its own.
@(test)
test_drag_next_wake :: proc(t: ^testing.T) {
    a := dragging_app(120, 300)
    testing.expect_value(t, app.drag_next_wake(&a, 100), -1) // nothing captured

    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)
    testing.expect_value(t, app.drag_next_wake(&a, 100), -1) // captured, but inside the pane

    a.mouse.y = 700
    testing.expect_value(t, app.drag_next_wake(&a, 100), 0.0) // overdue: redraw now
    _ = app.drag_tick(&a, 100)
    // A whole interval, give or take the f64 round trip through an absolute glfw time.
    testing.expect(t, abs(app.drag_next_wake(&a, 100) - app.DRAG_SCROLL_S) < 1e-9, "one interval to the next step")
    testing.expect_value(t, app.drag_next_wake(&a, 100 + app.DRAG_SCROLL_S), 0.0)
}
