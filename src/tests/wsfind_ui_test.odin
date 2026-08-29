package tests

import app "../slopd"
import clay "../../bindings/clay"
import "core:testing"
import "../txt"
import "../gfx"
import "../ui"
import "../search"

// The workspace prompt declared in Clay, under BOTH faces of the file pane. The claim is the one
// the shared UI half exists for: the same prompt and the same rows come out of the `ls` header
// and out of the browser's path region, in the box each face hands them — and the listing they
// cover is not declared at all, so nothing behind them can be clicked.
//
// Both panes are {0, 0, 600, 300} at scale 1 with the 10x16 test font, insetting to
// {2, 2, 596, 296}. `ls`: a one-row header, then the rows. Browser: a one-row bar with
// three-cell buttons, and a 160px sidebar.

@(private = "file")
WPANE :: gfx.Rect{0, 0, 600, 300}
@(private = "file")
WAREA :: gfx.Rect{2, 2, 596, 296}
@(private = "file")
WROW :: 16
@(private = "file")
WBAR :: 16
@(private = "file")
WBTN :: 30
@(private = "file")
WSIDE :: 160

// "WORKSPACE/" is 10 cells of 10px, and the field takes what is left of the box it is in.
@(private = "file")
WLBL :: 100

@(private = "file")
fake_prompt :: proc(a: ^app.App, n: int) {
    a.scale = 1
    a.face = clay_test_face()
    a.aux_mode = .FileTree
    a.focus = .Aux
    a.tree.dir = "/home/me/src"
    search.wsfind_init(&a.wsfind)
    a.wsfind.open = true
    a.wsfind.root = "/w" // literals throughout: torn down by hand, never by wsfind_destroy
    for i in 0 ..< n {
        append(&a.wsfind.rows, search.WS_Row{path = "/w/src/a.odin", dirty = i == 0})
    }
    append(&a.filebrowser.places, app.Place{"Home", "/home/me"})
    a.filebrowser.hover_row, a.filebrowser.hover_place, a.filebrowser.hover_seg = -1, -1, -1
}

@(private = "file")
fake_prompt_free :: proc(a: ^app.App) {
    delete(a.wsfind.rows)
    delete(a.filebrowser.places)
    txt.doc_destroy(&a.wsfind.query)
}

// The `ls` face: the prompt takes the header, and the rows take everything under it.
@(test)
test_wsfind_declared_in_ls :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_prompt(&a, 3)
    defer fake_prompt_free(&a)
    append(&a.tree.entries, app.FileEntry{name = "e", path = "/home/me/src/e", display = "-rw-  e"})
    defer delete(a.tree.entries)

    cmds := app.filetree_layout(&a, f, WPANE, 600, 300)

    // The line fills the header past its one-cell margin and the label.
    edit, ok := box_of(&cmds, clay.ID("ws_edit"), .Custom)
    testing.expect(t, ok, "the header declared no text field")
    testing.expect_value(t, edit, gfx.Rect{WAREA.x + 10 + WLBL, WAREA.y, WAREA.w - 10 - WLBL, WROW})

    // The first row is the selected one, at the top of the region under the header.
    row, rok := box_of(&cmds, clay.ID("ws_row", 0), .Rectangle)
    testing.expect(t, rok, "the selected row drew no background")
    testing.expect_value(t, row, gfx.Rect{WAREA.x, WAREA.y + WROW, WAREA.w, WROW})

    _, unsel := box_of(&cmds, clay.ID("ws_row", 1), .Rectangle)
    testing.expect(t, !unsel, "an unselected row must not paint a background (rule 3)")

    // …and the listing is GONE, not merely covered: a press cannot resolve to a row that was
    // never declared, which is what makes the prompt safe to leave the tree untouched behind.
    _, listed := box_of(&cmds, clay.ID("ft_row", 0), .Rectangle)
    testing.expect(t, !listed, "the listing was declared under the prompt")
    testing.expect_value(t, app.wsfind_hit(&a.wsfind, 0, 3), -1) // nothing hovered, nothing hit
}

// The browser face: the same prompt in the path region, the same rows in the contents' region —
// and the bar's buttons and the places sidebar still standing, so the pane does not reflow.
@(test)
test_wsfind_declared_in_browser :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_prompt(&a, 3)
    defer fake_prompt_free(&a)
    a.file_pane = .Browser
    append(&a.tree.entries, app.FileEntry{name = "e", path = "/home/me/src/e", display = "-rw-  e"})
    defer delete(a.tree.entries)

    cmds := app.filebrowser_layout(&a, f, WPANE, 600, 300)

    path := gfx.Rect{WAREA.x + 3 * WBTN, WAREA.y, WAREA.w - 4 * WBTN, WBAR}
    edit, ok := box_of(&cmds, clay.ID("ws_edit"), .Custom)
    testing.expect(t, ok, "the path region declared no text field")
    testing.expect_value(t, edit, app.wsfind_field_rect(path, 10))

    content := gfx.Rect{WAREA.x + WSIDE, WAREA.y + WBAR, WAREA.w - WSIDE, WAREA.h - WBAR}
    row, rok := box_of(&cmds, clay.ID("ws_row", 0), .Rectangle)
    testing.expect(t, rok, "the selected row drew no background")
    testing.expect_value(t, row, gfx.Rect{content.x, content.y, content.w, WROW})

    _, listed := box_of(&cmds, clay.ID("fb_item", 0), .Rectangle)
    testing.expect(t, !listed, "the listing was declared under the prompt")

    // The chrome the prompt does not take is untouched: the sidebar still lists its place, and
    // the view toggle is still on the bar's right edge.
    side := gfx.Rect{WAREA.x, WAREA.y + WBAR, WSIDE, WAREA.h - WBAR}
    testing.expect_value(t, texts_in_box(&cmds, side), 1)
    toggle := gfx.Rect{path.x + path.w, WAREA.y, WBTN, WBAR}
    testing.expect_value(t, texts_in_box(&cmds, toggle), 1)
}

// How many text runs start inside `region` — filebrowser_ui_test's, which is file-private there.
@(private = "file")
texts_in_box :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), region: gfx.Rect) -> (n: int) {
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        r := ui.clay_rect(c.boundingBox)
        if c.commandType == .Text && gfx.rect_hit(region, r.x, r.y) {
            n += 1
        }
    }
    return
}
