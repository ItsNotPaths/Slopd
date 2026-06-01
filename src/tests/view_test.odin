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

// Util: no editor ever, the aux pane fills the window, and focus is pinned to it
// even when something asks to focus the (absent) editor.
@(test)
test_view_util_pins_aux :: proc(t: ^testing.T) {
    a: app.App
    a.view = .Util
    a.focus = .Aux

    v := app.panes_visible(&a)
    testing.expect(t, !v.editor && v.aux)

    app.set_focus(&a, .Editor) // open_file etc. must not reveal a missing editor
    testing.expect_value(t, a.focus, app.Focus.Aux)
    v = app.panes_visible(&a)
    testing.expect(t, !v.editor && v.aux)
}

// `zen` / `zm` toggles in and out of Split; it is a no-op under the Util launch mode.
@(test)
test_view_toggle_zen :: proc(t: ^testing.T) {
    a: app.App // .Split
    a.focus = .Aux // browsing the aux pane when zen is invoked
    app.view_toggle_zen(&a)
    testing.expect_value(t, a.view, app.View.Zen)
    testing.expect_value(t, a.focus, app.Focus.Editor) // zen lands in the editor
    app.view_toggle_zen(&a)
    testing.expect_value(t, a.view, app.View.Split)

    a.view = .Util
    app.view_toggle_zen(&a) // launch mode, not a runtime toggle
    testing.expect_value(t, a.view, app.View.Util)
}
