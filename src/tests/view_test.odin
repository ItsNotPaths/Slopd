package tests

import app ".."
import "core:testing"

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
    testing.expect_value(t, a.focus, app.Focus.Editor) // zen lands in the editor
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
