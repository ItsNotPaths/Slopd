package tests

import app ".."
import "core:testing"
import "vendor:glfw" // key codes only, for the bare-modifier rule; no window is opened

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


// Standing the pointer down while the keyboard is in use. The problem it solves is two
// highlights that both mean "here": a list paints the row under the pointer AND the selected
// row, and while the arrows are moving the selection the pointer is not saying anything —
// it is resting wherever it was left, lighting a row nobody is thinking about.
@(test)
test_mouse_stand_down_gates_hover :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    a.hover_on = true

    testing.expect(t, app.hover_shown(&a), "hover is on by default with the mouse on")

    app.mouse_stand_down(&a)
    testing.expect(t, !app.hover_shown(&a), "a keystroke must stop hover painting")

    app.mouse_wake(&a)
    testing.expect(t, app.hover_shown(&a), "moving the pointer brings it back")

    // The config toggle and the stand-down are independent gates, and hover needs both.
    a.hover_on = false
    testing.expect(t, !app.hover_shown(&a))
    a.hover_on = true
    app.mouse_stand_down(&a)
    a.mouse_on = false
    testing.expect(t, !app.hover_shown(&a))
}

// The gate is on PAINTING hover, never on claiming a click — a press wakes the pointer in
// the callback, before any pane can ask. So there is no state in which a click the user
// aimed is swallowed, and a pane that is stood down still resolves what is under the
// pointer for the click's sake.
@(test)
test_mouse_stand_down_never_eats_a_click :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    a.hover_on = true
    app.mouse_stand_down(&a)

    // What the button callback does, in its order: wake, then park the press.
    app.mouse_wake(&a)
    a.mouse.click = true
    a.mouse.click_count = 1

    testing.expect(t, app.hover_shown(&a), "the press woke the pointer")
    count, ok := app.mouse_take_click(&a)
    testing.expect(t, ok, "a click must still be claimable")
    testing.expect_value(t, count, 1)
}

// A wheel notch deliberately does NOT wake it: scrolling is a pointer action that does not
// move the pointer, so relighting whatever it happens to rest over would put back the exact
// competition this removes. Scrolling itself keeps working, because routing reads a
// position and not a hover.
//
// Scope, stated because a mutation proved it: this pins the half that is reachable —
// wheel_apply, which is where every notch is spent — and it would catch a wake added there.
// It cannot see scroll_callback, which needs a real window (GetWindowUserPointer) and so is
// not exercised by anything headless; that half is held by inspection alone.
@(test)
test_mouse_wheel_does_not_wake :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 20 {
        append(&a.grep.hits, app.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)
    a.hover_on = true
    app.mouse_stand_down(&a)

    app.wheel_apply(&a, .List, 2)
    testing.expect_value(t, a.grep.scroll, 2 * app.WHEEL_LINES) // the notch still landed
    testing.expect(t, !app.hover_shown(&a), "a wheel notch must not reveal the pointer")
}

// A bare modifier is not a verb, and must not stand the pointer down: Alt+click drops a
// cursor, so holding Alt has to leave the cursor on screen for you to aim it, and Ctrl held
// is the filetree's chord bar rather than a keystroke of its own.
@(test)
test_key_is_modifier :: proc(t: ^testing.T) {
    testing.expect(t, app.key_is_modifier(glfw.KEY_LEFT_ALT))
    testing.expect(t, app.key_is_modifier(glfw.KEY_RIGHT_CONTROL))
    testing.expect(t, app.key_is_modifier(glfw.KEY_LEFT_SHIFT))
    testing.expect(t, app.key_is_modifier(glfw.KEY_LEFT_SUPER))
    testing.expect(t, !app.key_is_modifier(glfw.KEY_A))
    testing.expect(t, !app.key_is_modifier(glfw.KEY_DOWN))
    testing.expect(t, !app.key_is_modifier(glfw.KEY_ENTER))
}
