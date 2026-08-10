package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// C8a: the window frame. One tree per frame, the panes floating inside it at the rects
// compute_layout chose.
//
// The claim worth testing is not "two panes fit on a screen" — it is the one that was FALSE
// for five checkpoints and is what the whole checkpoint exists to buy: **every pane's
// PointerOver answers about that pane.** Until here Clay held one tree and each pane declared
// its own, so a frame ended holding whichever pane went last (the aux one), and the editor
// got `false` for every element it owned no matter where the pointer was. That was rule 11 in
// docs/clay-refactor.md, and the tests below are its obituary: if someone ever splits the
// declaration back apart, the second one fails immediately and by name.
//
// The layout used throughout is a 500x300 window split by a 2px gutter — editor {0,0,249,280},
// aux {251,0,249,280}, strip {0,280,500,20} — which is compute_layout's own arrangement at
// a.split = 0.5, written out rather than computed so the boxes below are hand-derived.

@(private = "file")
WIN_W :: 500
@(private = "file")
WIN_H :: 300
@(private = "file")
ED_PANE :: app.Rect{0, 0, 249, 280}
@(private = "file")
ED_AREA :: app.Rect{2, 2, 245, 276} // inset by the 2px focus ring
@(private = "file")
AUX_PANE :: app.Rect{251, 0, 249, 280}
@(private = "file")
AUX_AREA :: app.Rect{253, 2, 245, 276}
@(private = "file")
FT_ROW_H :: 18

// The two panes declared into ONE tree, in window_frame's order (editor first, aux second).
// The declarations are the app's own procs; only the pair of calls is written out here,
// which is what window_frame's aux_mode switch does.
@(private = "file")
two_panes :: proc(a: ^app.App, f: ^app.Font, v: app.Editor_View) {
    app.clay_window_begin(WIN_W, WIN_H)
    if clay.UI(clay.ID(app.WIN_ROOT))(app.clay_window_root(WIN_W, WIN_H)) {
        app.editor_declare(a, f, ED_PANE, v, 0)
        app.filetree_declare(a, f, AUX_PANE)
    }
}

@(private = "file")
fixture :: proc(a: ^app.App, f: ^app.Font) -> app.Editor_View {
    app.editor_init(&a.editor)
    a.scale = 1
    a.mouse_on = true
    a.mouse.known = true
    app.buffer_set_text(app.editor_current(&a.editor), "alpha\nbravo\ncharlie")

    a.tree.dir = "/tmp/ft"
    for _ in 0 ..< 8 {
        append(&a.tree.entries, app.FileEntry{name = "e", path = "/tmp/ft/e", display = "e"})
    }

    area, row_h, rows := app.editor_geom(ED_PANE, 1, f.line_height)
    return app.editor_view(app.editor_current(&a.editor), f, area, row_h, rows, 0)
}

@(private = "file")
teardown :: proc(a: ^app.App) {
    app.editor_destroy(&a.editor)
    delete(a.tree.entries)
}

// Both panes land where compute_layout put them, in one tree. This is the floating
// attachment doing the job the "full-window container padded by the pane's origin" trick used
// to do one pane at a time — and the reason the trick had to go is the very next test, not
// this one: two padded full-window roots would have been laid out as SIBLINGS, the second
// one starting off the right edge of the screen.
@(test)
test_window_places_both_panes :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    v := fixture(&a, &f)
    defer teardown(&a)

    two_panes(&a, &f, v)
    cmds := clay.EndLayout(0)

    ed_clip, aux_clip: app.Rect
    custom: app.Rect
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := app.clay_rect(c.boundingBox)
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
    testing.expect_value(t, custom, ED_AREA) // the editor's text surface, inside its own clip

    // The panes do not overlap, which is what makes Passthrough the right capture mode for
    // them: there is no pixel two of them could both claim.
    testing.expect(t, ED_AREA.x + ED_AREA.w <= AUX_AREA.x, "the panes overlap")
}

// Each pane's clip group CLOSES before the next one opens. This is the assertion that costs
// nothing and would have cost an afternoon: clay_paint keeps one clip stack and INTERSECTS on
// nesting (a GL scissor is a single rect), so two pane groups that interleaved would leave the
// aux pane clipped to `editor ∩ aux` — which is empty. The pane would paint absolutely
// nothing, in a build where every box in the command list is correct.
//
// It also pins the paint ORDER the overlays are going to need (C8c): a floating element's
// whole subtree is emitted before the next floating sibling's, so declaration order is paint
// order and a higher zIndex really does land on top.
@(test)
test_window_pane_clips_do_not_interleave :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

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
    testing.expect_value(t, depth, 0) // every group balanced, or the bridge latches a scissor
    testing.expect(t, seen_ed && seen_ft, "a pane declared no clip of its own")
}

// THE POINT OF C8a. Both panes are in one tree, so both answer — and each answers only about
// itself. Before this checkpoint the first two assertions were false for every pointer
// position in the program.
@(test)
test_window_one_tree_answers_for_every_pane :: proc(t: ^testing.T) {
    raw := clay_test_context(WIN_W, WIN_H)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    v := fixture(&a, &f)
    defer teardown(&a)

    two_panes(&a, &f, v) // frame 1: gives Clay boxes to hit-test against
    _ = clay.EndLayout(0)

    // Over the editor's second text row. The aux pane is declared AFTER the editor, which is
    // exactly the arrangement that used to make this `false`.
    clay.SetPointerState({100, f32(ED_AREA.y + 20)}, false)
    two_panes(&a, &f, v)
    _ = clay.EndLayout(0)
    testing.expect(t, clay.PointerOver(clay.ID("ed_pane")), "the editor cannot see its own pane")
    testing.expect(t, clay.PointerOver(clay.ID("ed_body")), "the editor cannot see its own body")
    testing.expect(t, !clay.PointerOver(clay.ID("ft_pane")), "the aux pane claimed a pointer over the editor")

    // And over the filetree's third entry row — one header row plus two rows down from the
    // top of the aux content area. The list panes were always right about this; what is new
    // is that they are right for a reason rather than by draw order.
    clay.SetPointerState({f32(AUX_AREA.x + 20), f32(AUX_AREA.y + 2 * FT_ROW_H + 4)}, false)
    two_panes(&a, &f, v)
    _ = clay.EndLayout(0)
    testing.expect(t, clay.PointerOver(clay.ID("ft_row", 1)), "the filetree lost its own row")
    testing.expect(t, !clay.PointerOver(clay.ID("ft_row", 0)), "the hit spilled onto the row above")
    testing.expect(t, !clay.PointerOver(clay.ID("ed_pane")), "the editor claimed a pointer over the aux pane")

    // The gutter belongs to neither: compute_layout leaves 2px of window background between
    // them, and a pane that captured the pointer would have swallowed it.
    clay.SetPointerState({f32(ED_AREA.x + ED_AREA.w + 1), 100}, false)
    two_panes(&a, &f, v)
    _ = clay.EndLayout(0)
    testing.expect(t, !clay.PointerOver(clay.ID("ed_pane")), "the editor claimed the gutter")
    testing.expect(t, !clay.PointerOver(clay.ID("ft_pane")), "the aux pane claimed the gutter")
}
