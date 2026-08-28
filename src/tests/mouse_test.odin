package tests

import app "../slopd"
import "core:testing"
import "vendor:glfw" // key codes only; no window is opened
import "../ui"
import "../search"
import "../pty"
import "../edit"

// The routing decision table. wheel_target is pure — App state plus the frame's Layout in, a
// target out — so "which pane owns this notch" is settled here. Headless throughout.
//
// The layout is a 1000x600 window split down the middle with a 40px strip, which is what
// compute_layout produces at the default split of 0.5:
//   editor  x[0, 499)   aux  x[502, 1000)   strip  y[560, 600)
// The 2px gutter is deliberately included: a notch there belongs to neither pane.

@(private = "file")
LAY :: app.Layout {
    editor = {0, 0, 499, 560},
    aux    = {502, 0, 498, 560},
    strip  = {0, 560, 1000, 40},
    gutter = 2,
    vis    = {editor = true, aux = true},
}

// app_init is deliberately not called: it allocates the project root, and wheel_target reads
// only main / aux_mode / scale.
@(private = "file")
routing_app :: proc(mode: app.AuxMode) -> app.App {
    return app.App{aux_mode = mode, scale = 1}
}

// The two panes, plus the places that are neither: the gutter and the strip.
@(test)
test_wheel_target_panes :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)

    testing.expect_value(t, app.wheel_target(&a, LAY, 10, 10), ui.Wheel_Target.Editor)
    testing.expect_value(t, app.wheel_target(&a, LAY, 498, 300), ui.Wheel_Target.Editor) // last column
    testing.expect_value(t, app.wheel_target(&a, LAY, 700, 300), ui.Wheel_Target.List)

    testing.expect_value(t, app.wheel_target(&a, LAY, 500, 300), ui.Wheel_Target.None) // in the gutter
    testing.expect_value(t, app.wheel_target(&a, LAY, 400, 580), ui.Wheel_Target.None) // status strip
    testing.expect_value(t, app.wheel_target(&a, LAY, 2000, 300), ui.Wheel_Target.None) // off-window
}

// The editor pane resolves by SURFACE: an image is a document too, but a notch over it must not
// silently scroll a buffer that is not on screen.
@(test)
test_wheel_target_main_surface :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    testing.expect_value(t, app.wheel_target(&a, LAY, 100, 100), ui.Wheel_Target.Editor)
    a.main = .Image
    testing.expect_value(t, app.wheel_target(&a, LAY, 100, 100), ui.Wheel_Target.Media)
}

// Every aux mode routes to one target, and the three list panes share one.
@(test)
test_wheel_target_aux_modes :: proc(t: ^testing.T) {
    AUX_X :: 800 // comfortably inside the aux pane
    cases := [?]struct {
        mode: app.AuxMode,
        want: ui.Wheel_Target,
    } {
        {.FileTree, .List},
        {.Grep, .List},
        {.Config, .List},
        {.Terminal, .Terminal},
    }
    for c in cases {
        a := routing_app(c.mode)
        testing.expect_value(t, app.wheel_target(&a, LAY, AUX_X, 300), c.want)
    }
}

// A hidden pane is a zero rect out of compute_layout, which is what lets wheel_target skip a
// visibility check. Zen with the editor focused is the live case.
@(test)
test_wheel_target_hidden_pane :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    lay := app.Layout {
        editor = {0, 0, 1000, 560},
        strip  = {0, 560, 1000, 40},
        vis    = {editor = true, aux = false},
    }
    testing.expect_value(t, app.wheel_target(&a, lay, 700, 300), ui.Wheel_Target.Editor)

    // The mirror: Full on the aux pane, where the editor is the zero rect.
    lay2 := app.Layout {
        aux   = {0, 0, 1000, 560},
        strip = {0, 560, 1000, 40},
        vis   = {editor = false, aux = true},
    }
    testing.expect_value(t, app.wheel_target(&a, lay2, 100, 300), ui.Wheel_Target.List)
}

// Before the first frame App.lay is zero, so a wheel event beating the renderer must find
// nothing rather than a pane that was never laid out.
@(test)
test_wheel_target_before_first_frame :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    testing.expect_value(t, app.wheel_target(&a, app.Layout{}, 0, 0), ui.Wheel_Target.None)
    testing.expect_value(t, app.wheel_target(&a, app.Layout{}, 400, 300), ui.Wheel_Target.None)
}

// --- the verb half -------------------------------------------------------------------

// A notch moves the VIEW and leaves the selection alone: WHEEL_LINES rows, with the pane stamped
// detached so neither viewport policy overwrites the write next frame.
@(test)
test_wheel_apply_list_scrolls_view :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 20 {
        append(&a.grep.hits, search.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)
    a.grep.selected = 4

    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, a.grep.scroll, ui.WHEEL_LINES)
    testing.expect_value(t, a.grep.selected, 4) // the cursor did not move

    // The stamp is not asserted here: wheel_apply reads glfw.GetTime(), which is 0 headless,
    // and 0 is the value that MEANS attached. scroll_test.odin covers it directly.

    app.wheel_apply(&a, .List, 2)
    testing.expect_value(t, a.grep.scroll, 3 * ui.WHEEL_LINES)
    app.wheel_apply(&a, .List, -1)
    testing.expect_value(t, a.grep.scroll, 2 * ui.WHEEL_LINES)

    // Unclamped: the callback has no font, pane rect or row list, so it cannot know where the
    // end is. list_scroll_apply clamps next frame (scroll_test.odin).
    app.wheel_apply(&a, .List, -100)
    testing.expect(t, a.grep.scroll < 0, "the callback does not clamp; the frame does")
}

// The one exception to WHEEL_LINES: a row there is a whole entry, or a row of tiles. One per
// notch, a third of what grep and config get.
@(test)
test_wheel_apply_file_pane_is_slower :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    for i in 0 ..< 40 {
        append(&a.tree.entries, app.FileEntry{name = "e", path = "/e", display = "e"})
    }
    defer delete(a.tree.entries)

    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, a.tree.scroll, ui.WHEEL_LINES_FILE)
    app.wheel_apply(&a, .List, 3)
    testing.expect_value(t, a.tree.scroll, 4 * ui.WHEEL_LINES_FILE)
    app.wheel_apply(&a, .List, -2)
    testing.expect_value(t, a.tree.scroll, 2 * ui.WHEEL_LINES_FILE)

    // A comparison rather than a number, so the claim survives either constant being retuned.
    testing.expect(t, ui.WHEEL_LINES_FILE < ui.WHEEL_LINES, "the file panes lost their slower wheel")

    // The selection does not move: a wheel scrolls the view, everywhere (rule 10).
    testing.expect_value(t, a.tree.selected, 0)
}

// A zero notch is a no-op, and an unwired target must stay silent rather than falling through.
@(test)
test_wheel_apply_inert_targets :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 5 {
        append(&a.grep.hits, search.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)

    app.wheel_apply(&a, .List, 0) // no notches
    testing.expect_value(t, a.grep.scroll, 0)
    testing.expect_value(t, a.grep.scroll_detached, f64(0)) // nothing was detached
    app.wheel_apply(&a, .None, 3)
    testing.expect_value(t, a.grep.scroll, 0)

    // .Media zooms now, but must still not reach a neighbour's handler — and with the main
    // surface on Text there is no image to zoom.
    app.wheel_apply(&a, .Media, 3)
    testing.expect_value(t, a.grep.scroll, 0)
    testing.expect_value(t, a.media.zoom, f32(0)) // no image open
}

// The one wheel target that is not a scroll, and the one that ignores WHEEL_LINES. Routed
// through wheel_apply rather than media_wheel, because the claim is that the ROUTING reaches
// it: a target that silently kept doing nothing would look like one that works.
@(test)
test_wheel_apply_media_zooms :: proc(t: ^testing.T) {
    a := routing_app(.FileTree)
    a.main = .Image
    a.lay = LAY
    a.media = app.Media {
        w    = 200,
        h    = 100,
        zoom = 1,
    }
    a.mouse.x, a.mouse.y = 250, 280 // the editor pane's centre-ish

    app.wheel_apply(&a, .Media, -1) // negative is UP: toward the picture
    testing.expect_value(t, a.media.zoom, app.MEDIA_ZOOM_STEP)

    app.wheel_apply(&a, .Media, 1) // and back out
    testing.expect(t, abs(a.media.zoom - 1) < 1e-5, "a notch each way returns to where it started")

    // A trackpad's batched event lands where the same number of discrete notches would.
    a.media.zoom = 1
    app.wheel_apply(&a, .Media, -2)
    expected := app.MEDIA_ZOOM_STEP * app.MEDIA_ZOOM_STEP
    testing.expect(t, abs(a.media.zoom - expected) < 1e-5, "notches compound")
}


// The problem it solves is two highlights that both mean "here": a list paints the row under
// the pointer AND the selected row, and while the arrows move the selection the pointer is
// resting wherever it was left.
@(test)
test_mouse_stand_down_gates_hover :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    a.hover_on = true

    testing.expect(t, ui.hover_shown(app.ctx_of(&a)), "hover is on by default with the mouse on")

    app.mouse_stand_down(&a)
    testing.expect(t, !ui.hover_shown(app.ctx_of(&a)), "a keystroke must stop hover painting")

    app.mouse_wake(&a)
    testing.expect(t, ui.hover_shown(app.ctx_of(&a)), "moving the pointer brings it back")

    // Independent gates, and hover needs both.
    a.hover_on = false
    testing.expect(t, !ui.hover_shown(app.ctx_of(&a)))
    a.hover_on = true
    app.mouse_stand_down(&a)
    a.mouse_on = false
    testing.expect(t, !ui.hover_shown(app.ctx_of(&a)))
}

// The gate is on PAINTING hover, never on claiming a click: a press wakes the pointer in the
// callback, before any pane can ask, so no click the user aimed is swallowed.
@(test)
test_mouse_stand_down_never_eats_a_click :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    a.hover_on = true
    app.mouse_stand_down(&a)

    // What the button callback does, in order: wake, then park the press.
    app.mouse_wake(&a)
    a.mouse.click = true
    a.mouse.click_count = 1

    testing.expect(t, ui.hover_shown(app.ctx_of(&a)), "the press woke the pointer")
    count, ok := ui.mouse_take_click(app.ctx_of(&a))
    testing.expect(t, ok, "a click must still be claimable")
    testing.expect_value(t, count, 1)
}

// Turning a wheel is a hand on the mouse, so it wakes the pointer like any other pointer event.
// Through mouse_wheel rather than wheel_apply, because that is the seam the wake lives on. The
// half left in scroll_callback is the "never had a cursor position" fallback, needing a
// real window.
@(test)
test_mouse_wheel_wakes :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 20 {
        append(&a.grep.hits, search.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)
    a.hover_on = true
    a.mouse_on = true
    a.mouse.known = true
    // mouse_wheel routes the notch itself, so it needs a cached layout and a position.
    a.lay = LAY
    a.mouse.x, a.mouse.y = 700, 300
    app.mouse_stand_down(&a)

    app.mouse_wheel(&a, -1) // GLFW's sign: negative yoffset is a scroll DOWN
    testing.expect(t, ui.hover_shown(app.ctx_of(&a)), "a wheel event must reveal the pointer")
    testing.expect_value(t, a.grep.scroll, ui.WHEEL_LINES)

    // A sub-notch event wakes too, though it spends no notch: a wake gated on whole notches
    // would leave the cursor hidden through a whole trackpad gesture.
    app.mouse_stand_down(&a)
    before := a.grep.scroll
    app.mouse_wheel(&a, -0.25)
    testing.expect(t, ui.hover_shown(app.ctx_of(&a)), "a fractional wheel event must reveal it too")
    testing.expect_value(t, a.grep.scroll, before) // …and moved nothing yet

    // `mouse: off` is still off: no wake, no scroll.
    app.mouse_stand_down(&a)
    a.mouse_on = false
    app.mouse_wheel(&a, -1)
    testing.expect(t, !ui.hover_shown(app.ctx_of(&a)))
    testing.expect_value(t, a.grep.scroll, before)
}

// A trackpad reports fractions of a notch, and rounding each event up would make a gentle
// two-finger drag tear through the buffer. On a ±1 device it is the identity, so a clean run at
// this desk says nothing about it — hence a test.
@(test)
test_mouse_wheel_subnotch_accumulates :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 40 {
        append(&a.grep.hits, search.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)
    a.mouse_on = true
    a.mouse.known = true
    a.lay = LAY
    a.mouse.x, a.mouse.y = 700, 300

    // Four quarter-notches make one notch, and not before the fourth.
    for _ in 0 ..< 3 {
        app.mouse_wheel(&a, -0.25)
        testing.expect_value(t, a.grep.scroll, 0)
    }
    app.mouse_wheel(&a, -0.25)
    testing.expect_value(t, a.grep.scroll, ui.WHEEL_LINES)

    // The remainder carries its own sign, so reversing does not spend an unaccumulated notch.
    a.grep.scroll = 0
    app.mouse_wheel(&a, -0.5)
    testing.expect_value(t, a.grep.scroll, 0)
    app.mouse_wheel(&a, 0.5) // back the other way: the accumulator returns to zero
    testing.expect_value(t, a.grep.scroll, 0)
    app.mouse_wheel(&a, 0.5)
    app.mouse_wheel(&a, 0.5)
    testing.expect_value(t, a.grep.scroll, -ui.WHEEL_LINES) // one notch up
}

// Not a verb, so it must not stand the pointer down: Alt+click drops a cursor and needs the
// cursor on screen to aim, and Ctrl held is the filetree's chord bar.
@(test)
test_key_is_modifier :: proc(t: ^testing.T) {
    testing.expect(t, ui.key_is_modifier(glfw.KEY_LEFT_ALT))
    testing.expect(t, ui.key_is_modifier(glfw.KEY_RIGHT_CONTROL))
    testing.expect(t, ui.key_is_modifier(glfw.KEY_LEFT_SHIFT))
    testing.expect(t, ui.key_is_modifier(glfw.KEY_LEFT_SUPER))
    testing.expect(t, !ui.key_is_modifier(glfw.KEY_A))
    testing.expect(t, !ui.key_is_modifier(glfw.KEY_DOWN))
    testing.expect(t, !ui.key_is_modifier(glfw.KEY_ENTER))
}

// Through wheel_apply rather than past it. It used to call terminal_sel_move, so a notch moved
// the keyboard's COPY CURSOR and dragged a selection's anchor under it. Rule 10 says a wheel
// scrolls the view and never the selection, and this pane was the last place it did not hold.
@(test)
test_wheel_apply_terminal_scrolls_the_view :: proc(t: ^testing.T) {
    a := routing_app(.Terminal)
    term := new(pty.Terminal)
    defer free(term)
    pty.terminal_vt_init(term, 2, 20)
    defer pty.terminal_vt_destroy(term)
    pty.terminal_enable_scrollback(term)
    pty.terminal_feed(term, transmute([]u8)string("L0\r\nL1\r\nL2\r\nL3\r\nL4"))
    append(&a.terminals, term)
    defer delete(a.terminals)

    app.wheel_apply(&a, .Terminal, -1)
    testing.expect_value(t, pty.terminal_view_top(term), term.sb_total - ui.WHEEL_LINES)
    testing.expect(t, !term.sel_active, "a notch must not conjure a copy cursor")
    testing.expect(t, term.view_detached, "... it detaches the VIEW, like every other pane")

    app.wheel_apply(&a, .Terminal, 1)
    testing.expect_value(t, pty.terminal_view_top(term), term.sb_total) // the live bottom
}

// --- the horizontal axis --- Two ways in, one destination: Shift + the wheel, and a tilt wheel
// or trackpad arriving as GLFW's xoffset. Both must land on the buffer's column and nowhere
// else, and neither may take a chord another pane already means something by.

@(private = "file")
wheel_editor_app :: proc() -> app.App {
    a := routing_app(.FileTree)
    edit.editor_init(&a.editor)
    a.mouse_on = true
    a.mouse.known = true
    a.lay = LAY
    a.mouse.x, a.mouse.y = 100, 100 // over the editor pane
    // Room to scroll BOTH ways, so "the other axis did not move" is a claim the buffer could
    // have failed: a one-line buffer clamps the page to 0 regardless.
    buf: [dynamic]u8
    defer delete(buf)
    for _ in 0 ..< 100 {
        append(&buf, 'x', '\n')
    }
    edit.buffer_set_text(edit.editor_current(&a.editor), string(buf[:]))
    return a
}

// Shift picks the axis and only the axis: neither gesture may move the other.
@(test)
test_wheel_shift_scrolls_columns :: proc(t: ^testing.T) {
    a := wheel_editor_app()
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    app.mouse_wheel(&a, -1) // plain: the page moves…
    testing.expect_value(t, b.scroll, ui.WHEEL_LINES)
    testing.expect_value(t, b.hscroll, 0) // …and the column does not

    a.shift_held = true
    app.mouse_wheel(&a, -1) // Shift: the column moves…
    testing.expect_value(t, b.hscroll, ui.WHEEL_COLS)
    testing.expect_value(t, b.scroll, ui.WHEEL_LINES) // …and the page is left alone
    // The detach STAMP is buffer_test's: it comes from glfw.GetTime(), zero with no window.

    // Back the other way, bounded at home rather than running negative. The callback cannot
    // clamp the far end, but it can clamp this one.
    app.mouse_wheel(&a, 1)
    testing.expect_value(t, b.hscroll, 0)
    app.mouse_wheel(&a, 1)
    testing.expect_value(t, b.hscroll, 0)
}

// No modifier, and not negated: GLFW's xoffset is already positive for a scroll to the right.
@(test)
test_wheel_native_horizontal_axis :: proc(t: ^testing.T) {
    a := wheel_editor_app()
    defer edit.editor_destroy(&a.editor)
    b := edit.editor_current(&a.editor)

    app.mouse_wheel(&a, 0, 1) // positive x = right = later columns
    testing.expect_value(t, b.hscroll, ui.WHEEL_COLS)
    testing.expect_value(t, b.scroll, 0) // the page never moved

    app.mouse_wheel(&a, 0, -1)
    testing.expect_value(t, b.hscroll, 0)

    // Its own sub-notch accumulator: a trackpad reports both axes on a diagonal drift, and a
    // shared remainder would leak sideways travel into the page.
    for _ in 0 ..< 3 {
        app.mouse_wheel(&a, -0.25, 0.25)
        testing.expect_value(t, b.hscroll, 0)
        testing.expect_value(t, b.scroll, 0)
    }
    app.mouse_wheel(&a, -0.25, 0.25)
    testing.expect_value(t, b.hscroll, ui.WHEEL_COLS)
    testing.expect_value(t, b.scroll, ui.WHEEL_LINES)
}

// Only the editor scrolls sideways, so Shift+wheel over anything else is still the plain
// vertical gesture. Over a terminal that chord is already spoken for — "scroll my scrollback
// rather than forward it to the child" — and taking it would break that.
@(test)
test_wheel_shift_left_alone_off_the_editor :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 40 {
        append(&a.grep.hits, search.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)
    a.mouse_on = true
    a.mouse.known = true
    a.lay = LAY
    a.mouse.x, a.mouse.y = 700, 300 // over the aux pane
    a.shift_held = true

    app.mouse_wheel(&a, -1)
    testing.expect_value(t, a.grep.scroll, ui.WHEEL_LINES)

    // And a sideways notch moves nothing, rather than falling back to the page.
    before := a.grep.scroll
    app.mouse_wheel(&a, 0, 1)
    testing.expect_value(t, a.grep.scroll, before)
}
