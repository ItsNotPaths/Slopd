package tests

import app "../slopd"
import clay "../../bindings/clay"
import "core:testing"
import "../gfx"
import "../ui"
import "../edit"

// The window frame: one tree per frame, the panes floating inside it at the rects
// compute_layout chose.
//
// The claim worth testing is that every pane's PointerOver answers about THAT pane. Clay holds
// one tree, so while each pane declared its own a frame ended holding whichever went last and
// the editor got `false` for every element it owned. Split the declaration back apart and the
// second test below fails by name.
//
// The layout throughout is a 500x300 window split by a 2px gutter — editor {0,0,249,280}, aux
// {251,0,249,280}, strip {0,280,500,20} — written out rather than computed.

@(private = "file")
WIN_W :: 500
@(private = "file")
WIN_H :: 300
@(private = "file")
ED_PANE :: gfx.Rect{0, 0, 249, 280}
@(private = "file")
ED_AREA :: gfx.Rect{2, 2, 245, 276} // inset by the 2px focus ring
@(private = "file")
AUX_PANE :: gfx.Rect{251, 0, 249, 280}
@(private = "file")
AUX_AREA :: gfx.Rect{253, 2, 245, 276}
@(private = "file")
FT_ROW_H :: 18

// Into ONE tree, in window_frame's order. The declarations are the app's own procs; only the
// pair of calls is written out, which is what window_frame's aux_mode switch does.
@(private = "file")
two_panes :: proc(a: ^app.App, f: ^gfx.Font, v: app.Editor_View) {
    app.clay_window_begin(WIN_W, WIN_H)
    if clay.UI(clay.ID(app.WIN_ROOT))(app.clay_window_root(WIN_W, WIN_H)) {
        app.editor_declare(a, f, ED_PANE, v, 0)
        app.filetree_declare(app.ctx_of(a), a, f, AUX_PANE, a.tree.scroll, 0, 0)
    }
}

@(private = "file")
fixture :: proc(a: ^app.App, f: ^gfx.Font) -> app.Editor_View {
    edit.editor_init(&a.editor)
    a.scale = 1
    a.mouse_on = true
    a.mouse.known = true
    edit.buffer_set_text(edit.editor_current(&a.editor), "alpha\nbravo\ncharlie")

    a.tree.dir = "/tmp/ft"
    for _ in 0 ..< 8 {
        append(&a.tree.entries, app.FileEntry{name = "e", path = "/tmp/ft/e", display = "e"})
    }

    area, row_h, rows := app.editor_geom(ED_PANE, 1, f.line_height)
    return app.editor_view(edit.editor_current(&a.editor), f, area, row_h, rows, 0)
}

@(private = "file")
teardown :: proc(a: ^app.App) {
    edit.editor_destroy(&a.editor)
    delete(a.tree.entries)
}

// The floating attachment doing the job the "full-window container padded by the pane's origin"
// trick did one pane at a time. The trick had to go because two padded full-window roots would
// have laid out as SIBLINGS, the second starting off the right edge.
@(test)
test_window_places_both_panes :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    v := fixture(&a, &f)
    defer teardown(&a)

    two_panes(&a, &f, v)
    cmds := clay.EndLayout(0)

    ed_clip, aux_clip: gfx.Rect
    custom: gfx.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := ui.clay_rect(c.boundingBox)
        #partial switch c.commandType {
        case .ScissorStart:
            if c.id == clay.ID("ed_pane").id {
                ed_clip = r
            } else if c.id == clay.ID("ft_pane").id {
                aux_clip = r
            }
        case .Custom:
            custom = r
        }
    }

    testing.expect_value(t, ed_clip, ED_AREA)
    testing.expect_value(t, aux_clip, AUX_AREA)
    testing.expect_value(t, custom, ED_AREA) // the editor's text surface, inside its clip

    // The panes do not overlap, which is what makes Passthrough right for them.
    testing.expect(t, ED_AREA.x + ED_AREA.w <= AUX_AREA.x, "the panes overlap")
}

// Each pane's clip group closes before the next opens. clay_paint keeps one clip stack and
// intersects on nesting, so two interleaved pane groups would clip the aux pane to
// `editor ∩ aux` — empty — in a build where every box is correct.
//
// It also pins the paint ORDER the overlays need: a floating element's whole subtree is emitted
// before the next floating sibling's.
@(test)
test_window_pane_clips_do_not_interleave :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    v := fixture(&a, &f)
    defer teardown(&a)

    two_panes(&a, &f, v)
    cmds := clay.EndLayout(0)

    depth := 0
    seen_ed, seen_ft := false, false
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .ScissorStart:
            if c.id == clay.ID("ed_pane").id || c.id == clay.ID("ft_pane").id {
                testing.expectf(t, depth == 0, "a pane clip opened inside another (depth %d)", depth)
                seen_ed ||= c.id == clay.ID("ed_pane").id
                seen_ft ||= c.id == clay.ID("ft_pane").id
            }
            depth += 1
        case .ScissorEnd:
            depth -= 1
        }
    }
    testing.expect_value(t, depth, 0) // balanced, or the bridge latches a scissor
    testing.expect(t, seen_ed && seen_ft, "a pane declared no clip of its own")
}

// Both panes in one tree, so both answer, and each only about itself. The first two assertions
// used to be false for every pointer position in the program.
@(test)
test_window_one_tree_answers_for_every_pane :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    v := fixture(&a, &f)
    defer teardown(&a)

    two_panes(&a, &f, v) // frame 1: boxes to hit-test against
    _ = clay.EndLayout(0)

    // Over the editor's second text row. The aux pane is declared AFTER the editor, which is
    // exactly the arrangement that used to make this `false`.
    clay.SetPointerState({100, f32(ED_AREA.y + 20)}, false)
    two_panes(&a, &f, v)
    _ = clay.EndLayout(0)
    testing.expect(t, clay.PointerOver(clay.ID("ed_pane")), "the editor cannot see its own pane")
    testing.expect(t, clay.PointerOver(clay.ID("ed_body")), "the editor cannot see its own body")
    testing.expect(t, !clay.PointerOver(clay.ID("ft_pane")), "the aux pane claimed a pointer over the editor")

    // The filetree's third entry row. The list panes were always right about this; what is new
    // is that they are right for a reason rather than by draw order.
    clay.SetPointerState({f32(AUX_AREA.x + 20), f32(AUX_AREA.y + 2 * FT_ROW_H + 4)}, false)
    two_panes(&a, &f, v)
    _ = clay.EndLayout(0)
    testing.expect(t, clay.PointerOver(clay.ID("ft_row", 1)), "the filetree lost its own row")
    testing.expect(t, !clay.PointerOver(clay.ID("ft_row", 0)), "the hit spilled onto the row above")
    testing.expect(t, !clay.PointerOver(clay.ID("ed_pane")), "the editor claimed a pointer over the aux pane")

    // The gutter belongs to neither, and a pane that captured the pointer would swallow it.
    clay.SetPointerState({f32(ED_AREA.x + ED_AREA.w + 1), 100}, false)
    two_panes(&a, &f, v)
    _ = clay.EndLayout(0)
    testing.expect(t, !clay.PointerOver(clay.ID("ed_pane")), "the editor claimed the gutter")
    testing.expect(t, !clay.PointerOver(clay.ID("ft_pane")), "the aux pane claimed the gutter")
}

// ---------------------------------------------------------------------------------------
// The window's own pointer verbs: the divider drag and focus-follows-click
// ---------------------------------------------------------------------------------------
//
// Neither belongs to a pane. The divider is the GUTTER, the one strip no pane owns, and focus
// is a property of the arrangement with set_focus as its single choke point. Both run BEFORE
// compute_layout, because what they write is what it reads.
//
// The layout is the one at the top of this file, so the divider's centre is x = 250 and the
// gutter is x[249, 251).

@(private = "file")
LAY :: app.Layout {
    editor = ED_PANE,
    aux    = AUX_PANE,
    strip  = {0, 280, WIN_W, 20},
    gutter = 2,
    vis    = {editor = true, aux = true},
}

// app_init is deliberately not called: nothing here needs a project root, and set_focus on a
// bare App is the thing under test.
@(private = "file")
pointing_app :: proc(x, y: i32) -> app.App {
    a := app.App{scale = 1, mouse_on = true, split = 0.5, lay = LAY}
    a.mouse.known = true
    a.mouse.down = true
    a.mouse.click = true
    a.mouse.click_count = 1
    a.mouse.x, a.mouse.y = x, y
    return a
}

// The 2px gutter widened by DIVIDER_GRAB either side, so it can be hit at all. The widening is
// why the divider gets first refusal on a press: it overlaps both panes' focus-ring insets, and
// asking second would leave it reachable only in the two pixels it was widened to escape.
@(test)
test_divider_band_straddles_the_gutter :: proc(t: ^testing.T) {
    band, ok := app.divider_band(LAY, 1)
    testing.expect(t, ok, "two panes side by side have a divider")
    testing.expect_value(t, band, gfx.Rect{245, 0, 10, 280}) // 249 - 4, 2 + 2*4
    testing.expect(t, band.x < ED_PANE.x + ED_PANE.w, "the band must reach into the editor's edge")
    testing.expect(t, band.x + band.w > AUX_PANE.x, "and into the aux pane's")

    // The DPI scale is in it, or a 4px grab on a HiDPI screen is 2 logical pixels of target.
    hidpi, _ := app.divider_band(LAY, 2)
    testing.expect_value(t, hidpi.w, 2 + 2 * 8)
}

// The gap IS the predicate, over three arrangements. Zen is the one worth stating: its panes
// touch, so there is no divider and the boundary belongs to the editor's own text.
@(test)
test_divider_band_needs_two_panes_and_a_gutter :: proc(t: ^testing.T) {
    zen := LAY // the aux pane docked over the editor: adjacent, no gap
    zen.editor = {0, 0, 251, 280}
    zen.aux = {251, 0, 249, 280}
    _, ok := app.divider_band(zen, 1)
    testing.expect(t, !ok, "panes that touch have no divider between them")

    lone := LAY
    lone.aux = {}
    lone.vis = {editor = true, aux = false}
    _, ok = app.divider_band(lone, 1)
    testing.expect(t, !ok, "one visible pane has nothing to divide")

    _, ok = app.divider_band(app.Layout{}, 1)
    testing.expect(t, !ok, "before the first frame there is no layout at all")
}

// A press in the band captures the divider and CLAIMS the press, so neither the pane whose edge
// it overlaps nor focus-follows-click acts on it. The split then follows the pointer snapped
// rather than eased. Dropping the `a.split_anim` re-aim leaves compute_layout starting an ease
// on the next frame, and the last expect fails.
@(test)
test_divider_drag_moves_the_split :: proc(t: ^testing.T) {
    a := pointing_app(250, 140) // dead centre of the gutter

    app.divider_click(&a, a.lay)
    testing.expect(t, ui.drag_live(app.ctx_of(&a), .Split, 0), "a press in the band must capture")
    testing.expect(t, !a.mouse.click, "and must claim the press")

    // Inside the threshold: still a click, which on a divider does nothing.
    a.mouse.x = 252
    app.divider_drag(&a, WIN_W)
    testing.expect_value(t, a.split, f32(0.5))

    a.mouse.x = 350
    app.divider_drag(&a, WIN_W)
    testing.expect_value(t, a.split, f32(0.7))
    testing.expect_value(t, a.split_anim.to, a.split) // snapped: no ease pending
    testing.expect(t, a.split_anim.duration <= 0, "the divider must not trail the pointer")
}

// Clamped to Alt+[ / Alt+]'s range, because it is the same setting.
@(test)
test_divider_drag_clamps_like_the_keyboard :: proc(t: ^testing.T) {
    testing.expect_value(t, app.divider_split_at(0, WIN_W), f32(app.SPLIT_MIN))
    testing.expect_value(t, app.divider_split_at(WIN_W, WIN_W), f32(app.SPLIT_MAX))
    testing.expect_value(t, app.divider_split_at(250, WIN_W), f32(0.5))
    testing.expect_value(t, app.divider_split_at(250, 0), f32(app.SPLIT_MIN)) // no window yet

    a := pointing_app(250, 140)
    app.divider_click(&a, a.lay)
    a.mouse.x = -400 // off the left of the window
    app.divider_drag(&a, WIN_W)
    testing.expect_value(t, a.split, f32(app.SPLIT_MIN))
}

// Left pending for whoever else is drawing, as every pane's click verb does — and the reason a
// press in the middle of the editor is not eaten by a resize gesture.
@(test)
test_divider_ignores_presses_elsewhere :: proc(t: ^testing.T) {
    a := pointing_app(100, 140)
    app.divider_click(&a, a.lay)
    testing.expect(t, a.mouse.click, "a press over a pane must stay pending")
    testing.expect_value(t, a.drag.kind, ui.Drag_Kind.None)

    b := pointing_app(250, 140)
    b.mouse_on = false
    app.divider_click(&b, b.lay)
    testing.expect_value(t, b.drag.kind, ui.Drag_Kind.None)

    // With no drag held, the per-frame verb writes nothing.
    c := pointing_app(400, 140)
    app.divider_drag(&c, WIN_W)
    testing.expect_value(t, c.split, f32(0.5))
}

// For every pane at once, because doing it for one would have made one pane grab focus while
// five did not.
//
// The press is not consumed, which is the half worth pinning: clicking a filetree row focuses
// the tree AND selects the row, in that order, in one frame.
@(test)
test_focus_follows_click_without_eating_it :: proc(t: ^testing.T) {
    a := pointing_app(300, 140) // over the aux pane, focus in the editor
    testing.expect_value(t, a.focus, ui.Focus.Editor)

    app.focus_follows_click(&a, a.lay)
    testing.expect_value(t, a.focus, ui.Focus.Aux)
    testing.expect(t, a.mouse.click, "the pane still has to claim its own row")

    a.mouse.x = 100 // and back over the editor
    app.focus_follows_click(&a, a.lay)
    testing.expect_value(t, a.focus, ui.Focus.Editor)
}

// The gutter (which keeps a resize from stealing focus), the strip, off-window, and a pane that
// already has focus. The last is not thrift: set_focus re-stats the focused document, and firing
// that on every click inside the focused pane would put a disk stat on the click path.
@(test)
test_focus_follows_click_only_where_a_pane_is :: proc(t: ^testing.T) {
    who, ok := app.click_focus_target(LAY, 250, 140)
    testing.expect(t, !ok, "the gutter belongs to neither pane")
    who, ok = app.click_focus_target(LAY, 100, 290)
    testing.expect(t, !ok, "nor does the status strip")
    who, ok = app.click_focus_target(LAY, 900, 140)
    testing.expect(t, !ok, "nor does off-window")

    who, ok = app.click_focus_target(LAY, 300, 140)
    testing.expect(t, ok && who == .Aux, "a press over the aux pane names it")

    a := pointing_app(300, 140)
    a.mouse.click = false
    app.focus_follows_click(&a, a.lay)
    testing.expect_value(t, a.focus, ui.Focus.Editor)

    // A hidden pane carries a zero rect, so it cannot be clicked into.
    lone := LAY
    lone.aux = {}
    lone.vis = {editor = true, aux = false}
    _, ok = app.click_focus_target(lone, 300, 140)
    testing.expect(t, !ok, "a hidden pane has no rect to press")
}

// In the order window_pointer runs them: the divider takes its press FIRST, so a resize near the
// boundary cannot also move focus. Without it, the band's overlap would focus the aux pane on
// every grab.
@(test)
test_window_pointer_divider_outranks_focus :: proc(t: ^testing.T) {
    a := pointing_app(254, 140) // inside the band, and inside the aux pane's rect
    testing.expect(t, gfx.rect_hit(AUX_PANE, 254, 140), "the fixture must be over the aux pane")

    app.window_pointer(&a, WIN_W)
    testing.expect(t, ui.drag_live(app.ctx_of(&a), .Split, 0), "the divider takes the press")
    testing.expect_value(t, a.focus, ui.Focus.Editor) // unmoved: the press was spent

    // Two pixels further in it is an ordinary press on the pane, which does move focus.
    b := pointing_app(256, 140)
    app.window_pointer(&b, WIN_W)
    testing.expect_value(t, b.drag.kind, ui.Drag_Kind.None)
    testing.expect_value(t, b.focus, ui.Focus.Aux)
    testing.expect(t, b.mouse.click, "and the pane's own verb still gets it")
}
