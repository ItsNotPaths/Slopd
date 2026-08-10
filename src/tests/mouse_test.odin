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
    AUX_X :: 800 // inside the aux pane, right of the git sidebar/diff split at x=701
    cases := [?]struct {
        mode: app.AuxMode,
        want: app.Wheel_Target,
    } {
        {.FileTree, .List},
        {.Grep, .List},
        {.Config, .List},
        {.Procmon, .List},
        {.Terminal, .Terminal},
        {.Git, .Git_Diff}, // AUX_X lands in the diff column; the split is covered below
    }
    for c in cases {
        a := routing_app(c.mode)
        testing.expect_value(t, app.wheel_target(&a, LAY, AUX_X, 300), c.want)
    }
}

// The git pane's two columns, resolved through git_columns — the same proc draw_git lays
// out with, which is the point: a hit test and a paint that share one definition cannot
// drift. The hairline rule between them belongs to neither column.
@(test)
test_wheel_target_git_columns :: proc(t: ^testing.T) {
    a := routing_app(.Git)
    side, rule, diff := app.git_columns(LAY.aux, 1)

    // The split is 40% of the pane inside its 2px focus-ring inset, parted by a 1px rule:
    // a 498-wide pane insets to 494, of which the sidebar takes floor(494 * 0.40) = 197.
    testing.expect_value(t, side.x, 504)
    testing.expect_value(t, side.w, 197)
    testing.expect_value(t, rule.w, 1)
    testing.expect_value(t, diff.x, side.x + side.w + 1)
    testing.expect_value(t, side.w + rule.w + diff.w, LAY.aux.w - 4)

    testing.expect_value(t, app.wheel_target(&a, LAY, side.x, 300), app.Wheel_Target.Git_Sidebar)
    testing.expect_value(t, app.wheel_target(&a, LAY, side.x + side.w - 1, 300), app.Wheel_Target.Git_Sidebar)
    testing.expect_value(t, app.wheel_target(&a, LAY, rule.x, 300), app.Wheel_Target.None)
    testing.expect_value(t, app.wheel_target(&a, LAY, diff.x, 300), app.Wheel_Target.Git_Diff)
    testing.expect_value(t, app.wheel_target(&a, LAY, diff.x + diff.w - 1, 300), app.Wheel_Target.Git_Diff)

    // The pane's own inset is not part of either column, so a notch on the focus ring is
    // not a notch on the sidebar.
    testing.expect_value(t, app.wheel_target(&a, LAY, LAY.aux.x, 300), app.Wheel_Target.None)
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

// The list panes are "a cursor in a list", so a notch moves the SELECTION and the viewport
// follows under either scroll_mode — the resolution to MIDDLE re-deriving the top from the
// selection every frame. WHEEL_LINES rows per notch, clamped at both ends.
@(test)
test_wheel_apply_list_moves_selection :: proc(t: ^testing.T) {
    a := routing_app(.Grep)
    for i in 0 ..< 20 {
        append(&a.grep.hits, app.GrepHit{line = i + 1})
    }
    defer delete(a.grep.hits)

    app.wheel_apply(&a, .List, 1)
    testing.expect_value(t, a.grep.selected, app.WHEEL_LINES)
    app.wheel_apply(&a, .List, 2)
    testing.expect_value(t, a.grep.selected, 3 * app.WHEEL_LINES)
    app.wheel_apply(&a, .List, -1)
    testing.expect_value(t, a.grep.selected, 2 * app.WHEEL_LINES)

    app.wheel_apply(&a, .List, -100) // clamped at the first row, not negative
    testing.expect_value(t, a.grep.selected, 0)
    app.wheel_apply(&a, .List, 100) // clamped at the last row
    testing.expect_value(t, a.grep.selected, 19)
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
    testing.expect_value(t, a.grep.selected, 0)
    app.wheel_apply(&a, .None, 3)
    testing.expect_value(t, a.grep.selected, 0)
    app.wheel_apply(&a, .Media, 3) // pan/zoom is C8
    testing.expect_value(t, a.grep.selected, 0)
}

// The git sidebar scrolls under the pointer WITHOUT stealing region focus: git_move_sel is
// the keyboard path and refuses off-region, git_sidebar_move is the movement itself. A
// wheel over the sidebar while the diff holds focus must still move the sidebar.
@(test)
test_wheel_apply_git_sidebar_ignores_region_focus :: proc(t: ^testing.T) {
    a := routing_app(.Git)
    for i in 0 ..< 20 {
        append(&a.git.commits, app.Commit{})
    }
    defer delete(a.git.commits)
    a.git.section = .Log
    a.git.region = .Diff // focus is on the OTHER column

    app.wheel_apply(&a, .Git_Sidebar, 1)
    testing.expect_value(t, a.git.sel_log, app.WHEEL_LINES)
    testing.expect_value(t, a.git.region, app.GitRegion.Diff) // focus untouched

    // The keyboard path stays guarded — that asymmetry is the reason for the split.
    a.git.sel_log = 0
    app.git_move_sel(&a.git, 1)
    testing.expect_value(t, a.git.sel_log, 0)
}
