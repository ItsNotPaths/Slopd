package tests

import app "../slopd"
import clay "../../bindings/clay"
import "core:testing"
import "../txt"
import "../gfx"
import "../ui"

// The file browser declared in Clay. Same claim as every other pane's test — the boxes that
// paint, the box a press resolves against and the geometry the scroll uses are one tree — plus
// this pane's own: FOUR kinds of target, so the hit test says which kind, not just which index.
//
// The pane is {0, 0, 600, 300} at scale 1 with the 10x16 test font, insetting to
// {2, 2, 596, 296}: a 26px top bar, a 160px sidebar, and a content region of
// {162, 28, 436, 270}. List rows are 18px, so 15 fit.

@(private = "file")
PANE :: gfx.Rect{0, 0, 600, 300}
@(private = "file")
AREA :: gfx.Rect{2, 2, 596, 296}
@(private = "file")
BAR_H :: 26
@(private = "file")
SIDE_W :: 160
@(private = "file")
ROW_H :: 18
@(private = "file")
CONTENT :: gfx.Rect{AREA.x + SIDE_W, AREA.y + BAR_H, AREA.w - SIDE_W, AREA.h - BAR_H}
// The bar less its four square buttons: where the segments sit, and where the line scrolls.
@(private = "file")
PATH :: gfx.Rect{AREA.x + 3 * BAR_H, AREA.y, AREA.w - 4 * BAR_H, BAR_H}

// By hand: the layout assertions want known counts and stable names. Every string is a literal,
// so this is torn down with plain deletes, not filetree_destroy, which would free static
// storage.
@(private = "file")
fake_browser :: proc(a: ^app.App, n: int) {
    a.scale = 1
    a.face = clay_test_face()
    a.tree.dir = "/home/me/src"
    for i in 0 ..< n {
        append(&a.tree.entries, app.FileEntry{name = "entry", path = "/home/me/src/entry", display = "-rw-r--r--  entry"})
    }
    append(&a.filebrowser.places, app.Place{"Home", "/home/me"})
    append(&a.filebrowser.places, app.Place{"Src", "/home/me/src"})
    a.filebrowser.hover_row, a.filebrowser.hover_place, a.filebrowser.hover_seg = -1, -1, -1
}

@(private = "file")
fake_browser_free :: proc(a: ^app.App) {
    delete(a.tree.entries)
    delete(a.filebrowser.places)
}

// The three regions tile the content area exactly: a gap would be a band no hit test owns.
@(test)
test_filebrowser_geom :: proc(t: ^testing.T) {
    area, bar, side, content, row_h, bar_h := app.filebrowser_geom(PANE, 16, 10)
    testing.expect_value(t, area, AREA)
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, bar_h, i32(BAR_H))
    testing.expect_value(t, bar, gfx.Rect{AREA.x, AREA.y, AREA.w, BAR_H})
    testing.expect_value(t, side, gfx.Rect{AREA.x, AREA.y + BAR_H, SIDE_W, AREA.h - BAR_H})
    testing.expect_value(t, content, CONTENT)
    testing.expect_value(t, side.x + side.w, content.x) // they tile, with nothing between

    // Capped at half the pane: a fixed 16 cells in a narrow split would leave the contents
    // narrower than a single tile.
    _, _, narrow, ncontent, _, _ := app.filebrowser_geom(gfx.Rect{0, 0, 200, 300}, 16, 10)
    testing.expect_value(t, narrow.w, 98) // (200 - 4) / 2
    testing.expect_value(t, ncontent.w, 98)

    // A hidden pane is a zero rect (compute_layout leaves them so) and must report no rows
    // rather than a negative count that would index the listing backwards.
    _, _, _, empty, _, _ := app.filebrowser_geom(gfx.Rect{}, 16, 10)
    testing.expect_value(t, empty, gfx.Rect{})

    // List rows count entries, grid rows count TILES, and the column count comes from the same
    // call, so the keyboard's step and the declaration's row width cannot disagree.
    rows, cols := app.filebrowser_rows(CONTENT, .List, ROW_H, 1, 16, 10)
    testing.expect_value(t, rows, 15) // 270 / 18
    testing.expect_value(t, cols, 1)

    // A tile is 140x59: 14 cells wide, an icon band of round(16 * 2.4) = 38 over a caption row
    // of round(16 * 0.8) = 13, with 4px of padding either side.
    tw, th := app.filebrowser_tile(16, 10, CONTENT.w)
    testing.expect_value(t, tw, f32(140))
    testing.expect_value(t, th, f32(59))
    icon_h, name_h := app.filebrowser_tile_bands(16)
    testing.expect_value(t, icon_h, f32(38))
    testing.expect_value(t, name_h, f32(13))

    grows, gcols := app.filebrowser_rows(CONTENT, .Grid, ROW_H, 1, 16, 10)
    testing.expect_value(t, gcols, 3) // 436 / (14 cells * 10)
    testing.expect_value(t, grows, 4) // 270 / 59, which is 4.57 rows

    // The smaller caption buys back characters: 14 cells at 0.8 each is 17, less one for the
    // truncation mark.
    testing.expect_value(t, app.filebrowser_tile_name_cells(), 16)

    // The unit the viewport and its tween count in changes with the presentation. Getting it
    // wrong scrolls a grid at a third of the distance it paints, which looks like an easing bug.
    testing.expect_value(t, app.filebrowser_row_h(.List, ROW_H, 1, 16, 10), i32(ROW_H))
    testing.expect_value(t, app.filebrowser_row_h(.Grid, ROW_H, 1, 16, 10), i32(59 + 6)) // + gap

    // The gap is BETWEEN tiles and never after the last, so a region exactly three tiles and two
    // gaps wide still fits three columns.
    testing.expect_value(t, app.filebrowser_grid_cols(3 * 140 + 2 * 6, 140, 6), 3)
    testing.expect_value(t, app.filebrowser_grid_cols(3 * 140 + 2 * 6 - 1, 140, 6), 2)
}

// In CONTENT ROWS, and that unit changes with the presentation. Both write the same
// `ft.scroll`, which is what lets the wheel stay one line in mouse.odin.
@(test)
test_filebrowser_scroll_unit :: proc(t: ^testing.T) {
    a: app.App
    fake_browser(&a, 60)
    defer fake_browser_free(&a)

    a.tree.selected = 20
    app.filebrowser_scroll_apply(app.ctx_of(&a), &a.filebrowser, &a.tree, 15, 1, false)
    testing.expect_value(t, a.tree.scroll, 20 - 15 + 1) // the entry onto the bottom row

    // The same selection in a 3-wide grid is on tile row 6, which already fits in a 5-row
    // viewport scrolled to 2: the row, not the entry, is what the policy follows.
    a.filebrowser.view = .Grid
    a.tree.scroll = 0
    app.filebrowser_scroll_apply(app.ctx_of(&a), &a.filebrowser, &a.tree, 5, 3, false)
    testing.expect_value(t, a.tree.scroll, 6 - 5 + 1)
}

// A known listing comes back as boxes where the design says: three square buttons, the path,
// the sidebar rail, and the rows under the bar.
@(test)
test_filebrowser_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 40) // more than fits: only the visible window may be declared
    defer fake_browser_free(&a)
    // Scrolled AND settled — see filetree_ui_test: the declaration follows the tween.
    a.tree.scroll = 5
    a.tree.scroll_anim = {to = 5}
    a.tree.selected = 6

    cmds := app.filebrowser_layout(&a, f, PANE, 600, 300)

    // Square, left to right along the bar, which keeps the icons on a common baseline.
    back, ok := box_of(&cmds, clay.ID("fb_btn", u32(app.Browse_Btn.Back)), .Rectangle)
    testing.expect(t, !ok, "an un-hovered button must declare no background (rule 3)")
    _ = back

    bar, bok := box_of(&cmds, clay.ID("fb_bar"), .Rectangle)
    testing.expect(t, bok, "the top bar drew no background")
    testing.expect_value(t, bar, gfx.Rect{AREA.x, AREA.y, AREA.w, BAR_H})

    // The selected row: full content width, under the bar, at its scrolled position.
    row, rok := box_of(&cmds, clay.ID("fb_item", 6), .Rectangle)
    testing.expect(t, rok, "the selected row drew no background")
    testing.expect_value(t, row, gfx.Rect{CONTENT.x, CONTENT.y + ROW_H, CONTENT.w, ROW_H})

    _, unsel := box_of(&cmds, clay.ID("fb_item", 5), .Rectangle)
    testing.expect(t, !unsel, "an unselected, unmarked row must not paint a background")

    // Virtualisation: the rows past the bottom edge are not declared.
    _, far := box_of(&cmds, clay.ID("fb_item", 39), .Rectangle)
    testing.expect(t, !far, "a row past the viewport was declared")

    // A single-edge border on the sidebar itself (rule 5), not a hand-placed fill. Found by BOX
    // and not by id: Clay derives a border command's id from the element's, so `box_of` would
    // miss it however correct the declaration is.
    rails := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType != .Border {
            continue
        }
        rails += 1
        testing.expect_value(t, ui.clay_rect(c.boundingBox), gfx.Rect{AREA.x, AREA.y + BAR_H, SIDE_W, AREA.h - BAR_H})
        testing.expect_value(t, int(c.renderData.border.width.right), 1)
        testing.expect_value(t, int(c.renderData.border.width.left), 0) // a rail, not a box
    }
    testing.expect_value(t, rails, 1)
}

// Tiles of a fixed cell width, in rows of `cols`, each with a swatch. The width is in CELLS, so
// the grid scales with the font zoom without a second setting to keep in step.
@(test)
test_filebrowser_grid_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 10)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid
    a.tree.selected = 4

    cmds := app.filebrowser_layout(&a, f, PANE, 600, 300)

    // Entry 4 is the second tile of the second row, placed at one PITCH in each axis. The tile
    // does not grow: the gap is the solver's spacing, so a selected tile's highlight stops at
    // its own edge.
    tile, ok := box_of(&cmds, clay.ID("fb_item", 4), .Rectangle)
    testing.expect(t, ok, "the selected tile drew no background")
    testing.expect_value(t, tile, gfx.Rect{CONTENT.x + 140 + 6, CONTENT.y + 59 + 6, 140, 59})

    // Every tile carries a swatch: it is the tile's icon, not its highlight.
    sw, swok := box_of(&cmds, clay.ID("fb_swatch", 0), .Rectangle)
    testing.expect(t, swok, "a tile drew no swatch")
    testing.expect_value(t, sw.w, i32(80)) // 8 cells of the 14
    testing.expect_value(t, sw.h, i32(38)) // the icon band: 2.4 text rows, rounded

    // Centred in its tile by the solver rather than by arithmetic (rule 5).
    testing.expect_value(t, sw.x, CONTENT.x + (140 - 80) / 2)
}

// The four kinds are the reason it returns a struct. Clay answers from the tree it is holding,
// so each of these is two frames: declare, then point.
@(test)
test_filebrowser_hit_kinds :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    a.tree.scroll = 5
    a.tree.scroll_anim = {to = 5}

    segs := app.filebrowser_segments(a.tree.dir)
    probe :: proc(a: ^app.App, face: gfx.Face, segs: []app.Path_Seg, x, y: i32) -> app.FB_Hit {
        _ = app.filebrowser_layout(a, face, PANE, 600, 300) // frame 1: boxes for the pointer
        clay.SetPointerState({f32(x), f32(y)}, false)
        _ = app.filebrowser_layout(a, face, PANE, 600, 300) // frame 2: resolves against frame 1
        return app.filebrowser_hit(&a.filebrowser, &a.tree, segs, 0, a.tree.scroll, 15, 1)
    }

    back := probe(&a, f, segs, AREA.x + 5, AREA.y + 5)
    testing.expect_value(t, back.kind, app.FB_Hit_Kind.Button)
    testing.expect_value(t, back.btn, app.Browse_Btn.Back)

    // The view toggle is last on the bar, hard against the right edge.
    view := probe(&a, f, segs, AREA.x + AREA.w - 5, AREA.y + 5)
    testing.expect_value(t, view.kind, app.FB_Hit_Kind.Button)
    testing.expect_value(t, view.btn, app.Browse_Btn.View)

    // A path segment: past the three buttons, on the "/" root button.
    seg := probe(&a, f, segs, AREA.x + 3 * BAR_H + 5, AREA.y + 5)
    testing.expect_value(t, seg.kind, app.FB_Hit_Kind.Segment)
    testing.expect_value(t, seg.index, 0)

    // The whitespace after the last segment is the path bar itself: the press that turns the
    // bar into a text line.
    blank := probe(&a, f, segs, PATH.x + PATH.w - 5, AREA.y + 5)
    testing.expect_value(t, blank.kind, app.FB_Hit_Kind.PathBar)

    place := probe(&a, f, segs, AREA.x + 20, AREA.y + BAR_H + ROW_H + 4)
    testing.expect_value(t, place.kind, app.FB_Hit_Kind.Place)
    testing.expect_value(t, place.index, 1)

    // A row, resolving to the ENTRY index rather than the visible row.
    row := probe(&a, f, segs, CONTENT.x + 50, CONTENT.y + ROW_H + 4)
    testing.expect_value(t, row.kind, app.FB_Hit_Kind.Row)
    testing.expect_value(t, row.index, 6)

    // Empty space below the last row reports None rather than the nearest row, which is what
    // lets a right press there open the DIRECTORY's menu.
    resize(&a.tree.entries, 3)
    a.tree.scroll = 0
    below := probe(&a, f, segs, CONTENT.x + 50, CONTENT.y + 3 * ROW_H + 4)
    testing.expect_value(t, below.kind, app.FB_Hit_Kind.None)
}

// Chrome activates on one press, a row selects on one and opens on two, and a press that hit
// nothing is left for whoever else draws.
@(test)
test_filebrowser_click_verbs :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    segs := app.filebrowser_segments(a.tree.dir)

    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .None, index = -1}, PATH, 10)
    testing.expect(t, a.mouse.click, "a press that hit nothing must not be claimed")

    a.mouse.click_count = 1
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Row, index = 6}, PATH, 10)
    testing.expect_value(t, a.tree.selected, 6)
    testing.expect(t, !a.mouse.click, "a press that hit a row must be claimed")

    // The view toggle flips on a single press and writes the choice back, so it is the one
    // button that persists. config_override keeps that off the shipped file.
    config_override("/tmp/slopd_fb_view.config")
    defer config_override_release()
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Button, index = -1, btn = .View}, PATH, 10)
    testing.expect_value(t, a.filebrowser.view, app.Browse_View.Grid)

    // Back with an empty history is a no-op: the button is drawn disabled.
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Button, index = -1, btn = .Back}, PATH, 10)
    testing.expect_value(t, a.tree.dir, "/home/me/src")

    // `mouse: off`: the keyboard path is untouched.
    a.mouse_on = false
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Row, index = 9}, PATH, 10)
    testing.expect_value(t, a.tree.selected, 6)
}

// A press on the whitespace after the segments makes the bar a text line on the same directory;
// a press elsewhere puts the buttons back and does NOT consume that press.
@(test)
test_filebrowser_path_line :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    defer txt.doc_destroy(&a.filebrowser.path)
    segs := app.filebrowser_segments(a.tree.dir)

    a.mouse.click = true
    a.mouse.click_count = 1
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .PathBar, index = -1}, PATH, 10)
    testing.expect(t, a.filebrowser.path_edit, "the whitespace press did not open the line")
    line := txt.doc_string(&a.filebrowser.path, context.temp_allocator)
    testing.expect_value(t, line, "/home/me/src") // seeded with where you are
    testing.expect_value(t, a.filebrowser.path.cursors[0].head.col, 12) // caret at the end

    // A press INSIDE the open line goes to the field: it moves the caret rather than reopening
    // the line. The caret is a boundary, rounded, so 3.5 cells in lands after the third rune.
    a.mouse.click = true
    a.mouse.click_x = PATH.x + 35
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .PathBar, index = -1}, PATH, 10)
    testing.expect(t, a.filebrowser.path_edit)
    testing.expect_value(t, a.filebrowser.path.cursors[0].head.col, 4)

    a.mouse.click = true
    a.mouse.click_x = PATH.x + 34 // just under the half-cell: the boundary before
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .PathBar, index = -1}, PATH, 10)
    testing.expect_value(t, a.filebrowser.path.cursors[0].head.col, 3)

    // A press on a row closes the line AND selects the row.
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Row, index = 4}, PATH, 10)
    testing.expect(t, !a.filebrowser.path_edit, "a press elsewhere must put the buttons back")
    testing.expect_value(t, a.tree.selected, 4)

    // Enter on a path that is not a directory keeps the line open, so the typo stays on screen.
    app.filebrowser_path_open(&a)
    txt.doc_set_text(&a.filebrowser.path, "/no/such/directory/here")
    app.filebrowser_path_commit(&a)
    testing.expect(t, a.filebrowser.path_edit, "a bad path must not close the line")
    testing.expect_value(t, a.tree.dir, "/home/me/src")
}

// The line replaces the segment buttons in the same region; the buttons either side stay, so the
// bar does not reflow.
@(test)
test_filebrowser_path_line_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    defer txt.doc_destroy(&a.filebrowser.path)

    // Clay derives a text command's id from its element, so the segments are counted by where
    // they landed — which is the claim anyway.
    toggle :: gfx.Rect{PATH.x + PATH.w, AREA.y, BAR_H, BAR_H}

    cmds := app.filebrowser_layout(&a, f, PANE, 600, 300)
    _, edit_off := box_of(&cmds, clay.ID("fb_edit"), .Custom)
    testing.expect(t, texts_in(&cmds, PATH) == 4, "the closed bar drew no segment") // 4 segments
    testing.expect(t, !edit_off, "the closed bar declared a text field")

    // Open: the field fills the path region and nothing is laid out inside it — the runes are
    // the painter's, since a caret and a cut head are not things Clay lays out.
    app.filebrowser_path_open(&a)
    open := app.filebrowser_layout(&a, f, PANE, 600, 300)
    edit, eok := box_of(&open, clay.ID("fb_edit"), .Custom)
    testing.expect(t, eok, "the open bar declared no text field")
    testing.expect_value(t, edit, PATH)
    testing.expect_value(t, texts_in(&open, PATH), 0) // no segment survived

    // The view toggle is still on the right edge: opening the line is not a reflow.
    testing.expect_value(t, texts_in(&open, toggle), 1)
    testing.expect_value(t, texts_in(&cmds, toggle), 1)
}

// Rule 8, where this pane can trip it: a tile is 14 CELLS wide, which at a narrow split is wider
// than the region. A fixed box that outgrows its parent is still a hit box, clickable past the
// pane's edge, so the tile caps at the content width.
@(test)
test_filebrowser_tile_capped_to_the_content :: proc(t: ^testing.T) {
    wide, _ := app.filebrowser_tile(16, 10, CONTENT.w)
    testing.expect_value(t, wide, f32(140)) // 14 cells, room to spare

    narrow, _ := app.filebrowser_tile(16, 10, 90)
    testing.expect_value(t, narrow, f32(90)) // capped, not overflowing

    // The column count stays at least one, so the grid degrades to a single column.
    rows, cols := app.filebrowser_rows(gfx.Rect{0, 0, 90, 270}, .Grid, ROW_H, 1, 16, 10)
    testing.expect_value(t, cols, 1)
    testing.expect_value(t, rows, 4)
}

// Icons are glyphs, so a list row gains a column and nothing else. The synthetic font carries no
// icon face, so `Face.icons` is set by hand — the same switch a build without fontTools flips.
@(test)
test_filebrowser_list_icon_column :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    a.file_icons = true
    f.icons = true

    cmds := app.filebrowser_layout(&a, f, PANE, 600, 300)
    ico, ok := box_of(&cmds, clay.ID("fb_ico", 0), .Rectangle)
    testing.expect(t, !ok, "the icon cell must declare no background of its own (rule 3)")
    _ = ico

    // Two text runs per row, the icon then the row, with the row two cells in. Content region
    // only: the top bar's button glyphs are text too.
    icon_x, name_x := first_two_texts_in(&cmds, CONTENT)
    testing.expect_value(t, icon_x, CONTENT.x + 10) // the one-cell left margin
    testing.expect_value(t, name_x, CONTENT.x + 30) // a two-cell icon column after it

    // With icons off the column is gone, so `file_icons` is a real toggle and not a blank
    // column. Counted, not positioned: with the toggle ignored the icons still draw and the row
    // text still starts on the same cell, so only the run COUNT tells the two apart.
    testing.expect_value(t, texts_in(&cmds, CONTENT), 8) // 4 rows x (icon + row)

    a.file_icons = false
    plain := app.filebrowser_layout(&a, f, PANE, 600, 300)
    first_x, _ := first_two_texts_in(&plain, CONTENT)
    testing.expect_value(t, first_x, CONTENT.x + 10)
    testing.expect_value(t, texts_in(&plain, CONTENT), 4) // the column is gone, not blank
}

@(private = "file")
texts_in :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), region: gfx.Rect) -> (n: int) {
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        r := ui.clay_rect(c.boundingBox)
        if c.commandType == .Text && gfx.rect_hit(region, r.x, r.y) {
            n += 1
        }
    }
    return
}

// The content rows, past the top bar's own glyphs.
@(private = "file")
first_two_texts_in :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), region: gfx.Rect) -> (a, b: i32) {
    a, b = -1, -1
    seen := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        r := ui.clay_rect(c.boundingBox)
        if c.commandType != .Text || !gfx.rect_hit(region, r.x, r.y) {
            continue
        }
        if seen == 0 {
            a = r.x
        } else if seen == 1 {
            b = r.x
        }
        seen += 1
    }
    return
}

// A tile's icon is the one thing in the chrome not drawn at the text size, so it is a Custom in
// the same box the plain swatch occupies. Same box either way: the grid must not reflow.
@(test)
test_filebrowser_tile_icon_or_swatch :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid

    plain := app.filebrowser_layout(&a, f, PANE, 600, 300)
    swatch, sok := box_of(&plain, clay.ID("fb_swatch", 0), .Rectangle)
    testing.expect(t, sok, "without an icon face the tile must draw its swatch")

    // With one: the same box, as a Custom rather than a Rectangle.
    a.file_icons = true
    f.icons = true
    iconed := app.filebrowser_layout(&a, f, PANE, 600, 300)
    _, still := box_of(&iconed, clay.ID("fb_swatch", 0), .Rectangle)
    testing.expect(t, !still, "the swatch must give way to the icon, not sit under it")
    custom, cok := box_of(&iconed, clay.ID("fb_swatch", 0), .Custom)
    testing.expect(t, cok, "the tile drew no icon")
    testing.expect_value(t, custom, swatch) // same box: no reflow
}

// The bottom edge. A tile row is 56px and the content region 270, so four rows fit WHOLE and
// 46px of a fifth is on screen. Declaring only the rows that fit leaves that band empty, which
// reads as the bottom row vanishing early rather than being clipped.
@(test)
test_filebrowser_declares_the_partial_bottom_row :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid

    rows, cols := app.filebrowser_rows(CONTENT, .Grid, ROW_H, 1, 16, 10)
    testing.expect_value(t, rows, 4) // whole rows: what the policy counts
    testing.expect_value(t, ui.list_visible_rows(CONTENT.h, 0, 59), 5) // …and what is on screen

    cmds := app.filebrowser_layout(&a, f, PANE, 600, 300)

    // Probed by SWATCH: a tile paints no background unless selected, but every tile carries
    // its picture.
    tile, ok := box_of(&cmds, clay.ID("fb_swatch", u32(rows * cols)), .Rectangle)
    testing.expect(t, ok, "the partially-visible bottom row of tiles was not declared")
    testing.expect(t, tile.y < CONTENT.y + CONTENT.h, "the bottom row starts below the region")

    // The tile it sits in runs past the bottom of the region, and the clip cuts it.
    row_top := CONTENT.y + i32(rows) * 59
    testing.expect(t, row_top < CONTENT.y + CONTENT.h, "the fifth row starts below the region")
    testing.expect(t, row_top + 59 > CONTENT.y + CONTENT.h, "the fifth row was not the partial one")

    // The row past that is still not declared: the fix is one more row, not no clipping.
    _, past := box_of(&cmds, clay.ID("fb_swatch", u32((rows + 1) * cols)), .Rectangle)
    testing.expect(t, !past, "a row entirely below the region was declared")
}

@(test)
test_filebrowser_list_partial_bottom_row :: proc(t: ^testing.T) {
    testing.expect_value(t, ui.list_visible_rows(100, 0, 18), 6)
    testing.expect_value(t, ui.list_visible_rows(90, 0, 18), 5) // divides evenly: no extra
    testing.expect_value(t, ui.list_visible_rows(90, 1, 18), 6) // …until a scroll is under way
    testing.expect_value(t, ui.list_visible_rows(0, 0, 18), 0) // a hidden pane shows nothing
    testing.expect_value(t, ui.list_visible_rows(100, 0, 0), 0) // and never divides by zero
}

// At its OWN bake size, which is why it is a Custom: Clay lays text out at the atlas's one size,
// and this is 80% of it. The glyphs need an atlas, but the box, the size handed to it and the
// elide budget are all assertable.
@(test)
test_filebrowser_tile_caption :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    f.px = 16 // so the caption's size is derived from something real
    ui.clay_use_face(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid

    cmds := app.filebrowser_layout(&a, f, PANE, 600, 300)

    // Under the icon band, spanning the tile, taking its remaining height.
    name, ok := box_of(&cmds, clay.ID("fb_name", 0), .Custom)
    testing.expect(t, ok, "the tile drew no caption")
    testing.expect_value(t, name.w, i32(140))
    testing.expect_value(t, name.h, i32(13)) // round(16 * 0.8)
    testing.expect_value(t, name.y, CONTENT.y + 4 + 38) // padding, then the icon band

    // Never a `Text` command: one that was would be at the body size.
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        testing.expect(t, !(c.commandType == .Text && c.id == clay.ID("fb_name", 0).id), "the caption fell back to body-size text")
    }

    // The advance scales with the bake, which lets the painter centre from the rune count.
    testing.expect_value(t, gfx.text_sized_cell(f, f.px * 0.8), f32(8))
}
