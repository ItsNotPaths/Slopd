package tests

import app "../slopd"
import "core:testing"
import "../ui"

// Split: both panes are always on screen regardless of focus.
@(test)
test_view_split_shows_both :: proc(t: ^testing.T) {
    a: app.App // zero value: view = .Split
    a.focus = .Editor
    v := app.panes_visible(&a)
    testing.expect(t, v.editor && v.aux)
    a.focus = .Aux
    v = app.panes_visible(&a)
    testing.expect(t, v.editor && v.aux)
}

// Zen: the editor is always present; the aux pane is shown only while focused, so
// focusing the editor hides it and any aux-focus trigger brings it back.
@(test)
test_view_zen_aux_follows_focus :: proc(t: ^testing.T) {
    a: app.App
    a.view = .Zen

    app.set_focus(&a, .Editor)
    v := app.panes_visible(&a)
    testing.expect(t, v.editor && !v.aux) // editor full-width, aux retracted

    app.set_focus(&a, .Aux) // e.g. Alt+Right / a goto command
    v = app.panes_visible(&a)
    testing.expect(t, v.editor && v.aux) // aux slides back in
}

// The focus ring: drawn only when two panes are on screen AND the pane in question holds
// focus — with one pane up it is a border around the whole window, which says nothing.
//
// The Zen editor is the case worth pinning, because `vis` alone gets it wrong. Focusing the
// editor in Zen starts the aux pane RETRACTING, and for the length of that slide `vis` still
// reports both panes while the editor grows toward the full width — so a ring keyed on
// visibility flashes a full-window outline for a few frames. Reported from the machine, and
// it is the reason focus_ring exists rather than an inline `vis.editor && vis.aux`.
@(test)
test_focus_ring_never_rings_the_zen_editor :: proc(t: ^testing.T) {
    both :: app.Pane_Vis{editor = true, aux = true}
    lone :: app.Pane_Vis{editor = true, aux = false}

    a: app.App // Split
    a.focus = .Editor
    testing.expect(t, app.focus_ring(&a, both, .Editor), "Split: the focused pane must ring")
    testing.expect(t, !app.focus_ring(&a, both, .Aux), "Split: the unfocused pane must not ring")

    // Mid-retraction in Zen: both panes visible, the editor focused and nearly full width.
    a.view = .Zen
    testing.expect(t, !app.focus_ring(&a, both, .Editor), "the Zen editor ringed the whole window")

    // The aux pane's own ring survives — sliding IN, it is what says the arrows go there.
    a.focus = .Aux
    testing.expect(t, app.focus_ring(&a, both, .Aux), "the Zen aux pane lost its ring")

    // Settled Zen (aux retracted) and Full both leave one pane up: no ring at all.
    a.focus = .Editor
    testing.expect(t, !app.focus_ring(&a, lone, .Editor), "a lone pane ringed the window")
    a.view = .Full
    testing.expect(t, !app.focus_ring(&a, lone, .Editor), "Full ringed the window")
}

// Full: exactly one surface fills the window, chosen by focus — focusing the editor
// shows the editor, focusing the aux shows the aux pane (Alt+E / Alt+T etc. swap).
@(test)
test_view_full_swaps_surface :: proc(t: ^testing.T) {
    a: app.App
    a.view = .Full

    app.set_focus(&a, .Editor) // Alt+E: editor fills the window
    v := app.panes_visible(&a)
    testing.expect(t, v.editor && !v.aux)

    app.set_focus(&a, .Aux) // Alt+T/G/…: the aux surface fills the window instead
    v = app.panes_visible(&a)
    testing.expect(t, !v.editor && v.aux)
}

// `zen` / `zm` toggles in and out of Split, and switches into Zen from any view
// (including Full). `full` / `fm` toggles Full, keeping whichever surface is current.
@(test)
test_view_toggles :: proc(t: ^testing.T) {
    a: app.App // .Split
    a.focus = .Aux // browsing the aux pane when zen is invoked
    app.view_toggle_zen(&a)
    testing.expect_value(t, a.view, app.View.Zen)
    testing.expect_value(t, a.focus, ui.Focus.Editor) // zen lands in the editor
    app.view_toggle_zen(&a)
    testing.expect_value(t, a.view, app.View.Split)

    app.view_toggle_full(&a)
    testing.expect_value(t, a.view, app.View.Full)
    app.view_toggle_zen(&a) // from Full -> Zen
    testing.expect_value(t, a.view, app.View.Zen)
    app.view_toggle_full(&a) // from Zen -> Full
    testing.expect_value(t, a.view, app.View.Full)
    app.view_toggle_full(&a) // Full -> Split
    testing.expect_value(t, a.view, app.View.Split)
}

// `normal` / `nm` names the arrangement instead of flipping a bit, which is the whole reason
// it exists: the two toggles only lead back to Split from their OWN mode, so getting out
// otherwise means remembering which one you are in. Asserted from all three views, including
// the two crossed cases that make a toggle the wrong tool — `zen` from Full lands in Zen and
// `full` from Zen lands in Full, neither of which is where the user asking for normal wants
// to be.
@(test)
test_view_normal_names_the_arrangement :: proc(t: ^testing.T) {
    a: app.App // .Split
    a.focus = .Aux

    app.view_normal(&a)
    testing.expect_value(t, a.view, app.View.Split) // idempotent from Split
    testing.expect_value(t, a.focus, ui.Focus.Aux) // and focus is KEPT, unlike zen's exit

    a.view = .Zen
    app.view_normal(&a)
    testing.expect_value(t, a.view, app.View.Split)
    testing.expect_value(t, a.focus, ui.Focus.Aux)

    a.view = .Full
    app.view_normal(&a)
    testing.expect_value(t, a.view, app.View.Split)

    // Both panes are on screen afterwards, whichever one holds the arrows — which is the
    // thing "normal" actually promises.
    v := app.panes_visible(&a)
    testing.expect(t, v.editor && v.aux, "normal mode must show both panes")
}
