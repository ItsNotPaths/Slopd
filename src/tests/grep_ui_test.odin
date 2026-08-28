package tests

import app "../slopd"
import clay "../../bindings/clay"
import "core:testing"
import "../gfx"
import "../ui"
import "../search"

// The grep results pane declared in Clay. The filetree proved a flat list of one-row items;
// this proves the case every remaining pane has — one ITEM is several display ROWS. So the
// assertions are the indirections: the flattening, the row -> hit map a click resolves through,
// and the anchor the scroll policy frames a block by.
//
// The pane is {100, 50, 300, 200} at scale 1 with the synthetic 10x16 font: a content area of
// {102, 52, 296, 196}, a 21px row, and 8 display rows under the query header.

@(private = "file")
PANE :: gfx.Rect{100, 50, 300, 200}
@(private = "file")
AREA :: gfx.Rect{102, 52, 296, 196}
@(private = "file")
ROW_H :: 21
@(private = "file")
MAX_ROWS :: 8

// Hit 0 is a three-line block around line 10, hit 1 a two-line block around line 100, so the
// gutter widens to three cells. The strings are literals and the ctx slices point at
// caller-owned arrays, so this is torn down with plain `delete`, not grep_destroy.
//
// Flattened, that is 9 display rows:
//   0 header a.odin:10   1 ctx 9   2 ctx 10 (match)   3 ctx 11   4 spacer
//   5 header b.odin:100  6 ctx 99  7 ctx 100 (match)  8 spacer
@(private = "file")
fixture :: proc(a: ^app.App, ctx0: []string, ctx1: []string) {
    a.project_root = "/proj"
    append(
        &a.grep.hits,
        search.GrepHit {
            path      = "/proj/src/a.odin",
            line      = 10,
            text      = "bb",
            ctx       = ctx0,
            ctx_first = 9,
        },
    )
    append(
        &a.grep.hits,
        search.GrepHit {
            path      = "/proj/src/b.odin",
            line      = 100,
            text      = "ee",
            ctx       = ctx1,
            ctx_first = 99,
        },
    )
}

// Every later assertion rests on this shape, and `hit` is what makes a click possible.
@(test)
test_grep_rows_flatten :: proc(t: ^testing.T) {
    a: app.App
    c0 := [?]string{"aa", "bb", "cc"}
    c1 := [?]string{"dd", "ee"}
    fixture(&a, c0[:], c1[:])
    defer delete(a.grep.hits)

    rows := search.grep_rows(&a.grep, a.project_root, context.temp_allocator)
    testing.expect_value(t, len(rows), 9)

    // The title is project-relative and carries its block's index, as every row of the block
    // does: that is what a click resolves through.
    testing.expect(t, rows[0].header, "row 0 is not a block title")
    testing.expect_value(t, rows[0].text, "src/a.odin:10")
    testing.expect_value(t, rows[0].hit, 0)

    // Numbered from ctx_first, with exactly one marked as the match.
    testing.expect_value(t, rows[1].gutter, "9")
    testing.expect_value(t, rows[2].gutter, "10")
    testing.expect(t, rows[2].match, "the hit line is not marked as the match")
    testing.expect(t, !rows[1].match && !rows[3].match, "a context line was marked as the match")
    testing.expect_value(t, rows[3].text, "cc")

    // The spacer belongs to no block, which stops a click in the gap selecting either.
    testing.expect_value(t, rows[4].hit, -1)
    testing.expect_value(t, rows[5].hit, 1)
    testing.expect_value(t, rows[5].text, "src/b.odin:100")
    testing.expect_value(t, rows[8].hit, -1)

    // Measured from the rows that will be DRAWN, not estimated from max(line) + GREP_CONTEXT.
    testing.expect_value(t, search.grep_gutter_w(rows), 3)
}

// A block is framed by its TITLE row, so it scrolls into view from its top rather than by
// whichever of its rows is nearest.
@(test)
test_grep_anchor :: proc(t: ^testing.T) {
    a: app.App
    c0 := [?]string{"aa", "bb", "cc"}
    c1 := [?]string{"dd", "ee"}
    fixture(&a, c0[:], c1[:])
    defer delete(a.grep.hits)

    rows := search.grep_rows(&a.grep, a.project_root, context.temp_allocator)
    testing.expect_value(t, search.grep_anchor(rows, 0), 0)
    testing.expect_value(t, search.grep_anchor(rows, 1), 5) // the second block's title row
    testing.expect_value(t, search.grep_anchor(rows, 99), 0) // out of range: the top

    // The policy runs on DISPLAY rows: selecting the second block pulls its title onto the
    // bottom row of the viewport.
    app.grep_scroll_apply(&a.grep, search.grep_anchor(rows, 1), 4, len(rows), false)
    testing.expect_value(t, a.grep.scroll, 5 - 4 + 1)
}

// GREP_ROW_PAD, not the filetree's: the panes are deliberately not the same density.
@(test)
test_grep_geom :: proc(t: ^testing.T) {
    area, row_h, rows := app.grep_geom(PANE, 16)
    testing.expect_value(t, area, AREA)
    testing.expect_value(t, row_h, i32(ROW_H))
    testing.expect_value(t, rows, MAX_ROWS) // (196 - 21) / 21

    _, _, none := app.grep_geom(gfx.Rect{}, 16)
    testing.expect_value(t, none, 0)
}

// The declared tree resolves to the columns the hand-drawn pane used — a one-cell margin, a
// right-aligned gutter, one cell of gap — plus the two marks that say which block is selected.
@(test)
test_grep_command_list :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    a.scale = 1
    a.face = clay_test_face()
    c0 := [?]string{"aa", "bb", "cc"}
    c1 := [?]string{"dd", "ee"}
    fixture(&a, c0[:], c1[:])
    defer delete(a.grep.hits)
    a.grep.query = "needle"
    a.grep.selected = 0

    rows := search.grep_rows(&a.grep, a.project_root, context.temp_allocator)
    cmds := app.grep_layout(&a, f, PANE, rows, 500, 300)

    rects, borders, texts := 0, 0, 0
    scissor, border_box: gfx.Rect
    row_box: [9]gfx.Rect
    row_seen: [9]bool
    gut9_x, gut100_x, line_x, title_x: i32 = -1, -1, -1, -1
    for i in 0 ..< cmds.length {
        c := clay.RenderCommandArray_Get(&cmds, i)
        r := ui.clay_rect(c.boundingBox)
        #partial switch c.commandType {
        case .ScissorStart:
            scissor = r
        case .Border:
            borders += 1
            border_box = r
        case .Rectangle:
            rects += 1
            for j in 0 ..< 9 {
                if c.id == clay.ID("gp_row", u32(j)).id {
                    row_box[j] = r
                    row_seen[j] = true
                }
            }
        case .Text:
            d := c.renderData.text
            s := string(d.stringContents.chars[:d.stringContents.length])
            switch s {
            case "9":
                gut9_x = r.x
            case "100":
                gut100_x = r.x
            case "cc":
                line_x = r.x
            case "src/a.odin:10":
                title_x = r.x
            }
            texts += 1
        }
    }

    // The clip group is the body, under the query header.
    testing.expect_value(t, scissor, gfx.Rect{AREA.x, AREA.y + ROW_H, AREA.w, AREA.h - ROW_H})

    // Only the selected block's four rows band, at full pane width.
    testing.expect_value(t, rects, 4)
    testing.expect(t, row_seen[0] && row_seen[3], "the selected block did not band")
    testing.expect(t, !row_seen[4] && !row_seen[5], "a row outside the selected block banded")
    testing.expect_value(t, row_box[2], gfx.Rect{AREA.x, AREA.y + ROW_H + 2 * ROW_H, AREA.w, ROW_H})

    // Exactly one Border, on the match line of the selected block, at the row's left edge. A
    // left-only border is why the bridge skips zero-width edges.
    testing.expect_value(t, borders, 1)
    testing.expect_value(t, border_box, row_box[2])

    // Title flush at the one-cell margin, gutter right-aligned in three cells, line text one
    // cell past it.
    testing.expect_value(t, title_x, AREA.x + 10)
    testing.expect_value(t, gut100_x, AREA.x + 10) // 3 runes fills the column
    testing.expect_value(t, gut9_x, AREA.x + 30) // 1 rune, pushed right
    testing.expect_value(t, line_x, AREA.x + 50) // margin + 3-cell gutter + 1-cell gap

    // Virtualisation: the 9th row is off the bottom, and spacers contribute no text.
    testing.expect_value(t, texts, 13) // header + 2 titles + 5 gutters + 5 lines
}

// A click anywhere in a block selects the BLOCK: the row it landed on is a detail of how a hit
// is displayed, and Up/Down already move by block.
@(test)
test_grep_hit_resolves_to_block :: proc(t: ^testing.T) {
    raw := clay_test_context(500, 300)
    defer clay_test_context_free(raw)
    f := clay_test_face()
    ui.clay_use_face(&f)

    a: app.App
    a.scale = 1
    a.face = clay_test_face()
    c0 := [?]string{"aa", "bb", "cc"}
    c1 := [?]string{"dd", "ee"}
    fixture(&a, c0[:], c1[:])
    defer delete(a.grep.hits)

    rows := search.grep_rows(&a.grep, a.project_root, context.temp_allocator)
    _ = app.grep_layout(&a, f, PANE, rows, 500, 300) // frame 1: boxes to hit

    body_y :: AREA.y + ROW_H // the first display row

    // Row 3, the LAST context line of block 0, still resolves to block 0.
    clay.SetPointerState({f32(AREA.x + 50), f32(body_y + 3 * ROW_H + 4)}, false)
    _ = app.grep_layout(&a, f, PANE, rows, 500, 300)
    testing.expect_value(t, app.grep_hit(rows, 0, MAX_ROWS), 0)

    // Row 6, a context line of the second block, resolves to block 1.
    clay.SetPointerState({f32(AREA.x + 50), f32(body_y + 6 * ROW_H + 4)}, false)
    _ = app.grep_layout(&a, f, PANE, rows, 500, 300)
    testing.expect_value(t, app.grep_hit(rows, 0, MAX_ROWS), 1)

    // Row 4, the blank spacer, is dead space.
    clay.SetPointerState({f32(AREA.x + 50), f32(body_y + 4 * ROW_H + 4)}, false)
    _ = app.grep_layout(&a, f, PANE, rows, 500, 300)
    testing.expect_value(t, app.grep_hit(rows, 0, MAX_ROWS), -1)

    // The query header is not a row, and neither is anywhere off the pane.
    clay.SetPointerState({f32(AREA.x + 50), f32(AREA.y + 4)}, false)
    _ = app.grep_layout(&a, f, PANE, rows, 500, 300)
    testing.expect_value(t, app.grep_hit(rows, 0, MAX_ROWS), -1)
}

// A press is taken only when it hit something, so one aimed elsewhere stays available.
@(test)
test_grep_click_selects :: proc(t: ^testing.T) {
    a: app.App
    a.mouse_on = true
    c0 := [?]string{"aa", "bb", "cc"}
    c1 := [?]string{"dd", "ee"}
    fixture(&a, c0[:], c1[:])
    defer delete(a.grep.hits)

    a.mouse.click = true
    a.mouse.click_count = 1
    app.grep_click(&a, 1)
    testing.expect_value(t, a.grep.selected, 1)
    testing.expect(t, !a.mouse.click, "a click that hit a block must be claimed")

    a.mouse.click = true
    app.grep_click(&a, -1)
    testing.expect_value(t, a.grep.selected, 1)
    testing.expect(t, a.mouse.click, "a click that hit nothing must not be claimed")

    // A block index past the end cannot select: the rows and the hits are rebuilt at different
    // moments, so this is a real ordering hazard.
    a.mouse.click = true
    app.grep_click(&a, 99)
    testing.expect_value(t, a.grep.selected, 1)

    a.mouse_on = false
    a.mouse.click = true
    app.grep_click(&a, 0)
    testing.expect_value(t, a.grep.selected, 1)
}
