package tests

import app ".."
import clay "../../bindings/clay"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// C3: the filetree declared in Clay. The claim being tested is not "it draws" — that needs
// a window — but the thing the port exists for: geometry, hit-testing and paint all come
// from ONE tree, so a row's box, the row the pointer resolves to, and the row that gets
// selected cannot disagree. Everything here is headless: a Clay context over test memory,
// a synthetic 10x16 font, no GL and no GLFW.
//
// The pane used throughout is {100, 50, 300, 100} at scale 1, which insets to a content
// area of {102, 52, 296, 96}: an 18px row height (16px line + 2px pad), an 18px header,
// and a 78px body holding 4 rows.

@(private = "file")
PANE :: app.Rect{100, 50, 300, 100}
@(private = "file")
AREA :: app.Rect{102, 52, 296, 96}
@(private = "file")
ROW_H :: 18
@(private = "file")
ROWS :: 4 // entry rows that fit under the header

// A listing built by hand rather than read off a disk: the layout assertions want a known
// entry count and stable names, and none of them touch the filesystem. The strings are
// literals, so this is torn down with plain `delete` — NOT filetree_destroy, which frees
// every field and would be freeing static storage.
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

// Every phase of the frame sizes itself from this one proc, which is what stops them
// drifting — so the numbers it produces are worth pinning outright.
@(test)
test_filetree_geom :: proc(t: ^testing.T) {
    area, row_h, rows := app.filetree_geom(PANE, 1, 16)
    testing.expect_value(t, area, AREA) // inside the 2px focus ring
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, rows, ROWS) // (96 - 18) / 18, the header taking the first row

    // A hidden pane is a zero rect (compute_layout leaves them so), and must report no
    // rows rather than a negative count that would index the entry list backwards.
    _, _, none := app.filetree_geom(app.Rect{}, 1, 16)
    testing.expect_value(t, none, 0)

    // A pane too short for even one row still reports one: the clip group is what keeps it
    // inside the pane, which is the same bargain the pre-Clay code struck.
    _, _, tiny := app.filetree_geom(app.Rect{0, 0, 300, 24}, 1, 16)
    testing.expect_value(t, tiny, 1)

    // DPI scale reaches both the inset and the row padding, so the whole pane stays on the
    // cell grid at 2x rather than only the text growing.
    area2, row_h2, _ := app.filetree_geom(PANE, 2, 32)
    testing.expect_value(t, area2, app.Rect{104, 54, 292, 92})
    testing.expect_value(t, row_h2, i32(36))
}

// The viewport write that used to be a side effect of painting. Being a normal state
// update is the whole point: it can be exercised without a frame, and a frame that does
// not draw no longer means a list that does not scroll.
@(test)
test_filetree_scroll_apply :: proc(t: ^testing.T) {
    a: app.App
    fake_tree(&a, 20)
    defer fake_tree_free(&a)

    // FOLLOW: the top holds still while the selection is inside the viewport, then moves
    // the minimum to bring it back — the selection onto the bottom row.
    a.tree.selected = 2
    app.filetree_scroll_apply(&a.tree, ROWS, false)
    testing.expect_value(t, a.tree.scroll, 0)

    a.tree.selected = 6
    app.filetree_scroll_apply(&a.tree, ROWS, false)
    testing.expect_value(t, a.tree.scroll, 6 - ROWS + 1)

    // MIDDLE: the selection is pinned to the middle row instead.
    a.tree.selected = 10
    app.filetree_scroll_apply(&a.tree, ROWS, true)
    testing.expect_value(t, a.tree.scroll, 10 - ROWS / 2)
}

// The end-to-end claim: a known listing and viewport come back as boxes on the cell grid,
// in the same places the hand-drawn pane put them. The columns are the load-bearing part —
// a one-cell left margin, then a two-cell prefix column, so names start on cell 3.
@(test)
test_filetree_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    a.scale = 1
    fake_tree(&a, 20) // far more than fits: the visible window must be the only thing declared
    defer fake_tree_free(&a)
    // Scrolled AND settled: the view is where the tween is, not where the target is, so a
    // fixture that only set `scroll` would be asserting the first frame of an animation from
    // row 0. A zero-duration Anim is the settled state (anim_value returns `to`).
    a.tree.scroll = 5
    a.tree.scroll_anim = {to = 5}
    a.tree.selected = 6

    cmds := app.filetree_layout(&a, &f, PANE, 500, 300)

    counts: [10]int
    head_text, scissor, pane_clip: app.Rect
    row_boxes: [20]app.Rect
    row_seen: [20]bool
    texts := 0
    prefix_x, name_x: i32 = -1, -1
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := app.clay_rect(c.boundingBox)
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
            // Two now, and they are not interchangeable — see the assertions below.
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

    // The header sits at the top of the content area, its text centred in the row.
    testing.expect_value(t, head_text.y, AREA.y + (ROW_H - 16) / 2)
    testing.expect_value(t, head_text.x, AREA.x + 10) // the one-cell left margin

    // TWO clip groups since C8a, and the outer one is the point of the checkpoint: with one
    // tree over the whole window there is no per-pane clay_paint left to be handed the pane
    // rect as its root clip, so the pane clips ITSELF. Without it a long directory name in
    // the header would paint across the gutter into the editor.
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorStart)], 2)
    testing.expect_value(t, counts[int(clay.RenderCommandType.ScissorEnd)], 2)
    testing.expect_value(t, pane_clip, AREA)
    // The inner one is the body, under the header and running to the bottom of the pane.
    testing.expect_value(t, scissor, app.Rect{AREA.x, AREA.y + ROW_H, AREA.w, AREA.h - ROW_H})

    // Only the SELECTED row draws a background (nothing is marked here), and it is the
    // full width of the pane, as the fill it replaced was.
    testing.expect(t, row_seen[6], "the selected row drew no background")
    testing.expect_value(t, row_boxes[6], app.Rect{AREA.x, AREA.y + ROW_H + ROW_H, AREA.w, ROW_H})
    testing.expect(t, !row_seen[5], "an unselected, unmarked row must not paint a background")

    // The partial row at the bottom edge IS declared, and it runs past the body — the clip is
    // what cuts it, which is the whole point of declaring it.
    a.tree.selected = 5 + ROWS // the fifth row of the window
    partial := app.filetree_layout(&a, &f, PANE, 500, 300, 0)
    pbox, pok := box_of(&partial, clay.ID("ft_row", u32(5 + ROWS)), .Rectangle)
    testing.expect(t, pok, "the partially-visible bottom row was not declared")
    testing.expect(t, pbox.y + pbox.h > AREA.y + AREA.h, "the bottom row was not the partial one")
    a.tree.selected = 6

    // The columns: prefix on cell 1 of the row, name on cell 3 — the two-cell prefix
    // column the listing has always used.
    testing.expect_value(t, prefix_x, AREA.x + 10)
    testing.expect_value(t, name_x, AREA.x + 30)

    // Virtualisation: header + (prefix, name) per visible row, and NOT one per entry.
    //
    // FIVE rows, not four: the body is 78px and a row is 18, so four fit WHOLE and 6px of a
    // fifth is on screen. The count the policy uses (ROWS) is the whole ones — a selection has
    // to be entirely visible — but the declaration has to cover what the region touches, or
    // that 6px band renders as a gap along the bottom edge (list_visible_rows).
    testing.expect_value(t, texts, 1 + 2 * (ROWS + 1))
}

// A hit resolves to the ENTRY index, not the visible row index — which is the difference
// that matters, since the two only agree when the list is scrolled to the top. Clay
// answers from the tree it is holding, so this is two frames: declare, then point.
@(test)
test_filetree_hit :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    a.scale = 1
    fake_tree(&a, 20)
    defer fake_tree_free(&a)
    a.tree.scroll = 5 // rows 5..8 are on screen
    a.tree.scroll_anim = {to = 5} // settled there, so the boxes are at the target

    _ = app.filetree_layout(&a, &f, PANE, 500, 300) // frame 1: gives Clay boxes to hit

    // The second row of the body: y = area.y + header + one row, plus a few pixels in.
    y := AREA.y + ROW_H + ROW_H + 4
    clay.SetPointerState({f32(AREA.x + 50), f32(y)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300) // frame 2: pointer resolves against frame 1

    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), 6)

    // The header is not a row, and neither is the pane's focus-ring inset.
    clay.SetPointerState({f32(AREA.x + 50), f32(AREA.y + 4)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300)
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), -1)

    // Off the pane entirely.
    clay.SetPointerState({10, 10}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300)
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), -1)
}

// The verb half. A press is claimed only when it hit a row, so a click on the header or
// over another pane stays available to whoever else is drawing — and is dropped at the end
// of the frame rather than firing later somewhere the pointer no longer is.
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

    // A miss leaves both the selection and the pending press alone.
    a.mouse.click = true
    app.filetree_click(&a, -1)
    testing.expect_value(t, a.tree.selected, 6)
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")

    // `mouse: off` costs convenience, never capability: the keyboard path is untouched,
    // but a press does nothing.
    a.mouse_on = false
    a.mouse.click = true
    app.filetree_click(&a, 3)
    testing.expect_value(t, a.tree.selected, 6)
}

// Double click is Enter: it activates the row, which for a directory means the listing
// reloads at that directory. Run against a real temp tree, because activation frees and
// re-reads every entry — the same reason the other filetree tests use fixtures.
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

    // One press selects and goes no further — the listing must not move under a single
    // click, or a mis-aimed click would navigate.
    a.mouse.click = true
    a.mouse.click_count = 1
    app.filetree_click(&a, row)
    testing.expect_value(t, a.tree.selected, row)
    testing.expect(t, !strings.has_suffix(a.tree.dir, "sub"), "a single click navigated")

    // The second press of the run activates it.
    a.mouse.click = true
    a.mouse.click_count = 2
    app.filetree_click(&a, row)
    testing.expect(t, strings.has_suffix(a.tree.dir, "sub"), "a double click did not descend")
}

// **The viewport EASES, and the sub-row remainder rides on the clip.** Three frames of one
// jump, with the boxes hand-derived from the ease-out cubic (anim.odin): a scroll that
// teleported would put the target row at the top on the very first frame, and a scroll that
// eased in whole rows only would never place a row off the row grid.
//
// The jump is 0 -> 10 with a 4-row window, so the target row is not even declared at the start.
@(test)
test_filetree_scroll_eases :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_font()
    app.clay_use_font(&f)

    a: app.App
    a.scale = 1
    fake_tree(&a, 40)
    defer fake_tree_free(&a)
    // app_next_wake asks the editor for its own scroll tween, so the ring has to exist —
    // every fixture that reaches the scheduler pays this.
    app.editor_init(&a.editor)
    defer app.editor_destroy(&a.editor)
    a.tree.selected = 10 // so the row paints a background this can find
    a.tree.scroll = 10   // the TARGET; the tween starts from the settled 0

    // Frame one, at t=1: the tween is aimed but has not moved, so the window is still row 0
    // and row 10 is a screenful below it — declared nowhere.
    first := app.filetree_layout(&a, &f, PANE, 500, 300, 1)
    _, shown := box_of(&first, clay.ID("ft_row", 10), .Rectangle)
    testing.expect(t, !shown, "the view teleported to the target on the first frame")

    // Halfway through SCROLL_DUR the ease-out cubic is 1-(1-0.5)^3 = 0.875 of the way, so the
    // view sits at row 8.75: the window starts at 8 and every row is lifted by 0.75 of a row
    // (13px of 18). Row 10 is therefore two rows down from the top of the body, minus that.
    mid := app.filetree_layout(&a, &f, PANE, 500, 300, 1 + app.SCROLL_DUR / 2)
    box, ok := box_of(&mid, clay.ID("ft_row", 10), .Rectangle)
    testing.expect(t, ok, "the target row was not declared mid-scroll")
    testing.expect_value(t, box.y, AREA.y + ROW_H + 2 * ROW_H - 13)
    testing.expect(t, box.y % ROW_H != AREA.y % ROW_H, "mid-scroll the rows sat back on the row grid")

    // The extra row easing in must not STRETCH the clip group it is inside: the body's scissor
    // is the body's box, mid-scroll as much as at rest. A `SizingGrow` here would take the
    // group (and its hit boxes) past the bottom of the pane, invisibly (rule 8).
    body_clip: app.Rect
    for i in 0 ..< mid.length {
        c := clay.RenderCommandArray_Get(&mid, i)
        if c.commandType == .ScissorStart && c.id != clay.ID("ft_pane").id {
            body_clip = app.clay_rect(c.boundingBox)
        }
    }
    testing.expect_value(t, body_clip, app.Rect{AREA.x, AREA.y + ROW_H, AREA.w, AREA.h - ROW_H})

    // And the hit test resolves against the window that was PAINTED. Mid-scroll the top row on
    // screen is 8 while the TARGET is 10, so a probe aimed at the target misses it entirely —
    // which is the difference between a click landing and a click landing on the wrong row.
    clay.SetPointerState({f32(AREA.x + 50), f32(AREA.y + ROW_H + 2)}, false)
    _ = app.filetree_layout(&a, &f, PANE, 500, 300, 1 + app.SCROLL_DUR / 2)
    testing.expect_value(t, app.filetree_hit(&a.tree, 8, ROWS), 8)
    testing.expect_value(t, app.filetree_hit(&a.tree, a.tree.scroll, ROWS), -1)

    // And once the tween is spent the row lands exactly on the first body row, on the grid.
    done := app.filetree_layout(&a, &f, PANE, 500, 300, 1 + app.SCROLL_DUR)
    settled, sok := box_of(&done, clay.ID("ft_row", 10), .Rectangle)
    testing.expect(t, sok, "the target row vanished once the scroll finished")
    testing.expect_value(t, settled, app.Rect{AREA.x, AREA.y + ROW_H, AREA.w, ROW_H})

    // The scheduler has to keep waking while that runs, or the view freezes part-scrolled.
    // Focused on the aux pane, which is the state you scroll this list in, and which silences
    // the disk poll (an unscheduled one is always due, and would answer 0 for the editor
    // whatever the list is doing). frame_budget is the smallest wake there is — so demanding
    // it mid-tween is decisive; once settled the soonest deadline is the caret's blink edge,
    // which is strictly later. That difference is the whole claim: spin, then stop spinning.
    a.aux_mode = .FileTree
    a.focus = .Aux
    testing.expect_value(t, app.app_next_wake(&a, 1 + app.SCROLL_DUR / 2), app.frame_budget)
    testing.expect(
        t,
        app.app_next_wake(&a, 1 + 2 * app.SCROLL_DUR) > app.frame_budget,
        "the scroll went on demanding a vsync-paced redraw after it had settled",
    )
}
