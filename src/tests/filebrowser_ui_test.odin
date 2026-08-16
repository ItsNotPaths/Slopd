package tests

import app ".."
import clay "../../bindings/clay"
import "core:testing"

// The file browser declared in Clay. Same claim as every other pane's test — the boxes that
// paint, the box a press resolves against and the geometry the scroll uses are one tree — with
// the difference this pane brings: FOUR kinds of target, so the hit test has to say which kind
// it found and not merely which index.
//
// The pane used throughout is {0, 0, 600, 300} at scale 1 with the 10x16 test font, which
// insets to {2, 2, 596, 296}: a 26px top bar (16px line + 2*5 pad), a 160px sidebar (16 cells),
// and a content region of {162, 28, 436, 270}. List rows are 18px, so 15 of them fit.

@(private = "file")
PANE :: app.Rect{0, 0, 600, 300}
@(private = "file")
AREA :: app.Rect{2, 2, 596, 296}
@(private = "file")
BAR_H :: 26
@(private = "file")
SIDE_W :: 160
@(private = "file")
ROW_H :: 18
@(private = "file")
CONTENT :: app.Rect{AREA.x + SIDE_W, AREA.y + BAR_H, AREA.w - SIDE_W, AREA.h - BAR_H}
// The path region: the bar less its four square buttons — where the segments sit, and where the
// text line scrolls when the bar is one.
@(private = "file")
PATH :: app.Rect{AREA.x + 3 * BAR_H, AREA.y, AREA.w - 4 * BAR_H, BAR_H}

// A listing and a sidebar built by hand: the layout assertions want known counts and stable
// names, and none of them touch a disk. Every string is a literal, so this is torn down with
// plain deletes — NOT filetree_destroy, which would be freeing static storage.
@(private = "file")
fake_browser :: proc(a: ^app.App, n: int) {
    a.scale = 1
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

// The one geometry call every phase sizes itself from. The three regions tile the content area
// exactly — a gap between them would be a band of pane that no hit test owns.
@(test)
test_filebrowser_geom :: proc(t: ^testing.T) {
    area, bar, side, content, row_h, bar_h := app.filebrowser_geom(PANE, 1, 16, 10)
    testing.expect_value(t, area, AREA)
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, bar_h, i32(BAR_H))
    testing.expect_value(t, bar, app.Rect{AREA.x, AREA.y, AREA.w, BAR_H})
    testing.expect_value(t, side, app.Rect{AREA.x, AREA.y + BAR_H, SIDE_W, AREA.h - BAR_H})
    testing.expect_value(t, content, CONTENT)
    testing.expect_value(t, side.x + side.w, content.x) // they tile, with nothing between

    // The sidebar is capped at half the pane: a fixed 16 cells in a narrow split would leave
    // the contents narrower than a single tile.
    _, _, narrow, ncontent, _, _ := app.filebrowser_geom(app.Rect{0, 0, 200, 300}, 1, 16, 10)
    testing.expect_value(t, narrow.w, 98) // (200 - 4) / 2
    testing.expect_value(t, ncontent.w, 98)

    // A hidden pane is a zero rect (compute_layout leaves them so) and must report no rows
    // rather than a negative count that would index the listing backwards.
    _, _, _, empty, _, _ := app.filebrowser_geom(app.Rect{}, 1, 16, 10)
    testing.expect_value(t, empty, app.Rect{})

    // List rows count entries; grid rows count TILES, and the column count comes from the same
    // call so the keyboard's step and the declaration's row width cannot disagree.
    rows, cols := app.filebrowser_rows(CONTENT, .List, ROW_H, 1, 16, 10)
    testing.expect_value(t, rows, 15) // 270 / 18
    testing.expect_value(t, cols, 1)

    // A tile is 140x59: 14 cells wide, and an icon band of round(16 * 2.4) = 38 over a caption
    // row of round(16 * 0.8) = 13, with 4px of padding either side. The icon is the tall part
    // on purpose — a tile is read icon-first.
    tw, th := app.filebrowser_tile(1, 16, 10, CONTENT.w)
    testing.expect_value(t, tw, f32(140))
    testing.expect_value(t, th, f32(59))
    icon_h, name_h := app.filebrowser_tile_bands(16)
    testing.expect_value(t, icon_h, f32(38))
    testing.expect_value(t, name_h, f32(13))

    grows, gcols := app.filebrowser_rows(CONTENT, .Grid, ROW_H, 1, 16, 10)
    testing.expect_value(t, gcols, 3) // 436 / (14 cells * 10)
    testing.expect_value(t, grows, 4) // 270 / 59, which is 4.57 rows

    // The caption's smaller size buys back characters: 14 cells of tile at 0.8 of a cell each
    // is 17, less one for the truncation mark.
    testing.expect_value(t, app.filebrowser_tile_name_cells(), 16)

    // The unit the viewport and its tween count in changes with the presentation: a list row,
    // or a whole row of tiles. Getting this wrong scrolls a grid at a third of the distance it
    // paints, which is the kind of thing that looks like an easing bug and is not one.
    testing.expect_value(t, app.filebrowser_row_h(.List, ROW_H, 1, 16, 10), i32(ROW_H))
    testing.expect_value(t, app.filebrowser_row_h(.Grid, ROW_H, 1, 16, 10), i32(59 + 6)) // + the gap

    // The gap is BETWEEN tiles and never after the last one, so a region exactly three tiles and
    // two gaps wide still fits three columns — and one tile narrower fits two.
    testing.expect_value(t, app.filebrowser_grid_cols(3 * 140 + 2 * 6, 140, 6), 3)
    testing.expect_value(t, app.filebrowser_grid_cols(3 * 140 + 2 * 6 - 1, 140, 6), 2)
}

// The viewport is in CONTENT ROWS, and that unit changes with the presentation: an entry in
// List, a row of tiles in Grid. Both write the same `ft.scroll`, which is what lets the wheel
// stay one line of code in mouse.odin.
@(test)
test_filebrowser_scroll_unit :: proc(t: ^testing.T) {
    a: app.App
    fake_browser(&a, 60)
    defer fake_browser_free(&a)

    a.tree.selected = 20
    app.filebrowser_scroll_apply(&a, 15, 1, false)
    testing.expect_value(t, a.tree.scroll, 20 - 15 + 1) // the entry onto the bottom row

    // The same selection in a 3-wide grid is on tile row 6, which already fits in a 5-row
    // viewport scrolled to 2 — the row, not the entry, is what the policy follows.
    a.filebrowser.view = .Grid
    a.tree.scroll = 0
    app.filebrowser_scroll_apply(&a, 5, 3, false)
    testing.expect_value(t, a.tree.scroll, 6 - 5 + 1)
}

// The end-to-end claim: a known listing comes back as boxes where the design says they are —
// three square buttons, then the path, the sidebar rail, and the rows under the bar.
@(test)
test_filebrowser_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 40) // more than fits: only the visible window may be declared
    defer fake_browser_free(&a)
    // Scrolled AND settled — see filetree_ui_test: the declaration follows the tween.
    a.tree.scroll = 5
    a.tree.scroll_anim = {to = 5}
    a.tree.selected = 6

    cmds := app.filebrowser_layout(&a, &f, PANE, 600, 300)

    // The buttons are SQUARE and sit left to right along the bar, which is the design's own
    // requirement and what keeps the icons on a common baseline at any zoom.
    back, ok := box_of(&cmds, clay.ID("fb_btn", u32(app.Browse_Btn.Back)), .Rectangle)
    testing.expect(t, !ok, "an un-hovered button must declare no background (rule 3)")
    _ = back

    bar, bok := box_of(&cmds, clay.ID("fb_bar"), .Rectangle)
    testing.expect(t, bok, "the top bar drew no background")
    testing.expect_value(t, bar, app.Rect{AREA.x, AREA.y, AREA.w, BAR_H})

    // The selected row: full content width, under the bar, at its scrolled position.
    row, rok := box_of(&cmds, clay.ID("fb_item", 6), .Rectangle)
    testing.expect(t, rok, "the selected row drew no background")
    testing.expect_value(t, row, app.Rect{CONTENT.x, CONTENT.y + ROW_H, CONTENT.w, ROW_H})

    _, unsel := box_of(&cmds, clay.ID("fb_item", 5), .Rectangle)
    testing.expect(t, !unsel, "an unselected, unmarked row must not paint a background")

    // Virtualisation: the rows past the bottom edge are not declared at all.
    _, far := box_of(&cmds, clay.ID("fb_item", 39), .Rectangle)
    testing.expect(t, !far, "a row past the viewport was declared")

    // The sidebar's rail is a single-edge border on the sidebar itself (rule 5) rather than a
    // hand-placed fill. Found by BOX and not by id: Clay derives a border command's id from the
    // element's, the same way it does for a clip group's scissor (C8c), so `box_of` would miss
    // it however correct the declaration is.
    rails := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        if c.commandType != .Border {
            continue
        }
        rails += 1
        testing.expect_value(t, app.clay_rect(c.boundingBox), app.Rect{AREA.x, AREA.y + BAR_H, SIDE_W, AREA.h - BAR_H})
        testing.expect_value(t, int(c.renderData.border.width.right), 1)
        testing.expect_value(t, int(c.renderData.border.width.left), 0) // a RAIL, not a box
    }
    testing.expect_value(t, rails, 1)
}

// Grid mode: tiles of a fixed cell width, laid out in rows of `cols`, each with a swatch. The
// tile is what makes this a browser rather than a list, and its width is in CELLS — so the
// whole grid scales with the font zoom without a second zoom setting to keep in step.
@(test)
test_filebrowser_grid_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 10)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid
    a.tree.selected = 4

    cmds := app.filebrowser_layout(&a, &f, PANE, 600, 300)

    // Entry 4 is the second tile of the second row (cols = 3), and a tile is 140 by 59 — placed
    // at one PITCH in each axis, since a 6px gap sits between tiles both ways. The tile itself
    // does not grow: the gap is the solver's spacing, so a selected tile's highlight stops at
    // its own edge instead of running into its neighbour's.
    tile, ok := box_of(&cmds, clay.ID("fb_item", 4), .Rectangle)
    testing.expect(t, ok, "the selected tile drew no background")
    testing.expect_value(t, tile, app.Rect{CONTENT.x + 140 + 6, CONTENT.y + 59 + 6, 140, 59})

    // Every tile carries a swatch, selected or not — it is the tile's icon, not its highlight.
    sw, swok := box_of(&cmds, clay.ID("fb_swatch", 0), .Rectangle)
    testing.expect(t, swok, "a tile drew no swatch")
    testing.expect_value(t, sw.w, i32(80)) // 8 cells of the 14
    testing.expect_value(t, sw.h, i32(38)) // the icon band: 2.4 text rows, rounded

    // The swatch is centred in its tile by the solver rather than by arithmetic (rule 5).
    testing.expect_value(t, sw.x, CONTENT.x + (140 - 80) / 2)
}

// The hit test says WHICH KIND of thing was found, and the four kinds are the reason it returns
// a struct. Clay answers from the tree it is holding, so each of these is two frames: declare,
// then point.
@(test)
test_filebrowser_hit_kinds :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    a.tree.scroll = 5
    a.tree.scroll_anim = {to = 5}

    segs := app.filebrowser_segments(a.tree.dir)
    probe :: proc(a: ^app.App, f: ^app.Font, segs: []app.Path_Seg, x, y: i32) -> app.FB_Hit {
        _ = app.filebrowser_layout(a, f, PANE, 600, 300) // frame 1: boxes for the pointer
        clay.SetPointerState({f32(x), f32(y)}, false)
        _ = app.filebrowser_layout(a, f, PANE, 600, 300) // frame 2: resolves against frame 1
        return app.filebrowser_hit(a, segs, 0, a.tree.scroll, 15, 1)
    }

    // The first square button, at the bar's left edge.
    back := probe(&a, &f, segs, AREA.x + 5, AREA.y + 5)
    testing.expect_value(t, back.kind, app.FB_Hit_Kind.Button)
    testing.expect_value(t, back.btn, app.Browse_Btn.Back)

    // The view toggle is the LAST thing on the bar, hard against the right edge.
    view := probe(&a, &f, segs, AREA.x + AREA.w - 5, AREA.y + 5)
    testing.expect_value(t, view.kind, app.FB_Hit_Kind.Button)
    testing.expect_value(t, view.btn, app.Browse_Btn.View)

    // A path segment: past the three buttons, on the "/" root button.
    seg := probe(&a, &f, segs, AREA.x + 3 * BAR_H + 5, AREA.y + 5)
    testing.expect_value(t, seg.kind, app.FB_Hit_Kind.Segment)
    testing.expect_value(t, seg.index, 0)

    // The whitespace AFTER the last segment is the path bar itself, not a miss and not the
    // nearest button: it is the press that turns the bar into a text line.
    blank := probe(&a, &f, segs, PATH.x + PATH.w - 5, AREA.y + 5)
    testing.expect_value(t, blank.kind, app.FB_Hit_Kind.PathBar)

    // The sidebar's second shortcut.
    place := probe(&a, &f, segs, AREA.x + 20, AREA.y + BAR_H + ROW_H + 4)
    testing.expect_value(t, place.kind, app.FB_Hit_Kind.Place)
    testing.expect_value(t, place.index, 1)

    // And a row — resolving to the ENTRY index, not the visible row, which is the difference
    // that only shows up once the list is scrolled.
    row := probe(&a, &f, segs, CONTENT.x + 50, CONTENT.y + ROW_H + 4)
    testing.expect_value(t, row.kind, app.FB_Hit_Kind.Row)
    testing.expect_value(t, row.index, 6)

    // Empty space below the last row is not a target — it reports None rather than the nearest
    // row, which is what lets a RIGHT press there open the DIRECTORY's menu instead of a file's.
    resize(&a.tree.entries, 3)
    a.tree.scroll = 0
    below := probe(&a, &f, segs, CONTENT.x + 50, CONTENT.y + 3 * ROW_H + 4)
    testing.expect_value(t, below.kind, app.FB_Hit_Kind.None)
}

// The verb half. Chrome activates on ONE press (a button has nothing to select first), a row
// selects on one and opens on two, and a press that hit nothing is left for whoever else draws.
@(test)
test_filebrowser_click_verbs :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    segs := app.filebrowser_segments(a.tree.dir)

    // A miss claims nothing.
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .None, index = -1}, PATH, 10)
    testing.expect(t, a.mouse.click, "a press that hit nothing must not be claimed")

    // A row selects, and one press does not open it.
    a.mouse.click_count = 1
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Row, index = 6}, PATH, 10)
    testing.expect_value(t, a.tree.selected, 6)
    testing.expect(t, !a.mouse.click, "a press that hit a row must be claimed")

    // The view toggle flips on a single press — and writes the choice back, so it is the one
    // button that persists. (config_override keeps that off the shipped file.)
    config_override("/tmp/slopd_fb_view.config")
    defer config_override_release()
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Button, index = -1, btn = .View}, PATH, 10)
    testing.expect_value(t, a.filebrowser.view, app.Browse_View.Grid)

    // Back with an empty history is a no-op rather than an error: the button is drawn disabled,
    // and a press on it must do nothing at all.
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Button, index = -1, btn = .Back}, PATH, 10)
    testing.expect_value(t, a.tree.dir, "/home/me/src")

    // `mouse: off` costs convenience, never capability — the keyboard path is untouched.
    a.mouse_on = false
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Row, index = 9}, PATH, 10)
    testing.expect_value(t, a.tree.selected, 6)
}

// The path bar's two states. A press on the whitespace after the segments makes it a text line
// on the same directory; a press anywhere else puts the buttons back, and does NOT consume that
// press — dismissing the line and selecting a row are one gesture, as they are in Dolphin.
@(test)
test_filebrowser_path_line :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    defer app.doc_destroy(&a.filebrowser.path)
    segs := app.filebrowser_segments(a.tree.dir)

    a.mouse.click = true
    a.mouse.click_count = 1
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .PathBar, index = -1}, PATH, 10)
    testing.expect(t, a.filebrowser.path_edit, "the whitespace press did not open the line")
    line := app.doc_string(&a.filebrowser.path, context.temp_allocator)
    testing.expect_value(t, line, "/home/me/src") // seeded with where you are
    testing.expect_value(t, a.filebrowser.path.cursors[0].head.col, 12) // caret at the end

    // A press INSIDE the open line goes to the FIELD: it moves the caret rather than reopening
    // the line (which would throw away what had been typed). The caret is a BOUNDARY, rounded —
    // 3.5 cells in lands after the third rune, exactly as a press in the editor body does.
    a.mouse.click = true
    a.mouse.click_x = PATH.x + 35
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .PathBar, index = -1}, PATH, 10)
    testing.expect(t, a.filebrowser.path_edit)
    testing.expect_value(t, a.filebrowser.path.cursors[0].head.col, 4)

    a.mouse.click = true
    a.mouse.click_x = PATH.x + 34 // just under the half-cell: the boundary before it
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .PathBar, index = -1}, PATH, 10)
    testing.expect_value(t, a.filebrowser.path.cursors[0].head.col, 3)

    // A press on a row closes the line AND selects the row — one press, both meanings.
    a.mouse.click = true
    app.filebrowser_click(&a, segs, app.FB_Hit{kind = .Row, index = 4}, PATH, 10)
    testing.expect(t, !a.filebrowser.path_edit, "a press elsewhere must put the buttons back")
    testing.expect_value(t, a.tree.selected, 4)

    // Enter on a path that is not a directory KEEPS the line open: the typo is still on screen
    // and one keystroke from being fixed, where closing would throw it away.
    app.filebrowser_path_open(&a)
    app.doc_set_text(&a.filebrowser.path, "/no/such/directory/here")
    app.filebrowser_path_commit(&a)
    testing.expect(t, a.filebrowser.path_edit, "a bad path must not close the line")
    testing.expect_value(t, a.tree.dir, "/home/me/src")
}

// Declared, the line REPLACES the segment buttons in the same region — the buttons either side
// of it stay, so the bar does not reflow as you open and close it.
@(test)
test_filebrowser_path_line_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    defer app.doc_destroy(&a.filebrowser.path)

    // Clay derives a text command's id from its own element, so the segments are counted by
    // WHERE they landed — which is the claim anyway: text inside the path region.
    toggle :: app.Rect{PATH.x + PATH.w, AREA.y, BAR_H, BAR_H}

    // Closed: the segments are there and there is no field.
    cmds := app.filebrowser_layout(&a, &f, PANE, 600, 300)
    _, edit_off := box_of(&cmds, clay.ID("fb_edit"), .Custom)
    testing.expect(t, texts_in(&cmds, PATH) == 4, "the closed bar drew no segment") // /, home, me, src
    testing.expect(t, !edit_off, "the closed bar declared a text field")

    // Open: the field fills the path region, and nothing is laid out inside it — the line's
    // runes are the painter's, since a caret and a cut head are not things Clay lays out.
    app.filebrowser_path_open(&a)
    open := app.filebrowser_layout(&a, &f, PANE, 600, 300)
    edit, eok := box_of(&open, clay.ID("fb_edit"), .Custom)
    testing.expect(t, eok, "the open bar declared no text field")
    testing.expect_value(t, edit, PATH)
    testing.expect_value(t, texts_in(&open, PATH), 0) // no segment survived

    // The view toggle is still on the bar's right edge: opening the line is not a reflow.
    testing.expect_value(t, texts_in(&open, toggle), 1)
    testing.expect_value(t, texts_in(&cmds, toggle), 1)
}

// Rule 8, in the one place this pane can trip it: a tile is 14 CELLS wide, and at a narrow
// split that is wider than the region the tiles are in. A fixed box that outgrows its parent is
// still a hit box — the clip group hides the overflow and the row goes on being clickable past
// the pane's edge — so the tile caps at the content width and leaves one usable column.
@(test)
test_filebrowser_tile_capped_to_the_content :: proc(t: ^testing.T) {
    wide, _ := app.filebrowser_tile(1, 16, 10, CONTENT.w)
    testing.expect_value(t, wide, f32(140)) // 14 cells, room to spare

    narrow, _ := app.filebrowser_tile(1, 16, 10, 90)
    testing.expect_value(t, narrow, f32(90)) // capped, not overflowing

    // And the column count stays at least one, so the grid degrades to a single column rather
    // than to no columns at all.
    rows, cols := app.filebrowser_rows(app.Rect{0, 0, 90, 270}, .Grid, ROW_H, 1, 16, 10)
    testing.expect_value(t, cols, 1)
    testing.expect_value(t, rows, 4)
}

// Icons are glyphs, so a LIST row gains a column and nothing else: a two-cell icon cell, then
// the dired-style row on the cell after it. The synthetic font carries no icon face, so
// `icons_ok` is set by hand here — which is also the switch a build without fontTools flips.
@(test)
test_filebrowser_list_icon_column :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    a.file_icons = true
    f.icons_ok = true

    cmds := app.filebrowser_layout(&a, &f, PANE, 600, 300)
    ico, ok := box_of(&cmds, clay.ID("fb_ico", 0), .Rectangle)
    testing.expect(t, !ok, "the icon cell must declare no background of its own (rule 3)")
    _ = ico

    // Two text runs per row now — the icon, then the row — and the row starts two cells in.
    // Only the CONTENT region's runs: the top bar's button glyphs are text too.
    icon_x, name_x := first_two_texts_in(&cmds, CONTENT)
    testing.expect_value(t, icon_x, CONTENT.x + 10) // the one-cell left margin
    testing.expect_value(t, name_x, CONTENT.x + 30) // a two-cell icon column after it

    // With icons off the column is gone entirely, so the pane is byte-for-byte what it was
    // before them — which is what makes `file_icons` a real toggle rather than a blank column.
    // Counted, not positioned: with the toggle ignored the icons still draw and the ROW text
    // still starts on the same cell, so an x assertion passes under both implementations. The
    // run COUNT is what tells them apart — two per row with icons, one without.
    testing.expect_value(t, texts_in(&cmds, CONTENT), 8) // 4 rows x (icon + row)

    a.file_icons = false
    plain := app.filebrowser_layout(&a, &f, PANE, 600, 300)
    first_x, _ := first_two_texts_in(&plain, CONTENT)
    testing.expect_value(t, first_x, CONTENT.x + 10)
    testing.expect_value(t, texts_in(&plain, CONTENT), 4) // the column is gone, not blank
}

// How many text runs fall inside `region`.
@(private = "file")
texts_in :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), region: app.Rect) -> (n: int) {
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        r := app.clay_rect(c.boundingBox)
        if c.commandType == .Text && app.rect_hit(region, r.x, r.y) {
            n += 1
        }
    }
    return
}

// The x of the first two text runs whose box falls inside `region` — the content rows, past the
// top bar's own glyphs.
@(private = "file")
first_two_texts_in :: proc(cmds: ^clay.ClayArray(clay.RenderCommand), region: app.Rect) -> (a, b: i32) {
    a, b = -1, -1
    seen := 0
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(cmds, i)
        r := app.clay_rect(c.boundingBox)
        if c.commandType != .Text || !app.rect_hit(region, r.x, r.y) {
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

// A GRID tile's icon is the one thing in the chrome that is not text at the text size — a glyph
// can only be drawn at the size it was baked — so it is a Custom in the same box the plain
// coloured swatch occupies. Same box either way: the grid must not reflow when icons are off.
@(test)
test_filebrowser_tile_icon_or_swatch :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid

    // No icon face: a plain coloured swatch, as before.
    plain := app.filebrowser_layout(&a, &f, PANE, 600, 300)
    swatch, sok := box_of(&plain, clay.ID("fb_swatch", 0), .Rectangle)
    testing.expect(t, sok, "without an icon face the tile must draw its swatch")

    // With one: the same box, as a Custom rather than a Rectangle.
    a.file_icons = true
    f.icons_ok = true
    iconed := app.filebrowser_layout(&a, &f, PANE, 600, 300)
    _, still := box_of(&iconed, clay.ID("fb_swatch", 0), .Rectangle)
    testing.expect(t, !still, "the swatch must give way to the icon, not sit under it")
    custom, cok := box_of(&iconed, clay.ID("fb_swatch", 0), .Custom)
    testing.expect(t, cok, "the tile drew no icon")
    testing.expect_value(t, custom, swatch) // same box: no reflow either way
}

// **The bottom edge.** A tile row is 56px and the content region is 270, so four rows fit WHOLE
// and 46px of a fifth is on screen — a sixth of the pane. Declaring only the rows that fit
// leaves that band empty, which reads as the bottom row of icons vanishing early rather than
// being clipped. `list_visible_rows` is the difference; this is the case that found it.
@(test)
test_filebrowser_declares_the_partial_bottom_row :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 40)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid

    rows, cols := app.filebrowser_rows(CONTENT, .Grid, ROW_H, 1, 16, 10)
    testing.expect_value(t, rows, 4) // whole rows — what the viewport POLICY counts
    testing.expect_value(t, app.list_visible_rows(CONTENT.h, 0, 59), 5) // …and what is on screen

    cmds := app.filebrowser_layout(&a, &f, PANE, 600, 300)

    // Probed by SWATCH: a tile paints no background unless it is selected, but every tile
    // carries its picture, so that is the element that says "this tile was declared".
    tile, ok := box_of(&cmds, clay.ID("fb_swatch", u32(rows * cols)), .Rectangle)
    testing.expect(t, ok, "the partially-visible bottom row of tiles was not declared")
    testing.expect(t, tile.y < CONTENT.y + CONTENT.h, "the bottom row starts below the region")

    // The tile it sits in runs past the bottom of the region — the clip cuts it, as it should.
    row_top := CONTENT.y + i32(rows) * 59
    testing.expect(t, row_top < CONTENT.y + CONTENT.h, "the fifth row starts below the region")
    testing.expect(t, row_top + 59 > CONTENT.y + CONTENT.h, "the fifth row was not the partial one")

    // And the row past THAT is still not declared — the fix is one more row, not no clipping.
    _, past := box_of(&cmds, clay.ID("fb_swatch", u32((rows + 1) * cols)), .Rectangle)
    testing.expect(t, !past, "a row entirely below the region was declared")
}

// The list presentation has the same edge, and the same answer.
@(test)
test_filebrowser_list_partial_bottom_row :: proc(t: ^testing.T) {
    // 100px of body at 18px rows: five whole and 10px of a sixth.
    testing.expect_value(t, app.list_visible_rows(100, 0, 18), 6)
    testing.expect_value(t, app.list_visible_rows(90, 0, 18), 5) // divides evenly: no extra
    testing.expect_value(t, app.list_visible_rows(90, 1, 18), 6) // …until a scroll is under way
    testing.expect_value(t, app.list_visible_rows(0, 0, 18), 0) // a hidden pane shows nothing
    testing.expect_value(t, app.list_visible_rows(100, 0, 0), 0) // and never divides by zero
}

// The caption is drawn at its OWN bake size, which is why it is a Custom rather than a
// `clay.Text`: Clay lays text out at the atlas's one size, and this is 80% of it. The box is
// what a headless test can see; the glyphs need an atlas, so the painter itself is left to the
// machine — but the box, the size handed to it and the elide budget are all assertable.
@(test)
test_filebrowser_tile_caption :: proc(t: ^testing.T) {
    raw := clay_test_context(600, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    f.px = 16 // the synthetic font's bake size, so the caption's is derived from something real
    app.clay_use_font(&f)

    a: app.App
    fake_browser(&a, 4)
    defer fake_browser_free(&a)
    a.filebrowser.view = .Grid

    cmds := app.filebrowser_layout(&a, &f, PANE, 600, 300)

    // The caption sits under the icon band, spans the tile, and is the tile's remaining height.
    name, ok := box_of(&cmds, clay.ID("fb_name", 0), .Custom)
    testing.expect(t, ok, "the tile drew no caption")
    testing.expect_value(t, name.w, i32(140))
    testing.expect_value(t, name.h, i32(13)) // round(16 * 0.8)
    testing.expect_value(t, name.y, CONTENT.y + 4 + 38) // padding, then the icon band

    // A caption is never a `Text` command: one that was would be at the body size, which is the
    // whole thing this replaced.
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        testing.expect(t, !(c.commandType == .Text && c.id == clay.ID("fb_name", 0).id), "the caption fell back to body-size text")
    }

    // The advance scales with the bake, which is what lets the painter centre a caption from
    // its rune count alone — 0.8 of a 10px cell.
    txt: app.Text
    txt.font = f
    testing.expect_value(t, app.text_sized_cell(&txt, f.px * 0.8), f32(8))
}
