package tests

import app ".."
import "core:testing"

// The drag capture machine, headless: it holds no window, no Clay context and no geometry of
// its own — only what a press RESOLVED to, with the clients bringing the pixels.
//
// The autoscroll questions use mouse_test.odin's layout, a 1000x600 window split down the
// middle. drag_autoscrolling asks `a.lay`, so the test writes one rather than running a frame.

@(private = "file")
LAY :: app.Layout {
    editor = {0, 0, 499, 560},
    aux    = {502, 0, 498, 560},
    strip  = {0, 560, 1000, 40},
    gutter = 2,
    vis    = {editor = true, aux = true},
}

// The pointer held down at (x, y), with the last frame's layout in hand.
@(private = "file")
dragging_app :: proc(x, y: i32) -> app.App {
    a := app.App{mouse_on = true, lay = LAY}
    a.mouse.known = true
    a.mouse.down = true
    a.mouse.x, a.mouse.y = x, y
    return a
}

// A press captures; one already OVER does not. The second half keeps a click completed inside
// one inter-frame gap from leaving a drag nothing will release.
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

// Kind AND target: a buffer switched with the button down must leave the drag inert rather than
// pointing it at another file's text.
@(test)
test_drag_live_is_kind_and_target :: proc(t: ^testing.T) {
    a := dragging_app(120, 90)
    app.drag_begin(&a, .Editor_Text, 1, 1, app.Pos{0, 0}, 0)

    testing.expect(t, app.drag_live(&a, .Editor_Text, 1), "the drag it began")
    testing.expect(t, !app.drag_live(&a, .Editor_Text, 0), "another buffer must not be written")
    testing.expect(t, !app.drag_live(&a, .Terminal_Sel, 1), "another kind of drag entirely")
}

// The release is PARKED, not acted on: WaitEvents drains a motion and the release after it in
// one batch, so clearing on release would throw away the part the user was aiming with. The drag
// survives, gets one more frame, and dies in the sweep at the end of it.
@(test)
test_drag_release_parks_then_sweeps :: proc(t: ^testing.T) {
    a := dragging_app(120, 90)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{2, 2}, 2)

    // A sweep before the button comes up changes nothing.
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

// Otherwise a drag begun before the toggle goes on extending after the pointer stopped
// existing.
@(test)
test_drag_sweep_buries_on_mouse_off :: proc(t: ^testing.T) {
    a := dragging_app(120, 90)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)

    a.mouse_on = false
    app.drag_sweep(&a)
    testing.expect_value(t, a.drag.kind, app.Drag_Kind.None)
}

// The question both the client and the scheduler ask, which keeps the autoscroll wake off a
// render->state backchannel. Vertical only: a pointer dragged out the side of the pane is still
// pointing at a visible row.
@(test)
test_drag_autoscrolling_edges :: proc(t: ^testing.T) {
    a := dragging_app(120, 300)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)
    testing.expect(t, !app.drag_autoscrolling(&a), "inside the pane")

    a.mouse.y = -20
    testing.expect(t, app.drag_autoscrolling(&a), "above the pane")

    a.mouse.y = 560 // the strip's first row; the editor is y[0, 560)
    testing.expect(t, app.drag_autoscrolling(&a), "below the pane")

    a.mouse.y, a.mouse.x = 300, 900 // over the aux pane, level with the text
    testing.expect(t, !app.drag_autoscrolling(&a), "out the side is not out the bottom")

    // The terminal's drag reads the AUX rect, the same band vertically. Pinned so a later kind
    // added to the switch cannot silently inherit the editor's.
    a.drag.kind = .Terminal_Sel
    a.mouse.y = 570
    testing.expect(t, app.drag_autoscrolling(&a), "the aux pane has the same bottom edge")

    // The divider drags by pixel delta and has no view to run off the end of.
    a.drag.kind = .Split
    testing.expect(t, !app.drag_autoscrolling(&a), "a divider does not autoscroll")

    // Nor the media pan, whose answer is NEITHER axis: the pointer is well below the editor
    // pane here, which makes every other kind say yes.
    a.drag.kind = .Media_Pan
    a.mouse.x, a.mouse.y = 120, 900
    testing.expect(t, !app.drag_autoscrolling(&a), "a pan has no rows to walk past the edge")

    // Before the first frame a.lay is zero, and a zero-height rect must not read as "past the
    // bottom of it" — which `y >= r.y + r.h` says for every y, 0 included.
    b := dragging_app(0, 0)
    b.lay = {}
    app.drag_begin(&b, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)
    testing.expect(t, !app.drag_autoscrolling(&b), "no layout yet is not an edge")
}

// One line at the boundary, one more per row height beyond, capped. The cap is the point: the
// overshoot is unbounded, and a drag that teleports to the end of the file is not a drag.
@(test)
test_drag_scroll_step :: proc(t: ^testing.T) {
    testing.expect_value(t, app.drag_scroll_step(0, 18), 1)
    testing.expect_value(t, app.drag_scroll_step(17, 18), 1)
    testing.expect_value(t, app.drag_scroll_step(18, 18), 2)
    testing.expect_value(t, app.drag_scroll_step(54, 18), 4)
    testing.expect_value(t, app.drag_scroll_step(100000, 18), app.DRAG_SCROLL_MAX)
    testing.expect_value(t, app.drag_scroll_step(50, 0), 1) // a degenerate pane still steps
}

// Its zero value is in the PAST on purpose: leaving the pane acts on the next frame rather than
// up to DRAG_SCROLL_S later.
@(test)
test_drag_tick_paces_and_starts_immediately :: proc(t: ^testing.T) {
    a := dragging_app(120, 900)
    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)

    testing.expect(t, app.drag_tick(&a, 100), "the first tick is due at once")
    testing.expect(t, !app.drag_tick(&a, 100), "and is spent: no second step in the same frame")
    testing.expect(t, !app.drag_tick(&a, 100 + app.DRAG_SCROLL_S/2), "nor half an interval later")
    testing.expect(t, app.drag_tick(&a, 100 + app.DRAG_SCROLL_S), "the next interval steps again")
}

// A click and a wheel notch each ARRIVE as an event, so the loop is awake for them; a drag held
// still past the bottom edge produces none and would sit frozen without a wake.
@(test)
test_drag_next_wake :: proc(t: ^testing.T) {
    a := dragging_app(120, 300)
    testing.expect_value(t, app.drag_next_wake(&a, 100), -1) // nothing captured

    app.drag_begin(&a, .Editor_Text, 0, 1, app.Pos{0, 0}, 0)
    testing.expect_value(t, app.drag_next_wake(&a, 100), -1) // captured, inside the pane

    a.mouse.y = 700
    testing.expect_value(t, app.drag_next_wake(&a, 100), 0.0) // overdue: redraw now
    _ = app.drag_tick(&a, 100)
    // A whole interval, give or take the f64 round trip through an absolute glfw time.
    testing.expect(t, abs(app.drag_next_wake(&a, 100) - app.DRAG_SCROLL_S) < 1e-9, "one interval to the next step")
    testing.expect_value(t, app.drag_next_wake(&a, 100 + app.DRAG_SCROLL_S), 0.0)
}

// The only piece of the machine the editor and the terminal do not use. It exists because a
// CLICK on the split divider must do nothing, where a click in text is a zero-length drag.
//
// The latch is the assertion that matters: un-latched, a divider dragged well past the threshold
// and returned to within a pixel of the press would refuse the last frame and strand the split.
// Dropping the early `if a.drag.moved` return fails the third expect and nothing else.
@(test)
test_drag_moved_latches :: proc(t: ^testing.T) {
    a := dragging_app(300, 200)
    app.drag_begin(&a, .Split, 0, 1, app.Pos{}, 0)

    testing.expect(t, !app.drag_moved(&a, 3), "a press that has not moved is not a drag")
    a.mouse.x = 302 // two pixels: inside the threshold
    testing.expect(t, !app.drag_moved(&a, 3), "nor is one that has barely twitched")

    a.mouse.x = 340
    testing.expect(t, app.drag_moved(&a, 3), "past the threshold it is a drag")
    a.mouse.x = 301 // back within a pixel of the press
    testing.expect(t, app.drag_moved(&a, 3), "and stays one on the way back")

    // Max-norm: either axis alone is enough.
    b := dragging_app(300, 200)
    app.drag_begin(&b, .Media_Pan, 0, 1, app.Pos{}, 0)
    b.mouse.y = 210
    testing.expect(t, app.drag_moved(&b, 3), "vertical travel counts too")

    // A fresh capture starts un-latched: the field is per-gesture.
    app.drag_release(&b)
    app.drag_sweep(&b)
    app.drag_begin(&b, .Split, 0, 1, app.Pos{}, 0)
    testing.expect(t, !app.drag_moved(&b, 3), "a new press starts from nothing")
}

// The VIEW's position at press time, carried so each frame re-derives the pan from the total
// travel rather than accumulating a per-frame delta.
@(test)
test_drag_begin_carries_the_pan_origin :: proc(t: ^testing.T) {
    a := dragging_app(400, 250)
    app.drag_begin(&a, .Media_Pan, 0, 1, app.Pos{}, 0, [2]f32{-30, 12})

    testing.expect_value(t, a.drag.kind, app.Drag_Kind.Media_Pan)
    testing.expect_value(t, a.drag.origin_pan, [2]f32{-30, 12})
    testing.expect_value(t, a.drag.origin_x, 400)
    testing.expect_value(t, a.drag.origin_y, 250)

    // It defaults, so the three clients with no pan are unchanged by its existing.
    b := dragging_app(400, 250)
    app.drag_begin(&b, .Editor_Text, 0, 1, app.Pos{3, 3}, 3)
    testing.expect_value(t, b.drag.origin_pan, [2]f32{0, 0})
}
