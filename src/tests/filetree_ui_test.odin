package tests

import app "../slopd"
import clay "../../bindings/clay"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../gfx"
import "../ui"
import "../edit"

// The filetree declared in Clay. The claim is not "it draws" but that geometry, hit-testing and
// paint all come from ONE tree, so a row's box, the row the pointer resolves to and the row that
// gets selected cannot disagree. Headless: a Clay context over test memory, a synthetic 10x16
// font, no GL.
//
// The pane is {100, 50, 300, 100} at scale 1, insetting to {102, 52, 296, 96}: an 18px row
// height, an 18px header, and a 78px body holding 4 rows.

@(private = "file")
PANE :: gfx.Rect{100, 50, 300, 100}
@(private = "file")
AREA :: gfx.Rect{102, 52, 296, 96}
@(private = "file")
ROW_H :: 18
@(private = "file")
ROWS :: 4 // entry rows that fit under the header

// By hand rather than off a disk: the assertions want a known count and stable names. The
// strings are literals, so this is torn down with plain `delete`, not filetree_destroy, which
// would free static storage.
@(private = "file")
fake_tree :: proc(a: ^app.App, n: int) {
    a.tree.dir = "/tmp/ft"
    for i in 0 ..< n {
        append(
            &a.tree.entries,
            app.FileEntry{name = "e", path = "/tmp/ft/e", display = "drwxr-xr-x  e"},
        )
    }
}

@(private = "file")
fake_tree_free :: proc(a: ^app.App) {
    delete(a.tree.entries)
}

// Every phase sizes itself from this one proc, so its numbers are worth pinning outright.
@(test)
test_filetree_geom :: proc(t: ^testing.T) {
    area, row_h, rows := app.filetree_geom(PANE, 1, 16)
    testing.expect_value(t, area, AREA) // inside the 2px focus ring
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, rows, ROWS) // (96 - 18) / 18, the header taking the first row

    // A hidden pane is a zero rect and must report no rows, not a negative count.
    _, _, none := app.filetree_geom(gfx.Rect{}, 1, 16)
    testing.expect_value(t, none, 0)

    // Too short for even one row still reports one: the clip keeps it inside the pane.
    _, _, tiny := app.filetree_geom(gfx.Rect{0, 0, 300, 24}, 1, 16)
    testing.expect_value(t, tiny, 1)

    // DPI scale reaches the inset and the row padding both, so the whole pane stays on the
    // cell grid at 2x.
    area2, row_h2, _ := app.filetree_geom(PANE, 2, 32)
    testing.expect_value(t, area2, gfx.Rect{104, 54, 292, 92})
    testing.expect_value(t, row_h2, i32(36))
}

// A normal state update rather than a side effect of painting, so it can be exercised without a
// frame and a frame that does not draw no longer means a list that does not scroll.
@(test)
test_filetree_scroll_apply :: proc(t: ^testing.T) {
    a: app.App
    fake_tree(&a, 20)
    defer fake_tree_free(&a)

    // Follow: the top holds still while the selection is inside, then moves the minimum.
    a.tree.selected = 2
    app.filetree_scroll_apply(&a.tree, ROWS, false)
    testing.expect_value(t, a.tree.scroll, 0)

    a.tree.selected = 6
    app.filetree_scroll_apply(&a.tree, ROWS, false)
    testing.expect_value(t, a.tree.scroll, 6 - ROWS + 1)

    // Middle: the selection is pinned to the middle row.
    a.tree.selected = 10
    app.filetree_scroll_apply(&a.tree, ROWS, true)
    testing.expect_value(t, a.tree.scroll, 10 - ROWS / 2)
}

// A known listing and viewport come back as boxes on the cell grid, where the hand-drawn pane
// put them. The columns are the load-bearing part: a one-cell margin, then a two-cell prefix
// column, so names start on cell 3.
@(test)
test_filetree_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    a.scale = 1
    fake_tree(&a, 20) // more than fits: only the visible window may be declared
    defer fake_tree_free(&a)
    // Scrolled AND settled: the view is where the tween is, not where the target is, so a
    // fixture that only set `scroll` would be asserting the first frame of an animation from
    // row 0. A zero-duration Anim is the settled state (anim_value returns `to`).
    a.tree.scroll = 5
    a.tree.scroll_anim = {to = 5}
    a.tree.selected = 6

    cmds := app.filetree_layout(&a, &f, PANE, 500, 300)

    counts: [10]int
    head_text, scissor, pane_clip: gfx.Rect
    row_boxes: [20]gfx.Rect
    row_seen: [20]bool
    texts := 0
    prefix_x, name_x: i32 = -1, -1
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := ui.clay_rect(c.boundingBox)
        counts[int(c.commandType)] += 1
        #partial switch c.commandType {
        case .Text:
            if texts == 0 {
                head_text = r // the header is declared first
            } else if texts == 1 {
                prefix_x = r.x // first row: prefix, then name
            } else if texts == 2 {
                name_x = r.x
            }
            texts += 1
        case .ScissorStart:
            // Two, and not interchangeable — see the assertions below.
            if c.id == clay.ID("ft_pane").id {
                pane_clip = r
            } else {
                scissor = r
            }
        case .Rectangle:
            for j in 0 ..< 20 {
                if c.id == clay.ID("ft_row", u32(j)).id {
                    row_boxes[j] = r
                    row_seen[j] = true
                }
            }
        }
    }

    // At the top of the content area, its text centred in the row.
    testing.expect_value(t, head_text.y, AREA.y + (ROW_H - 16) / 2)
    testing.expect_value(t, head_text.x, AREA.x + 10) // the one-cell left margin

    // Two clip groups. The outer one matters: with one tree over the whole window there is no
    // per-pane clay_paint to be handed the pane rect as its root clip, so the pane clips
    // ITSELF. Without it a long directory name would paint across the gutter into the editor.
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorStart)], 2)
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorEnd)], 2)
    testing.expect_value(t, pane_clip, AREA)
    // The inner one is the body, under the header and running to the pane's bottom.
    testing.expect_value(t, scissor, gfx.Rect{AREA.x, AREA.y + ROW_H, AREA.w, AREA.h - ROW_H})

    // Only the selected row draws a background, at the full width of the pane.
    testing.expect(t, row_seen[6], "the selected row drew no background")
    testing.expect_value(t, row_boxes[6], gfx.Rect{AREA.x, AREA.y + ROW_H + ROW_H, AREA.w, ROW_H})
    testing.expect(t, !row_seen[5], "an unselected, unmarked row must not paint a background")

    // The partial row at the bottom edge IS declared and runs past the body: the clip cuts it,
    // which is the point of declaring it.
    a.tree.selected = 5 + ROWS // the fifth row of the window
    partial := app.filetree_layout(&a, &f, PANE, 500, 300, 0)
    pbox, pok := box_of(&partial, clay.ID("ft_row", u32(5 + ROWS)), .Rectangle)
    testing.expect(t, pok, "the partially-visible bottom row was not declared")
    testing.expect(t, pbox.y + pbox.h > AREA.y + AREA.h, "the bottom row was not the partial one")
    a.tree.selected = 6

    // Prefix on cell 1, name on cell 3: the two-cell prefix column.
    testing.expect_value(t, prefix_x, AREA.x + 10)
    testing.expect_value(t, name_x, AREA.x + 30)

    // Virtualisation: header plus (prefix, name) per visible row, not one per entry.
    //
    // Five rows, not four: the body is 78px and a row 18, so four fit WHOLE and 6px of a fifth
    // is on screen. The policy counts whole rows, but the declaration has to cover what the
    // region touches, or that 6px band renders as a gap.
    testing.expect_value(t, texts, 1 + 2 * (ROWS + 1))
}

// To the ENTRY index, not the visible row index: the two agree only at the top. Clay answers
// from the tree it holds, so this is two frames: declare, then point.
@(test)
test_filetree_hit :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    a.scale = 1
    fake_tree(&a, 20)
    defer fake_tree_free(&a)
    a.tree.scroll = 5 // rows 5..8 are on screen
    a.tree.scroll_anim = {to = 5} // settled, so the boxes are at the target

    _ = app.filetree_layout(&a, &f, PANE, 500, 300) // frame 1: boxes to hit

    // The body's second row: area.y + header + one row, plus a few pixels.
    y := AREA.y + ROW_H + ROW_H + 4
    clay.SetPointerState({f32(AREA.x + 50), f32(y)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300) // frame 2: pointer resolves against frame 1

    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), 6)

    // The header is not a row, and neither is the pane's focus-ring inset.
    clay.SetPointerState({f32(AREA.x + 50), f32(AREA.y + 4)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300)
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), -1)

    clay.SetPointerState({10, 10}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300)
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), -1)
}

// A press is claimed only when it hit a row, so a click on the header or over another pane stays
// available to whoever else is drawing, and is dropped at the end of the frame.
@(test)
test_filetree_click_selects :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    fake_tree(&a, 20)
    defer fake_tree_free(&a)

    a.mouse.click = true
    a.mouse.click_count = 1
    app.filetree_click(&a, 6)
    testing.expect_value(t, a.tree.selected, 6)
    testing.expect(t, !a.mouse.click, "a click that hit a row must be claimed")

    // A miss leaves the selection and the pending press alone.
    a.mouse.click = true
    app.filetree_click(&a, -1)
    testing.expect_value(t, a.tree.selected, 6)
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")

    // `mouse: off`: the keyboard path is untouched, but a press does nothing.
    a.mouse_on = false
    a.mouse.click = true
    app.filetree_click(&a, 3)
    testing.expect_value(t, a.tree.selected, 6)
}

// Double click is Enter, so for a directory the listing reloads there. Against a real temp tree,
// because activation frees and re-reads every entry.
@(test)
test_filetree_click_double_activates :: proc(t: ^testing.T) {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    dir := filepath.join({base, "slopd_ft_click"}, context.temp_allocator) or_else ""
    sub := filepath.join({dir, "sub"}, context.temp_allocator) or_else ""
    os.remove(sub)
    os.remove(dir)
    os.make_directory(dir)
    os.make_directory(sub)
    defer {
        os.remove(sub)
        os.remove(dir)
    }

    a: app.App
    a.mouse_on = true
    app.filetree_load(&a.tree, dir)
    defer app.filetree_destroy(&a.tree)

    row := -1
    for e, i in a.tree.entries {
        if e.name == "sub" {
            row = i
        }
    }
    testing.expect(t, row >= 0, "fixture directory missing")

    // One press selects and goes no further, or a mis-aimed click would navigate.
    a.mouse.click = true
    a.mouse.click_count = 1
    app.filetree_click(&a, row)
    testing.expect_value(t, a.tree.selected, row)
    testing.expect(t, !strings.has_suffix(a.tree.dir, "sub"), "a single click navigated")

    a.mouse.click = true
    a.mouse.click_count = 2
    app.filetree_click(&a, row)
    testing.expect(t, strings.has_suffix(a.tree.dir, "sub"), "a double click did not descend")
}

// The viewport eases, and the sub-row remainder rides on the clip. Three frames of one jump,
// with the boxes hand-derived from the ease-out cubic: a scroll that teleported would put the
// target row at the top on the first frame, and one that eased in whole rows only would never
// place a row off the row grid. The jump is 0 -> 10 with a 4-row window.
@(test)
test_filetree_scroll_eases :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    ui.clay_use_font(&f)

    a: app.App
    a.scale = 1
    fake_tree(&a, 40)
    defer fake_tree_free(&a)
    // app_next_wake asks the editor for its own scroll tween, so the ring has to exist.
    edit.editor_init(&a.editor)
    defer edit.editor_destroy(&a.editor)
    a.tree.selected = 10 // so the row paints a background this can find
    a.tree.scroll = 10   // the TARGET; the tween starts from the settled 0

    // Frame one, at t=1: the tween is aimed but has not moved, so the window is still row 0.
    first := app.filetree_layout(&a, &f, PANE, 500, 300, 1)
    _, shown := box_of(&first, clay.ID("ft_row", 10), .Rectangle)
    testing.expect(t, !shown, "the view teleported to the target on the first frame")

    // Halfway through SCROLL_DUR the ease-out cubic is 0.875 of the way, so the view sits at
    // row 8.75: the window starts at 8 and every row lifts by 0.75 of a row (13px of 18).
    mid := app.filetree_layout(&a, &f, PANE, 500, 300, 1 + ui.SCROLL_DUR / 2)
    box, ok := box_of(&mid, clay.ID("ft_row", 10), .Rectangle)
    testing.expect(t, ok, "the target row was not declared mid-scroll")
    testing.expect_value(t, box.y, AREA.y + ROW_H + 2 * ROW_H - 13)
    testing.expect(t, box.y % ROW_H != AREA.y % ROW_H, "mid-scroll the rows sat back on the row grid")

    // The extra row easing in must not stretch the clip group: the body's scissor is the body's
    // box, mid-scroll as much as at rest. A `SizingGrow` would take it past the pane (rule 8).
    body_clip: gfx.Rect
    for i in 0 ..< mid.length {
        c := clay.RenderCommandArray_Get(&mid, i)
        if c.commandType == .ScissorStart && c.id != clay.ID("ft_pane").id {
            body_clip = ui.clay_rect(c.boundingBox)
        }
    }
    testing.expect_value(t, body_clip, gfx.Rect{AREA.x, AREA.y + ROW_H, AREA.w, AREA.h - ROW_H})

    // The hit test resolves against the PAINTED window: mid-scroll the top row on screen is 8
    // while the target is 10, so a probe aimed at the target misses entirely.
    clay.SetPointerState({f32(AREA.x + 50), f32(AREA.y + ROW_H + 2)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300, 1 + ui.SCROLL_DUR / 2)
    testing.expect_value(t, app.filetree_hit(&a.tree, 8, ROWS), 8)
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), -1)

    // Once the tween is spent the row lands exactly on the first body row.
    done := app.filetree_layout(&a, &f, PANE, 500, 300, 1 + ui.SCROLL_DUR)
    settled, sok := box_of(&done, clay.ID("ft_row", 10), .Rectangle)
    testing.expect(t, sok, "the target row vanished once the scroll finished")
    testing.expect_value(t, settled, gfx.Rect{AREA.x, AREA.y + ROW_H, AREA.w, ROW_H})

    // The scheduler must keep waking while that runs, or the view freezes part-scrolled.
    // Focused on the aux pane, which silences the disk poll. frame_budget is the smallest wake
    // there is, so demanding it mid-tween is decisive; once settled the soonest deadline is the
    // caret's blink edge, which is strictly later.
    a.aux_mode = .FileTree
    a.focus = .Aux
    testing.expect_value(t, app.app_next_wake(&a, 1 + ui.SCROLL_DUR / 2), ui.frame_budget)
    testing.expect(
        t,
        app.app_next_wake(&a, 1 + 2 * ui.SCROLL_DUR) > ui.frame_budget,
        "the scroll went on demanding a vsync-paced redraw after it had settled",
    )
}
