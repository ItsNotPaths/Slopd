package tests

import app ".."
import "core:testing"

// C2's routing decision table. wheel_target is pure — App state plus the frame's Layout
// in, a target out — so the whole "which pane owns this notch" question is settled here
// rather than by waggling a mouse over a window. Everything below is headless: no GLFW,
// no GL, no Clay context.
//
// The layout used throughout is a 1000x600 window split down the middle with a 40px
// status strip, which is what compute_layout produces for the default a.split of 0.5:
//   editor  x[0, 499)   aux  x[502, 1000)   strip  y[560, 600)
// The 2px gutter between the panes is deliberately included — a notch there belongs to
// neither pane, and that is a case worth pinning.

@(private = "file")
LAY :: app.Layout {
    editor = {0, 0, 499, 560},
    aux    = {502, 0, 498, 560},
    strip  = {0, 560, 1000, 40},
    gutter = 2,
    vis    = {editor = true, aux = true},
}

// A bare App positioned over a given aux mode. app_init is deliberately NOT called: it
// allocates the project root, and none of these assertions need it — wheel_target reads
// only main / aux_mode / scale.
@(private = "file")
routing_app :: proc(mode: app.AuxMode) -> app.App {
    return app.App{aux_mode = mode, scale = 1}
}

// The two top-level panes, plus the places that are neither: the gutter between them and
// the status strip below both.
@(test)
test_wheel_target_panes :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)

    testing.expect_value(t, app.wheel_target(&a, LAY, 10, 10), app.Wheel_Target.Editor)
    testing.expect_value(t, app.wheel_target(&a, LAY, 498, 300), app.Wheel_Target.Editor) // last editor column
    testing.expect_value(t, app.wheel_target(&a, LAY, 700, 300), app.Wheel_Target.List)

    testing.expect_value(t, app.wheel_target(&a, LAY, 500, 300), app.Wheel_Target.None) // in the gutter
    testing.expect_value(t, app.wheel_target(&a, LAY, 400, 580), app.Wheel_Target.None) // status strip
    testing.expect_value(t, app.wheel_target(&a, LAY, 2000, 300), app.Wheel_Target.None) // off-window
}

// The editor pane resolves by SURFACE, not by pane: an image is a document too, but its
// pan/zoom is C8, so it must be a distinct target rather than silently scrolling a buffer
// that is not on screen.
@(test)
test_wheel_target_main_surface :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    testing.expect_value(t, app.wheel_target(&a, LAY, 100, 100), app.Wheel_Target.Editor)
    a.main = .Image
    testing.expect_value(t, app.wheel_target(&a, LAY, 100, 100), app.Wheel_Target.Media)
}

// Every aux mode routes to exactly one target, and the four list panes share one.
@(test)
test_wheel_target_aux_modes :: proc(t: ^testing.T) {
    AUX_X :: 800 // comfortably inside the aux pane
    cases := [?]struct {
        mode: app.AuxMode,
        want: app.Wheel_Target,
    } {
        {.FileTree, .List},
        {.Grep, .List},
        {.Config, .List},
        {.Procmon, .List},
        {.Terminal, .Terminal},
    }
    for c in cases {
        a := routing_app(c.mode)
        testing.expect_value(t, app.wheel_target(&a, LAY, AUX_X, 300), c.want)
    }
}

// A hidden pane is a ZERO rect out of compute_layout, which is what lets wheel_target skip
// a visibility check. Zen with the editor focused is the live case: the aux pane is not on
// screen, so nothing in the window may resolve to it.
@(test)
test_wheel_target_hidden_pane :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    lay := app.Layout {
        editor = {0, 0, 1000, 560},
        strip  = {0, 560, 1000, 40},
        vis    = {editor = true, aux = false},
    }
    testing.expect_value(t, app.wheel_target(&a, lay, 700, 300), app.Wheel_Target.Editor)

    // And the mirror: Full on the aux pane, where the editor is the zero rect.
    lay2 := app.Layout {
        aux   = {0, 0, 1000, 560},
        strip = {0, 560, 1000, 40},
        vis   = {editor = false, aux = true},
    }
    testing.expect_value(t, app.wheel_target(&a, lay2, 100, 300), app.Wheel_Target.List)
}

// Before the first frame App.lay is zero, so a wheel event that beats the renderer must
// find nothing rather than dereferencing a pane that was never laid out.
@(test)
test_wheel_target_before_first_frame :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    testing.expect_value(t, app.wheel_target(&a, app.Layout{}, 0, 0), app.Wheel_Target.None)
    testing.expect_value(t, app.wheel_target(&a, app.Layout{}, 400, 300), app.Wheel_Target.None)
}

// --- the verb half -------------------------------------------------------------------

// A notch in a list pane moves the VIEW and leaves the selection where it is — the same
// thing it means in the editor and the terminal, and the same thing it means
// on every other desktop. WHEEL_LINES rows per notch, and the press stamps the pane as
// detached so neither viewport policy overwrites the write on the next frame.
@(test)
test_wheel_apply_list_scrolls_view :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 20 {
        append(&a.grep.hits, app.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)
    a.grep.selected = 4

    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, a.grep.scroll, app.WHEEL_LINES)
    testing.expect_value(t, a.grep.selected, 4) // the cursor did not move

    // The stamp itself is not asserted here: wheel_apply reads glfw.GetTime(), which is 0
    // in a headless test, and 0 is the value that MEANS attached. The stamp and the
    // re-attach are exercised against list_scroll_by / list_scroll_apply directly, in
    // scroll_test.odin — the same split buffer_test.odin uses for the editor's detach.

    app.wheel_apply(&a, .List, 2)
    testing.expect_value(t, a.grep.scroll, 3 * app.WHEEL_LINES)
    app.wheel_apply(&a, .List, -1)
    testing.expect_value(t, a.grep.scroll, 2 * app.WHEEL_LINES)

    // Deliberately UNCLAMPED here: the callback has no font, no pane rect and no flattened
    // row list, so it cannot know where the end is. list_scroll_apply clamps on the next
    // frame, which is asserted in scroll_test.odin.
    app.wheel_apply(&a, .List, -100)
    testing.expect(t, a.grep.scroll < 0, "the callback does not clamp; the frame does")
}

// A zero notch is a no-op, and the targets with nothing wired yet must stay silent rather
// than falling through to a neighbour's handler.
@(test)
test_wheel_apply_inert_targets :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 5 {
        append(&a.grep.hits, app.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)

    app.wheel_apply(&a, .List, 0) // no notches
    testing.expect_value(t, a.grep.scroll, 0)
    testing.expect_value(t, a.grep.scroll_detached, f64(0)) // and nothing was detached
    app.wheel_apply(&a, .None, 3)
    testing.expect_value(t, a.grep.scroll, 0)
    app.wheel_apply(&a, .Media, 3) // pan/zoom is C8
    testing.expect_value(t, a.grep.scroll, 0)
}

