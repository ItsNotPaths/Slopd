package tests

import app "../slopd"
import clay "../../bindings/clay"
import "core:testing"
import "../gfx"
import "../ui"

// The context menu declared in Clay. Two claims no other surface makes: it is placed by the
// POINTER rather than the layout, and it paints OVER a pane rather than inside one — so its clip
// group opens after that pane's has closed, which is invisible in the boxes.
//
// With the 10x16 test font at scale 1: rows are 20px, a separator band 5px, the margin 8px
// either side. The menu below is 12 cells at its widest item, so 136px by 65px.

@(private = "file")
ITEMS := [?]ui.Menu_Item {
    {"Open", "Enter", .Open, true},
    {action = .None},
    {"Cut", "^x", .Cut, true},
    {"Paste", "^v", .Paste, false},
}

@(private = "file")
MENU :: gfx.Rect{10, 10, 136, 65}

@(private = "file")
menu_app :: proc(a: ^app.App, x: i32 = 10, y: i32 = 10) {
    a.scale = 1
    a.face = clay_test_face()
    a.mouse_on = true
    app.ctxmenu_open(a, .FileOps, ITEMS[:], x, y, {"/tmp", .Dir})
}

// The width comes from the WIDEST item, because a popup is sized to its contents before it is
// placed: the one place in the chrome that measures a string itself.
@(test)
test_ctxmenu_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    menu_app(&a)
    defer app.ctxmenu_destroy(&a)

    rect, row_h, sep_h, pad := app.ctxmenu_geom(&a.ctxmenu, 16, 10, 600, 300)
    testing.expect_value(t, rect, MENU)
    testing.expect_value(t, row_h, i32(20))
    testing.expect_value(t, sep_h, i32(5))
    testing.expect_value(t, pad, u16(8))
    testing.expect_value(t, ui.ctxmenu_width_cells(&a.ctxmenu), 12) // "Open" + 3 + "Enter"

    cmds := app.ctxmenu_layout(&a, f, 600, 300)

    box, ok := box_of(&cmds, clay.ID("cm_pane"), .Rectangle)
    testing.expect(t, ok, "the popup drew no background — it is not inside a panel()")
    testing.expect_value(t, box, MENU)

    // The highlighted row takes the selection bar; a disabled one takes nothing.
    first, fok := box_of(&cmds, clay.ID("cm_item", 0), .Rectangle)
    testing.expect(t, fok, "the selected item drew no bar")
    testing.expect_value(t, first, gfx.Rect{MENU.x, MENU.y, MENU.w, 20})
    _, dok := box_of(&cmds, clay.ID("cm_item", 3), .Rectangle)
    testing.expect(t, !dok, "a disabled item painted a background")

    // A band with a single top border, not a filled bar, so the rows either side are 20px
    // apart plus the 5px gap.
    cut, cok := box_of(&cmds, clay.ID("cm_item", 2), .Rectangle)
    testing.expect(t, !cok, "an unselected item painted a background")
    _ = cut

    // The label on the margin, the hint pushed right by the solver (rule 5).
    label, hint: gfx.Rect
    seen := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType != .Text {
            continue
        }
        if seen == 0 {
            label = ui.clay_rect(c.boundingBox)
        } else if seen == 1 {
            hint = ui.clay_rect(c.boundingBox)
        }
        seen += 1
    }
    testing.expect_value(t, label.x, MENU.x + 8)
    testing.expect_value(t, hint.x + hint.w, MENU.x + MENU.w - 8) // ends on the far margin
    testing.expect_value(t, seen, 6) // three items of label + hint; the separator has none
}

// The occlusion claim. A popup declared in the flow of a pane lands inside that pane's scissor
// group, where the renderer composites quads UNDER glyphs, so its backdrop would paint behind
// the names it covers. `floating` avoids it: a floating element is its own layout root, and Clay
// emits roots in order.
@(test)
test_ctxmenu_paints_over_a_pane :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    menu_app(&a, 100, 100)
    defer app.ctxmenu_destroy(&a)
    a.tree.dir = "/tmp/ft"
    for i in 0 ..< 8 {
        append(&a.tree.entries, app.FileEntry{name = "e", path = "/tmp/ft/e", display = "e"})
    }
    defer delete(a.tree.entries)

    // A pane and the popup in one tree, in window_frame's order.
    app.clay_window_begin(600, 300)
    if clay.UI(clay.ID(app.WIN_ROOT))(app.clay_window_root(600, 300)) {
        app.filetree_declare(app.ctx_of(&a), &a, f, gfx.Rect{0, 0, 300, 300}, 0, 0)
        app.ctxmenu_declare(app.ctx_of(&a), &a.ctxmenu, f, 600, 300)
    }
    cmds := clay.EndLayout(0)

    // Tracking clip depth: the menu's backdrop must be inside a group that opened after every
    // one of the pane's closed. Found by CONTAINMENT rather than id, since Clay derives a
    // scissor's id from the element that asked for one.
    depth, open_groups_at_menu, menu_seen := 0, -1, false
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        #partial switch c.commandType {
        case .ScissorStart:
            depth += 1
        case .ScissorEnd:
            depth -= 1
        case .Rectangle:
            if c.id == clay.ID("cm_pane").id {
                menu_seen = true
                open_groups_at_menu = depth
            }
        }
    }
    testing.expect(t, menu_seen, "the popup emitted no backdrop at all")
    testing.expect_value(t, open_groups_at_menu, 1) // its own group, and only its own

    // And nothing opens a group after it: the popup is painted last.
    after := 0
    passed := false
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType == .Rectangle && c.id == clay.ID("cm_pane").id {
            passed = true
            continue
        }
        if passed && c.commandType == .ScissorStart {
            after += 1
        }
    }
    testing.expect_value(t, after, 0)
}

// A single press activates, a context menu being already the second half of a gesture, and a
// press anywhere inside the box is swallowed rather than reaching the pane under it.
@(test)
test_ctxmenu_hit_and_click :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    menu_app(&a)
    defer app.ctxmenu_destroy(&a)
    a.ctxmenu.rect = MENU

    _ = app.ctxmenu_layout(&a, f, 600, 300) // frame 1: boxes for the pointer
    clay.SetPointerState({50, 45}, false) // the third row
    _ = app.ctxmenu_layout(&a, f, 600, 300)
    testing.expect_value(t, app.ctxmenu_hit(&a.ctxmenu), 2)

    // The separator band is dead space, as chrome rows are everywhere else.
    clay.SetPointerState({50, 32}, false)
    _ = app.ctxmenu_layout(&a, f, 600, 300)
    testing.expect_value(t, app.ctxmenu_hit(&a.ctxmenu), -1)

    // A press on a separator is claimed anyway, swallowed rather than passed down.
    a.mouse.click = true
    a.mouse.click_count = 1
    a.mouse.x, a.mouse.y = 50, 32
    app.ctxmenu_click(&a, -1)
    testing.expect(t, !a.mouse.click, "a press inside the popup must not fall through to a pane")
    testing.expect(t, app.ctxmenu_shown(&a), "a press on a separator must not close the menu")

    // A live item runs on the FIRST press and closes the menu with it.
    a.mouse.click = true
    a.mouse.x, a.mouse.y = 50, 45
    app.ctxmenu_click(&a, 2)
    testing.expect(t, !app.ctxmenu_shown(&a), "a single press on an item did not activate it")

    // A press outside the box is not the menu's: ctxmenu_dismiss_click has it, a frame earlier
    // and before any pane can.
    menu_app(&a)
    a.ctxmenu.rect = MENU
    a.mouse.click = true
    a.mouse.x, a.mouse.y = 400, 200
    app.ctxmenu_click(&a, -1)
    testing.expect(t, a.mouse.click, "a press outside the popup must be left for the dismissal")
}
